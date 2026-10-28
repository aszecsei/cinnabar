# Hot reload

In development, the engine and game code are a DLL that `host.exe` reloads when it changes. This document gives the rules that game-side code must follow, the reload sequence, and what survives each kind of restart. Read [Architecture](architecture.md#hot-reload) first for where the boundary sits. Every later document assumes these rules, and most of their stranger-looking decisions (handles instead of pointers, registrations rebuilt in `on_reload`, host trampolines for Luau) come from here.

**In this document:** [Why the rules exist](#why-the-rules-exist) · [Rules](#rules) · [What survives](#what-survives) · [Reload sequence](#reload-sequence) · [Checking a design against the rules](#checking-a-design-against-the-rules)

## Why the rules exist

Each Odin module gets its own copy of every package it imports, including the runtime. The game DLL can also be replaced while the process runs. Anything that points into the old DLL's image becomes invalid or stale after a reload.

Three kinds of thing live in the DLL's image, and all of them are easy to store by accident:

| What | Examples | Where it hides |
|---|---|---|
| Code | Procedure pointers, closures, vtables | System procedures, callbacks, `Allocator` procedures, Luau C functions |
| Type information | `typeid`, `^Type_Info`, `any` | Component registries, serializers, "generic" containers keyed by type |
| Constant data | String literals, static tables | Names stored for debugging, lookup tables held by pointer |

The engine's answer is the same for all three: persistent state holds **handles, stable IDs and copies**, and anything that must point into code is a **registration** that `on_reload` makes again.

## Rules

These rules apply to all game-side code (`lib/engine` and games).

1. **No mutable package-level globals.** All persistent game-side state lives in one root `Game_State`. The host allocates it and passes it in by pointer.
2. **Persistent allocators belong to the host.** An `Allocator` contains a procedure pointer. Persistent memory uses arenas implemented in `core`, so the pointer stays valid across reloads.
3. **No DLL-owned pointers in persistent state.** This includes procedure pointers, `typeid`, `^Type_Info`, `any` and string literals, which all point into the DLL image. Use handles and IDs instead. `on_reload` rebuilds all registrations (systems, callbacks, script bindings).
4. **Old DLLs stay loaded.** Each build is copied to `mygame_N.dll` (with a matching `.pdb`) and is never unloaded. This makes a missed case from rule 3 run stale code instead of crashing. It also avoids PDB file locks on Windows.

## What survives

There are three ways a running game changes code or state, and each keeps a different amount.

| | Code reload (same `Game_State` layout) | Soft restart (layout changed) | Host restart |
|---|---|---|---|
| Window, GPU device, swapchain | Kept | Kept | Lost |
| `Game_State` and everything in it: the world, asset handles, the renderer's tables | Kept; `on_reload` rebuilds registrations | Fresh: `shutdown`, then `init` | Fresh |
| GPU resources in the `Game` scope | Kept | Destroyed by `core` between `shutdown` and `init` ([GPU](../gpu/resources-and-pipelines.md#resources)) | Lost |
| GPU resources in the `Level`, `Asset` and `Permanent` scopes | Kept | Kept | Lost |
| Loaded asset blobs | Kept (the table is in `Game_State`) | Loaded again on demand | Loaded again |
| Pipelines | Kept; `on_reload` updates each with the new shaders, and the old ones draw until the new compile | Created again | Created again |
| The Luau VM: modules, behaviour instances, suspended coroutines | Kept; `on_reload` refills the binding tables ([Scripting](../scripting/embedding.md#host-trampolines)) | Destroyed with the state | Destroyed |
| Debug lines with a duration | Kept (host memory, [Rendering](../rendering/layers-and-output.md#debug)) | Kept | Lost |
| Virtual memory the game reserved directly | Kept | Released by `core` ([Core](../core/jobs-and-memory.md#memory)) | Released |
| The editor's scene | Unaffected | The editor sends it again ([Editor](../editor/document-and-scenes.md#document-model)) | The editor sends it again |

A code reload is what `just game-dll` gives in the common case. A soft restart happens when a field of `Game_State`, or of any component type (whose layouts are mixed into the hash, see [World](../world/ecs.md#component-registry)), changes. A host restart is needed only when host-side code changes: `lib/core`, `src/host`, or `luau.dll`.

## Reload sequence

1. `core` detects a new DLL build.
2. At the end of the frame, the host waits until the job system is drained. Background jobs run only host code, so they can continue.
3. The host loads `mygame_N.dll` and resolves `Game_API`.
4. The host compares the new DLL's `abi_hash` with its own: a hash of the GPU command format (see [GPU](../gpu/command-buffers.md#command-buffers)) and of `Platform_API`'s layout. If they differ, the host keeps the old DLL and asks for a restart.
5. The host compares the new `layout_hash` with the old one. The DLL computes this hash at runtime by walking the type info of `Game_State` (field names, offsets and types).
   - **Same hash:** the host calls `on_reload`. State is kept.
   - **Different hash:** the host calls `shutdown` and then `init` with fresh state. This is a soft restart. The window, the GPU device and the loaded assets stay up. Between the two calls, `core` destroys the GPU resources that the old game left in the `Game` scope (see [GPU](../gpu/resources-and-pipelines.md#resources)).
6. While an editor is linked, the host tells it which happened (`Game_Reloaded` with the kind). After a code reload the game sends its types again; after a soft restart the editor sends its scene again.

The reload point is between frames, after the job system is drained and before the editor's messages are handled, so no job, no script and no editor operation is ever in flight across it.

## Checking a design against the rules

When adding a feature that keeps state, ask these in order. The answers are the pattern every existing subsystem follows.

1. **Where does the state live?** In `Game_State`, directly or through a host allocator. Never in a package-level variable.
2. **Does it hold a procedure, a `typeid` or a string literal?** Then it is a registration. Keep it in a table that `on_reload` clears and the game's registration procedure fills again. Examples: `ecs` systems and queries, `script` bindings, `editor` commands, `render` post effects and extractors.
3. **Does it hold a pointer into a blob, a component or the VM heap?** Blobs are swapped by the asset runtime and component storage moves; hold an asset handle, an `Entity`, or a `lua_ref` instead, and look the data up when you use it.
4. **Does it hold a GPU resource?** Hold the handle, and give the resource the right scope: `Game` for anything the game creates for itself, `Asset` for resident asset data, `Permanent` only in `core`.
5. **Is it in a shared package?** Then its layout is compiled into both sides. Changing a `gpu` packet or `Platform_API` is caught by the ABI hash; changing `Game_State` by the layout hash. Changing a `link` message changes the protocol version. Nothing else is checked, so keep shared packages small.
6. **Does a job or a callback run it?** A job must finish within the frame, and a Luau callback must be a host trampoline (see [Scripting](../scripting/embedding.md#host-trampolines)).
