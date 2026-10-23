# Scripting

All gameplay logic that spans frames (coroutines, timers, sequences, "wait two seconds") runs in sandboxed Luau, not in the job system. See [Architecture](architecture.md#scripting) for the overview, and [World](world.md#the-script-view) for how scripts see entities and components.

## Embedding

- **One copy of Luau.** Luau has internal static state, and its VM heap holds pointers to Luau's own built-in functions. The host and the game DLL must therefore share one copy. In development, Luau is built as `luau.dll` (with `LUA_API` defined as an export), and both modules load it. In release, it is linked statically.
- **Heap:** the VM is created with `lua_newstate` and a host-side allocator over the script heap arena. The heap, including suspended script coroutines, survives code reload.
- **Native bindings go through a dispatcher.** A `lua_CFunction` pushed from the DLL would be a DLL-owned pointer stored in the heap (see [Hot reload](hot-reload.md#rules), rule 3). Instead, every binding is the same host-side dispatcher function in `lib/core`, with a binding index as its upvalue. The dispatcher calls the procedure at that index in a table, and `on_reload` fills that table again. Scripts can keep binding functions in locals across a reload.
- **Errors:** Luau is built with `LUA_USE_LONGJMP`. An error raised in a binding jumps over Odin frames and skips their `defer` statements. Bindings therefore raise errors only before they do work that needs a `defer`.
- **Sandboxing:** the host calls `luaL_sandbox` on the main state and `luaL_sandboxthread` for each script.
- **Threading:** a Luau state is not thread-safe. Scripts run in the serial script phase of the frame.

## Script assets

Script source is content. `tools/cook` compiles it to bytecode with `luau_compile`, and the Luau version is part of the cache key. Scripts hot-reload through the asset system, like any other asset.
