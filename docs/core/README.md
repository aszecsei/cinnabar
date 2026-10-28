# Core

The platform layer in `lib/core`: the frame, jobs, memory and input, and the porting surface.

## Documents

Read them in this order the first time.

| Document | What it covers |
|---|---|
| [Platform](platform.md) | Platform and backend selection, `Platform_API`, and the frame bracket. |
| [Jobs and memory](jobs-and-memory.md) | The fiber job system and the memory arenas. |
| [Input](input.md) | Keyboard and mouse input, and the editor's input. |
| [Profiling](profiling.md) | The frame profiler: CPU zones, frames, costs and captures. |

## Overview

`core` is host-side code: it is compiled into `host.exe` in development and into the release executable, and it is never hot-reloaded. Everything the game needs from it crosses the boundary as a procedure in `Platform_API`.

| Package | What it holds |
|---|---|
| `lib/core` | `api.odin`: `Platform_API` and `Game_API`. `platform.odin`: frame begin and end, the arenas, the DLL loader and reload detection. `input.odin`: `Input` and the queue for the editor's input. `window_windows.odin`: the window and its messages. `file.odin`: file reading and modification times. |
| `lib/core/jobs` | The fiber job system: workers, fibers, counters and the fiber-aware mutex. |
| `lib/core/profile` | The frame profiler: zones, the frame ring, costs and captures ([Profiling](profiling.md#profiler)). |
| `lib/core/layout` | The type layout hash that `Game_API.layout_hash` and the blob headers use. |
| `lib/core/capture` | Frame captures as images: the conversion from each output mode, the half-size downscale, and the PNG and GIF encoders ([Editor: Capture](../editor/capture.md#capture)). |
| `lib/core/gpu` | The GPU interface, validation, the null backend and the D3D12 backend ([GPU](../gpu/README.md)). |
| `lib/core/luau`, `lib/core/script` | The Luau bindings and the VM's host side ([Scripting](../scripting/embedding.md#embedding)). |

The services below are the ones every other part depends on, in the order a frame meets them: the platform selection that decides what code is compiled, the API that exposes it, the frame loop, input, jobs and memory.

## References

- Christian Gyrling, [*Parallelizing the Naughty Dog Engine Using Fibers*](https://www.gdcvault.com/play/1022186/Parallelizing-the-Naughty-Dog-Engine), GDC 2015: the fiber pool, counters as the only synchronization primitive, and the rule against locks across a yield.
- Odin's [`context` system](https://odin-lang.org/docs/overview/#implicit-context-system), which is how allocators reach game-side code without globals.
- Microsoft, [*Virtual Memory Functions*](https://learn.microsoft.com/en-us/windows/win32/memory/virtual-memory-functions): `VirtualAlloc` reserve and commit, which the arenas and the world's storage are built on.
