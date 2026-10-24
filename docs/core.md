# Core

`lib/core` is the platform layer. It owns every OS and device resource, and it provides the job system and memory arenas. See [Architecture](architecture.md#platform-layer) for the overview.

## Platform and backend abstraction

Windows and D3D12 are the first targets. A later port must only add files to `core`.

- **OS layer:** Odin's file-suffix convention (`*_windows.odin`) selects the platform implementation at compile time.
- **GPU backend:** the `gpu_backend` collection selects the backend at compile time. There is no runtime dispatch. See [GPU](gpu.md#packages).
- **Rules:** `lib/engine` and games never import `core:sys/windows`, `vendor:directx` or any backend package. `lib/core/gpu/d3d12` is the only code that imports `vendor:directx`.

## Job system

The job system in `lib/core/jobs` has one worker thread per core and a pool of fibers. Jobs wait on atomic counters. Job entry procedures can come from the game DLL.

- **Interface:** a `Job` is a procedure and a data pointer. `jobs_run(jobs, &counter)` starts jobs and adds them to a `Counter`. `jobs_wait(&counter)` suspends the calling fiber until the counter is zero. A zero `Counter` is ready to use, and it can live on the stack of the fiber that waits for it.
- **Game access:** the game calls the job system through `Platform_API`. The game DLL contains its own copy of `lib/core/jobs` for the types, but that copy's scheduler is not running.
- **Main thread:** the frame runs on the main thread's own fiber. While that fiber waits, the main thread runs jobs. The main fiber resumes only on the main thread, so window calls from the frame code stay on the window's thread.
- **Jobs are frame-scoped.** A job must not stay suspended across a frame boundary. A suspended fiber's stack holds return addresses into the DLL, so the [reload sequence](hot-reload.md#reload-sequence) requires a drained job system. `core` waits for all frame jobs at the end of each frame, and logs an error if any were still running. Logic that spans frames belongs in [scripts](scripting.md).
- **Background jobs:** `jobs.run_background` starts jobs that may run across frames. They must run only host code, so the host can never unload code that they run. The GPU backend compiles pipelines this way. Background jobs are not part of `Platform_API`.
- **No thread-local state in jobs.** A fiber can resume on a different thread. Jobs must not use `@thread_local` variables or the runtime's default `context.temp_allocator`. Each job's fiber has its own scratch arena as `context.temp_allocator`. It is freed when the next job starts on the fiber.
- **No OS locks across a yield.** An OS lock blocks its thread, so a fiber that waits while it holds one can deadlock the workers. Use the fiber-aware `jobs.Mutex` (`jobs_lock` and `jobs_unlock`) for any section that waits. A fiber that finds the mutex locked suspends, and its thread runs other jobs. The unlocking fiber hands the mutex to the oldest waiter. An OS lock is still fine for a short section that never waits.

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

Game-side stores that must not move, such as world storage, reserve virtual memory directly with `memory_reserve` and `memory_commit` in `Platform_API`. They hold no allocator, so they survive code reload. `core` releases every reservation that the game still holds at a soft restart.
