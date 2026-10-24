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

1. Finds every call of the global `require` with Luau's parser, so comments and strings never look like requires. A `require` whose argument is not one string literal is an error. The parser also tells whether the script calls `Behaviour.define`.
2. Resolves every `require` string to a GUID, with Luau's rules (see [Scripting](scripting.md#modules-and-require)). A missing module, a path that names both `x.luau` and `x/init.luau`, or a cycle is an error.
3. Type checks the module against the definition file that `--definitions` names (see [Scripting](scripting.md#types-and-tooling)), and the modules it requires, with Luau's analyzer. The cooker gives the analyzer every module's source and resolved requires, so it reads no files. A type error is a cook error.
4. Compiles it with `luau_compile`. Development uses optimization level 1 and debug level 2. Release uses optimization level 2 and debug level 1.
5. For a script that calls `Behaviour.define`: runs its top level in a sandboxed VM with the Luau libraries, the prelude (`lib/engine/script/prelude.luau`) and a `require` that follows the resolved requires, but no engine. If it returns a behaviour class, the cooker records the class name and the fields (see [Scripting](scripting.md#behaviours)).
6. Writes the blob to a temporary file and renames it, so the running game never reads a partial blob.

The cache key includes the source, the `.meta` file, the cooker version, the Luau version, the build configuration, the source path, the GUID that each require resolves to, the prelude, the definition file, and the sources of every module that the script requires, directly or not. A behaviour's field defaults and the type check depend on those modules, so a changed dependency cooks its dependents again.

Script import settings in `.meta`: `native = true` compiles the module to machine code at load, like a `--!native` comment at the top of the source. An unknown setting is a warning.

### Scenes

Scenes are `.scene` text files (see [Editor](editor.md#scenes)). `just scenes` runs `cook scenes --cache build/cache --config dev|release --root game=<content root>`. The cooker cannot lay out native components, because their types exist only in the game DLL, so it checks only the file: its syntax, and that the scene IDs and the script GUIDs that it names exist. A missing one is a warning. A scene with an error keeps its old blob. The cache key covers the cooker version, the configuration, the source path, the source and the `.meta` file.

## Cook daemon

In development, the cook daemon keeps the cache up to date while the sources change. It is `cook daemon`, in the same executable as the batch commands, so both use the same importers. The editor starts it (see [Editor](editor.md#processes)), and `just watch` runs it without the editor.

`cook daemon --link <port> --cache <dir> --definitions <file> --root <name>=<dir>...`

- **Development only:** the daemon cooks the `dev` configuration. Release content comes from the batch commands.
- **Importers:** each asset kind has an importer, chosen by the source's extension. An importer collects its sources, gives each asset's dependencies, cooks one asset, and checks the import settings that it accepts. A batch command indexes every asset of its kind and cooks each one whose key changed. The daemon cooks only the assets that a change makes dirty. Shaders are not assets yet, so the daemon does not cook them.
- **Index:** the daemon keeps every asset in memory: its GUID, source path, kind, import settings, cache key, status (current, cooking or failed) and problems. It also keeps each asset's dependencies (a script's requires, and the scripts that a scene names) and its dependents, the assets that depend on it. A scan of the roots builds the index when the daemon starts. *A saved index comes when the scan becomes slow.*
- **Watching:** the daemon watches each root, and the definition file, with `ReadDirectoryChangesW`. It collects changes until 100 ms pass without one, then cooks them in one pass. A new definition file makes every script dirty, because it is part of every script's key.
- **A pass** cooks the dirty assets and their dependents, directly or not, each after its dependencies. An asset that fails keeps its old blob, as in a batch cook, and its problems go to the editor. After a pass that writes blobs, the daemon writes the cache's generation (see [Loading](#loading)).
- **One writer:** the daemon holds `build/cache/.cook.lock` while it runs. A batch cook that cannot take the lock stops with an error that names the daemon, so the two never both give an asset a `.meta` file.

### Asset operations

The daemon is the only program that writes `.meta` files, and it moves every asset with its `.meta` file. The editor asks the daemon for every change to the content roots, except the text of a scene that it saves (see [Editor](editor.md#content-browser)).

- **Create** makes an asset from a template, such as a script, a behaviour or a scene, with a new `.meta` file. Save As for a scene creates the asset first, so the editor knows the GUID before it writes the scene.
- **Move and rename** change the index first, then move the source and its `.meta` file. The daemon recognizes the watcher's events for its own operations, so it does not see the files as new assets. Folders have no `.meta` files and no GUIDs.
- **Duplicate** copies the source and gives the copy a new `.meta` file.
- **Delete** sends the source and its `.meta` file to the Recycle Bin. The editor first asks the daemon for the asset's dependents, and shows them in the confirmation.
- **Import settings:** the daemon checks new settings with the asset's importer, writes the `.meta` file, and cooks the asset again. **Re-import** cooks an asset again with the same settings.
- **No undo:** asset operations change the project, not the scene, so they are not on the editor's undo stack. The Recycle Bin recovers a deleted asset.
- **Moved modules:** a `require` names a path, so moving or renaming a script breaks the requires of the scripts that require it. The next pass reports each broken require as a problem of the script that has it, with its line. *Later, the daemon offers to rewrite the requires when it moves a module.*
- **Moves outside the editor:** a source that Explorer or git moves without its `.meta` file gets a new GUID, and the `.meta` file that stays behind is an orphan. The daemon reports each orphan as a warning. *Later, it pairs an orphan with a new source that has the same contents.*

### Cook link

The editor talks to the daemon through the cook link. It has the editor link's transport (see [Editor](editor.md#editor-link)) and its own messages.

- **One transport:** `lib/engine/wire` has the framing, the wire format and the schema writer, for any union of messages. `lib/engine/editor/link` and `lib/engine/asset/cook_link` each give a union of messages. Neither imports anything from core or engine.
- **The daemon is the server.** It listens on `127.0.0.1` at the port that `--link` gives, and serves one editor at a time.
- **Handshake:** `Hello`, then `Welcome` with the roots and the configuration, or `Refused`, as in the editor link.
- **Schema:** `cook --emit-link-schema` writes `build/link/cook-schema.json`, and the editor's generator turns it into C# as it does the editor link's schema.

| Group | Messages |
|---|---|
| Session | `Hello`, `Welcome`, `Refused`, `Log` |
| Index | `Asset_Snapshot` with every asset and folder, then `Asset_Delta` with the added, changed and removed ones |
| Cooking | `Cook_Started`, `Cook_Finished` with the generation and the counts, `Asset_Problems` with each problem's file, line, column and text |
| Details | `Asset_Details_Request`, answered with the import settings, dependencies, dependents, and a behaviour's class and fields |
| Operations | `Create_Asset`, `Create_Folder`, `Move_Assets`, `Rename_Asset`, `Duplicate_Assets`, `Delete_Assets`, `Set_Import_Settings`, `Reimport`, each answered with `Operation_Result` |

### Implementation phases

1. **Daemon:** the importers, the index, the watcher, incremental passes, the cache's generation and `asset.poll` that reads it, the lock, and `just watch`. No editor.
2. **Cook link:** `lib/engine/wire`, `cook_link` and its schema, and the editor's side (see [Editor](editor.md#implementation-phases)).
3. **Asset operations.**
4. **Later:** rewriting requires, pairing orphans, a saved index, and thumbnails as a cook output.

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

## Loading

- **Two sources, one format:** the asset runtime (`lib/engine/asset`) reads through `asset.Source`, a union with two backends, so it holds no procedure pointers. `Loose_Cache` is used in development and `Bundle` is used in release. Both read the same blob format. *Until bundles exist, release builds read the release loose cache.*
- **Loose cache:** one blob per asset, `build/cache/<config>/<guid>.blob`. The cooker overwrites a blob when its cache key changes. The runtime reads files through `file_read` and `file_modified` in `Platform_API`, and keeps blobs in memory from `asset_allocator`, the host's heap.
- **Handles:** `asset.load` returns a generational handle, and the same handle for an asset that is already loaded. A handle to an unloaded asset is detected. The asset table lives in `Game_State`, so a code reload keeps every loaded asset. A soft restart loads them again.
- **Bundles** (`*.cbb`) contain a header, a table of contents sorted by GUID, and aligned blobs. A bundle is a load unit (global, per-level, or a streaming chunk), and it lists the bundles it depends on.
- **Asset hot reload:** in development, after a cook writes blobs, it writes a counter to `build/cache/<config>/.generation`, through a temporary file and a rename. The cook daemon and the batch commands both do this. The game calls `asset.poll` at the end of each frame, and `poll` checks the counter's modification time. When the counter changes, `poll` checks the modification time of each loaded blob, and swaps every new blob behind its generational handle in that frame. A script and the modules that it requires therefore change together. The game learns of new blobs only through the cache, so it needs no connection to the daemon, and hot reload works with or without the editor. *Until the daemon exists, `poll` checks each loaded blob at most every 0.25 s.* The game passes `poll`'s result to `script.reload_changed`, which reloads the scripts among the swapped blobs (see [Scripting](scripting.md#script-hot-reload)).
- **Scripts load on demand.** A script blob stays loaded while its module is loaded. The VM holds the module's result, not the blob, so the blob can be swapped under it.
