# Editor link

The message connection between the editor and the host, its framing, schema and generated C#, and the game side that mirrors the world to the editor.

**In this document:** [Editor link](#editor-link) · [World](#world)

## Editor link

The editor link is a message connection between the editor and the host. It uses TCP over loopback.

- **The host is the server.** It listens on `127.0.0.1` at the port that `--link` gives, so only the local machine can connect. It serves one editor at a time and refuses a second connection. The editor picks a free port, starts the host with it, and connects, retrying while the host starts. It connects again after a host restart.
- **Framing:** each message is a 12-byte little-endian header (payload length, kind, flags, request ID) and a payload of at most 64 MiB. A response has the request ID of its request. An event has request ID 0.
- **Wire format:** numbers are little-endian as they are in memory, a `bool` is one byte, enums are their backing integer, and strings and slices are a `u32` count followed by their bytes or elements. A fixed array has no count, and a struct is its fields in order. A payload that does not decode to exactly one message is refused.
- **Handshake:** the editor sends `Hello` with its protocol version. The host answers `Welcome` with the game's name and the DLL's layout hash, or `Refused` with both versions. The editor then stops the host and shows the reason (see [Crash recovery](processes-and-projects.md#crash-recovery)).
- **Two handlers.** The host handles the messages that need no game state: the handshake, the Game view's size, the viewports' frame acknowledgements, the capture source and input, and it sends its own stats. The game handles the mode, because only it knows what its frame runs. It passes every other message, still encoded, to `Game_API.editor_poll`, once per frame between frames, with the connection (0 while no editor is linked). The game decodes them with its own copy of `lib/engine/editor/link`, and appends its own messages to a buffer that the host owns, which the host then queues. The game cannot write to the outbox directly: it logs while it polls, and the logger takes the outbox's lock. Type info for game-side types exists only in the DLL's image, so the editor never reflects over game types itself.
- **Threads:** in the host, an accept thread waits for the editor, a reader thread queues its messages, and a writer thread sends the outbox. The main thread handles the queued messages between frames, after the reload point, while no job runs. Events of a frame go out at the end of it. The server is `lib/engine/wire/serve`, which the cook daemon also uses, and stopping it joins every thread that it started.
- **The linked editor:** the server owns the connection and whether it is linked, under one lock. The main thread answers a `Hello` with `Welcome`, and then links that connection. The link fails if that connection closed in the meantime. The host's events, such as `Host_Stats`, go only to the linked editor. Only the answer to its `Hello` goes to a connection that is not linked.
- **The log:** while an editor is linked, the host's logger sends every line, the game's and the jobs' included, over the link instead of to the host's console. The logger asks the server under its lock. A line never goes to an editor before its `Welcome`, and once the editor leaves, the next line goes to the console. A line carries its level, time, location and text. If more than 16 MiB is waiting to be sent, log lines are dropped and counted. The editor's console also shows the host's own console output, which has the lines before the link and anything that does not go through the logger, such as a crash.
- **One schema:** the messages are Odin structs in `lib/engine/editor/link`, a package that imports nothing from core or engine, so the host and the game both use it. The framing, the wire format and the schema writer are in `lib/engine/wire`, which the cook link shares (see [Content pipeline](../content/daemon-and-operations.md#cook-link)). `just link-schema` runs `host --emit-link-schema`, which writes `build/obj/link/link-schema.json`, and `cook --emit-link-schema`, which writes `build/obj/link/cook-schema.json`, and a C# source generator for `Cinnabar.Editor.Link` reads both. A message's kind is its index in the `Message` union, and the protocol version is a hash of the schema, so any change to a message changes the version. A changed message is a build error in the editor, not a decode error at run time. Odin's `Snake_Case` names become `PascalCase` in C#.

To add a message: add a struct to the `Message` union in `lib/engine/editor/link`, handle it in the host or in `editor.poll`, run `just link-schema`, and the editor's build gives the C# record. The compiler then finds every place that must handle it.

### Messages

| Group | Messages |
|---|---|
| Session | `Hello`, `Welcome`, `Refused`, `Log`, `Game_Reloaded` |
| Types | Component types with their fields, behaviour classes with their fields, `Game_Commands`; `Run_Game_Command`, `Game_Command_Result` |
| World | Entity list snapshot and deltas (create, destroy, rename, reparent), watch and unwatch an entity, field value deltas for watched entities |
| Edit | `Load_Scene`, with the scene's GUID, so the game finds its cooked blob's navmeshes, `Apply_Operations`, `Edit_Problems` |
| Viewport | `Editor_Camera`, `Set_Selection`, `Set_Hidden`, `Gizmo_State`, `Box_Handles`, `Pick_Request`, `Pick_Result`, `Set_Viewport_Settings`, `Nav_Probe` (the Navigation Path tool's points, see [Viewport](viewport.md#navigation-path)); `Editor_Camera`, `Gizmo_State`, `Box_Handles`, `Pick_Request` and `Set_Viewport_Settings` name a viewport, and `Editor_Camera` has the camera's projection, with an orthographic one's height and far plane |
| Views | `Open_Viewport` and `Close_Viewport`, which the editor sends as a viewport's control shows and hides, for up to five viewports (`MAX_VIEWPORTS`), `Viewport_Target`, which the game sends for each open viewport, and `Viewport_Acknowledged`, which the host handles (see [Viewport](viewport.md#views)) |
| Game size | `Game_Size`, the Game view's size in physical pixels, which the host handles (see [Viewport](viewport.md#views)) |
| Capture source | `Capture_Source`, the viewport that the host's screenshots and history ring read, which the host handles (see [Capture](capture.md#capture)) |
| Mode | `Set_Mode`, `Step_Frame`, and `Editor_Input`, which the host handles |
| Stats | `Host_Stats`, which the host sends, and `Game_Stats` |
| Profile | `Profile_Summary`, `Profile_Capture_Request`, `Profile_Capture` and `Profile_Recording`, which the host handles (see [Profile](#profile)) |
| Previews | `Open_Preview`, `Preview_Settings`, `Close_Preview`, `Preview_Target`, and `Preview_Acknowledged`, which the host handles (see [Rendering](../rendering/materials.md#material-previews)) |
| Capture | `Capture_Request` and `Capture_Result`, which the host handles: the frames are its own (see [Capture](capture.md#capture)) |
| Thumbnails | `Bake_Thumbnail` to the game, and `Thumbnail_Failed` from it, for the content browser's pictures, with the file in a `Capture_Request` (see [Thumbnails](../content/daemon-and-operations.md#thumbnails)) |
| Live meshes | `Live_Mesh`, `Live_Mesh_Vertices` and `Release_Live_Mesh`: the mesh files the editor edits, which the game draws from memory (see [Mesh editing](mesh-editing.md#live-meshes)) |
| Sky | `Sky_Sun_Request` and `Sky_Sun`: where the texture sky's sun is, which the game answers from its renderer, or why it has none (see [Sky](../rendering/sky.md#texture)) |
| Animators | `Animator_View`, what a watched entity's Animator plays, or with an entity of 0 an animation graph's preview, and `Set_Preview_Parameter` and `Restart_Preview` (see [Animation graph editor](animation-graph-editor.md#preview)) |
| Agents | `Agent_View`, what a watched entity's Agent does: its decision, the nodes that run or have a result by their IDs, and the blackboard's values as text, once after the watch and then when it changes, and `Agent_Actions`, the game's native actions with their parameters, sent when an editor links and after a code reload, as `Game_Commands` is (see [Decision editor](decision-editor.md#live-view), [Agents: The editor](../ai/agents.md#the-editor)) |
| UI previews | `Ui_Preview_Settings`, how a preview shows a UI document, and `Ui_Preview_Layout`, where its elements went (see [UI editor](ui-editor.md#the-games-side)) |
| Reflection probes | `Capture_Reflection_Probes`, the probes to capture now, none for all, and `Reflection_Probe_View`, a watched probe's slot and last capture, when it changes (see [Viewport](viewport.md#reflection-probes)) |

### Profile

The host's profiler ([Core](../core/profiling.md#profiler)) talks to the editor's [profiler panel](shell-and-panels.md#profiler) without the game: every zone is the host's, so the host handles every profile message.

- **`Profile_Summary`** goes out right before each `Host_Stats`, for the same interval: the CPU, wait and GPU times' averages and most, the frames with the longest CPU and GPU times, the zones that the threads dropped, whether the host records, and the costs per frame of each pass, system and script callback, with their names as text.
- **`Profile_Capture_Request`** asks for a frame: the next one, the longest of the last `count`, or one by number. The editor gives it an `id`, and the host answers with a **`Profile_Capture`** with the same `id` once the frame has ended and its GPU times are in, or have not come for 8 frames. A frame that the host no longer has comes back with `available` false and a `reason`.
- **A capture** has a table of the names that it uses, its lanes (each thread, then the graphics and the compute queue), and its zones. A zone's start is in nanoseconds from the frame's start, its name an index into the table, and its lane an index into the lanes. GPU spans are zones on the GPU lanes. 10,000 zones are about 150 KB.
- **`Profile_Recording`** starts or stops the recording of zones. The host records again when the editor disconnects.

## World

The game's side of the link is `lib/engine/editor`. The game keeps an `editor.Editor` in its `Game_State`, and its `Game_API.editor_poll` calls `editor.poll` with the world and the script runtime. On the editor's side, `WorldModel` in `Cinnabar.Editor.Model` mirrors what it hears. The mirror is read-only: it changes only through the game's messages.

- **A new connection gets everything.** When `poll` sees a connection that its session is not for, it ends the session and starts another, and it sends `Component_Types` and an `Entity_Snapshot` (see [A new game state](#a-new-game-state)). After a `Load_Scene`, it sends an `Entity_Snapshot` again, and forgets the watches, the selection and the hidden entities, whose entities are gone. A soft restart makes a fresh `Game_State`, which knows no connection, so the editor gets everything again then too. A snapshot replaces the editor's mirror, and the editor sends its watches, its selection, its hidden entities and its mesh overlay again after one, because they name entities by handle.
- **Deltas:** at most ten times a second, the game scans the world with `ecs.world_iter_changed` and compares each entity slot with what it last told the editor: the handle, the archetype (which stands for the set of components), the parent, the active state and the name. It sends an `Entity_Delta` with the changed entities and the destroyed ones. The scan visits only the chunks where a row arrived, or where `Parent` or `Name` was written, since the last scan (see [ECS: Change versions](../world/ecs.md#change-versions)): a change of archetype or of active state moves the row. If any entity was despawned since the last scan, a sweep over what the game told the editor finds the ones that are not alive. A slot that a new generation took therefore counts as a destroyed entity and a new one.
- **Watching:** the outliner needs every entity, but only a few entities need their field values. The editor sends `Watch_Entity` and `Unwatch_Entity` for the selection, and the game sends `Entity_Values` for each watched entity at most twenty times a second, and only when the encoded values changed. A watched entity that dies stops being watched. At most 64 entities are watched.
- **Values are bytes.** A component's value is its memory, and the editor reads each field at its offset with `FieldValues`, so the game does no per-field work. A behaviour's fields come from `script.inspect`, which reads the instance's table for each field that `Behaviour.define` declared, without calling any script code. A behaviour's value also names the script asset whose module returned its class, which is how the document finds it.
- After a code reload, the game sends the types again, and the panels rebuild.

### A new game state

A new link, from a start, a restart or a crash, and a soft restart both give the editor a game state that knows nothing that the editor sent. A code reload keeps the game state, so it is not one.

- **The game's side.** What one connection has sent the game, and what the game has sent it, is the `Session` in `editor.Editor`: the entities that the editor knows and watches, the selection, the hidden entities, the picks, the Navigation Path tool's points, and each viewport's kind, camera, gizmo, settings and target (`View`), the mode, the previews and the thumbnail, the live meshes and the mesh overlay, and when the game last sent each kind of update. `begin_session` starts one and `end_session` frees it, closes its previews and its viewports, and zeroes it, at `init`, at `destroy` and for each new connection. State that a new editor must not inherit goes in `Session`, so `end_session` frees it. The viewport tools' GPU objects, the commands, the UI state and `by_scene_id` stay outside it. A pick that the GPU still runs comes back with an old ticket, which the next session ignores.
- **The editor's side.** `EditorShell.OnNewGameState` is the one handler. A new link and a `Game_Reloaded` of kind `Soft_Restart` both call it. It clears every cache of what the game was sent, drops every request that waits for the game, and sends again:

  | What | Message |
  |---|---|
  | The mode, which the editor resets to Edit, as the game does | none |
  | The open scene | `Load_Scene` |
  | Each shown viewport | `Open_Viewport` |
  | Each shown scene view's camera, gizmo and box handles | `Editor_Camera`, `Gizmo_State`, `Box_Handles` |
  | The selection and the hidden entities | `Set_Selection`, `Set_Hidden` |
  | Each shown viewport's settings | `Set_Viewport_Settings` |
  | The Game view's size, if it has had one | `Game_Size` |
  | The viewport that captures read | `Capture_Source` |
  | The mesh overlay | `Mesh_Overlay` |
  | The Navigation Path tool's points | `Nav_Probe` |
  | The live meshes | `Live_Mesh` |
  | Each open preview, with what it shows | `Open_Preview`, `Preview_Settings` |

  It drops the picks and the `Sky_Sun_Request` in flight, disconnects the previews from the old targets until the new `Preview_Target`s come, and restarts the thumbnail queue, whose bake the old state lost. A preview's `unsaved` flag follows the cook daemon's cache, not the game, so `Open_Preview` sends it again as it is. A new feature that keeps a copy of game state, or waits for an answer from the game, resets it in `OnNewGameState`, and nowhere else.

### Types

- A component type gives its stable ID, its name, its size and its fields. A field gives its name, offset, kind, read-only flag, range and color flag, and an enum's backing kind and named values.
- **Field kinds:** the integer and float types, `bool`, enums, `[2]f32`, `[3]f32`, `quaternion128`, `World_Position` and `Entity`. A nested struct that is none of these adds its fields with dotted names, such as `inner.amount`. Other fields are hidden. *Asset references come with asset fields.*
- **Struct tags:** the `editor` tag is a list of words with spaces between them. `-` hides a field, `read` makes it, and anything in it, read-only, `range=0,100` gives a slider range, and `color` marks a `[3]f32` as a linear color, as in `editor:"color range=0,1"`. The walk follows the same rules as `script.expose`. The `Behaviours` component's Luau reference is hidden this way. The walk is `scene.component_fields`, so a scene can set exactly the fields that the editor shows.
