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

    bool visit(Luau::AstExprCall* call) override
    {
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
// does not parse; the errors are reported through onError.
CN_LUAU_API bool cn_luau_find_requires(const char* source, size_t size, void* ud, cn_luau_require_fn onRequire, cn_luau_error_fn onError)
{
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
    return true;
}
