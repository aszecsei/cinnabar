# Embedding

How one copy of Luau is shared by the host and the game DLL, why every function pointer Luau stores is host code, the optional direct field access path, the watchdog and the collector. This is engine-developer material; a scripter can start at [API](api.md).

**In this document:** [Host trampolines](#host-trampolines) · [Direct field access](#direct-field-access) · [Watchdog](#watchdog) · [Garbage collection](#garbage-collection)

- **One copy of Luau.** Luau has internal static state, and its VM heap holds pointers to Luau's own built-in functions. The host and the game DLL must therefore share one copy. In development, Luau is built as `luau.dll`, and both modules load it. In release, it is linked statically. `tools/cook` links the compiler and the analyzer statically. It runs in its own process, so it does not share the VM.
- **Build:** `just luau` builds `lib/core/luau/CMakeLists.txt` twice, into `build/obj/luau/shared` (`luau.dll` with the VM, the compiler and the code generator) and `build/obj/luau/static`. Both builds export the C API with `extern "C"` and use the static CRT, like Odin. `luau_compile` returns memory from Luau's CRT, so the bindings release it with `luau.free_bytecode`. A running host keeps `luau.dll` locked, and a changed `luau.dll` needs a host restart.
- **One VM per `Game_State`.** The game creates the VM in `init` with `script_open` in `Platform_API`, and destroys it in `shutdown`. A code reload keeps the VM. A soft restart destroys it with the rest of the game state, because the world holds references into it.
- **Heap:** the VM is created with `lua_newstate` and a host-side allocator. Luau places small objects in its own size-class pages, so the allocator mostly sees page-sized and large requests. Blocks up to 1 MiB come from TLSF, in 8 MiB pools in one 4 GiB reservation of each VM. A larger block gets its own virtual memory. `script_close`, or a soft restart, releases all of it. The heap, including suspended script coroutines, survives code reload.
- **Errors:** Luau is built with `LUA_USE_LONGJMP`. An error raised in a binding jumps over Odin frames and skips their `defer` statements. Bindings therefore raise errors only before they do work that needs a `defer`.
- **Sandboxing:** the host calls `luaL_sandbox` on the main state and `luaL_sandboxthread` on each module's thread. Scripts have no `os`, `io`, `debug` or `loadstring`, and they cannot change the engine globals.
- **Threading:** a Luau state is not thread-safe. Scripts run only in the serial script phase of the frame (see [Frame](behaviours.md#frame)).

## Host trampolines

Luau stores function pointers in the VM heap and in its global state. A pointer into the DLL image would become stale after a code reload (see [Hot reload](../overview/hot-reload.md#rules), rule 3). Every function pointer that Luau stores is therefore a host function in `lib/core/script`:

| Luau hook | Host function | Forwards to |
|---|---|---|
| `lua_Alloc` | Script heap allocator | Nothing. It is host code. |
| Every `lua_CFunction` binding | One dispatcher | The game's binding table, by binding ID |
| Metamethods (`__index`, `__namecall`, `__eq` and others) | The same dispatcher: each metamethod is a binding | The game's binding, which finds the method or field in its per-type tables by userdata tag and atom |
| `useratom` | The atom interner | Nothing. It is host code. |
| `interrupt` | The watchdog | Nothing. It is host code. |
| `panic` | Logs and aborts | Nothing. It is host code. |

The game reaches these through `Platform_API`: `script_open`, `script_close`, `script_push_binding` (a dispatcher closure for a binding name) and `script_atom` (interns a name). `script_open` stores a pointer to the game's `script_host.Bindings` in `lua_Callbacks.userdata`. The table lives in `Game_State`, so its address does not change across a reload, and `on_reload` fills it again. Bindings run with the context in `Bindings.ctx`, which the game sets each time before it runs scripts.

- **Bindings have stable IDs.** A binding's ID is the hash of its qualified name, such as `Entity.get`. The dispatcher closure holds the ID as its upvalue, not an index. Scripts can therefore keep binding functions in locals across a reload, even when the new DLL registers bindings in a different order. A call to a binding that the new DLL no longer registers raises an error that names it.
- **Atoms are stable.** The host interns every name that the game registers as a method or field, and the `useratom` callback gives a string the index of its name. The interner is append-only and host-owned, so an atom never changes meaning. Bindings use `lua_namecallatom` and `lua_tostringatom` to find a method or field without a string compare. Luau asks for a string's atom once, the first time that code needs it, and keeps the answer. A string whose atom was asked for before its name was interned therefore has none, and the binding falls back to a lookup by name.
- **No userdata destructors.** `lua_newuserdatadtor` and `lua_setuserdatadtor` store function pointers, so engine userdata are plain data with no destructor. A userdata never owns a native resource. It holds handles.
- **Bindings can yield.** A binding that waits (such as `wait`) returns a yield request, and the dispatcher calls `lua_yield`.

## Direct field access

Luau's experimental `lua_registeruserdatadirectaccess` lets the VM call a get, set or namecall callback for a tagged userdata without a Luau call frame. It is an optional feature, selected by the `LUAU_DIRECT_ACCESS` config in `lib/core/script`. It is off by default. `CINNABAR_DIRECT_ACCESS=true just build` turns it on for the host, the game DLL and release builds.

- **When the VM uses it:** at load, Luau rewrites each field read, field write and method call whose key has an atom to an instruction that calls the tag's direct access callback when the value is userdata. Every exposed field and every method name is interned, so their accesses qualify. Any other value takes the usual path.
- **Same arguments, different entry.** The VM calls the callback in a C call frame with the metamethod's arguments: the userdata, the key and, for a write, the value. The callbacks are host functions, like the dispatcher (`script_host.direct_access`, through `Platform_API.script_direct_access`), and they call the game's handlers in `Bindings.direct`, which `on_reload` fills again. The handlers do what the metamethods do, so scripts see the same behaviour with the feature on or off. `just test` runs the script tests both ways.
- **The engine's userdata:** component references (field reads and writes), `Quaternion` (fields and methods) and `WorldPosition` (methods). A `Transform` write takes the general path, because a child's write also sets its local pose. Light userdata, such as `Entity`, have no direct access in Luau.
- **The cached slot is a hint.** Luau gives the callback a `cachedslot` for each instruction, which every userdata tag shares. A component reference stores the field's index plus one in it, and uses the field there only if it belongs to the reference's component and has the key's atom. Otherwise it looks up the field again.
- **Why optional:** the API is experimental and can change in a Luau update. With the feature off, nothing calls it, so a Luau update never blocks on it.
- `Bindings.direct_calls` counts the calls, so tests can tell that the path is used.

## Watchdog

The `interrupt` callback checks a deadline at loop back edges and calls. A script that runs past its budget in one resume raises an error with a traceback, and only that coroutine or handler stops. The budget is `DEFAULT_BUDGET` (100 ms), in development and release alike.

## Garbage collection

- The script phase runs an incremental GC step with a fixed budget each frame. It never runs a full collection during a frame.
- Each loaded module gets a Luau memory category (`lua_setmemcat`): its index + 1, and the last of the 256 modules shares the 255th's. Category 0 is the engine. A module's top level runs in its category, a main script's thread has its module's, and each behaviour instance keeps its class's module's, which its callbacks run in. A coroutine's thread keeps the category of the code that started it, so what a behaviour's coroutines allocate counts toward its module too. `script.memory` gives the VM's total and each module's part, and the editor's resource monitor shows them.
