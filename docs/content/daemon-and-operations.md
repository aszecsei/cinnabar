# Cook daemon

The daemon keeps the cache current while sources change, owns every `.meta` file, does the editor's asset operations, and serves the cook link.

**In this document:** [Cook daemon](#cook-daemon)

## Cook daemon

In development, the cook daemon keeps the cache up to date while the sources change. It is `cook daemon`, in the same executable as the batch commands, so both use the same importers. The editor starts it (see [Editor](../editor/processes-and-projects.md#processes)), and `just watch` runs it without the editor.

`cook daemon --cache <dir> [--definitions <file>] [--dxc <dxc.exe>] [--include <dir>]... [--link <port>] --root <name>=<dir>...`

Without `--dxc`, every shader fails with a problem that says so.

- **Development only:** the daemon cooks the `dev` configuration. Release content comes from the batch commands.
- **The same pass:** a daemon pass is the batch commands' pass for every kind (see [Cooking](identity-and-cooking.md#cooking)): one scan of the roots, then each asset whose key changed. A key covers what its asset depends on, so a pass cooks the changed assets and their dependents, and nothing else. Every pass parses every scene, also one that is up to date, so its warnings and the scripts that it names are known at every pass. A pass over the sample's content takes about 10 ms.
- **Index:** after each pass, the daemon builds an index of the content: every asset with its GUID, root, path, kind, status (current or failed), import settings, behaviour class, dependencies (a script's requires, and the scripts that a scene names), problems, for a sub-asset its parent, for a texture its cooked size, and for a material or an instance its tool texture and hotspots (see [Materials](kinds/materials.md#materials)), and every folder. A problem belongs to the asset whose source or `.meta` file it is in, and the others belong to no asset. The daemon compares the index with the last pass's, and keeps the new one.
- **Removed assets:** when an asset leaves the index, the daemon deletes its blob, so a game that starts later does not load it. A running game keeps the modules that it has loaded. An asset that only shares its GUID with a copy keeps its blob.
- **Orphans:** a `.meta` file without its asset is a warning that belongs to no asset (see [Asset operations](#asset-operations)).
- **Watching:** the daemon watches each root, and the definition file's directory, with `ReadDirectoryChangesW`. It does not read what changed, because the next pass scans everything, so a change that Windows drops when its buffer fills loses nothing. After a change, it waits until 100 ms pass without another, then makes one pass. A new definition file makes every script dirty, because it is part of every script's key.
- **Problems:** an asset that fails is tried again at each pass until it cooks. The daemon logs an asset's problems when they change, and not again at each pass, and a pass that cooks something says how much. A `.meta` file that the daemon writes for a new asset is a change too, so it makes one more pass, which finds nothing to cook.
- **One writer:** the daemon holds the cache's lock while it runs. A second daemon of the same cache stops with an error.

### Asset operations

The daemon is the only program that writes `.meta` files, and it moves every asset with its `.meta` file. The editor asks the daemon for every change to the content roots, except the text of a scene that it saves (see [Editor](../editor/shell-and-panels.md#content-browser)). The operations are in `tools/cook/operations.odin`.

- **All or nothing:** an operation checks everything first: the root, the folder, each name, and that no file is in the way. It then fails without changing anything, or does all of it. A move that fails halfway moves back what it moved.
- **Names** are what Windows takes and the scan does not skip: no `<>:"/\|?*`, no name that starts with a dot or ends with a dot or a space, and no device name such as `CON`. An asset's name is without its extension, which the daemon adds.
- **Then a pass:** after the operations that the editor sent, the daemon makes a pass, sends what changed, and then answers each operation. The editor's index therefore has the change when the answer comes. The watcher's events for the operation make one more pass, which finds nothing to cook.
- **Create** makes an asset from a template, with a new `.meta` file: a script that returns a table, a behaviour whose class is named for its file (`door_bell.luau` defines `Door_Bell`), an empty scene, a lit material graph with only its output node, a material function whose one input is linked to its one output, or a mesh file of a 1 m box (see [Mesh files](kinds/meshes.md#mesh-files)). A folder's parent must exist.
- **Saving a material** is the editor's, as saving a scene is: the material editor writes the graph's text.
- **Sub-assets** move, rename, duplicate, delete and re-import only with their file, because their GUIDs are in its `.meta` file. The operations take files, never sub-assets: an operation given a sub-asset's GUID fails with a reason that names its file, and the editor disables the file operations while the selection holds a sub-asset. Changing a model's import settings keeps its `mesh.` lines.
- **Move and rename** move the `.meta` file, then the source. They never replace a file, and a rename that changes only the case works. A file moves to another drive too. Folders have no `.meta` files and no GUIDs. A folder renames with everything in it, on its drive.
- **Duplicate** copies the source to `<name>_copy`, or `<name>_copy_2` and on, and gives the copy a new `.meta` file with the same import settings. Its sub-assets get new GUIDs at the next pass, as a new file's do.
- **Delete** sends sources with their `.meta` files, and folders with everything in them, to the Recycle Bin. A root cannot be deleted. The editor finds the assets that use what a delete takes in its index, and shows them in the confirmation.
- **Import settings:** the daemon checks new settings with the asset's importer, writes the `.meta` file through a temporary file, and cooks the asset again, because the settings are part of its key. The `.meta` file keeps its comments. A setting that the importer does not know stays as the file has it, but the editor cannot add one. **Re-import** cooks assets again with the same settings, also when their keys say that they are up to date.
- **Saving a scene** is the editor's. Save As writes the scene's text where the user picks, and a new scene in a root gets its `.meta` file at the daemon's next pass, as any new file does.
- **No undo:** asset operations change the project, not the scene, so they are not on the editor's undo stack. The Recycle Bin recovers a deleted asset.
- **Moved modules:** a `require` names a path, so moving or renaming a script breaks the requires of the scripts that require it. The next pass reports each broken require as a problem of the script that has it, with its line.
- **Moves outside the editor:** a source that Explorer or git moves without its `.meta` file gets a new GUID, and the `.meta` file that stays behind is an orphan. The scan reports each orphan as a warning.
- **Directory handles:** the scan reads each directory with `os.read_all_directory_by_path`. Odin's `os.walker` leaves the last directory that it reads open, which would stop the daemon from renaming or deleting that folder.

### Cook link

The editor talks to the daemon through the cook link. It has the editor link's transport (see [Editor](../editor/link.md#editor-link)) and its own messages.

- **One transport:** `lib/engine/wire` has the framing, the wire format and the schema writer, for any union of messages. `lib/engine/editor/link` and `lib/engine/asset/cook_link` each give a union of messages. Neither imports anything from core or engine.
- **The daemon is the server.** It listens on `127.0.0.1` at the port that `--link` gives, and serves one editor at a time.
- **Handshake:** `Hello`, then `Welcome` with the roots, the configuration, the importers, each with its extension and import settings, and the kinds of node of material graphs, then the whole index as an `Asset_Snapshot`, an `Asset_Problems` for each asset that has problems, and the `Shading_Models` with their surface inputs. A `Hello` of another protocol version gets `Refused`. Then the daemon's log goes over the link, as the host's does.
- **After each pass** that changed the index, the daemon sends an `Asset_Delta` and an `Asset_Problems` for each asset whose problems changed, and `Shading_Models` when a shading model changed. It sends `Cook_Finished` after every pass.
- **During a pass** that takes longer than 250 ms, the daemon sends `Cook_Progress` at most every 100 ms and at the end of each step: the step's kind, a stage's name for a stage's step, and the jobs that are done of the total. A step is the assets of a kind, or one stage's meshes and textures, as a stage is most of a large cook. Which counts the messages carry depends on the timing; what the pass cooks does not. A quick pass sends none.
- **An entry has everything that the editor shows,** the import settings, the behaviour class, a sub-asset's parent and name, a material's permutations, a texture's size and a material's tool texture and hotspots included, so the editor never asks for an asset's details or opens an image. It finds an asset's dependents in the dependencies of the others.
- **Previews:** `Cook_Preview` gives the text of a material that the editor has not saved. The daemon scans the roots, cooks the text as the material with that GUID, for its default switches only, into the preview area of the cache, `<cache>/dev/preview/<guid>.blob`, and answers with a `Preview_Result` of the same request ID: the first error, or `""`, and the problems with the lines of the text. A preview cooks between passes, writes no generation and changes no index; its problems go in the answer and not to the log. The daemon deletes the preview area when it starts (see [Rendering](../rendering/materials.md#material-previews)).
- **Schema:** `cook --emit-link-schema` writes `build/obj/link/cook-schema.json`, and the editor's generator turns it into C# in `Cinnabar.Editor.Link.Cook`, as it does the editor link's schema in `Cinnabar.Editor.Link.Protocol`.

| Group | Messages |
|---|---|
| Session | `Hello`, `Welcome`, `Refused`, `Log` |
| Index | `Asset_Snapshot` with every asset and folder, then `Asset_Delta` with the changed and removed assets and the folders that came and went, and `Shading_Models` |
| Cooking | `Cook_Progress` with a step's kind, a stage's name, and the jobs done and in all, `Asset_Problems` with each problem's file, line, column and text, and `Cook_Finished` with the generation, the counts and the time |
| Previews | `Cook_Preview`, a request answered with a `Preview_Result` of the same request ID |
| Operations | `Create_Asset`, `Create_Folder`, `Move_Assets`, `Rename_Asset`, `Rename_Folder`, `Duplicate_Assets`, `Delete_Assets`, `Set_Import_Settings`, `Reimport`, each a request answered with an `Operation_Result` of the same request ID: the reason that it failed, or the GUIDs of the assets that it made |

