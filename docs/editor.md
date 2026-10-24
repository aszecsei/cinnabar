# Editor

The editor is a separate C# application, built with Avalonia. It runs `host.exe` as a child process and controls it through the editor link. See [Architecture](architecture.md#editor) for the overview.

The model for the layout is a dense production tool: a ribbon of commands, a docked outliner, a viewport with tool overlays, a categorized property grid, and panels for undo history, the log and resource counters.

## Processes

- **Host:** the editor starts the host inside a Windows Job Object, so the host exits when the editor exits. If the host crashes, the editor stays up, reports the crash and offers to restart the host (see [Crash recovery](#crash-recovery)).
- **Cook daemon:** the editor also starts the cook daemon. It asks the daemon to create, move and re-import assets, and the daemon keeps each asset's `.meta` file with it.
- **Standalone:** `host.exe` also runs without the editor, in its own window.
- **Arguments:** the editor starts the host with `--shared <name>` for the viewport (see [GPU](gpu.md#presentation)), `--link <port>` for the editor link, and `--adapter <luid>` (see [Viewport](#viewport)).

## UI framework

The editor uses Avalonia on .NET 10, not WPF. The deciding factor is the viewport.

- **WPF cannot show a D3D12 texture directly.** `D3DImage` takes only D3D9Ex surfaces, so each frame would go from D3D12 through D3D11 to a legacy shared texture and into D3D9Ex: an extra copy, BGRA8 only, and pacing tied to WPF's render thread. A child swapchain in an `HwndHost` avoids the copy, but WPF content cannot draw over it (the airspace problem), so the tool palette and the stats overlay would each need their own window.
- **Avalonia imports external GPU images into its compositor.** `ICompositionGpuInterop` imports D3D11 textures, so the viewport is an ordinary composited control, and other controls draw over it. On Windows the import needs a keyed mutex, which a D3D12 resource cannot have, so the editor copies each frame once (see [Viewport](#viewport)).
- **What WPF has that Avalonia lacks** is a mature ribbon and a wider set of third-party controls. The editor builds its own ribbon (see [Ribbon](#ribbon)), and it would build its own property grid in either framework, because the types come from the DLL over the link and not from CLR objects.
- Avalonia also runs on other platforms. That is not a goal, but it means a later Vulkan or Metal port does not force a new editor.

## Projects

The editor is in `src/editor`. Only the application project references Avalonia. The others are plain .NET libraries, so tests run without UI. A project is added with the phase that first needs it: phase 2 added `Commands` and `Tests`, phase 3 added `Link` and its generator, phase 4 added `Model`, and phase 5 added `Document`.

| Project | Responsibility |
|---|---|
| `Cinnabar.Editor.Link` | The editor link client: the connection, framing, the wire format, and the messages that the generator writes from the schema. |
| `Cinnabar.Editor.Link.Generator` | The Roslyn source generator that turns the link's schema into C# records with their readers and writers. |
| `Cinnabar.Editor.Model` | The type registry and the mirror of the host's world: entities, hierarchy, and the watched field values. It is updated only from link events. |
| `Cinnabar.Editor.Document` | Scenes: the scene file's reader and writer, the snapshot that the host loads, operations, the undo stack, save, and autosave. |
| `Cinnabar.Editor.Commands` | The command registry. The ribbon, menus, shortcuts and the command palette all run commands from it. |
| `Cinnabar.Editor` | The Avalonia application: the shell, docking, the ribbon, the panels and the viewport. |
| `Cinnabar.Editor.Tests` | Tests for the libraries and for the shell, which has no controls of its own, so a test can build one without a window. Later, tests against a real host with the null backend. |

`just editor` builds the solution with `dotnet build`, `just edit` builds everything and starts the editor with the game's `scenes/main.scene`, and `just test` runs the editor's tests with the engine's. Build output goes to `build/dotnet`. The editor's settings are in `%LOCALAPPDATA%\cinnabar\editor`.

## Document model

**The editor owns the scene.** The host's world is a mirror of the editor's document while the editor is in edit mode.

- **Why:** the host can lose its world at any time. A crash loses it, and so does a soft restart after a `Game_State` layout change (see [Hot reload](hot-reload.md#reload-sequence)). Unsaved edits must survive both. If the host owned the scene, they would not.
- **Edits are operations.** Every change is an operation on the document: create or destroy an entity, rename, reparent, set active, add or remove a component, set or reset a field, remove a behaviour, and set or reset a behaviour's field. Each operation returns its inverse when it applies. The editor applies an operation to its document, puts it on the undo stack and sends it to the host in `Apply_Operations`. The host applies it to its world. The editor never waits for the host to confirm an edit.
- **Resetting** a field removes it from the scene, so a component's field is zero and a behaviour's field has its class's default, as in a scene that does not set it.
- **Edits of more than one operation:** destroying an entity destroys its descendants first, each with its own operation, so undo creates each after its parent. Duplicating copies an entity and its descendants with new scene IDs, and a reference inside the copy refers to the copy. Reparenting sets the entity's `Local_Transform`, or for a new root its `Transform`, so it stays where it is in the world: `SceneEdits` composes poses as the engine's propagation does.
- **Transactions:** an interaction groups its operations into one undo entry. A gizmo drag or a drag on a number field sends field values while it moves, and makes one undo entry when the mouse is released. A step that replaces the step before it, such as the next value of the same field, takes its place, so the entry has the last value and the first inverse. An operation that does not fit the document, such as one for an entity that is not there, undoes the transaction's earlier steps and goes to the console.
- **Undo and redo** are Ctrl+Z and Ctrl+Y. A new edit after an undo drops the entries after it. The document is dirty when its position in the history is not the one that the file has, so undoing back to it makes the document clean again. The title bar and the status bar mark a dirty scene with a dot.
- **Save** (Ctrl+S) writes the file through a temporary file, so a crash never leaves half a file. Save As (Ctrl+Shift+S) writes a new file, which the editor then edits. Closing the editor or opening another scene with unsaved changes asks whether to save them.
- **Selection by scene ID:** the editor keeps the selected entity's scene ID, so a resync, which gives every entity a new handle, keeps the selection. An entity that an edit creates is selected when the host reports it. Entities that the game spawned have no scene ID, and the editor does not edit them.
- **Resync:** when the link connects, the editor sends the whole document as a scene snapshot (`Load_Scene`), and the host replaces its world with it. This is the same path after a crash, a host restart and a soft restart. The host reports a soft restart with an event, and the editor sends the snapshot again. The game loads its own scene at `init`, so without an open document the host shows that.
- **Opening a scene:** `--scene <file>`, or Open Scene (Ctrl+O). A file with an error does not open: its problems go to the console with their lines, and the open scene stays. The title bar and the status bar show the scene's file.
- **Rejected operations:** the host can refuse an operation, for example a field that the new DLL no longer has. It sends `Edit_Problems` with the entity's scene ID and the reason. The document keeps the operation, and the editor shows a warning on the entity, in the outliner and the properties panel, and in the console. A scene load sends its problems too, which replace the ones before them. The document is never changed to match the host.
- **The game's side** maps scene IDs to entities. A load fills the map, and a stale entry, such as for the game's own scene at `init`, makes the game build it again from every entity's `Scene_Entity`. The operations use the loader's procedures for an entity, a component or a field, so they convert values and report problems as a load does.

### Modes

| Mode | Host runs | Edits |
|---|---|---|
| Edit | Transform propagation, render extraction and editor rendering. No `Fixed` or `Update` systems, and no scripts. | Operations on the document |
| Play | The full frame. | None. The outliner and properties show the host's world, read-only, with a tint. |
| Paused | Nothing, or one frame per step command. | None |

- **Play** tells the host to start the simulation on the world it has. Scripts get `awake` and `start` as for a scene load.
- **Stop** tells the host to discard its world, and the editor sends the snapshot again. Nothing from play mode reaches the document.
- Entities that the game spawns at run time have no scene ID. The outliner shows them in play mode under their handle.

## Scenes

A scene is a source asset with a GUID and a `.meta` file, like every other asset (see [Content pipeline](content-pipeline.md#identity)). The cooker parses scenes with `asset_format.scene_parse`, and the editor with `SceneFile` in `Cinnabar.Editor.Document`. The two must agree.

- **Scene IDs:** each entity in a scene has a 64-bit random ID, nonzero and unique in its scene. Operations, the link and the scene file use scene IDs. The host maps them to entity handles, which change on every load. The loader gives each entity a `Scene_Entity` component with its scene ID, and `Entity_Info` carries it to the editor.
- **Text source:** a scene file is text, so it diffs and merges. It starts with `scene 1`, the format's version. It has one block per entity, sorted by scene ID, so an edit changes only the lines of the entity it touches. Fields are written by name. A line that starts with `#` is a comment, and the editor keeps only the comments before `scene 1`.
- **Entity keys:** an entity block has `name`, `parent` (a scene ID) and `active = false` for a disabled entity, then its `component` and `behaviour` blocks with their fields indented. An entity key that the editor does not know is a warning, and the editor writes it back unchanged.
- **Values:** `true` and `false`; a number, or an array of up to four numbers such as `[0, 0.7071068, 0, 0.7071068]`; a quoted string with `\"`, `\\`, `\n` and `\t`; a scene ID after `@`, such as `@1b04c7e95a2f3d88`, or `@0` for none; and a bare word, such as an enum value's name. A number written as an integer is kept exactly. The writer gives every float a point or an exponent, so it reads back as a float.
- **Components by stable ID:** a component block gives the [stable ID](world.md#ecs) and the type's name. The loader uses the ID. The name is for people and for error messages.
- **Positions** are raw `i64` values (see [World](world.md#where-positions-go)), so a scene round-trips exactly. The editor shows meters.
- **Unknown data round-trips.** A component ID or a field that the current DLL does not know is kept, written back unchanged, and reported as a warning. A broken build therefore never deletes scene data.
- **Behaviours** are written by script GUID, with their field values by name.
- **Names:** the engine's `Name` component holds up to 63 bytes in the component itself, because component storage holds no pointers. A longer name is cut at a character boundary. The outliner and the properties panel show names, and `Entity_Info` carries them.
- **Prefab paths:** an entity in a prefab instance is identified by a path: the instance's scene ID, then `#` and the entity's scene ID in the prefab, such as `5f3a9c01e2b47d10#a90b3e7f15c4d2e8`. A prefab in a prefab adds a level for each nesting. The prefab's asset GUID is not in the path, because every instance of a prefab has the same one. The path stays the same when the prefab changes, so overrides in the scene still find their entities.

A sketch of the format:

```
scene 1

entity 5f3a9c01e2b47d10
name = "Door"
parent = @1b04c7e95a2f3d88
component 1 Transform
	position = [16777216, 0, -754974720]
	rotation = [0, 0.7071068, 0, 0.7071068]
	scale = [1, 1, 1]
behaviour 9d2e41c0b7a35f6e81c4d2a90b3e7f15
	open_angle = 90
	trigger = @7a11e0c3d94b2f56
```

**Cooking:** the cooker cannot lay out native components, because their types exist only in the DLL. The cooked blob therefore stores each field as a tagged value with the hash of its name (see [Content pipeline](content-pipeline.md#scenes)), and the scene loader in `lib/engine/scene` matches them to the fields of the registered types at load. The same code applies a snapshot from the editor.

**Loading** replaces every entity in the world, between frames, with `ecs.despawn_all`. After it, the world gives out the freed slots from the lowest index up, so the handles, and with them the outliner's order, follow the scene's order. The loader spawns every entity before it sets any field, so a field can refer to an entity later in the file.

- A field that the scene does not set is zero. A value is converted to its field's kind: an integer must fit, an enum takes a name or an integer, a position takes three integers, and an entity takes a scene ID.
- What the world cannot use is skipped with a warning, and the rest of the entity still loads: a component that the game does not register, a field that its type does not have, a value that does not fit, a scene ID that is not in the scene, or a behaviour field that the class does not declare.
- `Previous_Transform` starts equal to `Transform`, so nothing interpolates from where the old world was. Behaviours wake in the next script phase.
- The `Name`, `Parent`, `Inactive` and `Scene_Entity` components come from the entity's keys, so a component block for one of them is ignored.
- A component that cooked scenes use gets an explicit ID (see [World](world.md#component-registry)). The sample game's components are 1001 and up.

## Editor link

The editor link is a message connection between the editor and the host. It uses TCP. Locally it runs over loopback. Later, the same protocol connects to a host on another machine or a console.

- **The host is the server.** It listens on `127.0.0.1` at the port that `--link` gives, so only the local machine can connect. It serves one editor at a time and refuses a second connection. The editor picks a free port, starts the host with it, and connects, retrying while the host starts. It connects again after a host restart.
- **Framing:** each message is a 12-byte little-endian header (payload length, kind, flags, request ID) and a payload of at most 64 MiB. A response has the request ID of its request. An event has request ID 0.
- **Wire format:** numbers are little-endian as they are in memory, a `bool` is one byte, enums are their backing integer, and strings and slices are a `u32` count followed by their bytes or elements. A fixed array has no count, and a struct is its fields in order. A payload that does not decode to exactly one message is refused.
- **Handshake:** the editor sends `Hello` with its protocol version. The host answers `Welcome` with the game's name and the DLL's layout hash, or `Refused` with both versions, and the editor shows the reason.
- **Two handlers.** The host handles the messages that need no game state: the handshake, viewport size and frame acknowledgements now, and input, mode changes and stats later. It passes every other message, still encoded, to `Game_API.editor_poll`, once per frame between frames, with the connection (0 while no editor is linked). The game decodes them with its own copy of `lib/engine/editor/link`, and appends its own messages to a buffer that the host owns, which the host then queues. The game cannot write to the outbox directly: it logs while it polls, and the logger takes the outbox's lock. Type info for game-side types exists only in the DLL's image, so the editor never reflects over game types itself.
- **Threads:** in the host, an accept thread waits for the editor, a reader thread queues its messages, and a writer thread sends the outbox. The main thread handles the queued messages between frames, after the reload point, while no job runs. Events of a frame go out at the end of it.
- **The log:** while an editor is linked, the host's logger sends every line, the game's and the jobs' included, over the link instead of to the host's console. A line carries its level, time, location and text. If more than 16 MiB is waiting to be sent, log lines are dropped and counted. The editor's console also shows the host's own console output, which has the lines before the link and anything that does not go through the logger, such as a crash.
- **One schema:** the messages are Odin structs in `lib/engine/editor/link`, a package that imports nothing from core or engine, so the host and the game both use it. `just link-schema` runs `host --emit-link-schema`, which writes `build/link/link-schema.json`, and a C# source generator for `Cinnabar.Editor.Link` reads it. A message's kind is its index in the `Message` union, and the protocol version is a hash of the schema, so any change to a message changes the version. A changed message is a build error in the editor, not a decode error at run time. Odin's `Snake_Case` names become `PascalCase` in C#.

### Messages

| Group | Messages |
|---|---|
| Session | `Hello`, `Welcome`, `Refused`, `Log`, `Game_Reloaded` |
| Types | Component types with their fields, behaviour classes with their fields, game commands |
| World | Entity list snapshot and deltas (create, destroy, rename, reparent), watch and unwatch an entity, field value deltas for watched entities |
| Edit | `Load_Scene`, `Apply_Operations`, `Edit_Problems` |
| Viewport | `Viewport_Size`, `Frame_Target`, `Frame_Acknowledged`; later camera, selection, gizmo state, input, pick request and result |
| Mode | Play, pause, step, stop |
| Stats | Frame times, memory, counters, script memory by module |

## World

The game's side of the link is `lib/engine/editor`. The game keeps an `editor.Editor` in its `Game_State`, and its `Game_API.editor_poll` calls `editor.poll` with the world and the script runtime. On the editor's side, `WorldModel` in `Cinnabar.Editor.Model` mirrors what it hears. The mirror is read-only: it changes only through the game's messages.

- **A new connection gets everything.** When `poll` sees a connection that its state is not for, it sends `Component_Types` and an `Entity_Snapshot`. After a `Load_Scene`, it sends an `Entity_Snapshot` again, and forgets the watches, whose entities are gone. A soft restart makes a fresh `Game_State`, which knows no connection, so the editor gets everything again then too. A snapshot replaces the editor's mirror, and the editor sends its watches again after one.
- **Deltas:** at most ten times a second, the game scans the world with `ecs.world_iter` and compares each entity slot with what it last told the editor: the handle, the archetype (which stands for the set of components), the parent, the active state and the name. It sends an `Entity_Delta` with the changed entities and the destroyed ones. A slot that a new generation took counts as a destroyed entity and a new one. The scan visits every entity, which suits worlds of tens of thousands; larger worlds will need change tracking in the ECS.
- **Watching:** the outliner needs every entity, but only a few entities need their field values. The editor sends `Watch_Entity` and `Unwatch_Entity` for the selection, and the game sends `Entity_Values` for each watched entity at most twenty times a second, and only when the encoded values changed. A watched entity that dies stops being watched. At most 64 entities are watched.
- **Values are bytes.** A component's value is its memory, and the editor reads each field at its offset with `FieldValues`, so the game does no per-field work. A behaviour's fields come from `script.inspect`, which reads the instance's table for each field that `Behaviour.define` declared, without calling any script code. A behaviour's value also names the script asset whose module returned its class, which is how the document finds it.
- After a code reload, the game sends the types again, and the panels rebuild.

### Types

- A component type gives its stable ID, its name, its size and its fields. A field gives its name, offset, kind, read-only flag and range, and an enum's backing kind and named values.
- **Field kinds:** the integer and float types, `bool`, enums, `[3]f32`, `quaternion128`, `World_Position` and `Entity`. A nested struct that is none of these adds its fields with dotted names, such as `inner.amount`. Other fields are hidden. *Asset references come with asset fields.*
- **Struct tags:** `editor:"-"` hides a field, `editor:"read"` makes it, and anything in it, read-only, and `editor:"range=0,100"` gives a slider range. The walk follows the same rules as `script.expose`. The `Behaviours` component's Luau reference is hidden this way. The walk is `scene.component_fields`, so a scene can set exactly the fields that the editor shows.

## Viewport

- **Frames:** the host renders into the named shared textures `<name>.textureN` and signals `<name>.fence` (see [GPU](gpu.md#presentation)).
- **One copy per frame.** Avalonia's Windows backend, ANGLE on D3D11, imports only D3D11 textures with a keyed mutex, in `R8G8B8A8_UNORM`, and it imports no semaphores. Its Vulkan backend imports only Vulkan's own handles. The `Direct3D12FenceNtHandle` semaphore type exists only for macOS. So the editor has its own D3D11 device, which opens the host's textures. On each composition update, if the host's fence shows a newer finished frame, the editor copies that frame into one of three keyed-mutex textures of its own, and gives that texture to the compositor. The fence is read on the CPU, so the copy never waits on the GPU.
- **Opening the host's objects:** D3D11 cannot open a named shared object, so a D3D12 device on the same adapter turns the names into handles. D3D11 refuses a shared typeless texture from D3D12 unless it allows simultaneous access, so the host's shared textures have the frame target's typed sRGB format.
- **Same adapter:** shared objects open only on the adapter that created them. The editor reads the LUID of Avalonia's composition adapter and starts the host with `--adapter <luid>`.
- **Back-pressure:** the editor reads a host texture only while it copies it. After each copy it ends a D3D11 event query, and when the GPU has passed it, the editor sends `Frame_Acknowledged` with the generation and the frame. The host renders frame k into a shared texture only if k ≤ acknowledged + 2, so it never draws into a texture that the editor is still copying. Otherwise `core` gives the frame a scratch target that nothing reads. A slow editor drops frames from the viewport. It never stalls the simulation. The host paces frames from the editor's `Hello` until the link closes.
- **Resizing:** the viewport sends its size in physical pixels, once it has not changed for 120 ms, so a drag makes one resize. The host renders at that size from a following frame, clamped to 8192 on each side, and sends `Frame_Target` with the new generation's name prefix, number and size. The editor opens the new set and releases the old one, and keeps the last picture on screen until the new generation's first frame. The host sends `Frame_Target` for the first generation right after the `Welcome`.
- **Camera:** in edit mode, the editor owns the camera. The fly and orbit controls are in C#, and the editor sends the pose (a `World_Position`, a rotation and the projection) each frame. A host restart therefore keeps the view. In play mode, the game's camera is used, unless the editor turns on its free camera.
- **Input:** while the viewport has focus in play mode, the editor sends keyboard and mouse input, and the host gives it to the game as `core.Input` (see [Core](core.md#input)).
- **Selection and picking:** the host renders an entity ID buffer in edit mode. A pick request gives a pixel, and the result gives the scene ID and the depth. A box selection gives a rectangle and gets a list. The host draws the selection outline.
- **Gizmos:** the gizmo's interaction is in C#. The editor knows the camera and the selected entities' poses, does the hit test and the drag math, and sends field values. The host only draws the gizmo from the gizmo state message (kind, pose, space, highlighted axis). Snapping is in the editor too.
- **Overlays:** the tool palette, the stats overlay and the camera speed control are Avalonia controls over the viewport.
- The editor does not reparent the host's window into its own. Windows attaches the input queues of a cross-process parent and child window, so a stall in the game would freeze the editor UI.

## Shell

- **Docking:** the Dock library for Avalonia. The default layout is the outliner on the left, the viewport in the middle, the properties and undo history on the right, and the console, asset browser and resource monitor at the bottom.
- **One instance of each panel.** Closing a panel takes it out of the layout, and showing it again puts the same panel back in its default dock, so its state survives. Docking can rebuild a panel's view at any time, so a view holds no state: the console's lines are in a `ConsoleLog`, and the viewport's device and frames are in a `ViewportSession`.
- **The layout file:** the editor saves the layout to `layout.json` when it closes. The file is the editor's own: the tree of splits, tool docks and the document dock, with proportions and panel IDs. Dock's serializer would store Dock's types, and need metadata for each. A panel that floats docks again in its default dock at the next start, and panels cannot be pinned. A layout that has no viewport, or that does not parse, is replaced by the default with a warning in the console.
- **The viewport is the only document.** It cannot close, float or move into a tool dock.
- **Status bar:** the host's state (waiting for the viewport, running, stopped, exited with its code), the scene's file, the entity count and the mode. The selection count comes with selection.
- **Theme:** dark, with one accent color, cinnabar (`#E34234`), also in Dock's brushes. Play mode tints the shell. Icons are Fluent UI System Icons (MIT), as path data in `Icons/Icons.axaml`, so the editor depends on no icon package.
- **Errors:** an exception that no code handles on the UI thread goes to the console, and the editor keeps running. A bug in one panel must not close the editor and lose unsaved work.

### Ribbon

The editor has its own ribbon control. The Avalonia ribbon libraries are small and not maintained much, and a ribbon that reads the command registry is not much work.

- **The ribbon is data.** A layout gives tabs, groups in each tab, and items in each group. Every item names a command ID. The ribbon has no logic of its own.
- **Item kinds:** large button, a stack of up to three small buttons, split button, dropdown, and combo box. A toggle command shows as a toggle in any of them, with a check in menus. A combo box needs a choice command, which has a list of options. A gallery comes later.
- **Validation:** `RibbonLayout.Validate` finds unknown commands, unknown categories, repeated tabs and items of the wrong shape. The shell reports them in the console, and a test checks the default ribbon.
- **Tab categories:** a tab can belong to a category with a name and a color, such as Art, Design or Audio. The category shows as a colored band over its tabs, with its name over the first tab of each run. The editor's tabs have no categories yet, so no band shows.
- **Contextual tabs** have a condition, such as "a terrain entity is selected", and show only when it is true. A condition is a named context, such as `host.running`, that the editor sets.
- **Game commands** that the DLL describes can name a tab and a group. They appear in the ribbon, and they come and go with a code reload.
- Double-clicking a tab, or Ctrl+F1, collapses the ribbon to its tabs, and clicking a tab opens it again. When the window is too narrow, the ribbon scrolls.
- *Later:* groups that shrink as the window narrows, key tips, and a quick access toolbar.

### Commands

- A command has an ID such as `edit.undo`, a label, an icon, a default shortcut, a can-execute check and an execute procedure.
- **Editor commands** are C#. **Game commands** are described by the DLL and run in the game through `Game_API.editor_poll`. A game command that changes the scene returns operations, and the editor applies them as for any edit, so they can be undone.
- **Toggles and choices:** a command with a checked state is a toggle. A choice command picks one of a list of options. A command raises `Changed` when it runs, and owners of shared state, such as the host session, invalidate every command, so views update without polling.
- **Key bindings:** `keybindings.json` in the editor settings is an object from command ID to key gesture, such as `{ "view.stats": "F3" }`. An empty gesture removes a shortcut. When two commands get the same gesture, the first by ID keeps it, and the console says so.
- **The command palette** (Ctrl+Shift+P) searches every command by label and ID. Every word of the query must match. A label that starts with the query ranks first, then a label with a word that starts with it.

## Panels

| Panel | Contents |
|---|---|
| Outliner | The entity hierarchy, with a filter, visibility and lock toggles, drag to reparent, and multi-select |
| Properties | The components and behaviours of the selection |
| Viewport | The frames, the overlays, the gizmo and the camera |
| Asset Browser | The content roots, through the cook daemon |
| Undo History | The undo stack, after a row for the scene as it opened. Clicking an entry undoes or redoes to it. Undone entries are dimmed, and the one that the file has is marked saved. |
| Console | The host's and the cooker's log, with filters by level and source |
| Resource Monitor | Frame times, memory, GPU resource counts and script memory by module |

### Outliner

- The outliner is a virtualized list of the visible rows of the tree, indented by depth. A tree control with one item per entity does not scale to tens of thousands of entities.
- The hierarchy comes from `Parent`, in handle order. An entity whose parent the editor does not know is a root. Rows start expanded, and the outliner remembers the ones that the user collapsed.
- A row shows the entity's name, or the entity as the engine prints it (`Entity(3:1)`) when it has none, and its components, without the ones that the tree shows itself (`Parent`, `Previous_Transform`, `Inactive`, `Disabled`, `Name`, `Scene_Entity`). An inactive entity is dimmed.
- **Filter:** a filter shows the rows whose name, entity or components match, with their ancestors.
- **Dragging** a row onto another row reparents its entity, and onto the space below the rows makes it a root, without moving it in the world. A row cannot go under itself or its descendants. A row also drags onto an entity field in the properties panel.
- A row's menu duplicates, deletes and moves to the root, and makes a new entity. A row whose entity the game could not apply all of has a warning mark, with the problems in its tooltip.
- **Visibility and lock are editor state.** Hidden entities are not drawn in the viewport, and locked entities cannot be picked. Neither changes the game's `Disabled` state, and neither is saved in the scene. The editor saves them for each user.

### Properties

- The panel is built from the type descriptors: one group per component or behaviour, one row per field, and an editor for each field kind. A component with no fields the editor can show, such as a tag, is a chip with its name. The components that the header shows (`Parent`, `Name`, `Inactive`, `Scene_Entity`) and `Behaviours` are not groups.
- **Editing:** a field edits when the document has its component or behaviour. A number, a string or an axis is a box that sets the field on Enter or when it loses focus, and puts the value back on Escape. Dragging a number's name, or an axis's colored marker, changes it in one undo entry, ten times as fast with Shift and a tenth with Ctrl. A `bool` is a check box, an enum a choice of its names, and an entity reference takes a drop from the outliner and has a button that clears it. A rotation edits as Euler angles, so an edit of one angle keeps the others as they show. A position edits in meters, with m, km, Mm or Gm, and the other axes keep their raw values exactly. A box that has focus keeps what the user types while the host's values arrive.
- **What does not edit:** fields with `editor:"read"`, a child's `Transform`, which propagation writes from its `Local_Transform`, `Previous_Transform`, which the world writes, and entities that the game spawned.
- **The header** edits the name and, with the Active badge, the active state. Each group has a button that removes its component or behaviour, and Add Component offers the registered types that the entity lacks. A `Transform` or a `Local_Transform` starts as the identity. Adding a behaviour comes with the asset browser, which lists the scripts.
- A component that the document has and the game does not is a group with its values as the file writes them. The scene keeps it, and the group can remove it.
- The panel builds its controls when the entity, its components or its behaviours change. When only values change, it updates their text, so it keeps its expanders and scroll position while values change twenty times a second. A collapsed group stays collapsed across selections.
- An entity reference, such as `Parent` or an entity field, is a link that selects that entity.
- **Reset:** a field that the scene sets shows a reset button, which removes it from the scene. With prefabs, the default is the prefab's value.
- **Multi-select** comes with box selection: the panel shows the components that every selected entity has. A field whose values differ shows as mixed, and setting it makes one operation for each entity, in one transaction.
- **How values show:** vectors, positions and rotations are three boxes marked red, green and blue for x, y and z. A rotation shows Euler angles in degrees, in the engine's order (z, then x, then y, as `Quaternion.euler` in scripts), with the quaternion in the tooltip. A position shows a distance in the largest unit of m, km, Mm and Gm that keeps it short, with the exact meters in the tooltip, and sets raw values. Numbers have grouped thousands and at most three decimals. A `bool` is a check box, an enum its value's name, and names read as words: `Previous_Transform` is "Previous Transform". Components without fields, such as tags, are chips under the groups, and a behaviour's group has a Script badge.
- An entity reference shows the target's name, and accepts a drag from the outliner. An asset reference shows the asset's name, and accepts a drag from the asset browser.

### Asset browser

- The editor never writes a `.meta` file. It asks the cook daemon to create, move, rename and re-import assets, so each asset keeps its GUID (see [Content pipeline](content-pipeline.md#identity)).
- Until the cook daemon exists, the asset browser is read-only.

## Crash recovery

- **Host crash:** the document is in the editor, so nothing is lost. The editor reports the crash with the end of the host's log, and restarts the host. The link connects again, the editor sends the snapshot, and the camera and the selection stay.
- **Editor crash:** the editor saves each dirty scene to `build/editor/autosave/` every 30 s, and when a transaction ends if 30 s have passed. An autosave is named for its scene's file and a hash of its full path. When a scene opens and its autosave is newer than its file, the editor offers to restore it. Restoring makes the scene dirty, because its file lacks the changes. Saving the scene, undoing back to its file, choosing not to save it, or discarding the offer deletes the autosave.
- **Code reload:** the host sends the types again. **Soft restart:** the host also sends a restart event, and the editor sends the snapshot again (see [Document model](#document-model)).

## Implementation phases

1. **Viewport:** an Avalonia window that shows the host's live frames: the editor's D3D11 device, the copy into keyed-mutex textures, the host's `--adapter`, and the host in its Job Object.
2. **Shell:** the projects, the docking layout, the ribbon and the command registry.
3. **Link:** the server in `src/host`, the handshake, the schema and the C# generator, back-pressure, resizing, and the console. Tests in `Cinnabar.Editor.Tests` run the real host when it is built: the handshake, a refused version, a resize, and back-pressure measured on the shared fence.
4. **Read-only world:** types, the entity list and deltas, the outliner, and the properties panel for watched entities, with behaviours' fields.
5. **Scenes:** the `Name` component, the scene format, the loader, `cook scenes`, and snapshots over the link.
6. **Editing:** operations, transactions, undo history, save and autosave, and field editors.
7. **Viewport tools:** the editor camera, the ID buffer and picking, the selection outline, gizmos and snapping.
8. **Modes:** play, pause, step and stop, and input forwarding.
9. **Later:** the asset browser (with the cook daemon), the resource monitor, game commands in the ribbon, prefabs.

## Deferred

- **Large worlds:** positions reach ±2^38 m, and one scene file per world does not scale. Level and world streaming will split the world into scenes that load separately, and the editor will then edit several scenes at once.
- **Edit-mode scripts:** some tools need behaviours that run in edit mode, like Unity's `ExecuteInEditMode`. Edit mode runs no scripts until then.
- **More than one viewport:** each viewport has its own shared target and camera, so the host renders the scene once for each viewport.
