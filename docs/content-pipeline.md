# Content pipeline

`tools/cook` compiles source assets into blobs. Development builds read blobs from a loose cache, and release builds read them from bundles. See [Architecture](architecture.md#content-pipeline) for the overview.

## Identity

Every source asset has a GUID, stored in a `.meta` sidecar file next to it with its import settings. The cooker assigns a GUID the first time it sees an asset. Renames and moves keep the GUID as long as the `.meta` file moves too, and the editor makes sure it does. Content refers to other content only by GUID.

- A GUID is 128 random bits. Engine content (such as the script prelude) has fixed GUIDs in committed `.meta` files.
- Each game has one content root, `samples/<game>/content/`. Engine content is in `lib/engine/content/`.
- At runtime, a loaded asset is a generational handle in the asset runtime's table. Persistent state holds handles or GUIDs, never pointers into blobs (see [Hot reload](hot-reload.md#rules)).

## Cooking

- **Shared schemas:** `tools/cook` imports the same asset-type package from `lib/engine` that the runtime uses, so their struct layouts cannot diverge. Each asset type's version comes from its layout hash, so changing a type invalidates its cache entries.
- **Incremental cooking:** a cache key is a hash of the source files, the import settings and the cooker version.
- **Shaders** are HLSL. `tools/cook` compiles them with DXC to DXIL for D3D12. A Vulkan port adds SPIR-V from DXC, and a Metal port adds a metallib from `metal-shaderconverter`. All shaders use one fixed bindless root signature (see [GPU](gpu.md#binding-model)), and the cooker rejects a shader that does not fit it. The runtime never compiles or reflects shaders. The DXC version is part of the cache key. For now the cooker cooks only shaders, and writes each output next to its source with its cache key in `<output>.key` (see [GPU](gpu.md#shaders)).

### Scripts

Scripts are `.luau` files. `tools/cook` links the Luau compiler and analyzer from `vendor/luau`, the same commit that the runtime uses. The analyzer has no C API, so a small C++ shim in `tools/cook` exposes type checking as one C function.

For each script, the cooker:

1. Resolves every `require` string to a GUID, relative to the file or through a `.luaurc` alias. A missing module or a cycle is an error.
2. Type checks the module against the engine definition file (see [Scripting](scripting.md#types-and-tooling)) and the modules it requires.
3. Compiles it with `luau_compile`. Development uses optimization level 1 and debug level 2. Release uses optimization level 2 and debug level 1.
4. Runs its top level in a sandboxed VM with the prelude and no native bindings. If it returns a behaviour class, the cooker records the field schema.
5. Writes the blob.

The cache key includes the source, the `.meta` settings, the cooker version, the Luau version, the build configuration, the definition file, and the sources of every module that the script requires, directly or not. The type check depends on them, so a changed dependency cooks its dependents again.

Script import settings in `.meta`: `native` (compile to machine code at load) and `mode` (the default type checking mode, if `.luaurc` does not set it).

## Blob format

Compiled blobs use offsets instead of pointers. The runtime can map a blob and use it without parsing. Blobs are aligned for direct GPU upload and compressed individually.

A script blob holds:

| Part | Contents |
|---|---|
| Header | Magic, layout hash, GUID, flags (`Native`, `Behaviour`) |
| Bytecode | The output of `luau_compile` |
| Requires | Sorted pairs of require string and target GUID |
| Fields | For a behaviour: class name, and each field's name, type and default value |
| Source path | The path relative to the content root. Error messages and tracebacks use it as the chunk name. |

## Loading

- **Two sources, one format:** the asset runtime reads through an `Asset_Source` interface with two backends. `Loose_Cache` is used in development and `Bundle` is used in release. Both read the same blob format.
- **Bundles** (`*.cbb`) contain a header, a table of contents sorted by GUID, and aligned blobs. A bundle is a load unit (global, per-level, or a streaming chunk), and it lists the bundles it depends on.
- **Asset hot reload:** in development, the cook daemon watches the content roots and tells the running game when a blob changes. The asset runtime swaps the data behind the asset's generational handle at the end of the frame. Until the daemon exists, the host polls the loose cache. A script swap reaches the script runtime, which reloads the module (see [Scripting](scripting.md#script-hot-reload)).
- **Scripts load on demand.** A script blob stays loaded while its module is loaded. The VM holds the module's result, not the blob, so the blob can be swapped under it.
