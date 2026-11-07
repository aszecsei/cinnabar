# Conventions

A few rules appear in every document, because every part of the engine is shaped by them. Knowing them makes the rest predictable. Each links to the document that explains it.

**In this document:** [Rules that cut across](#rules-that-cut-across) · [State with a lifecycle](#state-with-a-lifecycle)

## Rules that cut across

A few rules appear in every document, because every part of the engine is shaped by them. Knowing them makes the rest predictable.

| Rule | Why | Where it is explained |
|---|---|---|
| **One `Game_State`, no mutable globals.** | The host owns the memory, so a code reload keeps it. | [Hot reload](hot-reload.md#rules) |
| **No pointers into the DLL image in persistent state:** no procedure pointers, `typeid`s, type infos or string literals. Use handles and stable IDs, and rebuild registrations in `on_reload`. | A reload replaces the image. | [Hot reload](hot-reload.md#rules) |
| **Registrations are rebuilt, not kept:** systems, queries, extractors, script bindings, game commands, post effects, pipelines' descriptions. | They hold procedure pointers and names. | [World](../world/ecs.md#systems), [Scripting](../scripting/embedding.md#host-trampolines), [Editor](../editor/shell-and-panels.md#game-commands) |
| **Stable IDs for component types; GUIDs for content.** | Cooked data, the editor and scripts all outlive any one build. | [World](../world/ecs.md#component-registry), [Content pipeline](../content/identity-and-cooking.md#identity) |
| **Jobs are frame-scoped and hold no thread-local state.** | A suspended fiber's stack points into the DLL, and a fiber can resume on another thread. | [Core](../core/jobs-and-memory.md#job-system) |
| **Logic that spans frames is a script coroutine.** | Jobs cannot span frames; scripts and their coroutines live in the host-owned VM heap. | [Scripting](../scripting/behaviours.md#coroutines) |
| **Structural changes to the world are deferred to command buffers**, except in the serial script phase. | Jobs iterate the world in parallel. | [World](../world/ecs.md#command-buffers) |
| **The GPU boundary is plain data.** The engine records command buffers; the backend tracks no state. | Parallel recording, porting, and reload safety. | [GPU](../gpu/command-buffers.md#command-buffers) |
| **Shared packages import nothing one-sided.** `format`, `wire`, `link`, `cook_link`, `layout` and `gpu` compile into the host, the DLL and the tools. | Their layouts must agree across processes and builds. | [Modules](README.md#modules) |
| **The editor owns the scene; the daemon owns `.meta` files; the host owns the world.** | Each piece of state has one writer, so a crash of any process loses nothing it does not own. | [Editor](../editor/document-and-scenes.md#document-model), [Content pipeline](../content/daemon-and-operations.md#asset-operations) |

## State with a lifecycle

Some state changes over time: a connection, a load, a cook, a drag, a capture, a GPU build. Keep each such state as one value, and change it in one place. Do not spread it over several bools, nullable fields or sentinel values that together say which state it is in. Spread state allows combinations that must not happen, and each new feature must remember to reset its own part. These rules apply to Odin and C# alike.

| Rule | Why |
|---|---|
| **One state, one value.** A lifecycle is an enum or a union. Data that belongs to one state is part of that state: a `Maybe(Edit)` or a union variant, not a bool with fields beside it that are valid only while it is set. | Code that clears the flag but not its data leaves the data for the next user. |
| **One writer.** One proc or method changes the state and checks that the change is allowed. Other code asks it; it does not assign the state. | Writers in many places, each with its own compound check, drift apart. |
| **A zero value is not success.** A result starts as `Pending`, never as a value that reads as done. | An early return or a skipped item otherwise reports success. |
| **Commit when the work succeeds.** State that a frame's GPU work makes changes after `execute` succeeds, not while the passes are recorded. State that a request makes changes when the answer comes, not when it is sent. | A failed frame or a lost request otherwise leaves state that says the work ran. |
| **A shared begin and end hands out a token.** When several callers share one resource, such as an undo entry, a preview slot or an asset handle, each one that begins gets a token or a reference. Ending through a stale token does nothing, and an owner learns when its work was ended for it. | Callers otherwise end, commit or free each other's work. |
| **Answers across a boundary are matched by ticket, not by order.** This applies across a process, a thread or the GPU. | The other side can drop or cancel a request. One lost answer otherwise shifts every later one. |
| **State for one connection, or for one game state, is one struct that one proc resets.** Caches of what the other side was last sent are part of it. A new link and a soft restart both go through that proc. | A feature that adds its own reset line in one handler, but not in the others, breaks after a reconnect or a soft restart. |
| **One link's state has one owner and one lock.** Do not keep an atomic copy beside fields under a mutex, or a copy on another thread. | Copies under different rules disagree during a race. |
| **An owner that closes cancels its work.** Disposing or closing ends its timers, delayed calls and requests in flight, and a closed owner sends nothing. | Work that finishes after the close otherwise acts for an owner that is gone. |
