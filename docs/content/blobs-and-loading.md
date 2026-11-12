# Blobs and loading

The blob format every kind shares, how the asset runtime loads blobs from the loose cache and hot-reloads them, and the bundles that a release build loads them from.

**In this document:** [Blob format](#blob-format) · [Loading](#loading) · [Bundles](#bundles)

## Blob format

Compiled blobs use offsets instead of pointers. The runtime can map a blob and use it without parsing. Blobs are aligned for direct GPU upload. A blob in the loose cache is not compressed, except for a mesh's pages, each of which is an LZ4 block. A bundle compresses most blobs, each on its own. The runtime decompresses a blob into the same bytes before it uses it (see [Bundles](#bundles)).

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

A mesh blob with the `Paged` flag has pages in place of the positions, the attributes, the indices and the three meshlet streams, which are empty (see [Meshes: Pages](kinds/meshes.md#pages)). It has a page table of `Mesh_Page` records, 48 bytes each: where the page's LZ4 block is from the blob's start, its compressed and uncompressed sizes, the `fnv32a` of the block, its range of the mesh's meshlets, how many of them are level 0, where its vertices are in the assembled level 0, its range of the dependencies, and whether it is a root. After the table come the dependencies, as page indices. The blob keeps the meshlet count, the level buckets in each submesh, each level's errors, and the face area, which the pages would otherwise give. `head_size` is where the head ends: everything but the pages that are not roots, with the root pages last in it. The other pages follow, each at 16 bytes, to `file_size`. `format.mesh_view` checks a paged blob from its head alone, and `format.mesh_page_view` checks each page when a reader has decompressed it.

A skin blob holds its joints, parents first: each with its parent's index, its inverse bind matrix in three rows, its rest pose as a translation, a quaternion and a scale, its sphere at bind time and its name. It ends with the skin's name and the model's path. An animation blob holds its skin's GUID and count of joints, its duration, its channels (a joint, a part, an interpolation, and ranges of the keys), the keys' times in `f32`, and their values in `f32`, three or four per key. It ends with the animation's name and the model's path (see [Skins and animations](kinds/skins-and-animations.md#animations)).

An audio blob holds its frame count, its channels, whether it streams, its format, the frames that a pass skips, and its data at 48 kHz, which starts at 16 bytes: interleaved 16-bit PCM, blocks of IMA ADPCM, an Ogg Vorbis stream, or Opus packets each after its size in a little-endian `u16`. It starts with the source path after the header. A stream reads the header and then its data from the file as it plays, and never loads the blob. A sound that does not stream is loaded and, if it is compressed, decoded to PCM (see [Audio](kinds/audio.md#audio)).

A font blob holds its atlas's GUID and size, its units per em, the atlas's texels to an em and its distance range, its line metrics in em, which font of a collection it is, its glyphs sorted by id (each its cell in the atlas and its plane from the pen), the font's file, which starts at 16 bytes, its family name and the source path. The atlas is a texture blob of its own (see [Fonts](kinds/fonts.md#the-blob)).

A sprite sheet blob holds its atlas's GUID, the size that its frames' rectangles are in, its texels to a meter, its filter, its frames (each its rectangle, pivot, duration and name), its animations (each its name, frames, rate and whether it loops), and the source path (see [Sprite sheets](kinds/sprite-sheets.md#the-blob)).

A UI document blob holds its nodes in the order of a walk that visits each before its children (each its element, its parent, the end of its subtree, its line, its id, its attributes and its styles), its styles (each its name, its attributes and its variant for each state), its attributes (each an attribute and its value as text, which the runtime parses as it does a script's), the styles that each node takes, and the source path (see [UI documents](kinds/ui-documents.md#the-blob)).

The format package has its own enum of texture formats, because it imports nothing from `lib/core/gpu`. The runtime maps it to `gpu.Format`.

## Loading

- **The source:** the asset runtime (`lib/engine/asset`) reads through `asset.Source`, a union, so it holds no procedure pointers. It has two arms:
  - `Loose_Cache`, which development uses.
  - `Bundle`, which a release build uses (see [Bundles](#bundles)).

  A game passes `asset.content_source(platform.content_dir)` to `asset.init`. This gives `Bundle` when the build defines `BUNDLES=true`, as `just release` does, and `Loose_Cache` in every other build.
- **Loose cache:** one blob per asset, `<cache>/<guid>.blob`. The cache for the development configuration is `build/dev/content`, beside the host that reads it (see [Building and running](../overview/building-and-running.md#build-layout)). A release cook also writes a loose cache, `build/obj/release-cache`, and the package step packs it into bundles. The cooker overwrites a blob when its cache key changes. The runtime reads files through `file_read`, `file_read_range` and `file_modified` in `Platform_API`, and keeps blobs in memory from `asset_allocator`, the host's heap. **Of a mesh with pages it reads and keeps only the head** (`read_head`): it reads the start of each blob, and if that is a paged mesh, it reads `head_size` bytes and no more. The renderer reads each other page from the file when a view needs it, with `asset.blob_location` and `asset.modified`, the time of the file that the head came from.
- **Reading a blob's file:** some code reads a range of a blob itself, such as a sound's stream or a mesh's pages. It calls `asset.blob_location`, which gives three things:
  - The file.
  - The blob's offset in the file.
  - `raw`: whether the file holds the blob's bytes as they are.

  A loose blob is at offset 0 of its own file. A bundled blob is at the offset of its entry in the bundle, and it is `raw` only if the bundle does not compress it. `asset.read` reads a whole blob, decompressed, without loading the asset. The audio runtime uses it for a sound that does not stream.
- **Handles:** `asset.load` returns a generational handle, and the same handle for an asset that is already loaded, so the users of an asset share one handle. A handle to an unloaded asset is detected. The asset table lives in `Game_State`, so a code reload keeps every loaded asset. A soft restart loads them again.
- **Sharing and unloading:** each `asset.load` adds a user to the asset, and `asset.unload` removes one. The last unload frees the asset, so a user that unloads never frees the handle of another user. Code that keeps an asset for the session does not unload it. The count stops at its maximum, and then the asset stays loaded for the session. `asset.find` gives the handle of a loaded asset and adds no user, so do not unload what it gives. `asset.version` is 1 when an asset loads and increments with each hot reload. For a stale handle it is 0, so a stale handle never looks like the version that a user built from.
- **Asset hot reload:** only from the loose cache, so only in development. After a cook writes blobs, it writes a counter to the cache's `.generation`, through a temporary file and a rename. The cook daemon and the batch commands both do this. The game calls `asset.poll` at the end of each frame, and `poll` checks the counter's modification time. When the counter changes, `poll` checks the modification time of each loaded blob, and swaps every new blob behind its generational handle in that frame. A script and the modules that it requires therefore change together. The game learns of new blobs only through the cache, so it needs no connection to the daemon, and hot reload works with or without the editor. The game passes `poll`'s result to `script.reload_changed`, which reloads the scripts among the swapped blobs (see [Scripting](../scripting/tooling-and-hot-reload.md#script-hot-reload)).
- **GPU data:** the asset runtime keeps blobs on the CPU and knows nothing about the GPU. The renderer keeps a residency table (see [Rendering](../rendering/assets.md#gpu-residency)), which creates and streams the GPU resources of texture and mesh assets.
- **Scripts load on demand.** A script blob stays loaded while its module is loaded. The VM holds the module's result, not the blob, so the blob can be swapped under it.

## Bundles

A release build reads its content from bundles (`*.cbb`) in the `content` folder beside its executable. A bundle holds the blobs of one load unit in one file. A release therefore ships a few files in place of thousands of loose blobs. If a copy stops before the end, the runtime refuses the incomplete bundle, so one missing blob does not go unnoticed.

**The format** (`format/bundle.odin`):

| Part | Contents |
|---|---|
| Header | The magic `CBB1`, the head's size, the layout hash of the header and the entries, the file's size, and slices of the entries and the dependencies |
| Entries | One `Bundle_Entry` for each blob, sorted by GUID: the GUID, the kind, the codec (`None` or `Lz4`), the size in the file, the blob's size, and its offset from the file's start |
| Dependencies | The names of the bundles that this one depends on, without the extension |
| Blobs | Each blob at 16 bytes, as its codec stores it |

The header, the entries and the dependencies make the head, which the runtime reads when it opens the bundle. A blob is either one LZ4 block, which decompresses into the blob's exact bytes, or the blob as it is.

**Codecs.** The package step compresses each blob on its own with LZ4's HC codec at level 12, using one thread for each CPU core. A bundle is written once and read many times, and LZ4 decompresses at several GB/s. These blobs stay as they are (`None`):

- A sound that streams. The mixer reads its data from the file as it plays.
- A paged mesh. The renderer reads its pages from the file, and they are LZ4 blocks already.
- A blob that LZ4 does not make smaller.

The runtime reads an uncompressed blob from the bundle at its offset, as it reads a loose blob from offset 0 of its own file.

**Load units.** `cook package` writes one bundle for each level and one global bundle:

- **A level** is a scene that `bundles.global_scenes` in the project's settings does not name. Its bundle is `<scene guid>.cbb`. It holds the scene and what only that level uses.
- **What a blob uses** is the assets that it names (`format.blob_references`):
  - A scene's or prefab's behaviour scripts and asset fields, and a scene's navmeshes.
  - A script's requires.
  - A material's textures, and an instance's material and textures.
  - An effect's materials, meshes and textures.
  - An animation's skin, and an animation graph's clips.
  - A font's or a sprite sheet's atlas.
  - A UI document's fonts and images.

  A walk from a level follows these references, but it does not go into another level's scene, which belongs to that level.
- **The global bundle**, `global.cbb`, holds everything else. Every level's bundle depends on it. It holds:
  - What more than one level uses.
  - The scenes that `bundles.global_scenes` names.
  - What no level uses, such as what code loads by GUID: the engine's shaders and textures, a sample's scripts, and `mesh.default_material`.
  - Whatever a global blob uses, so that a global blob never needs a level's bundle.
- **Streaming chunks** do not have units yet, because nothing streams part of a scene.

Use `bundles.global_scenes` for scenes that are not levels, such as a menu or a scene that a script adds to another. Their assets go in the global bundle, because code can load them at any time.

**Opening.**

- `asset.init` with a `Bundle` source opens `global.cbb`.
- `asset.load` finds a GUID in the open bundles' entries by binary search. If no open bundle has the GUID, it may be a level's scene: `asset.load` opens `<guid>.cbb`, if it exists, and searches again. Loading a level's scene therefore opens the level's bundle.
- `asset.open_bundle` opens a bundle by name.
- A bundle opens after the bundles that it depends on.
- The runtime refuses a bundle, with an error, if the file is shorter or longer than its header says, or if its layout is not this build's.
- A bundle stays open for the session. Only its head stays in memory, about 40 bytes for each blob.

**What a release does not do.** Bundles do not change, so `asset.poll` returns nothing, and `asset.current` is always true. Hot reload of assets and of scripts is therefore for development only. Scripts load from bundles like every other asset (see [Scripting](../scripting/tooling-and-hot-reload.md#script-hot-reload)). There are no material previews.

**The package step.** `just release` cooks every kind into the game's release loose cache, `build/obj/release-cache/<game>`, with `cook all --prune`, so the cache holds only the game's content (see [Cooking](identity-and-cooking.md#cooking)). Then it runs `cook package --cache build/obj/release-cache/<game> --out build/release/content --project samples/<game>/project.settings`. `cinnabar export` does the same with the project's `build/release-cache` (see [Getting started](../overview/getting-started.md#releases)). The step does these things:

1. Takes the cache's lock.
2. Reads every blob.
3. Chooses each blob's unit.
4. Writes each bundle to a temporary file, then renames it.
5. Logs each bundle's number of blobs and its size, against the size of the loose blobs.

Before the step, `just release` removes `build/release/content`, so the folder holds only bundles.

