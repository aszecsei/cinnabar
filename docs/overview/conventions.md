# Conventions

A few rules appear in every document, because every part of the engine is shaped by them. Knowing them makes the rest predictable. Each links to the document that explains it.

**In this document:** [Rules that cut across](#rules-that-cut-across)

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
