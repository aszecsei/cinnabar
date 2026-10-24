# Content pipeline

`tools/cook` compiles source assets into blobs. Development builds read blobs from a loose cache, and release builds read them from bundles. See [Architecture](architecture.md#content-pipeline) for the overview.

## Identity

Every source asset has a GUID, stored in a `.meta` sidecar file next to it with its import settings. The cooker assigns a GUID the first time it sees an asset. Renames and moves keep the GUID as long as the `.meta` file moves too, and the editor makes sure it does. Content refers to other content only by GUID.

- A GUID is 128 random bits, written as 32 hex digits. Engine content (such as the script prelude) has fixed GUIDs in committed `.meta` files.
- A `.meta` file has lines of `key = value`, and `#` comments. `guid` is required. The other keys are import settings. When the cooker finds an asset without a `.meta` file, it writes one. Commit it with the asset.
- Two assets with the same GUID are a cook error. This happens when an asset is copied with its `.meta` file. Delete the copy's `.meta` file to give it a new GUID.
- Each game has one content root, `samples/<game>/content/`. Engine content is in `lib/engine/content/`. The cooker takes each root with a name, such as `--root game=samples/mygame/content`, and an asset's source path is the root's name and its path in the root, such as `game/scripts/hello.luau`.
- At runtime, a loaded asset is a generational handle in the asset runtime's table. Persistent state holds handles or GUIDs, never pointers into blobs (see [Hot reload](hot-reload.md#rules)).

## Cooking

- **Shared schemas:** `tools/cook` imports the same asset-type package from `lib/engine` that the runtime uses, `lib/engine/asset/format`, so their struct layouts cannot diverge. That package imports nothing from `lib/core`. Each asset type's version comes from its layout hash, so changing a type invalidates its cache entries.
- **Incremental cooking:** a cache key is a hash of the source files, the import settings and the cooker version.
- **Shaders** are HLSL. `tools/cook` compiles them with DXC to DXIL for D3D12. A Vulkan port adds SPIR-V from DXC, and a Metal port adds a metallib from `metal-shaderconverter`. All shaders use one fixed bindless root signature (see [GPU](gpu.md#binding-model)), and the cooker rejects a shader that does not fit it. The runtime never compiles or reflects shaders. The DXC version is part of the cache key. For now the cooker cooks only shaders, and writes each output next to its source with its cache key in `<output>.key` (see [GPU](gpu.md#shaders)).

### Scripts

Scripts are `.luau` files. `just scripts` runs `cook scripts --cache build/cache --config dev|release --root game=<content root>`. `tools/cook` links the Luau compiler, parser and analyzer from `vendor/luau`, the same commit that the runtime uses. The parser and the analyzer have no C API, so `luau_tools` (`lib/core/luau/luau_tools.cpp`) exposes what the cooker needs as C functions.

For each script, the cooker:

1. Finds every call of the global `require` with Luau's parser, so comments and strings never look like requires. A `require` whose argument is not one string literal is an error.
2. Resolves every `require` string to a GUID, with Luau's rules (see [Scripting](scripting.md#modules-and-require)). A missing module, a path that names both `x.luau` and `x/init.luau`, or a cycle is an error.
3. Type checks the module against the engine definition file (see [Scripting](scripting.md#types-and-tooling)) and the modules it requires. *Not yet: phase 5.*
4. Compiles it with `luau_compile`. Development uses optimization level 1 and debug level 2. Release uses optimization level 2 and debug level 1.
5. Runs its top level in a sandboxed VM with the prelude and no native bindings. If it returns a behaviour class, the cooker records the field schema. *Not yet: phase 4.*
6. Writes the blob to a temporary file and renames it, so the running game never reads a partial blob.

The cache key includes the source, the `.meta` file, the cooker version, the Luau version, the build configuration, the source path, and the GUID that each require resolves to. With type checking, it will also include the definition file and the sources of every module that the script requires, directly or not, because the type check depends on them.

Script import settings in `.meta`: `native = true` compiles the module to machine code at load. An unknown setting is a warning.

## Blob format

Compiled blobs use offsets instead of pointers. The runtime can map a blob and use it without parsing. Blobs are aligned for direct GPU upload and compressed individually. *Compression comes with bundles.*

Every blob starts with a header: the magic `CNB1`, the asset kind, the layout hash of the kind's structures, the cache key and the GUID. The runtime rejects a blob whose layout hash differs from its own, and the cooker reads the key to find blobs that are up to date. The runtime loads blobs at 16-byte alignment.

A script blob holds:

| Part | Contents |
|---|---|
| Header | The blob header, and flags (`Native`, `Behaviour`) |
| Bytecode | The output of `luau_compile` |
| Requires | Sorted pairs of require string and target GUID |
| Fields | For a behaviour: class name, and each field's name, type and default value |
| Source path | The root's name and the path in the root. Error messages and tracebacks use it as the chunk name. |

## Loading

- **Two sources, one format:** the asset runtime (`lib/engine/asset`) reads through `asset.Source`, a union with two backends, so it holds no procedure pointers. `Loose_Cache` is used in development and `Bundle` is used in release. Both read the same blob format. *Until bundles exist, release builds read the release loose cache.*
- **Loose cache:** one blob per asset, `build/cache/<config>/<guid>.blob`. The cooker overwrites a blob when its cache key changes. The runtime reads files through `file_read` and `file_modified` in `Platform_API`, and keeps blobs in memory from `asset_allocator`, the host's heap.
- **Handles:** `asset.load` returns a generational handle, and the same handle for an asset that is already loaded. A handle to an unloaded asset is detected. The asset table lives in `Game_State`, so a code reload keeps every loaded asset. A soft restart loads them again.
- **Bundles** (`*.cbb`) contain a header, a table of contents sorted by GUID, and aligned blobs. A bundle is a load unit (global, per-level, or a streaming chunk), and it lists the bundles it depends on.
- **Asset hot reload:** in development, the cook daemon watches the content roots and tells the running game when a blob changes. The asset runtime swaps the data behind the asset's generational handle at the end of the frame. Until the daemon exists, `asset.poll` checks the modification time of each loaded blob, at most every 0.25 s, and the game calls it at the end of each frame. A script swap reaches the script runtime, which reloads the module (see [Scripting](scripting.md#script-hot-reload)).
- **Scripts load on demand.** A script blob stays loaded while its module is loaded. The VM holds the module's result, not the blob, so the blob can be swapped under it.
