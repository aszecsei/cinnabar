# Jobs and memory

The two services everything else is built on: the fiber job system in `lib/core/jobs`, and the memory arenas that `core` owns so that they survive a code reload. The rules here (frame-scoped jobs, no thread-local state, no OS locks across a yield) are the ones [World](../world/README.md) and [Rendering](../rendering/README.md) rely on.

**In this document:** [Job system](#job-system) · [Memory](#memory)

## Job system

The job system in `lib/core/jobs` has one worker thread per core and a pool of fibers. Jobs wait on atomic counters. Job entry procedures can come from the game DLL.

- **Interface:** a `Job` is a procedure and a data pointer. `jobs_run(jobs, &counter)` starts jobs and adds them to a `Counter`. `jobs_wait(&counter)` suspends the calling fiber until the counter is zero. A zero `Counter` is ready to use, and it can live on the stack of the fiber that waits for it.
- **Game access:** the game calls the job system through `Platform_API`. The game DLL contains its own copy of `lib/core/jobs` for the types, but that copy's scheduler is not running.
- **Main thread:** the frame runs on the main thread's own fiber. While that fiber waits, the main thread runs jobs. The main fiber resumes only on the main thread, so window calls from the frame code stay on the window's thread.
- **Jobs are frame-scoped.** A job must not stay suspended across a frame boundary. A suspended fiber's stack holds return addresses into the DLL, so the [reload sequence](../overview/hot-reload.md#reload-sequence) requires a drained job system. `core` waits for all frame jobs at the end of each frame, and logs an error if any were still running. Logic that spans frames belongs in [scripts](../scripting/README.md).
- **Background jobs:** `jobs.run_background` starts jobs that may run across frames. They must run only host code, so the host can never unload code that they run. The GPU backend compiles pipelines this way. Background jobs are not part of `Platform_API`.
- **No thread-local state in jobs.** A fiber can resume on a different thread. Jobs must not use `@thread_local` variables or the runtime's default `context.temp_allocator`. Each job's fiber has its own scratch arena as `context.temp_allocator`. It is freed when the next job starts on the fiber.
- **No OS locks across a yield.** An OS lock blocks its thread, so a fiber that waits while it holds one can deadlock the workers. Use the fiber-aware `jobs.Mutex` (`jobs_lock` and `jobs_unlock`) for any section that waits. A fiber that finds the mutex locked suspends, and its thread runs other jobs. The unlocking fiber hands the mutex to the oldest waiter. An OS lock is still fine for a short section that never waits.

### How the engine uses it

The pattern is the same everywhere: split work into chunks, start one job per batch of chunks, wait on one counter. The ECS's systems start a job per batch of 4 chunks with a driver job per system ([World](../world/ecs.md#systems)); render extraction and the render graph's passes run a job per chunk or per pass piece ([World](../world/render-extraction.md#render-extraction), [GPU](../gpu/render-graph.md#render-graph)); the GPU backend translates each command buffer on its own job ([GPU](../gpu/command-buffers.md#submission)); the cooker compresses each texture mip's rows across every core ([Content pipeline](../content/identity-and-cooking.md#cooking)). Anything a job writes goes to memory that the job's data pointer names, usually frame memory, never to a global or a thread-local.

## Memory

`core` reserves large virtual address ranges at startup and hands out arenas with distinct lifetimes:

| Arena | Lifetime | Survives code reload |
|---|---|---|
| Permanent | Process | Yes |
| Frame | One frame, double-buffered | Not applicable |
| Asset | Managed by the asset runtime, which allocates from `asset_allocator` (the host's heap) | Yes |
| Script heap | Managed by the script VM | Yes |

All arenas belong to the host. Game-side code allocates from them through allocators passed in `context` or held in `Game_State`.

Game-side stores that must not move, such as world storage, reserve virtual memory directly with `memory_reserve` and `memory_commit` in `Platform_API`. They hold no allocator, so they survive code reload. `core` releases every reservation that the game still holds at a soft restart.

Frame memory is where almost everything transient goes: command buffers, the render graph, extraction records, the editor's messages for the game, and each job's scratch. It is double-buffered because the GPU backend's translation jobs of frame N can still be reading command buffers when frame N+1 starts recording.
