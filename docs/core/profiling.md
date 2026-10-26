# Profiling

The frame profiler in `lib/core/profile`: CPU zones on every thread, GPU spans from the backend's timestamps, a ring of recent frames, and the costs of each stats interval that the editor shows.

**In this document:** [Profiler](#profiler) · [Zones](#zones) · [Fibers and jobs](#fibers-and-jobs) · [GPU timestamps](#gpu-timestamps) · [Frames and costs](#frames-and-costs) · [Captures](#captures) · [Builds](#builds) · [Future work](#future-work)

## Profiler

The profiler answers two questions: where a frame's time goes, and which parts of the game cost the most over time. It records zones, which are named spans of time on a thread, and it adds them up for each frame.

- **The recorder is host code.** `core.init` starts it before the job system. The game DLL has its own copy of the package for the types and the front-end, but that copy's recorder is not running, as with the job system ([Jobs and memory](jobs-and-memory.md#job-system)).
- **The game zones through `Platform_API.profile`**, a `profile.Procs`. The front-end procedures take it: `profile.scope(&platform.profile, name)`. Engine packages keep the platform pointer, so they zone through it too. A `Platform_API` without the procedures, as in tests, records nothing.
- **Host code calls the recorder directly:** `profile.zone(name)` and `profile.zone_text(text, category)`, as `core`, the GPU backend and the host's loop do.

## Zones

A zone is a name, a detail and two times. `profile.scope(p, name, detail)` opens a zone until the end of the enclosing scope. `profile.scope_text(p, text, category)` interns the text each call, for zones that run a few times per frame.

- **Names are interned by content.** `profile.name(p, text, category)` copies the text into host memory the first time and returns a `profile.Name`. The same text always gives the same name, so a name cached in `Game_State` stays valid across code reloads and never points into the DLL image. Cache the name where a zone runs often: the ECS keeps one per system, and the script runtime one per behaviour instance. Past 16384 names, every new text gets the name `(too many names)`.
- **A category groups names:** `Frame`, `Wait`, `Job`, `System`, `Script`, `Render`, `Gpu`, `Asset`, `Editor` and `User`. A name keeps the category that it was first interned with. The editor colors zones by category, and the costs below read it.
- **The detail** is the callback of a script zone and the piece of a split render pass. It is 0 otherwise.
- **Each thread writes its own ring** of 16384 zones, which the main thread drains at the frame boundary. A thread that records more than that in a frame drops zones and counts them, and the editor shows the count.

What the engine zones:

| Where | Zones |
|---|---|
| `core` and the host | `Begin frame`, `End frame`, `Drain jobs`, `Game update`, `Hot reload`, `Editor link` |
| D3D12 backend | `GPU submit`, `Translate` (detail: the queue), `Execute`, and the waits below |
| ECS | `ECS Fixed`, `ECS Update`, `ECS Late`, `Apply commands`, `Propagate transforms`, and each system's batches by the system's name |
| Scripts | `Script phase` with `Awake`, `Start`, `Events`, `Update` and `Coroutines`, and each callback by its class's name, with the callback as the detail |
| Rendering | `Build frame`, `Compile graph`, `Record passes`, `Submit`, and each pass's recording by the pass's name |
| Others | `Assets poll`, `Editor poll` |

**Wait zones** are time that the main thread waits for the GPU or the display: `Wait for GPU` (the frame slot's fence), `Wait for swapchain`, `Shared frame pacing`, `Minimized` and `Present`. They are not CPU work, so the frame's CPU time leaves them out.

**Scripts** zone their own code with `Profile.begin(name)` and `Profile.finish()`, or `Profile.zone(name, fn, ...)`, which calls `fn` in a zone and returns its results ([API](../scripting/api.md#profile)). A zone that is still open when its callback returns or yields is closed there and marked unbalanced, with one warning. `Profile.finish` never closes the callback's own zone.

## Fibers and jobs

Zones belong to fibers, not threads. A fiber can suspend in a zone and resume on another thread, so each fiber keeps its own stack of open zones in `jobs.Fiber`, and the scheduler gives the running fiber's stack to the recorder at each switch.

- **A wait splits the open zones.** Before a fiber suspends in `jobs.wait` or `jobs.lock`, each of its open zones ends a segment marked `Suspended`. After it resumes, each starts a new segment marked `Resumed`, maybe on another thread. The segments have the fiber's index, so the editor can link them. A thread's zones therefore always nest, and the time that a fiber waits is a gap in its zones.
- **Each job has a zone**, named after the zone that started it and marked `Job`. A translation job of the GPU backend is named `GPU submit`, and an ECS batch job `ECS Update`, with the system's zone inside it. The job's zone ends before the job counts as finished, so the frame boundary that the finish lets through sees it.
- **The recorder's thread-locals** are read through procedures that the compiler cannot inline, as `jobs.current_worker` is, so a fiber that resumes on another thread writes to that thread's ring.

## GPU timestamps

A debug marker with the `Timed` flag is a GPU span: the backend measures it with timestamps and gives the profiler its time under the marker's label. The render graph times every pass's marker, so each pass has a GPU time without any work in the pass ([GPU](../gpu/render-graph.md#render-graph)).

- **D3D12** gives each frame slot a timestamp query heap of 4096 timestamps, which both queues write, and a readback buffer. A translation job takes an index for each end of a timed marker as it records the marker. The frame's first graphics list writes the frame's first timestamp, and its last graphics list, which runs after the graphics queue waits for the compute queue, writes the last one and resolves the heap.
- **The times reach the profiler late.** `begin_frame` reads a slot's timestamps after the slot's fence, two frames later, and gives them to `profile.add_gpu`. A frame that recorded nothing, such as one while the window is minimized, is given no spans, so a capture never waits for it.
- **The CPU's clock.** At each frame's start, `GetClockCalibration` gives each queue's timestamp and the QPC at one moment, and the spans are converted to the CPU's nanoseconds with each queue's frequency. GPU spans and CPU zones are therefore on one timeline. A span that ends before it begins, or lasts over a second, is dropped.
- **The frame's GPU time** is from its first timestamp to its last. Waits between the queues and idle time are in it.
- **Pass times overlap.** The GPU can run passes on one queue at the same time when no barrier is between them, so each pass's time is from its first timestamp to its last, which can include parts of its neighbours. A pass on the compute queue runs at the same time as graphics passes.
- **The null backend** gives each timed marker a span on a fake clock of 1 µs per packet, two frames late, so the profiler's tests see the real latency.

## Frames and costs

`profile.frame_boundary` runs first in `core.begin_frame`. It drains every thread's ring, closes the frame that ran into a ring of the last 128 frames, and measures it:

- **The frame's wait** is the time of the Wait zones on the main thread. **Its CPU time** is its length without the wait.
- **System costs** are the time of each system's zones, summed over the threads. **Script costs** are each class's time in each callback, without the script callbacks nested in it, so an `on_enable` that runs inside `update` counts once.
- **Calls** count zones, not segments.
- **Pass costs** are each pass's GPU time per queue, with the pieces of a split pass added up. They arrive with the frame's GPU spans, so they average over the frames with GPU spans.

The costs add up over the stats interval. `profile.take_summary` closes the interval: it gives the average and the most of each cost per frame, the averages and the most of the CPU, wait and GPU times, and the frames with the longest CPU and GPU times. The host sends it with each `Host_Stats` ([Editor](../editor/link.md#profile)).

## Captures

A capture is one frame's zones, with the zones of the frames before and after it that overlap it, such as a background job that ended later, and its GPU spans. `profile.capture(frame)` copies a frame from the ring.

- **The ring holds about two seconds** at 60 frames per second. For a longer history, the worst CPU and GPU frames of each closed interval are pinned once their GPU spans arrive. The last 240 pinned frames, a minute of 250 ms intervals, stay capturable after the ring has moved on. That covers the Resource Monitor's graph.
- **`profile.worst_recent(n)`** is the longest of the last `n` frames in the ring.
- **`profile.set_recording(false)`** stops recording. Zones that open while it is off are not recorded, and frames still close, without zones.

## Builds

`-define:PROFILE=false` removes the profiler. The front-end compiles to nothing, the recorder records nothing, and `Fiber_Zones` is empty. `Platform_API.profile` has the same fields in every build, so a game's `Game_State` does not depend on the define. `just release` builds without it, and `just test` runs the profiler's and the job system's tests both ways.

A zone costs a clock read and a ring write at each end, roughly 100 ns in an optimized build and more in the `-debug` development builds.

## Future work

- **GPU times on the copy queue.** The streaming copies on the copy queue are not timed: that needs `CopyQueueTimestampQueriesSupported` and a heap of the copy queue's own.
- **Allocation zones.** The script memory categories already count bytes per module; a zone's allocations would show where the garbage comes from.
- **Long captures.** A capture is one frame. A recording of many frames, saved to a file and opened in the editor later, would show stutters that a single frame misses.
