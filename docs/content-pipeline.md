# Content pipeline

`tools/cook` compiles source assets into blobs. Development builds read blobs from a loose cache, and release builds read them from bundles. See [Architecture](architecture.md#content-pipeline) for the overview.

## Identity

Every source asset has a GUID, stored in a `.meta` sidecar file next to it with its import settings. The cooker assigns a GUID the first time it sees an asset. Renames and moves keep the GUID as long as the `.meta` file moves too, and the editor makes sure it does. Content refers to other content only by GUID.

- A GUID is 128 random bits, written as 32 hex digits. Engine content (such as the script prelude) has fixed GUIDs in committed `.meta` files.
- A `.meta` file has lines of `key = value`, and `#` comments. `guid` is required. The other keys are import settings. When the cooker finds an asset without a `.meta` file, it writes one. Commit it with the asset.
- **Sub-assets:** one source file can make several assets, such as the meshes of a glTF file. Each sub-asset has its own GUID and its own blob, and loads like any other asset. Its GUID is in its file's `.meta` file, on a line `<kind>.<name> = <guid>`, such as `mesh.Door_Frame = 3f9c...`. The cooker writes the line when it first makes the sub-asset, and finds it again by kind and name, so a re-import keeps every reference. The file itself is the parent, and has a GUID of its own but no blob when it makes only sub-assets.
- **A renamed sub-asset** (a mesh renamed in the modelling tool) gets a new GUID, with a warning that names the old one. The old line stays in the `.meta` file, as a warning, until the asset is re-imported, so a rename back in the modelling tool restores it.
- Two assets with the same GUID, of any kinds, are a cook error, and neither cooks. This happens when an asset is copied with its `.meta` file. Delete the copy's `.meta` file to give it a new GUID.
- Each game has one content root, `samples/<game>/content/`. Engine content is in `lib/engine/content/`. The cooker takes each root with a name, such as `--root game=samples/mygame/content`, and an asset's source path is the root's name and its path in the root, such as `game/scripts/hello.luau`.
- At runtime, a loaded asset is a generational handle in the asset runtime's table. Persistent state holds handles or GUIDs, never pointers into blobs (see [Hot reload](hot-reload.md#rules)).

## Cooking

- **Shared schemas:** `tools/cook` imports the same asset-type package from `lib/engine` that the runtime uses, `lib/engine/asset/format`, so their struct layouts cannot diverge. That package imports nothing from `lib/core`. Each asset type's version comes from its layout hash, so changing a type invalidates its cache entries.
- **Incremental cooking:** a cache key is a hash of the source files, the import settings and the cooker version.
- **One scan:** every command that cooks scripts or scenes scans the roots once for every kind of asset, and gives each new asset its `.meta` file, whatever kind it cooks. Then it cooks each asset of its kinds whose key changed.
- **The cache's generation:** after a cook writes blobs, it adds one to the counter in `<cache>/<config>/.generation` (see [Loading](#loading)).
- **One cook at a time:** a cook holds `<cache>/.cook.lock` while it runs. Otherwise two cooks could both give a new asset a `.meta` file, each with its own GUID. Windows deletes the lock when the cook exits, also when it crashes. A dev batch cook that finds the lock held leaves the cache to the cook daemon, which keeps it up to date, so `just build` works while the editor is open. Any other cook stops with an error.
- **Problems:** each error and warning names its file (the asset's source or `.meta` file, or another file such as the definition file), and its line and column when it has them. A batch cook logs each one as `cook: <file>:<line>:<column>: <text>`.
- **Kinds:** scripts, scenes, shaders, textures and meshes. Each kind has an importer: its extensions, its import settings and its cook (see the sections below).
- **Slow kinds use every core.** A texture can take seconds, so block compression spreads each mip's rows of blocks over the CPU's threads. A 2048×2048 color texture with its mips cooks in about 1 s for development and 3 s for release. *Cooking several textures at once, and a pass that reports the assets that it has left so the editor can show progress, come when content grows.*
- **Third-party code** for the importers is in `vendor/`, built with CMake into `build/` like Luau, and linked into `tools/cook` only: Compressonator's `CMP_Core` for block compression, and meshoptimizer for meshes. Odin's `vendor:stb/image` and `vendor:cgltf` read the source files. The runtime links none of them.
- **Compressonator** is a submodule pinned to a release, but its repository is over 700 MB, so `vendor/compressonator` is a blobless clone that checks out only `cmp_core`, `license` and `applications/_libs/cmp_math`. `.gitmodules` marks it `update = none`, so `git submodule update` never checks out the rest, and `just install-compressonator` makes the sparse clone at the pinned commit. `just update-compressonator <tag>` moves the pin. `tools/cook/compressonator` builds `CMP_Core` with its own CMake project, and `cn_compress.cpp` gives the cooker a C API that compresses a whole mip, because `CMP_Core`'s API is C++ and compresses one block at a time.

### Scripts

Scripts are `.luau` files. `just scripts` runs `cook scripts --cache build/cache --config dev|release --root game=<content root>`. `tools/cook` links the Luau compiler, parser and analyzer from `vendor/luau`, the same commit that the runtime uses. The parser and the analyzer have no C API, so `luau_tools` (`lib/core/luau/luau_tools.cpp`) exposes what the cooker needs as C functions.

For each script, the cooker:

1. Finds every call of the global `require` with Luau's parser, so comments and strings never look like requires. A `require` whose argument is not one string literal is an error. The parser also tells whether the script calls `Behaviour.define`.
2. Resolves every `require` string to a GUID, with Luau's rules (see [Scripting](scripting.md#modules-and-require)). A missing module, a path that names both `x.luau` and `x/init.luau`, or a cycle is an error.
3. Type checks the module against the definition file that `--definitions` names (see [Scripting](scripting.md#types-and-tooling)), and the modules it requires, with Luau's analyzer. The cooker gives the analyzer every module's source and resolved requires, so it reads no files. A type error is a cook error.
4. Compiles it with `luau_compile`. Development uses optimization level 1 and debug level 2. Release uses optimization level 2 and debug level 1.
5. For a script that calls `Behaviour.define`: runs its top level in a sandboxed VM with the Luau libraries, the prelude (`lib/engine/script/prelude.luau`) and a `require` that follows the resolved requires, but no engine. If it returns a behaviour class, the cooker records the class name and the fields (see [Scripting](scripting.md#behaviours)).
6. Writes the blob to a temporary file and renames it, so the running game never reads a partial blob.

A script that fails keeps its old blob, so the running game keeps the last good version. Every script that requires it, directly or not, also keeps its old blob, with an error that names the script it requires. The other scripts still cook. Every script in a require cycle fails.

The cache key includes the source, the `.meta` file, the cooker version, the Luau version, the build configuration, the source path, the GUID that each require resolves to, the prelude, the definition file, and the sources of every module that the script requires, directly or not. A behaviour's field defaults and the type check depend on those modules, so a changed dependency cooks its dependents again.

Script import settings in `.meta`: `native = true` compiles the module to machine code at load, like a `--!native` comment at the top of the source. Each importer has a table of the settings that it takes, with their values, defaults and descriptions (`import_settings` in `tools/cook`). Every cook checks the `.meta` files with it: an unknown setting is a warning, and a value that the setting does not take is an error. The daemon sends the table to the editor, which shows an editor for each setting.

### Scenes

Scenes are `.scene` text files (see [Editor](editor.md#scenes)). `just scenes` runs `cook scenes --cache build/cache --config dev|release --root game=<content root>`. The cooker cannot lay out native components, because their types exist only in the game DLL, so it checks only the file: its syntax, and that the scene IDs and the script GUIDs that it names exist. A missing one is a warning. A scene with an error keeps its old blob. The cache key covers the cooker version, the configuration, the source path, the source and the `.meta` file.

### Shaders

Shaders are `.hlsl` files in the content roots. `just shaders` runs `cook shaders --cache build/cache --config dev|release --root game=<content root> --root engine=lib/engine/content --include lib/core/gpu/shaders`, and the daemon cooks them like any other kind.

- **One asset per file.** The cooker compiles each of the file's `vs_main`, `ps_main`, `cs_main`, `as_main` and `ms_main` entry points into one blob. A file with `[shader("...")]` attributes is a ray tracing library and has one library entry (see [GPU](gpu.md#shaders)).
- **Includes are not assets.** `.hlsli` files have no GUID and no `.meta` file. The cooker resolves an include next to the including file first, then in each `--include` directory. The daemon also watches the `--include` directories.
- **The fixed root signature** is attached to every stage, so DXC rejects a shader that does not fit it (see [GPU](gpu.md#binding-model)). The runtime never compiles or reflects shaders.
- **Configurations:** development compiles with debug information embedded (`-Zi -Qembed_debug`), so PIX shows the source. Release strips it.
- **Problems:** the cooker parses DXC's messages into problems with their file, line and column. A message in an include belongs to the include's file, and to no asset, as other files' problems do. A shader that fails keeps its old blob, so the running game keeps drawing with the last good version.
- **The cache key** covers the cooker version, the DXC version, the configuration, the source path, the source, the `.meta` file, and the source of every file that it includes, directly or not.
- **One process at a time:** Windows children inherit every inheritable handle, so a DXC started on one thread can hold the pipes of one that another thread started, which then waits forever. The cooker runs its child processes one at a time.
- **Engine shaders** are in the engine's content root, `lib/engine/content/shaders/`, with committed `.meta` files and fixed GUIDs: the editor tools' overlay and pick shaders first, and the renderer's later.
- A port adds SPIR-V from DXC or a metallib from `metal-shaderconverter` as more entries in the same blob.

### Textures

Textures are `.png`, `.jpg`, `.tga` and `.hdr` files, read with `vendor:stb/image`. `just textures` runs `cook textures --cache build/cache --config dev|release` with the roots. *`.exr` files, with `vendor:OpenEXRCore`, come later.*

| Setting | Values | Default | Effect |
|---|---|---|---|
| `usage` | `color`, `normal`, `mask`, `hdr`, `data` | From the name, see below | Selects the format and the mip filter |
| `mips` | `true`, `false` | `true` | Make the full mip chain |
| `max_size` | `256` to `16384` | `16384` | Halve the texture until its larger side fits |
| `wrap` | `repeat`, `clamp` | `repeat` | The edge mode of the mip filter. The sampler is the material's choice. |

| Usage | Format | Mips |
|---|---|---|
| `color` | BC7, sRGB. Alpha is kept. | Filtered in linear light. *Keeping an alpha-tested texture's coverage in its mips comes later.* |
| `normal` | BC5 (x and y; shaders compute z) | Filtered, then normalized again |
| `mask` | BC4 (one channel: roughness, occlusion, height) | Filtered |
| `hdr` | BC6H, unsigned | Filtered |
| `data` | `RGBA8_Unorm`, not compressed | Filtered |

- **The default usage** comes from the file when the cooker writes its `.meta` file: `.hdr` and `.exr` are `hdr`, a name ending in `_n` or `_normal` is `normal`, a name ending in `_r`, `_rough`, `_ao`, `_m`, `_metal` or `_mask` is `mask`, and everything else is `color`. The setting is then written in the `.meta` file, so a rename does not change it.
- **Size:** a texture larger than `max_size` halves until it fits. Mip 0 of a block-compressed texture is whole 4×4 blocks on the GPU (see [GPU](gpu.md)), so a texture whose sides are not multiples of 4 is resized up to the next ones.
- **Mips** use a Kaiser-windowed sinc filter, which widens with the scale when it shrinks, in floating point. Each mip filters from the one before it, and normal maps are normalized again after each step.
- **BC6H** interpolates its endpoints' half-float bits, which are close to logarithmic, so a 4×4 block that holds both 0 and bright values has coarse steps between them.
- **Quality:** development compresses at Compressonator's quality 0.05, and release at 0.5. The configuration is in the key, so release textures cook again in a release cook.
- **The cache key** covers the cooker version, the Compressonator version, the configuration, the source and the `.meta` file.
- *Cube maps and texture arrays come with environment lighting (see [Rendering](rendering.md)).*

### Meshes

Meshes come from `.gltf` and `.glb` files, read with `vendor:cgltf`. A glTF file is a model: a parent whose meshes are sub-assets (see [Identity](#identity)).

- **One mesh asset per glTF mesh**, named for the glTF mesh, in its own space with its own pivot. Node transforms are not baked in, so a mesh that many nodes use is one asset. Each glTF primitive becomes a submesh. Primitives that share a glTF material share a submesh, and each submesh has a material slot named for its glTF material.
- **Unnamed meshes** are named for the first node that uses them, then `mesh_<index>`.
- **`combine = true`** makes one mesh asset, named for the file, instead: the cooker walks the default scene's nodes and bakes their transforms into the vertices. This suits a file that is one prop exported in pieces. The default is `false`.
- *Later, a model also makes a prefab of its node hierarchy that places its meshes, and its textures and materials become sub-assets too (texture assets and material instances). That is importing a glTF file as a scene, and it waits for prefabs.*
- **Axes:** glTF is right-handed, with +y up and +z the asset's front. The engine is left-handed, with +x right, +y up and +z forward. The cooker negates x and reverses each triangle's winding.
- **Vertices** are two streams, so that depth and shadow passes read only positions:

| Stream | Contents | Size |
|---|---|---|
| Positions | `f32` x, y, z | 12 bytes |
| Attributes | Normal and tangent, octahedral in `snorm16` pairs, with the bitangent's sign; the first UV set in `f32`; the second UV set and the vertex color when the file has them | 16 to 28 bytes |

- **Processing** with meshoptimizer: weld identical vertices, order the triangles for the vertex cache and the vertices for fetching, and build meshlets of at most 64 vertices and 124 triangles, each with a bounding sphere and a normal cone for culling. Indices are 16-bit when the mesh has fewer than 65 536 vertices.
- **Bounds:** the mesh and each submesh have an axis-aligned box and a sphere.
- **Not imported yet:** the node hierarchy (except with `combine`), the file's materials, textures, cameras, lights, skins and animations.
- **Import settings:** `combine` (`true` or `false`, default `false`), `scale` (a number, default `1`) and `tangents` (`file` or `generate`, default `file`: MikkTSpace tangents are made when the file has none). The settings apply to every mesh of the file.
- **The cache key** is the model's: the cooker version, the meshoptimizer version, the source, the `.meta` file, and for a `.gltf` file the `.bin` files that it names. A model cooks all of its meshes together, and a mesh that fails fails the model, so its meshes keep their old blobs together.

## Cook daemon

In development, the cook daemon keeps the cache up to date while the sources change. It is `cook daemon`, in the same executable as the batch commands, so both use the same importers. The editor starts it (see [Editor](editor.md#processes)), and `just watch` runs it without the editor.

`cook daemon --cache <dir> [--definitions <file>] [--dxc <dxc.exe>] [--include <dir>]... [--link <port>] --root <name>=<dir>...`

Without `--dxc`, every shader fails with a problem that says so.

- **Development only:** the daemon cooks the `dev` configuration. Release content comes from the batch commands.
- **The same pass:** a daemon pass is the batch commands' pass for every kind (see [Cooking](#cooking)): one scan of the roots, then each asset whose key changed. A key covers what its asset depends on, so a pass cooks the changed assets and their dependents, and nothing else. Every pass parses every scene, also one that is up to date, so its warnings and the scripts that it names are known at every pass. A pass over the sample's content takes about 10 ms.
- **Index:** after each pass, the daemon builds an index of the content: every asset with its GUID, root, path, kind, status (current or failed), import settings, behaviour class, dependencies (a script's requires, and the scripts that a scene names), problems, and for a sub-asset its parent, and every folder. A problem belongs to the asset whose source or `.meta` file it is in, and the others belong to no asset. The daemon compares the index with the last pass's, and keeps the new one. *Scanning only the changed paths, and a saved index, come when a full scan becomes slow.*
- **Removed assets:** when an asset leaves the index, the daemon deletes its blob, so a game that starts later does not load it. A running game keeps the modules that it has loaded. An asset that only shares its GUID with a copy keeps its blob.
- **Orphans:** a `.meta` file without its asset is a warning that belongs to no asset (see [Asset operations](#asset-operations)).
- **Watching:** the daemon watches each root, and the definition file's directory, with `ReadDirectoryChangesW`. It does not read what changed, because the next pass scans everything, so a change that Windows drops when its buffer fills loses nothing. After a change, it waits until 100 ms pass without another, then makes one pass. A new definition file makes every script dirty, because it is part of every script's key.
- **Problems:** an asset that fails is tried again at each pass until it cooks. The daemon logs an asset's problems when they change, and not again at each pass, and a pass that cooks something says how much. A `.meta` file that the daemon writes for a new asset is a change too, so it makes one more pass, which finds nothing to cook.
- **One writer:** the daemon holds the cache's lock while it runs. A second daemon of the same cache stops with an error.

### Asset operations

The daemon is the only program that writes `.meta` files, and it moves every asset with its `.meta` file. The editor asks the daemon for every change to the content roots, except the text of a scene that it saves (see [Editor](editor.md#content-browser)). The operations are in `tools/cook/operations.odin`.

- **All or nothing:** an operation checks everything first: the root, the folder, each name, and that no file is in the way. It then fails without changing anything, or does all of it. A move that fails halfway moves back what it moved.
- **Names** are what Windows takes and the scan does not skip: no `<>:"/\|?*`, no name that starts with a dot or ends with a dot or a space, and no device name such as `CON`. An asset's name is without its extension, which the daemon adds.
- **Then a pass:** after the operations that the editor sent, the daemon makes a pass, sends what changed, and then answers each operation. The editor's index therefore has the change when the answer comes. The watcher's events for the operation make one more pass, which finds nothing to cook.
- **Create** makes an asset from a template, with a new `.meta` file: a script that returns a table, a behaviour whose class is named for its file (`door_bell.luau` defines `Door_Bell`), or an empty scene. A folder's parent must exist.
- **Sub-assets** move, rename and delete only with their file, because their GUIDs are in its `.meta` file. The operations take files, never sub-assets, and the editor offers them only on files.
- **Move and rename** move the `.meta` file, then the source. They never replace a file, and a rename that changes only the case works. A file moves to another drive too. Folders have no `.meta` files and no GUIDs. A folder renames with everything in it, on its drive.
- **Duplicate** copies the source to `<name>_copy`, or `<name>_copy_2` and on, and gives the copy a new `.meta` file with the same import settings. Its sub-assets get new GUIDs at the next pass, as a new file's do.
- **Delete** sends sources with their `.meta` files, and folders with everything in them, to the Recycle Bin. A root cannot be deleted. The editor finds the assets that use what a delete takes in its index, and shows them in the confirmation.
- **Import settings:** the daemon checks new settings with the asset's importer, writes the `.meta` file through a temporary file, and cooks the asset again, because the settings are part of its key. The `.meta` file keeps its comments. A setting that the importer does not know stays as the file has it, but the editor cannot add one. **Re-import** cooks assets again with the same settings, also when their keys say that they are up to date.
- **Saving a scene** is the editor's. Save As writes the scene's text where the user picks, and a new scene in a root gets its `.meta` file at the daemon's next pass, as any new file does.
- **No undo:** asset operations change the project, not the scene, so they are not on the editor's undo stack. The Recycle Bin recovers a deleted asset.
- **Moved modules:** a `require` names a path, so moving or renaming a script breaks the requires of the scripts that require it. The next pass reports each broken require as a problem of the script that has it, with its line. *Later, the daemon offers to rewrite the requires when it moves a module.*
- **Moves outside the editor:** a source that Explorer or git moves without its `.meta` file gets a new GUID, and the `.meta` file that stays behind is an orphan. The scan reports each orphan as a warning. *Later, it pairs an orphan with a new source that has the same contents.*
- **Directory handles:** the scan reads each directory with `os.read_all_directory_by_path`. Odin's `os.walker` leaves the last directory that it reads open, which would stop the daemon from renaming or deleting that folder.

### Cook link

The editor talks to the daemon through the cook link. It has the editor link's transport (see [Editor](editor.md#editor-link)) and its own messages.

- **One transport:** `lib/engine/wire` has the framing, the wire format and the schema writer, for any union of messages. `lib/engine/editor/link` and `lib/engine/asset/cook_link` each give a union of messages. Neither imports anything from core or engine.
- **The daemon is the server.** It listens on `127.0.0.1` at the port that `--link` gives, and serves one editor at a time.
- **Handshake:** `Hello`, then `Welcome` with the roots, the configuration and the importers, each with its extension and import settings, then the whole index as an `Asset_Snapshot` and an `Asset_Problems` for each asset that has problems. A `Hello` of another protocol version gets `Refused`. Then the daemon's log goes over the link, as the host's does.
- **After each pass** that changed the index, the daemon sends an `Asset_Delta` and an `Asset_Problems` for each asset whose problems changed. It sends `Cook_Finished` after every pass.
- **An entry has everything that the editor shows,** the import settings, the behaviour class and a sub-asset's parent included, so the editor never asks for an asset's details. It finds an asset's dependents in the dependencies of the others.
- **Schema:** `cook --emit-link-schema` writes `build/link/cook-schema.json`, and the editor's generator turns it into C# in `Cinnabar.Editor.Link.Cook`, as it does the editor link's schema in `Cinnabar.Editor.Link.Protocol`.

| Group | Messages |
|---|---|
| Session | `Hello`, `Welcome`, `Refused`, `Log` |
| Index | `Asset_Snapshot` with every asset and folder, then `Asset_Delta` with the changed and removed assets and the folders that came and went |
| Cooking | `Asset_Problems` with each problem's file, line, column and text, and `Cook_Finished` with the generation, the counts and the time |
| Operations | `Create_Asset`, `Create_Folder`, `Move_Assets`, `Rename_Asset`, `Rename_Folder`, `Duplicate_Assets`, `Delete_Assets`, `Set_Import_Settings`, `Reimport`, each a request answered with an `Operation_Result` of the same request ID: the reason that it failed, or the GUIDs of the assets that it made |

### Implementation phases

1. **Daemon:** one scan for every kind, scripts that fail without stopping the others, the watcher, the cache's generation and `asset.poll` that reads it, the lock, and `just watch`. No editor.
2. **Cook link:** problems by file and line, the index and its changes, `lib/engine/wire`, `cook_link` and its schema, and the editor's side (see [Editor](editor.md#implementation-phases)).
3. **Asset operations:** the operations, the importers' settings tables, orphans, and the editor's commands, menus, dragging and settings editors.
4. **GPU assets:** shaders, textures and meshes as assets, cooked in parallel, sub-assets, and the GPU residency table (see [Rendering](rendering.md#implementation-phases), phase 0).
5. **Later:** rewriting requires, pairing orphans, a saved index, and thumbnails as a cook output.

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

A texture blob holds the format, the size, the mip count, the usage, and the whole mip chain: each mip tightly packed, mip 0 first. That is the layout that `gpu_stream_texture` takes (see [GPU](gpu.md#streaming)), so the blob's data streams without a copy.

A mesh blob holds the bounds, the vertex count, the index size, a table of submeshes (the material slot's name, the index range, the meshlet range and the bounds), then the position stream, the attribute stream, the indices, and the meshlets: their vertex lists, their triangles packed as three bytes each, and their bounds and cones. Each stream starts at 16 bytes, so each streams straight into a buffer.

The format package has its own enum of texture formats, because it imports nothing from `lib/core/gpu`. The runtime maps it to `gpu.Format`.

## Loading

- **Two sources, one format:** the asset runtime (`lib/engine/asset`) reads through `asset.Source`, a union with two backends, so it holds no procedure pointers. `Loose_Cache` is used in development and `Bundle` is used in release. Both read the same blob format. *Until bundles exist, release builds read the release loose cache.*
- **Loose cache:** one blob per asset, `build/cache/<config>/<guid>.blob`. The cooker overwrites a blob when its cache key changes. The runtime reads files through `file_read` and `file_modified` in `Platform_API`, and keeps blobs in memory from `asset_allocator`, the host's heap.
- **Handles:** `asset.load` returns a generational handle, and the same handle for an asset that is already loaded. A handle to an unloaded asset is detected. The asset table lives in `Game_State`, so a code reload keeps every loaded asset. A soft restart loads them again.
- **Bundles** (`*.cbb`) contain a header, a table of contents sorted by GUID, and aligned blobs. A bundle is a load unit (global, per-level, or a streaming chunk), and it lists the bundles it depends on.
- **Asset hot reload:** in development, after a cook writes blobs, it writes a counter to `build/cache/<config>/.generation`, through a temporary file and a rename. The cook daemon and the batch commands both do this. The game calls `asset.poll` at the end of each frame, and `poll` checks the counter's modification time. When the counter changes, `poll` checks the modification time of each loaded blob, and swaps every new blob behind its generational handle in that frame. A script and the modules that it requires therefore change together. The game learns of new blobs only through the cache, so it needs no connection to the daemon, and hot reload works with or without the editor. The game passes `poll`'s result to `script.reload_changed`, which reloads the scripts among the swapped blobs (see [Scripting](scripting.md#script-hot-reload)).
- **GPU data:** the asset runtime keeps blobs on the CPU and knows nothing about the GPU. The renderer keeps a residency table (see [Rendering](rendering.md#gpu-residency)), which creates and streams the GPU resources of texture and mesh assets.
- **Scripts load on demand.** A script blob stays loaded while its module is loaded. The VM holds the module's result, not the blob, so the blob can be swapped under it.
