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

The editor is in `src/editor`. Only the application project references Avalonia. The others are plain .NET libraries, so tests run without UI. A project is added with the phase that first needs it: phase 2 added `Commands` and `Tests`.

| Project | Responsibility |
|---|---|
| `Cinnabar.Editor.Link` | The editor link client: the connection, framing, the message codecs, requests and event streams. |
| `Cinnabar.Editor.Model` | The type registry and the mirror of the host's world: entities, hierarchy, and the watched field values. It is updated only from link events. |
| `Cinnabar.Editor.Document` | Scenes, operations, the undo stack, selection, save, and autosave. |
| `Cinnabar.Editor.Commands` | The command registry. The ribbon, menus, shortcuts and the command palette all run commands from it. |
| `Cinnabar.Editor` | The Avalonia application: the shell, docking, the ribbon, the panels and the viewport. |
| `Cinnabar.Editor.Tests` | Tests for the libraries and for the shell, which has no controls of its own, so a test can build one without a window. Later, tests against a real host with the null backend. |

`just editor` builds the solution with `dotnet build`, `just edit` builds everything and starts the editor, and `just test` runs the editor's tests with the engine's. Build output goes to `build/dotnet`. The editor's settings are in `%LOCALAPPDATA%\cinnabar\editor`.

## Document model

**The editor owns the scene.** The host's world is a mirror of the editor's document while the editor is in edit mode.

- **Why:** the host can lose its world at any time. A crash loses it, and so does a soft restart after a `Game_State` layout change (see [Hot reload](hot-reload.md#reload-sequence)). Unsaved edits must survive both. If the host owned the scene, they would not.
- **Edits are operations.** Every change is an operation on the document: create or destroy an entity, set a field, add or remove a component or a behaviour, reparent, rename. Each operation has an inverse. The editor applies an operation to its document, puts it on the undo stack and sends it to the host. The host applies it to its world. The editor never waits for the host to confirm an edit.
- **Transactions:** an interaction groups its operations into one undo entry. A gizmo drag or a drag on a number field sends field values while it moves, and makes one undo entry when the mouse is released.
- **Resync:** when the link connects, the editor sends the whole document as a scene snapshot, and the host replaces its world with it. This is the same path after a crash, a host restart and a soft restart. The host reports a soft restart with an event, and the editor sends the snapshot again.
- **Rejected operations:** the host can refuse an operation, for example a field that the new DLL no longer has. The document keeps the operation, and the editor shows a warning on the entity. The document is never changed to match the host.

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

A scene is a source asset with a GUID and a `.meta` file, like every other asset (see [Content pipeline](content-pipeline.md#identity)). Scenes do not exist yet. This section gives the design.

- **Scene IDs:** each entity in a scene has a 64-bit random ID, unique in its scene. Operations, the link and the scene file use scene IDs. The host maps them to entity handles, which change on every load.
- **Text source:** a scene file is text, so it diffs and merges. It has one block per entity, sorted by scene ID, so an edit changes only the lines of the entity it touches. Fields are written by name.
- **Components by stable ID:** a component block gives the [stable ID](world.md#ecs) and the type's name. The loader uses the ID. The name is for people and for error messages.
- **Positions** are raw `i64` values (see [World](world.md#where-positions-go)), so a scene round-trips exactly. The editor shows meters.
- **Unknown data round-trips.** A component ID or a field that the current DLL does not know is kept, written back unchanged, and reported as a warning. A broken build therefore never deletes scene data.
- **Behaviours** are written by script GUID, with their field values by name.
- **Names:** the engine gets a `Name` component, so that the outliner can show names in play mode.
- **Prefab paths:** an entity in a prefab instance is identified by a path: the instance's scene ID, then `#` and the entity's scene ID in the prefab, such as `5f3a9c01e2b47d10#a90b3e7f15c4d2e8`. A prefab in a prefab adds a level for each nesting. The prefab's asset GUID is not in the path, because every instance of a prefab has the same one. The path stays the same when the prefab changes, so overrides in the scene still find their entities.

A sketch of the format:

```
entity 5f3a9c01e2b47d10
name = "Door"
parent = 1b04c7e95a2f3d88
component 1 Transform
	position = [16777216, 0, -754974720]
	rotation = [0, 0.7071068, 0, 0.7071068]
	scale = [1, 1, 1]
behaviour 9d2e41c0b7a35f6e81c4d2a90b3e7f15
	open_angle = 90
	trigger = 7a11e0c3d94b2f56
```

**Cooking:** the cooker cannot lay out native components, because their types exist only in the DLL. The cooked blob therefore stores each field as a tagged value with the hash of its name, and the scene loader in `lib/engine` matches them to the registry's field descriptors at load. The same code applies a snapshot from the editor.

## Editor link

The editor link is a message connection between the editor and the host. It uses TCP. Locally it runs over loopback. Later, the same protocol connects to a host on another machine or a console.

- **The host is the server.** It listens on the port that `--link` gives. The editor connects, and connects again after a host restart.
- **Framing:** each message is a little-endian header (length, kind, request ID) and a payload. A response has the request ID of its request. An event has request ID 0.
- **Handshake:** the first messages give the protocol version, the game's name and the DLL's layout hash. A version mismatch closes the link with an error that names both versions.
- **Two handlers.** The host handles the messages that need no game state: input, viewport size, frame acknowledgements, mode changes and stats from `core`. It passes every other message to `Game_API.editor_message`, which `lib/engine/editor` implements. Type info for game-side types exists only in the DLL's image, so the editor never reflects over game types itself.
- **When messages run:** a host thread reads the socket and queues messages. The host runs them at the start of the frame, after it polls input and before the fixed ticks, while no system runs. Events are sent at the end of the frame.
- **One schema:** the messages are Odin structs in `lib/engine/editor`. `host --emit-link-schema <file>` writes a JSON description of them, like `--emit-script-types`, and a C# source generator in `Cinnabar.Editor.Link` reads it. A changed message is therefore a build error in the editor, not a decode error at run time.

### Messages

| Group | Messages |
|---|---|
| Session | Hello, log lines, soft-restart and reload events |
| Types | Component types with their fields, behaviour classes with their fields, game commands |
| World | Entity list snapshot and deltas (create, destroy, rename, reparent), watch and unwatch an entity, field value deltas for watched entities |
| Edit | Apply operations, load a scene snapshot, refused operations |
| Viewport | Size, camera, selection, gizmo state, input, pick request and result, frame acknowledgement |
| Mode | Play, pause, step, stop |
| Stats | Frame times, memory, counters, script memory by module |

### Types

- A component type gives its stable ID, its name and its fields. A field gives its name, offset, kind and flags.
- **Field kinds:** the integer and float types, `bool`, enums with their names, `[3]f32`, `quaternion128`, `World_Position`, `Entity`, asset GUIDs and strings. Other fields are hidden.
- **Struct tags:** `editor:"-"` hides a field, `editor:"read"` makes it read-only, and `editor:"range=0,100"` gives a slider range. Fields walk the same Odin type info that `script.expose` walks.
- Behaviour fields come from the classes that the cooker recorded (see [Scripting](scripting.md#behaviours)). The host sends them for each loaded class.
- After a code reload, the host sends the types again, and the editor rebuilds the open panels.

### Watching

The outliner needs every entity, but only a few entities need their field values. The host sends the entity list once, then deltas each frame. It sends field values only for watched entities: the selection, and entities that a panel pins. In play mode, the values change every frame, so the host sends at most 20 updates per second for each watched entity.

## Viewport

- **Frames:** the host renders into the named shared textures `<name>.textureN` and signals `<name>.fence` (see [GPU](gpu.md#presentation)).
- **One copy per frame.** Avalonia's Windows backend, ANGLE on D3D11, imports only D3D11 textures with a keyed mutex, in `R8G8B8A8_UNORM`, and it imports no semaphores. Its Vulkan backend imports only Vulkan's own handles. The `Direct3D12FenceNtHandle` semaphore type exists only for macOS. So the editor has its own D3D11 device, which opens the host's textures. On each composition update, if the host's fence shows a newer finished frame, the editor copies that frame into one of three keyed-mutex textures of its own, and gives that texture to the compositor. The fence is read on the CPU, so the copy never waits on the GPU.
- **Opening the host's objects:** D3D11 cannot open a named shared object, so a D3D12 device on the same adapter turns the names into handles. D3D11 refuses a shared typeless texture from D3D12 unless it allows simultaneous access, so the host's shared textures have the frame target's typed sRGB format.
- **Same adapter:** shared objects open only on the adapter that created them. The editor reads the LUID of Avalonia's composition adapter and starts the host with `--adapter <luid>`.
- **Back-pressure:** the editor reads a host texture only while it copies it. It acknowledges each frame that it copies, and the host renders frame k into a shared texture only if k ≤ acknowledged + 2, so it never draws into a texture that the editor is copying. Otherwise `core` gives the frame a scratch target that nothing reads. A slow editor drops frames from the viewport. It never stalls the simulation.
- **Resizing:** the editor sends the viewport size, in physical pixels. The host makes new shared textures with a generation in their names, `<name>.g<gen>.textureN`, and reports the generation. The editor opens the new set and releases the old one.
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
- **Status bar:** the host's state (waiting for the viewport, running, stopped, exited with its code) and the mode. The selection count comes with selection.
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
- **Editor commands** are C#. **Game commands** are described by the DLL and run in the host through `Game_API.editor_message`. A game command that changes the scene returns operations, and the editor applies them as for any edit, so they can be undone.
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
| Undo History | The undo stack. Clicking an entry undoes or redoes to it. |
| Console | The host's and the cooker's log, with filters by level and source |
| Resource Monitor | Frame times, memory, GPU resource counts and script memory by module |

### Outliner

- The outliner is a virtualized list of the visible rows of the tree, indented by depth. A tree control with one item per entity does not scale to tens of thousands of entities.
- The hierarchy comes from `Parent`. Dragging a row onto another row is a reparent operation.
- **Visibility and lock are editor state.** Hidden entities are not drawn in the viewport, and locked entities cannot be picked. Neither changes the game's `Disabled` state, and neither is saved in the scene. The editor saves them for each user.

### Properties

- The panel is built from the type descriptors: one group per component or behaviour, one row per field, and an editor for each field kind.
- **Reset:** a field that differs from its default shows a reset button. With prefabs, the default is the prefab's value.
- **Multi-select:** the panel shows the components that every selected entity has. A field whose values differ shows as mixed, and setting it makes one operation for each entity, in one transaction.
- `World_Position` shows meters, and sets raw values.
- An entity reference shows the target's name, and accepts a drag from the outliner. An asset reference shows the asset's name, and accepts a drag from the asset browser.

### Asset browser

- The editor never writes a `.meta` file. It asks the cook daemon to create, move, rename and re-import assets, so each asset keeps its GUID (see [Content pipeline](content-pipeline.md#identity)).
- Until the cook daemon exists, the asset browser is read-only.

## Crash recovery

- **Host crash:** the document is in the editor, so nothing is lost. The editor reports the crash with the end of the host's log, and restarts the host. The link connects again, the editor sends the snapshot, and the camera and the selection stay.
- **Editor crash:** the editor saves each dirty scene to `build/editor/autosave/` every 30 s, and when a transaction ends if 30 s have passed. At start, it offers to restore a newer autosave.
- **Code reload:** the host sends the types again. **Soft restart:** the host also sends a restart event, and the editor sends the snapshot again (see [Document model](#document-model)).

## Implementation phases

1. **Viewport:** an Avalonia window that shows the host's live frames: the editor's D3D11 device, the copy into keyed-mutex textures, the host's `--adapter`, and the host in its Job Object.
2. **Shell:** the projects, the docking layout, the ribbon and the command registry.
3. **Link:** the server in `src/host`, the handshake, the schema and the C# generator, back-pressure, resizing, and the console.
4. **Read-only world:** types, the entity list and deltas, the outliner, and the properties panel for watched entities.
5. **Scenes:** the `Name` component, the scene format, the loader, `cook scenes`, and snapshots over the link.
6. **Editing:** operations, transactions, undo history, save and autosave, and field editors.
7. **Viewport tools:** the editor camera, the ID buffer and picking, the selection outline, gizmos and snapping.
8. **Modes:** play, pause, step and stop, and input forwarding.
9. **Later:** the asset browser (with the cook daemon), the resource monitor, game commands in the ribbon, prefabs.

## Deferred

- **Large worlds:** positions reach ±2^38 m, and one scene file per world does not scale. Level and world streaming will split the world into scenes that load separately, and the editor will then edit several scenes at once.
- **Edit-mode scripts:** some tools need behaviours that run in edit mode, like Unity's `ExecuteInEditMode`. Edit mode runs no scripts until then.
- **More than one viewport:** each viewport has its own shared target and camera, so the host renders the scene once for each viewport.
