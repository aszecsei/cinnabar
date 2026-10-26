# Scripting

Luau in cinnabar: how it is embedded across the reload boundary, the API scripts see, behaviours, and the tooling.

## Documents

Read them in this order the first time.

| Document | What it covers |
|---|---|
| [Embedding](embedding.md) | One Luau across the boundary, host trampolines, direct access, the watchdog and GC. |
| [API](api.md) | Values, entities and components, the engine libraries, and the Unity mapping. |
| [Behaviours](behaviours.md) | Classes, lifecycle, enabled state, coroutines, events and the script phase. |
| [Tooling and hot reload](tooling-and-hot-reload.md) | Modules, type definitions, script hot reload and native code generation. |

## Overview

Scripting is split across the boundary. The host owns the VM and everything Luau holds a pointer to; the game owns the bindings and everything that reads the world.

| Package | Side | File | What it holds |
|---|---|---|---|
| `lib/core/luau` | Shared | `luau.odin` | Odin bindings to the Luau C API. `CMakeLists.txt` builds Luau; `luau_shim.cpp` and `luau_tools.cpp` export what has no C API. |
| `lib/core/script` (`script_host`) | Host | `heap.odin` | The VM's allocator: TLSF pools in one reservation per VM, large blocks on their own pages. |
| | | `script.odin` | `script_open` and `script_close`, the binding dispatcher, the atom interner, the watchdog, the panic handler, direct access callbacks, and the `Bindings` table type. |
| `lib/engine/script` | Game | `script.odin` | `Runtime` in `Game_State`: init, reload, binding registration (`define`), running scripts. |
| | | `values.odin` | Userdata tags, metatables, `Entity`, component type values, pushing and reading values. |
| | | `entity.odin` | `Entity`'s methods and the `World` library. |
| | | `components.odin` | `expose`: component fields from Odin type info, component references. |
| | | `math.odin` | `Quaternion` and `WorldPosition`. |
| | | `behaviour.odin` | `Behaviours`, the prelude, classes, instances, attaching and the lifecycle. |
| | | `scheduler.odin` | Coroutines, waits, and the scheduler. |
| | | `phase.odin`, `frame.odin` | `run_phase`, `begin_phase`, `end_phase`, events. |
| | | `module.odin` | Modules, `require`, `spawn_script`, script hot reload. |
| | | `direct.odin` | The direct field access handlers. |
| | | `definitions.odin` | The `.d.luau` writer. `engine.d.luau` is the hand-written engine API. |
| | | `inspect.odin`, `edit.odin` | The editor's reads and edits of behaviour fields. |
| | | `memory.odin` | Memory categories by module. |
| | | `prelude.luau` | `Behaviour.define` and `Field`, in Luau. The cooker runs the same source. |

**The path of a call.** A script calls `entity:get(Health)`. Luau finds the method through the light userdata metatable, whose `__namecall` is a dispatcher closure made by `script_push_binding`, host code with the binding's stable ID as its upvalue. The dispatcher reads the game's `Bindings` table from `lua_Callbacks.userdata`, looks the ID up, and calls the game's procedure with `Bindings.ctx`. The procedure reads the world, pushes a component reference, and returns. If the binding waits, it returns a yield request and the dispatcher calls `lua_yield`. After a code reload, the same closure reaches the new DLL's procedure, because `on_reload` fills the table again under the same IDs. A script's data (the VM heap, its coroutines, its tables) never leaves host memory, and no Luau value holds a pointer into the DLL.

## Packages

| Package | Side | Responsibility |
|---|---|---|
| `lib/core/luau` | Shared | Odin bindings to the Luau C API: VM, compiler and code generator. Its `CMakeLists.txt` builds Luau. The `LUAU_SHARED` config selects `luau.dll` or the static libraries. |
| `lib/core/script` | Host | Package `script_host`: the VM's heap, and every function pointer that Luau stores (see [Host trampolines](embedding.md#host-trampolines)). The game uses its types, and calls it only through `Platform_API`. |
| `lib/engine/script` | Game | Binding registration, the entity and component view, behaviours, the scheduler, events, module loading and script hot reload. |
| `lib/engine/script/prelude.luau` | Shared | The engine prelude: `Behaviour.define` and `Field`, written in Luau. The runtime runs it at init, and `tools/cook` runs the same source to read behaviours' fields. |

`lib/engine` and games import `lib/core/luau` for types and calls. They never store a Luau function pointer of their own.

## Future work

Each document keeps the future work of its topic: [API](api.md#future-work) for what scripts can see and do, and [Tooling and hot reload](tooling-and-hot-reload.md#future-work) for typed behaviour classes, native code generation and the editor's tooling.

## References

- Luau, [luau.org](https://luau.org) and [github.com/luau-lang/luau](https://github.com/luau-lang/luau): the VM, compiler and analyzer that [Embedding](embedding.md#embedding) builds, and the [sandboxing guide](https://luau.org/sandbox) that the `luaL_sandbox` calls follow.
- Luau, [*Performance*](https://luau.org/performance): why `vector` is built in, how the compiler resolves global chains (the reason for [Globals that change](api.md#globals-that-change)), and the native code generator used in [Native code generation](tooling-and-hot-reload.md#native-code-generation).
- Luau, [*Type checking*](https://luau.org/typecheck) and the `.luaurc` [configuration](https://luau.org/syntax), with the `require` resolution rules of [Modules and `require`](tooling-and-hot-reload.md#modules-and-require).
- JohnnyMorganz, [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp): the language server that reads the definition file of [Types and tooling](tooling-and-hot-reload.md#types-and-tooling).
- Unity, [`MonoBehaviour`](https://docs.unity3d.com/ScriptReference/MonoBehaviour.html), [*Order of execution for event functions*](https://docs.unity3d.com/Manual/ExecutionOrder.html) and [*Coroutines*](https://docs.unity3d.com/Manual/Coroutines.html): the reference API for [Behaviours](behaviours.md#behaviours), [Lifecycle](behaviours.md#lifecycle) and [Coroutines](behaviours.md#coroutines).
- M. Masmano, I. Ripoll, A. Crespo and J. Real, *TLSF: A New Dynamic Memory Allocator for Real-Time Systems*, ECRTS 2004 ([PDF](http://www.gii.upv.es/tlsf/files/ecrts04_tlsf.pdf)): the allocator behind the script heap in [Embedding](embedding.md#embedding).
- Casey Muratori and Our Machinery on hot reload (see [Hot reload](../overview/README.md#references)): the constraints that make [Host trampolines](embedding.md#host-trampolines) necessary.
