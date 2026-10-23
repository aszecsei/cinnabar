# Hot reload

In development, the engine and game code are a DLL that `host.exe` reloads when it changes. This document gives the rules that game-side code must follow, and the reload sequence. See [Architecture](architecture.md#hot-reload) for the overview.

## Why the rules exist

Each Odin module gets its own copy of every package it imports, including the runtime. The game DLL can also be replaced while the process runs. Anything that points into the old DLL's image becomes invalid or stale after a reload.

## Rules

These rules apply to all game-side code (`lib/engine` and games).

1. **No mutable package-level globals.** All persistent game-side state lives in one root `Game_State`. The host allocates it and passes it in by pointer.
2. **Persistent allocators belong to the host.** An `Allocator` contains a procedure pointer. Persistent memory uses arenas implemented in `core`, so the pointer stays valid across reloads.
3. **No DLL-owned pointers in persistent state.** This includes procedure pointers, `typeid`, `^Type_Info`, `any` and string literals, which all point into the DLL image. Use handles and IDs instead. `on_reload` rebuilds all registrations (systems, callbacks, script bindings).
4. **Old DLLs stay loaded.** Each build is copied to `mygame_N.dll` (with a matching `.pdb`) and is never unloaded. This makes a missed case from rule 3 run stale code instead of crashing. It also avoids PDB file locks on Windows.

## Reload sequence

1. `core` detects a new DLL build.
2. At the end of the frame, the host waits until the job system is drained.
3. The host loads `mygame_N.dll` and resolves `Game_API`.
4. The host compares the new GPU command format hash with its own (see [GPU](gpu.md#command-buffers)). If they differ, the host keeps the old DLL and asks for a restart.
5. The host compares the new `layout_hash` with the old one. The DLL computes this hash at runtime by walking the type info of `Game_State` (field names, offsets and types).
   - **Same hash:** the host calls `on_reload`. State is kept.
   - **Different hash:** the host calls `shutdown` and then `init` with fresh state. This is a soft restart. The window, the GPU device and the loaded assets stay up.
