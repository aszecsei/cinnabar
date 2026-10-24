// C helpers over Luau's C++ libraries, for tools/cook. The runtime does not link them.
#include "Luau/Ast.h"
#include "Luau/Parser.h"

#include <string.h>

// A require call with a string literal argument. line is 1-based.
typedef void (*cn_luau_require_fn)(void* ud, const char* path, size_t size, int line);
// A parse error, or a require call whose argument is not a string literal. line is 1-based.
typedef void (*cn_luau_error_fn)(void* ud, const char* message, size_t size, int line);

namespace
{

struct RequireVisitor : Luau::AstVisitor
{
    void* ud;
    cn_luau_require_fn onRequire;
    cn_luau_error_fn onError;
    bool definesBehaviour = false;

    bool visit(Luau::AstExprCall* call) override
    {
        // Behaviour.define(...)
        if (Luau::AstExprIndexName* index = call->func->as<Luau::AstExprIndexName>())
        {
            Luau::AstExprGlobal* object = index->expr->as<Luau::AstExprGlobal>();
            if (object && strcmp(object->name.value, "Behaviour") == 0 && strcmp(index->index.value, "define") == 0)
                definesBehaviour = true;
        }

        Luau::AstExprGlobal* global = call->func->as<Luau::AstExprGlobal>();
        if (global && strcmp(global->name.value, "require") == 0)
        {
            int line = int(call->location.begin.line) + 1;
            Luau::AstExprConstantString* path = call->args.size == 1 ? call->args.data[0]->as<Luau::AstExprConstantString>() : nullptr;
            if (path)
            {
                onRequire(ud, path->value.data, path->value.size, line);
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
// does not parse; the errors are reported through onError. definesBehaviour is set if the source calls
// Behaviour.define, and native if it starts with a --!native comment.
CN_LUAU_API bool cn_luau_find_requires(
    const char* source, size_t size, void* ud, cn_luau_require_fn onRequire, cn_luau_error_fn onError, bool* definesBehaviour, bool* native
)
{
    *definesBehaviour = false;
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
    visitor.ud = ud;
    visitor.onRequire = onRequire;
    visitor.onError = onError;
    result.root->visit(&visitor);
    *definesBehaviour = visitor.definesBehaviour;
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
