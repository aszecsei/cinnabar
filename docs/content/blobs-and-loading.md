# Blobs and loading

The blob format every kind shares, and how the asset runtime loads blobs from the loose cache or, later, from bundles, and hot-reloads them.

**In this document:** [Blob format](#blob-format) · [Loading](#loading) · [Future work](README.md#future-work)

## Blob format

Compiled blobs use offsets instead of pointers. The runtime can map a blob and use it without parsing. Blobs are aligned for direct GPU upload and compressed individually. *Compression comes with bundles.*

Every blob starts with a header: the magic `CNB1`, the asset kind, the layout hash of the kind's structures, the cache key and the GUID. The runtime rejects a blob whose layout hash differs from its own, and the cooker reads the key to find blobs that are up to date. The runtime loads blobs at 16-byte alignment.

A script blob holds:

| Part | Contents |
|---|---|
| Header | The blob header, and flags (`Native`, `Behaviour`) |
| Bytecode | The output of `luau_compile` |
| Requires | Sorted pairs of require string and target GUID |
| Fields | For a behaviour (flag `Behaviour`): the class name, and each field's name, kind and default, sorted by name |
| Source path | The root's name and the path in the root. Error messages and tracebacks use it as the chunk name. |

A scene blob holds a table of entities: the scene ID, the parent's scene ID, the name, the active flag, and slices of component and behaviour records. A component record has the stable ID and the name. A behaviour record has the script's GUID. Each has a slice of field records: the hash of the field's name, the name for messages, and the tagged value. The loader in `lib/engine/scene` matches the hashes to the fields of the registered types.

A shader blob holds a table of entries. Each entry has a stage (`Vertex`, `Pixel`, `Compute`, `Amplification`, `Mesh` or `Library`), a target (`DXIL` first) and a slice of bytecode. It ends with the source path.

A texture blob holds the format, the size, the mip count, the usage, and the whole mip chain: each mip tightly packed, mip 0 first. That is the layout that `gpu_stream_texture` takes (see [GPU](../gpu/queues-streaming-readback.md#streaming)), so the blob's data streams without a copy.

A material blob holds its flags (two-sided, casts shadows, no lighting, reads time, sorted), its blend and cutoff, its parameters (name, type and offset), its switches' names and defaults, its default parameter block and its textures (each one's offset, its asset or its default), and its variants: each has a switch mask, a pass (`Forward`, `Prepass`, `Depth`, `Moments`, `Transparent` or `Transparent_Ids`) and a stage, and its bytecode. A material instance blob holds its material's GUID, its switches, and its resolved block and textures.

A mesh blob holds its flags (a second UV set, a vertex color, 32-bit indices), the vertex and index counts, the bounds, a table of submeshes (the material slot's name, the index range, the meshlet range and the bounds), then the position stream, the attribute stream, the indices, and the meshlets: their vertex lists, their triangles packed as three bytes each, and their spheres and cones, with the cone in `snorm8`. It ends with the mesh's name and the model's path. Each stream starts at 16 bytes, so each streams straight into a buffer. A model has no blob.

The format package has its own enum of texture formats, because it imports nothing from `lib/core/gpu`. The runtime maps it to `gpu.Format`.

## Loading

- **Two sources, one format:** the asset runtime (`lib/engine/asset`) reads through `asset.Source`, a union with two backends, so it holds no procedure pointers. `Loose_Cache` is used in development and `Bundle` is used in release. Both read the same blob format. *Until bundles exist, release builds read the release loose cache.*
- **Loose cache:** one blob per asset, `build/cache/<config>/<guid>.blob`. The cooker overwrites a blob when its cache key changes. The runtime reads files through `file_read` and `file_modified` in `Platform_API`, and keeps blobs in memory from `asset_allocator`, the host's heap.
- **Handles:** `asset.load` returns a generational handle, and the same handle for an asset that is already loaded. A handle to an unloaded asset is detected. The asset table lives in `Game_State`, so a code reload keeps every loaded asset. A soft restart loads them again.
- **Bundles** (`*.cbb`) contain a header, a table of contents sorted by GUID, and aligned blobs. A bundle is a load unit (global, per-level, or a streaming chunk), and it lists the bundles it depends on.
- **Asset hot reload:** in development, after a cook writes blobs, it writes a counter to `build/cache/<config>/.generation`, through a temporary file and a rename. The cook daemon and the batch commands both do this. The game calls `asset.poll` at the end of each frame, and `poll` checks the counter's modification time. When the counter changes, `poll` checks the modification time of each loaded blob, and swaps every new blob behind its generational handle in that frame. A script and the modules that it requires therefore change together. The game learns of new blobs only through the cache, so it needs no connection to the daemon, and hot reload works with or without the editor. The game passes `poll`'s result to `script.reload_changed`, which reloads the scripts among the swapped blobs (see [Scripting](../scripting/tooling-and-hot-reload.md#script-hot-reload)).
- **GPU data:** the asset runtime keeps blobs on the CPU and knows nothing about the GPU. The renderer keeps a residency table (see [Rendering](../rendering/assets.md#gpu-residency)), which creates and streams the GPU resources of texture and mesh assets.
- **Scripts load on demand.** A script blob stays loaded while its module is loaded. The VM holds the module's result, not the blob, so the blob can be swapped under it.

## Future work

- **Bundles and compression.** Release builds still read the release loose cache. A bundle (`*.cbb`) is a header, a table of contents sorted by GUID, and aligned, individually compressed blobs; one bundle per load unit, with the bundles it depends on. `asset.Source` already has the `Bundle` arm. Do this before any release build leaves the machine it was built on, because a loose cache of thousands of files is slow to install and easy to corrupt.
- **Cooked pipelines.** Pipeline descriptions stay in game code until the asset runtime can load cooked pipeline assets (see [GPU](../gpu/shaders.md#shaders)). A pipeline asset would name its shaders and fixed-function state, so a game adds a pass without code. Do this once more than the renderer's own pipelines exist.
- **SPIR-V and metallib entries.** A port adds more entries to the same shader blob, from DXC's SPIR-V output or `metal-shaderconverter`, with a target beside `DXIL`. The blob layout reserves the target field for it (see [GPU](../gpu/README.md#future-work)).
