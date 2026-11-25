// C helpers over Luau's C++ libraries, for tools/cook. The runtime does not link them.
#include "Luau/Ast.h"
#include "Luau/Parser.h"

#include <algorithm>
#include <string.h>
#include <vector>

// A require call with a string literal argument. line and column are 1-based, and the column counts bytes. start and
// end are the byte offsets in the source of the literal, with its quotes or brackets.
typedef void (*cn_luau_require_fn)(void* ud, const char* path, size_t size, int line, int column, size_t start, size_t end);
// A parse error, or a require call whose argument is not a string literal. line is 1-based.
typedef void (*cn_luau_error_fn)(void* ud, const char* message, size_t size, int line);
// An event handler of a behaviour class: a method on_<name>, with name without its on_. line is 1-based. The
// handler's parameters follow, each through the parameter function, without self.
typedef void (*cn_luau_handler_fn)(void* ud, const char* name, size_t size, int line);
// A parameter of the last handler, with its type annotation's text, or an empty text when it has none.
typedef void (*cn_luau_param_fn)(void* ud, const char* name, size_t size, const char* type, size_t typeSize);

namespace
{

// offsetOf turns a parser position, whose column counts bytes, into a byte offset in the source.
size_t offsetOf(const char* source, size_t size, Luau::Position position)
{
    size_t offset = 0;
    for (unsigned line = 0; line < position.line && offset < size; offset++)
    {
        if (source[offset] == '\n')
            line++;
    }
    return offset + position.column < size ? offset + position.column : size;
}

struct RequireVisitor : Luau::AstVisitor
{
    const char* source;
    size_t size;
    void* ud;
    cn_luau_require_fn onRequire;
    cn_luau_error_fn onError;
    cn_luau_handler_fn onHandler;
    cn_luau_param_fn onParam;
    bool definesClass = false;
    // The locals that hold a class from Behaviour.define, whose on_ methods are its handlers.
    std::vector<Luau::AstLocal*> classes;

    static bool isBehaviourDefine(Luau::AstExpr* expr)
    {
        Luau::AstExprCall* call = expr->as<Luau::AstExprCall>();
        Luau::AstExprIndexName* index = call ? call->func->as<Luau::AstExprIndexName>() : nullptr;
        Luau::AstExprGlobal* object = index ? index->expr->as<Luau::AstExprGlobal>() : nullptr;
        return object && strcmp(object->name.value, "Behaviour") == 0 && strcmp(index->index.value, "define") == 0;
    }

    bool visit(Luau::AstStatLocal* local) override
    {
        for (size_t i = 0; i < local->vars.size && i < local->values.size; i++)
        {
            if (isBehaviourDefine(local->values.data[i]))
                classes.push_back(local->vars.data[i]);
        }
        return true;
    }

    // function C:on_x(...) or function C.on_x(self, ...), where C holds a behaviour class. The engine's lifecycle
    // methods are not events.
    bool visit(Luau::AstStatFunction* function) override
    {
        Luau::AstExprIndexName* index = function->name->as<Luau::AstExprIndexName>();
        Luau::AstExprLocal* object = index ? index->expr->as<Luau::AstExprLocal>() : nullptr;
        if (!object || strncmp(index->index.value, "on_", 3) != 0)
            return true;
        if (std::find(classes.begin(), classes.end(), object->local) == classes.end())
            return true;
        const char* name = index->index.value + 3;
        static const char* const lifecycle[] = {"", "enable", "disable", "destroy", "reload"};
        for (const char* l : lifecycle)
        {
            if (strcmp(name, l) == 0)
                return true;
        }
        Luau::AstExprFunction* func = function->func;
        size_t first = 0;
        if (index->op == '.')
        {
            // The explicit self is not a parameter that an event fills.
            if (func->args.size == 0 || strcmp(func->args.data[0]->name.value, "self") != 0)
                return true;
            first = 1;
        }
        onHandler(ud, name, strlen(name), int(function->location.begin.line) + 1);
        for (size_t i = first; i < func->args.size; i++)
        {
            Luau::AstLocal* arg = func->args.data[i];
            size_t start = 0, end = 0;
            if (arg->annotation)
            {
                start = offsetOf(source, size, arg->annotation->location.begin);
                end = offsetOf(source, size, arg->annotation->location.end);
            }
            onParam(ud, arg->name.value, strlen(arg->name.value), source + start, end - start);
        }
        return true;
    }

    bool visit(Luau::AstExprCall* call) override
    {
        // Behaviour.define(...) or Action.define(...)
        if (Luau::AstExprIndexName* index = call->func->as<Luau::AstExprIndexName>())
        {
            Luau::AstExprGlobal* object = index->expr->as<Luau::AstExprGlobal>();
            if (object && (strcmp(object->name.value, "Behaviour") == 0 || strcmp(object->name.value, "Action") == 0) &&
                strcmp(index->index.value, "define") == 0)
                definesClass = true;
        }

        Luau::AstExprGlobal* global = call->func->as<Luau::AstExprGlobal>();
        if (global && strcmp(global->name.value, "require") == 0)
        {
            int line = int(call->location.begin.line) + 1;
            Luau::AstExprConstantString* path = call->args.size == 1 ? call->args.data[0]->as<Luau::AstExprConstantString>() : nullptr;
            if (path)
            {
                Luau::Location at = path->location;
                onRequire(
                    ud, path->value.data, path->value.size, int(at.begin.line) + 1, int(at.begin.column) + 1, offsetOf(source, size, at.begin),
                    offsetOf(source, size, at.end)
                );
            }
            else
            {
                static const char message[] = "require takes one string literal";
                onError(ud, message, sizeof(message) - 1, line);
            }
        }
        return true;
    }
};

} // namespace

// cn_luau_find_requires parses source and reports every call to the global require. It returns false if the source
// does not parse; the errors are reported through onError. definesClass is set if the source calls
// Behaviour.define or Action.define, and native if it starts with a --!native comment. It also reports the event
// handlers of the behaviour classes that the source defines, in the source's order, through onHandler and onParam.
CN_LUAU_API bool cn_luau_find_requires(
    const char* source, size_t size, void* ud, cn_luau_require_fn onRequire, cn_luau_error_fn onError, cn_luau_handler_fn onHandler,
    cn_luau_param_fn onParam, bool* definesClass, bool* native
)
{
    *definesClass = false;
    *native = false;
    Luau::Allocator allocator;
    Luau::AstNameTable names(allocator);
    Luau::ParseResult result = Luau::Parser::parse(source, size, names, allocator);
    for (const Luau::ParseError& error : result.errors)
    {
        const std::string& message = error.getMessage();
        onError(ud, message.data(), message.size(), int(error.getLocation().begin.line) + 1);
    }
    if (!result.errors.empty())
        return false;

    RequireVisitor visitor;
    visitor.source = source;
    visitor.size = size;
    visitor.ud = ud;
    visitor.onRequire = onRequire;
    visitor.onError = onError;
    visitor.onHandler = onHandler;
    visitor.onParam = onParam;
    result.root->visit(&visitor);
    *definesClass = visitor.definesClass;
    for (const Luau::HotComment& comment : result.hotcomments)
    {
        if (comment.header && comment.content == "native")
            *native = true;
    }
    return true;
}

// The type checker. The cooker gives it every module's source, mode and resolved requires, so it never reads files.
#include "Luau/BuiltinDefinitions.h"
#include "Luau/Frontend.h"

#include <string>
#include <unordered_map>

// A type error in a module. line and column are 1-based.
typedef void (*cn_luau_type_error_fn)(void* ud, const char* module, size_t moduleSize, int line, int column, const char* message, size_t size);

namespace
{

struct CheckerModule
{
    std::string source;
    Luau::Mode mode;
    std::unordered_map<std::string, std::string> requireMap;
};

struct CheckerFiles : Luau::FileResolver, Luau::ConfigResolver
{
    std::unordered_map<std::string, CheckerModule> modules;
    mutable Luau::Config config;

    std::optional<Luau::SourceCode> readSource(const Luau::ModuleName& name) override
    {
        auto it = modules.find(name);
        if (it == modules.end())
            return std::nullopt;
        return Luau::SourceCode{it->second.source, Luau::SourceCode::Module};
    }

    std::optional<Luau::ModuleInfo> resolveModule(const Luau::ModuleInfo* context, Luau::AstExpr* expr, const Luau::TypeCheckLimits&) override
    {
        Luau::AstExprConstantString* path = expr->as<Luau::AstExprConstantString>();
        if (!context || !path)
            return std::nullopt;
        auto from = modules.find(context->name);
        if (from == modules.end())
            return std::nullopt;
        auto to = from->second.requireMap.find(std::string(path->value.data, path->value.size));
        if (to == from->second.requireMap.end())
            return std::nullopt;
        return Luau::ModuleInfo{to->second};
    }

    const Luau::Config& getConfig(const Luau::ModuleName& name, const Luau::TypeCheckLimits&) const override
    {
        auto it = modules.find(name);
        config.mode = it != modules.end() ? it->second.mode : Luau::Mode::Nonstrict;
        return config;
    }
};

} // namespace

struct cn_luau_checker
{
    CheckerFiles files;
    Luau::Frontend frontend;
    bool frozen = false;

    cn_luau_checker()
        : frontend(Luau::SolverMode::Old, &files, &files)
    {
        Luau::registerBuiltinGlobals(frontend, frontend.globals);
    }
};

CN_LUAU_API cn_luau_checker* cn_luau_checker_create()
{
    return new cn_luau_checker();
}

CN_LUAU_API void cn_luau_checker_destroy(cn_luau_checker* checker)
{
    delete checker;
}

// cn_luau_checker_define loads a definition file into the global scope. It returns false, and reports the errors,
// if the file does not load. Call it before the first check.
CN_LUAU_API bool cn_luau_checker_define(cn_luau_checker* checker, const char* source, size_t size, void* ud, cn_luau_error_fn onError)
{
    Luau::LoadDefinitionFileResult result = checker->frontend.loadDefinitionFile(
        checker->frontend.globals, checker->frontend.globals.globalScope, std::string_view(source, size), "@cinnabar", false
    );
    for (const Luau::ParseError& error : result.parseResult.errors)
        onError(ud, error.getMessage().data(), error.getMessage().size(), int(error.getLocation().begin.line) + 1);
    if (result.module)
    {
        for (const Luau::TypeError& error : result.module->errors)
        {
            std::string message = Luau::toString(error);
            onError(ud, message.data(), message.size(), int(error.location.begin.line) + 1);
        }
    }
    return result.success;
}

// mode: 0 for nocheck, 1 for nonstrict, 2 for strict. A --! comment in the source overrides it.
CN_LUAU_API void cn_luau_checker_add_module(cn_luau_checker* checker, const char* name, size_t nameSize, const char* source, size_t size, int mode)
{
    CheckerModule& module = checker->files.modules[std::string(name, nameSize)];
    module.source.assign(source, size);
    module.mode = mode == 0 ? Luau::Mode::NoCheck : mode == 1 ? Luau::Mode::Nonstrict : Luau::Mode::Strict;
}

CN_LUAU_API void cn_luau_checker_add_require(
    cn_luau_checker* checker, const char* from, size_t fromSize, const char* path, size_t pathSize, const char* to, size_t toSize
)
{
    checker->files.modules[std::string(from, fromSize)].requireMap[std::string(path, pathSize)] = std::string(to, toSize);
}

// cn_luau_checker_check type checks a module, and the modules it requires, and reports the errors in the module. It
// returns the number of errors.
CN_LUAU_API int cn_luau_checker_check(cn_luau_checker* checker, const char* name, size_t nameSize, void* ud, cn_luau_type_error_fn onError)
{
    if (!checker->frozen)
    {
        Luau::freeze(checker->frontend.globals.globalTypes);
        checker->frozen = true;
    }
    std::string moduleName(name, nameSize);
    int count = 0;
    try
    {
        Luau::CheckResult result = checker->frontend.check(moduleName);
        for (const Luau::TypeError& error : result.errors)
        {
            if (error.moduleName != moduleName)
                continue;
            std::string message;
            if (const Luau::SyntaxError* syntax = Luau::get_if<Luau::SyntaxError>(&error.data))
                message = syntax->message;
            else
                message = Luau::toString(error, Luau::TypeErrorToStringOptions{&checker->files});
            onError(ud, moduleName.data(), moduleName.size(), int(error.location.begin.line) + 1, int(error.location.begin.column) + 1, message.data(), message.size());
            count += 1;
        }
    }
    catch (const std::exception& e)
    {
        std::string message = std::string("the type checker failed: ") + e.what();
        onError(ud, moduleName.data(), moduleName.size(), 1, 1, message.data(), message.size());
        count += 1;
    }
    return count;
}
