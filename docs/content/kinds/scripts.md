# Scripts

Scripts are `.luau` files. `just scripts` runs `cook scripts --cache build/<target>/content --config dev|release --root game=<content root>`. `tools/cook` links the Luau compiler, parser and analyzer from `vendor/luau`, the same commit that the runtime uses. The parser and the analyzer have no C API, so `luau_tools` (`lib/core/luau/luau_tools.cpp`) exposes what the cooker needs as C functions.

For each script, the cooker:

1. Finds every call of the global `require` with Luau's parser, so comments and strings never look like requires. A `require` whose argument is not one string literal is an error. The parser also tells whether the script calls `Behaviour.define`.
2. Resolves every `require` string to a GUID, with Luau's rules (see [Scripting](../../scripting/tooling-and-hot-reload.md#modules-and-require)). A missing module, a path that names both `x.luau` and `x/init.luau`, or a cycle is an error.
3. Type checks the module against the definition file that `--definitions` names (see [Scripting](../../scripting/tooling-and-hot-reload.md#types-and-tooling)), and the modules it requires, with Luau's analyzer. The cooker gives the analyzer every module's source and resolved requires, so it reads no files. A type error is a cook error.
4. Compiles it with `luau_compile`. Development uses optimization level 1 and debug level 2. Release uses optimization level 2 and debug level 1.
5. For a script that calls `Behaviour.define`: runs its top level in a sandboxed VM with the Luau libraries, the prelude (`lib/engine/script/prelude.luau`) and a `require` that follows the resolved requires, but no engine. If it returns a behaviour class, the cooker records the class name and the fields (see [Scripting](../../scripting/behaviours.md#behaviours)).
6. Writes the blob to a temporary file and renames it, so the running game never reads a partial blob.

A script that fails keeps its old blob, so the running game keeps the last good version. Every script that requires it, directly or not, also keeps its old blob, with an error that names the script it requires. The other scripts still cook. Every script in a require cycle fails.

The cache key includes the source, the `.meta` file, the cooker version, the Luau version, the build configuration, the source path, the GUID that each require resolves to, the prelude, the definition file, and the sources of every module that the script requires, directly or not. A behaviour's field defaults and the type check depend on those modules, so a changed dependency cooks its dependents again.

Script import settings in `.meta`: `native = true` compiles the module to machine code at load, like a `--!native` comment at the top of the source. Each importer has a table of the settings that it takes, with their values, defaults and descriptions (`import_settings` in `tools/cook`). Every cook checks the `.meta` files with it: an unknown setting is a warning, and a value that the setting does not take is an error. The daemon sends the table to the editor, which shows an editor for each setting.
