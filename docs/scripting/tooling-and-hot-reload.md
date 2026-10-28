# Tooling and hot reload

Modules and `require`, the type definitions that the cooker checks against and `luau-lsp` reads, script hot reload, and native code generation.

**In this document:** [Modules and `require`](#modules-and-require) · [Types and tooling](#types-and-tooling) · [Script hot reload](#script-hot-reload) · [Native code generation](#native-code-generation)

## Modules and `require`

- A module is one script asset. `require` takes a path relative to the requiring file (`"./util"`), or an alias from `.luaurc` (`"@game/ai/brain"`, `"@engine/Behaviour"`). These are the conventions that `luau-lsp` understands.
- **The cooker resolves every `require`.** The blob stores a map from each require string to the target's GUID. The runtime never searches a path. A missing module or a require cycle is a cook error.
- **Luau's rules:** a file `a/b.luau` is the module `a/b`, and `a/init.luau` is the module `a`. `./` and `../` start at the module's parent, so in `a/init.luau`, `./x` is a sibling of `a`. `@self/` starts at the module itself. Any other `@alias/` starts at the directory that the nearest `.luaurc` names for the alias, relative to that `.luaurc`. Alias names are not case-sensitive.
- `script.spawn_script` runs a script asset on its own sandboxed thread. Its chunk name is `@` and its source path, such as `@game/scripts/hello.luau`.
- `require` is one global binding. It finds the calling module from the caller's chunk name, and looks the path up in that module's map, so a module's functions resolve requires against their own module, wherever they are called from.
- Each module runs once, on its first require, on the requiring thread, in its own environment that reads through to the shared globals. A module must not yield at its top level. Its result is cached by GUID, and a module that returns nothing gives `true`. A module that raises an error at its top level is not cached, so a later require runs it again.

## Types and tooling

- **Definitions come from the bindings.** Type info for game-side types exists only in the DLL (see [Editor](../editor/link.md#editor-link)). `just script-types` runs `host.exe --emit-script-types <file>`, which calls `Game_API.script_types`. That procedure makes a world and a script runtime of its own, runs the game's registrations, and returns `script.definitions`, so it needs no game state and makes no GPU resources. The file goes to `build/obj/script-types/cinnabar.d.luau`.
- **What the file holds:**
  - The engine's API from `lib/engine/script/engine.d.luau`, which is written by hand.
  - `Entity`, whose `get` and `add` are overloaded for each exposed component.
  - `Key`.
  - Each exposed component: `HealthType` for the global `Health`, and `HealthRef` with the fields' types. An enum field is a union of its value names, so a typo is a type error.
  - The game's bindings, with the signature that the game passes to `define`, such as `script.define(r, "Game.frame", procedure, "() -> number")`. A binding without a signature takes and returns `any`.
- **Behaviours are loosely typed.** `Behaviour.define` returns `{ [any]: any }`, so methods can be defined on the class, and `self` and instances are untyped.
- `luau-lsp` reads the definition file and `.luaurc`, so editors get completion and type errors. The repository does not keep editor settings, so set it up yourself. It needs the standard platform, the definition file, the old type solver (see below), and no Rojo sourcemap. In VS Code, add this to `.vscode/settings.json`:

  ```jsonc
  {
  	"luau-lsp.platform.type": "standard",
  	"luau-lsp.types.definitionFiles": {
  		"@cinnabar": "build/obj/script-types/cinnabar.d.luau"
  	},
  	"luau-lsp.fflags.override": {
  		"LuauSolverV2": "false"
  	},
  	"luau-lsp.sourcemap.enabled": false
  }
  ```
- **`tools/cook` type checks** each script that it cooks against the same file (see [Content pipeline](../content/kinds/scripts.md#scripts)). A type error is a cook error, so the script keeps its old blob, and the running game keeps the previous version. Each file's `--!strict`, `--!nonstrict` or `--!nocheck` applies, and the nearest `.luaurc`'s `languageMode` sets the default, which is nonstrict without one. Without the definition file, as on the first build, the cooker warns and does not type check. The file's hash is in each script's cache key, so the scripts are checked once it exists.
- **The old type solver.** Under the new solver, `self` in `function Door:update()` gets a type inferred from the method's body, with read-only fields, so `self.phase += 1` is an error, and every behaviour would need annotations. The old solver gives `self` the class's type. The cooker uses the old solver, and the editor setting matches it.
- **The build order:** `just build` builds the host and the game DLL, writes the definitions from the DLL, and then cooks the scripts. The DLL embeds only committed `.meta` files, so it does not wait for the cook.

## Script hot reload

In development, a changed script reloads at the end of the frame in which the asset runtime swaps its blob. The game calls `script.reload_changed(r, asset.poll(assets))` there, when no script runs.

1. The asset runtime swaps the blob behind the script's handle (see [Content pipeline](../content/blobs-and-loading.md#loading)). A script with a type error keeps its old blob, so the game never sees it.
2. The script runtime runs the new version's top level in a fresh environment. If it fails, the old version stays and the error is logged.
3. If the old and the new results are both tables, the runtime **patches the old table in place**: it copies every key of the new table, and removes keys that the new table does not have. Modules that hold the old table see the new functions, and instances keep their metatable. If either result is not a table, the cache gets the new value, and modules that required the old one keep it, with a warning.
4. For a behaviour class, the class keeps its own `__index` and `__newindex`, which find the patched methods in it. Existing instances keep their state, get the default value of each new field, and start or stop getting `update` if the new version adds or removes it. Then each instance gets `on_reload`, if the class defines it.
5. **A main script restarts.** A script from `spawn_script` is one thread whose body is its top level, so nothing can be patched: its thread stops, and the new version runs from the top. Its `Main_Script` handle stays valid. Modules reload before main scripts restart, so a restarted script requires the new versions.
6. A module that no one has required yet loads the new version when it is first required.

Consequences for scripters:

- **Keep state on instances, not in module locals.** A module's locals are created again by the new version. Old closures keep the old locals.
- **A running coroutine finishes in its old code.** Its stack holds the old functions. New coroutines run the new code.
- **A main script's state resets.** Keep long-lived state in behaviours, or in a module's table, which survives the patch.

A code reload of the DLL does not touch scripts. The VM, the instances and the coroutines stay, and `on_reload` fills the binding tables again.

## Native code generation

A module that starts with `--!native`, or that has `native = true` in its `.meta`, is compiled to machine code. The cooker sets the blob's `Native` flag for either, and the runtime calls `luau_codegen_compile` on the module after it loads, after a script hot reload too, if `luau_codegen_supported` is true. Without a code generator, the module runs as bytecode, with the same results.

- `init` creates the code generator with `luau_codegen_create`. It is part of `luau.dll`, so its executable memory survives a code reload, and `lua_close` releases it.
- Luau compiles every function of the module except the ones that it considers cold, such as the top level, which runs once.
- The watchdog still works: native code calls the interrupt callback at the same safepoints.
- The whole module is native or not. Luau's `@native` attribute on one function needs the C++ code generation API, which the bindings do not have.
- The cooker does not pass the engine's userdata type names in `userdataTypes`, so native code does not specialize userdata field access.
