# Core

`lib/core` is the platform layer. It owns every OS and device resource, and it provides the job system and memory arenas. See [Architecture](architecture.md#platform-layer) for the overview.

## Platform and backend abstraction

Windows and D3D12 are the first targets. A later port must only add files to `core`.

- **OS layer:** Odin's file-suffix convention (`*_windows.odin`) selects the platform implementation at compile time.
- **GPU backend:** the `gpu_backend` collection selects the backend at compile time. There is no runtime dispatch. See [GPU](gpu.md#packages).
- **Rules:** `lib/engine` and games never import `core:sys/windows`, `vendor:directx` or any backend package. `lib/core/gpu/d3d12` is the only code that imports `vendor:directx`.

## Job system

The job system has one worker thread per core and a pool of fibers. Jobs wait on atomic counters. Job entry procedures can come from the game DLL.

- **Jobs are frame-scoped.** A job must not stay suspended across a frame boundary. A suspended fiber's stack holds return addresses into the DLL, so the [reload sequence](hot-reload.md#reload-sequence) requires a drained job system. Logic that spans frames belongs in [scripts](scripting.md).
- **No thread-local state in jobs.** A fiber can resume on a different thread. Jobs must not use `@thread_local` variables or the runtime's default `context.temp_allocator`. Each job gets a scratch allocator through `context`.
- **No OS locks across a yield.** Use the fiber-aware synchronization primitives from `core`.

## Memory

`core` reserves large virtual address ranges at startup and hands out arenas with distinct lifetimes:

| Arena | Lifetime | Survives code reload |
|---|---|---|
| Permanent | Process | Yes |
| Level | Until the level unloads | Yes |
| Frame | One frame, double-buffered | Not applicable |
| Asset | Managed by the asset runtime | Yes |
| Script heap | Managed by the script VM | Yes |

All arenas belong to the host. Game-side code allocates from them through allocators passed in `context` or held in `Game_State`.
