# Editor link

The message connection between the editor and the host, its framing, schema and generated C#, and the game side that mirrors the world to the editor.

**In this document:** [Editor link](#editor-link) · [World](#world)

## Editor link

The editor link is a message connection between the editor and the host. It uses TCP. Locally it runs over loopback. Later, the same protocol connects to a host on another machine or a console.

- **The host is the server.** It listens on `127.0.0.1` at the port that `--link` gives, so only the local machine can connect. It serves one editor at a time and refuses a second connection. The editor picks a free port, starts the host with it, and connects, retrying while the host starts. It connects again after a host restart.
- **Framing:** each message is a 12-byte little-endian header (payload length, kind, flags, request ID) and a payload of at most 64 MiB. A response has the request ID of its request. An event has request ID 0.
- **Wire format:** numbers are little-endian as they are in memory, a `bool` is one byte, enums are their backing integer, and strings and slices are a `u32` count followed by their bytes or elements. A fixed array has no count, and a struct is its fields in order. A payload that does not decode to exactly one message is refused.
- **Handshake:** the editor sends `Hello` with its protocol version. The host answers `Welcome` with the game's name and the DLL's layout hash, or `Refused` with both versions, and the editor shows the reason.
- **Two handlers.** The host handles the messages that need no game state: the handshake, the viewport's size, frame acknowledgements and input, and it sends its own stats. The game handles the mode, because only it knows what its frame runs. It passes every other message, still encoded, to `Game_API.editor_poll`, once per frame between frames, with the connection (0 while no editor is linked). The game decodes them with its own copy of `lib/engine/editor/link`, and appends its own messages to a buffer that the host owns, which the host then queues. The game cannot write to the outbox directly: it logs while it polls, and the logger takes the outbox's lock. Type info for game-side types exists only in the DLL's image, so the editor never reflects over game types itself.
- **Threads:** in the host, an accept thread waits for the editor, a reader thread queues its messages, and a writer thread sends the outbox. The main thread handles the queued messages between frames, after the reload point, while no job runs. Events of a frame go out at the end of it.
- **The log:** while an editor is linked, the host's logger sends every line, the game's and the jobs' included, over the link instead of to the host's console. A line carries its level, time, location and text. If more than 16 MiB is waiting to be sent, log lines are dropped and counted. The editor's console also shows the host's own console output, which has the lines before the link and anything that does not go through the logger, such as a crash.
- **One schema:** the messages are Odin structs in `lib/engine/editor/link`, a package that imports nothing from core or engine, so the host and the game both use it. The framing, the wire format and the schema writer are in `lib/engine/wire`, which the cook link shares (see [Content pipeline](../content/daemon-and-operations.md#cook-link)). `just link-schema` runs `host --emit-link-schema`, which writes `build/obj/link/link-schema.json`, and `cook --emit-link-schema`, which writes `build/obj/link/cook-schema.json`, and a C# source generator for `Cinnabar.Editor.Link` reads both. A message's kind is its index in the `Message` union, and the protocol version is a hash of the schema, so any change to a message changes the version. A changed message is a build error in the editor, not a decode error at run time. Odin's `Snake_Case` names become `PascalCase` in C#.

To add a message: add a struct to the `Message` union in `lib/engine/editor/link`, handle it in the host or in `editor.poll`, run `just link-schema`, and the editor's build gives the C# record. The compiler then finds every place that must handle it.

### Messages

| Group | Messages |
|---|---|
| Session | `Hello`, `Welcome`, `Refused`, `Log`, `Game_Reloaded` |
| Types | Component types with their fields, behaviour classes with their fields, `Game_Commands`; `Run_Game_Command`, `Game_Command_Result` |
| World | Entity list snapshot and deltas (create, destroy, rename, reparent), watch and unwatch an entity, field value deltas for watched entities |
| Edit | `Load_Scene`, `Apply_Operations`, `Edit_Problems` |
| Viewport | `Viewport_Size`, `Frame_Target`, `Frame_Acknowledged`, `Editor_Camera`, `Set_Selection`, `Set_Hidden`, `Gizmo_State`, `Pick_Request`, `Pick_Result`, `Viewport_Settings` |
| Mode | `Set_Mode`, `Step_Frame`, and `Editor_Input`, which the host handles |
| Stats | `Host_Stats`, which the host sends, and `Game_Stats` |
| Profile | `Profile_Summary`, `Profile_Capture_Request`, `Profile_Capture` and `Profile_Recording`, which the host handles (see [Profile](#profile)) |
| Previews | `Open_Preview`, `Preview_Settings`, `Close_Preview`, `Preview_Target`, and `Preview_Acknowledged`, which the host handles (see [Rendering](../rendering/materials.md#material-previews)) |
| Capture | `Capture_Request` and `Capture_Result`, which the host handles: the frames are its own (see [Capture](capture.md#capture)) |
| Live meshes | `Live_Mesh`, `Live_Mesh_Vertices` and `Release_Live_Mesh`: the mesh files the editor edits, which the game draws from memory (see [Mesh editing](mesh-editing.md#live-meshes)) |

### Profile

The host's profiler ([Core](../core/profiling.md#profiler)) talks to the editor's [profiler panel](shell-and-panels.md#profiler) without the game: every zone is the host's, so the host handles every profile message.

- **`Profile_Summary`** goes out right before each `Host_Stats`, for the same interval: the CPU, wait and GPU times' averages and most, the frames with the longest CPU and GPU times, the zones that the threads dropped, whether the host records, and the costs per frame of each pass, system and script callback, with their names as text.
- **`Profile_Capture_Request`** asks for a frame: the next one, the longest of the last `count`, or one by number. The editor gives it an `id`, and the host answers with a **`Profile_Capture`** with the same `id` once the frame has ended and its GPU times are in, or have not come for 8 frames. A frame that the host no longer has comes back with `available` false and a `reason`.
- **A capture** has a table of the names that it uses, its lanes (each thread, then the graphics and the compute queue), and its zones. A zone's start is in nanoseconds from the frame's start, its name an index into the table, and its lane an index into the lanes. GPU spans are zones on the GPU lanes. 10,000 zones are about 150 KB.
- **`Profile_Recording`** starts or stops the recording of zones. The host records again when the editor disconnects.

## World

The game's side of the link is `lib/engine/editor`. The game keeps an `editor.Editor` in its `Game_State`, and its `Game_API.editor_poll` calls `editor.poll` with the world and the script runtime. On the editor's side, `WorldModel` in `Cinnabar.Editor.Model` mirrors what it hears. The mirror is read-only: it changes only through the game's messages.

- **A new connection gets everything.** When `poll` sees a connection that its state is not for, it sends `Component_Types` and an `Entity_Snapshot`. After a `Load_Scene`, it sends an `Entity_Snapshot` again, and forgets the watches, whose entities are gone. A soft restart makes a fresh `Game_State`, which knows no connection, so the editor gets everything again then too. A snapshot replaces the editor's mirror, and the editor sends its watches again after one, and its live meshes, which a fresh `Game_State` has lost.
- **Deltas:** at most ten times a second, the game scans the world with `ecs.world_iter` and compares each entity slot with what it last told the editor: the handle, the archetype (which stands for the set of components), the parent, the active state and the name. It sends an `Entity_Delta` with the changed entities and the destroyed ones. A slot that a new generation took counts as a destroyed entity and a new one. The scan visits every entity, which suits worlds of tens of thousands; larger worlds will need change tracking in the ECS.
- **Watching:** the outliner needs every entity, but only a few entities need their field values. The editor sends `Watch_Entity` and `Unwatch_Entity` for the selection, and the game sends `Entity_Values` for each watched entity at most twenty times a second, and only when the encoded values changed. A watched entity that dies stops being watched. At most 64 entities are watched.
- **Values are bytes.** A component's value is its memory, and the editor reads each field at its offset with `FieldValues`, so the game does no per-field work. A behaviour's fields come from `script.inspect`, which reads the instance's table for each field that `Behaviour.define` declared, without calling any script code. A behaviour's value also names the script asset whose module returned its class, which is how the document finds it.
- After a code reload, the game sends the types again, and the panels rebuild.

### Types

- A component type gives its stable ID, its name, its size and its fields. A field gives its name, offset, kind, read-only flag, range and color flag, and an enum's backing kind and named values.
- **Field kinds:** the integer and float types, `bool`, enums, `[2]f32`, `[3]f32`, `quaternion128`, `World_Position` and `Entity`. A nested struct that is none of these adds its fields with dotted names, such as `inner.amount`. Other fields are hidden. *Asset references come with asset fields.*
- **Struct tags:** the `editor` tag is a list of words with spaces between them. `-` hides a field, `read` makes it, and anything in it, read-only, `range=0,100` gives a slider range, and `color` marks a `[3]f32` as a linear color, as in `editor:"color range=0,1"`. The walk follows the same rules as `script.expose`. The `Behaviours` component's Luau reference is hidden this way. The walk is `scene.component_fields`, so a scene can set exactly the fields that the editor shows.
