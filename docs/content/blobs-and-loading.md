# Blobs and loading

The blob format every kind shares, and how the asset runtime loads blobs from the loose cache and hot-reloads them.

**In this document:** [Blob format](#blob-format) · [Loading](#loading)

## Blob format

Compiled blobs use offsets instead of pointers. The runtime can map a blob and use it without parsing. Blobs are aligned for direct GPU upload and are not compressed.

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

A shader blob holds a table of entries. Each entry has a stage (`Vertex`, `Pixel`, `Compute`, `Amplification`, `Mesh` or `Library`), a target (`DXIL`) and a slice of bytecode. It ends with the source path.

A texture blob holds the format, the usage, the dimension (`D2`, `Cube` or `D2_Array`), the layer count, each layer's size, the mip count, and every layer's whole mip chain: layer 0 first, each mip tightly packed, mip 0 first. A cube's layers are its faces, in the order +x, -x, +y, -y, +z, -z (see [Textures](kinds/textures.md#cube-maps-and-arrays)). That is the layout that `gpu_stream_texture` takes (see [GPU](../gpu/queues-streaming-readback.md#streaming)), so the blob's data streams without a copy.

A material blob holds its flags (two-sided, casts shadows, no lighting, reads time, sorted), its blend and cutoff, its parameters (name, type and offset), its switches' names and defaults, its default parameter block and its textures (each one's offset, its asset or its default), and its variants: each has a switch mask, a pass (`Forward`, `Prepass`, `Depth`, `Moments`, `Transparent` or `Transparent_Ids`) and a stage, and its bytecode. A material instance blob holds its material's GUID, its switches, and its resolved block and textures.

A mesh blob holds its flags (a second UV set, a vertex color, 32-bit indices, a skin), the vertex and index counts, the bounds, a table of submeshes (the material slot's name, the index range, the meshlet range and the bounds), then the position stream, the attribute stream, the skin stream of a skinned mesh (see [Skins and animations](kinds/skins-and-animations.md#skin-stream)), the indices, and the meshlets of every level of detail: their records, with their culling spheres in `f16`, their spheres for the level in `f32`, their cones in `snorm8` and their errors, their refs to their vertices, 16 bits where they fit, in `u32` words, and their triangles, one `u32` each (see [Meshes](kinds/meshes.md#meshlets)). Then its collision data, unless its `collision` import setting is `false`: positions welded by position alone, triangles of three `u32` over them, and each triangle's submesh as a `u16` (see [Physics: Shapes](../physics/design.md#shapes)). It ends with the mesh's name and the model's path. Each stream starts at 16 bytes, so each streams straight into a buffer. A model has no blob.

A skin blob holds its joints, parents first: each with its parent's index, its inverse bind matrix in three rows, its rest pose as a translation, a quaternion and a scale, its sphere at bind time and its name. It ends with the skin's name and the model's path. An animation blob holds its skin's GUID and count of joints, its duration, its channels (a joint, a part, an interpolation, and ranges of the keys), the keys' times in `f32`, and their values in `f32`, three or four per key. It ends with the animation's name and the model's path (see [Skins and animations](kinds/skins-and-animations.md#animations)).

An audio blob holds its frame count, its channels, whether it streams, its format, the frames that a pass skips, and its data at 48 kHz, which starts at 16 bytes: interleaved 16-bit PCM, blocks of IMA ADPCM, an Ogg Vorbis stream, or Opus packets each after its size in a little-endian `u16`. It starts with the source path after the header. A stream reads the header and then its data from the file as it plays, and never loads the blob. A sound that does not stream is loaded and, if it is compressed, decoded to PCM (see [Audio](kinds/audio.md#audio)).

A font blob holds its atlas's GUID and size, its units per em, the atlas's texels to an em and its distance range, its line metrics in em, which font of a collection it is, its glyphs sorted by id (each its cell in the atlas and its plane from the pen), the font's file, which starts at 16 bytes, its family name and the source path. The atlas is a texture blob of its own (see [Fonts](kinds/fonts.md#the-blob)).

A UI document blob holds its nodes in the order of a walk that visits each before its children (each its element, its parent, the end of its subtree, its line, its id, its attributes and its styles), its styles (each its name, its attributes and its variant for each state), its attributes (each an attribute and its value as text, which the runtime parses as it does a script's), the styles that each node takes, and the source path (see [UI documents](kinds/ui-documents.md#the-blob)).

The format package has its own enum of texture formats, because it imports nothing from `lib/core/gpu`. The runtime maps it to `gpu.Format`.

## Loading

- **The source:** the asset runtime (`lib/engine/asset`) reads through `asset.Source`, a union, so it holds no procedure pointers. Its one arm is `Loose_Cache`, which development and release builds both use, each with its own configuration's cache.
- **Loose cache:** one blob per asset, `<cache>/<guid>.blob`, where the cache is `build/dev/content` for the development configuration and `build/release/content` for release, each beside the executable that reads it (see [Building and running](../overview/building-and-running.md#build-layout)). The cooker overwrites a blob when its cache key changes. The runtime reads files through `file_read` and `file_modified` in `Platform_API`, and keeps blobs in memory from `asset_allocator`, the host's heap.
- **Handles:** `asset.load` returns a generational handle, and the same handle for an asset that is already loaded. A handle to an unloaded asset is detected. The asset table lives in `Game_State`, so a code reload keeps every loaded asset. A soft restart loads them again.
- **Asset hot reload:** in development, after a cook writes blobs, it writes a counter to the cache's `.generation`, through a temporary file and a rename. The cook daemon and the batch commands both do this. The game calls `asset.poll` at the end of each frame, and `poll` checks the counter's modification time. When the counter changes, `poll` checks the modification time of each loaded blob, and swaps every new blob behind its generational handle in that frame. A script and the modules that it requires therefore change together. The game learns of new blobs only through the cache, so it needs no connection to the daemon, and hot reload works with or without the editor. The game passes `poll`'s result to `script.reload_changed`, which reloads the scripts among the swapped blobs (see [Scripting](../scripting/tooling-and-hot-reload.md#script-hot-reload)).
- **GPU data:** the asset runtime keeps blobs on the CPU and knows nothing about the GPU. The renderer keeps a residency table (see [Rendering](../rendering/assets.md#gpu-residency)), which creates and streams the GPU resources of texture and mesh assets.
- **Scripts load on demand.** A script blob stays loaded while its module is loaded. The VM holds the module's result, not the blob, so the blob can be swapped under it.

