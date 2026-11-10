# Platform

How `core` selects the platform and the GPU backend at compile time, the `Platform_API` struct that is the whole porting surface, and what `core` does at the start and end of every frame. Read [Hot reload](../overview/hot-reload.md) first for why the host owns everything here.

**In this document:** [Platform and backend abstraction](#platform-and-backend-abstraction) · [Platform_API](#platform_api) · [File reads](#file-reads) · [The frame](#the-frame)

## Platform and backend abstraction

Windows and D3D12 are the only targets. All code that depends on either is in `core`, so a port adds files to `core` and changes nothing in `engine` or in games.

- **OS layer:** Odin's file-suffix convention (`*_windows.odin`) selects the platform implementation at compile time.
- **GPU backend:** the `gpu_backend` collection selects the backend at compile time. There is no runtime dispatch. See [GPU](../gpu/interface.md#packages).
- **Rules:** `lib/engine` and games never import `core:sys/windows`, `vendor:directx` or any backend package. `lib/core/gpu/d3d12` is the only code that imports `vendor:directx`.

The porting surface is therefore exactly: the `*_windows.odin` files of `core`, `jobs` and `tools/cook`, and one backend package. A port that needs a new procedure in `Platform_API` is a sign that the engine has taken on a platform assumption, and the assumption should move into `core` instead.

## Platform_API

`Platform_API` is a struct of procedure pointers and a few values, filled by `core` and handed to `init` and `on_reload`. The game stores the struct in `Game_State` (the pointers are host code, so they are safe there). Its fields fall into groups:

| Group | Procedures | Notes |
|---|---|---|
| Memory | `permanent_allocator`, `frame_allocator`, `asset_allocator`, `heap_allocator`, `memory_reserve`, `memory_commit`, `memory_release` | See [Memory](jobs-and-memory.md#memory). |
| Paths | `content_dir`, `project_path` | Where the game's loose cache and its project settings are, as absolute strings in host memory: beside the executable, unless the host's command line says otherwise. See [Building and running](../overview/building-and-running.md#build-layout). |
| Time and input | `time_seconds`, `input` | `input` is the state at the start of the frame. See [Input](input.md#input). |
| Files | `file_read`, `file_read_range`, `file_modified`, `file_write`, `file_read_begin`, `file_read_result`, `file_read_end` | What the asset runtime reads the loose cache with, and the project package writes the user's settings with. `file_read_range` reads part of a file, such as a streamed sound's header, before it returns. The last three read a range across frames. See [File reads](#file-reads). |
| Window | `window_size`, `set_window_title` | The size is read once per frame. |
| Jobs | `jobs_run`, `jobs_wait`, `jobs_lock`, `jobs_unlock`, `jobs_worker_count` | See [Job system](jobs-and-memory.md#job-system). Background jobs are deliberately absent. |
| Profiler | `profile` | A `profile.Procs`, which the profile package's front-end takes. See [Profiling](profiling.md#zones). |
| Audio | `audio_write`, `audio_status`, `audio_test_tone` | The device's queue, its state, and whether `CINNABAR_TEST_TONE` asks for the test tone. See [Audio](audio.md#audio). |
| GPU | `gpu_features`, `gpu_frame_target`, `gpu_output`, `gpu_request_output`, `gpu_preview_target`, `gpu_release_preview_target`, `gpu_capture_texture`, `gpu_submit`, `gpu_upload`, `gpu_stream_*`, `gpu_transfer_done`, `gpu_read_buffer`, `gpu_create_*`, `gpu_update_*`, `gpu_pipeline_status`, `gpu_accel_reference`, `gpu_destroy_*`, `gpu_destroy_scope` | One field per backend procedure. See [GPU](../gpu/interface.md#packages). |
| Audio backend | `audio` | The `Audio_API` table that the project chose. See [Audio: Backends](../audio/backends.md#the-contract). |
| Scripting | `script_open`, `script_close`, `script_push_binding`, `script_atom`, `script_direct_access` | The host trampolines. See [Scripting](../scripting/embedding.md#host-trampolines). |

In release, `main_release` fills the same struct with direct references, so a game never knows which configuration it is in.

## File reads

A game cannot start work that goes on across frames, as its jobs are frame-scoped ([Jobs](jobs-and-memory.md#job-system)). So the host reads for it. The renderer reads a mesh's pages this way ([Rendering: GPU residency](../rendering/assets.md#gpu-residency)).

- **`file_read_begin(path, offset, size)`** starts a read of `size` bytes from `offset` on a background job, and returns a `File_Read` ticket. It returns 0 if `MAX_FILE_READS` (256) reads are open, or if the size is 0 or more than `MAX_FILE_READ_SIZE` (256 MiB).
- **`file_read_result(read)`** gives the state: `Pending`, `Done` or `Failed`. With `Done` it gives the bytes, which are in the host's memory at a blob's alignment, and stay valid until the read ends. A read fails if the file does not exist or has fewer bytes than the range. A ticket of 0, or of a read that ended, has failed, so no code reads a state as success by default.
- **`file_read_end(read)`** frees the read. A read that is still `Pending` is cancelled: its job frees the buffer when it finishes. The owner of a read must end it.

The host owns each buffer, so a job never writes to memory of a game that is gone. A ticket holds its slot's generation, so the ticket of an ended read never names the slot's next read. The job opens the file, reads and closes it, as the cooker cannot replace a blob that is open. At a soft restart `core` ends every read that the old game left, and `core.shutdown` waits for the jobs.

## The frame

`core.begin_frame` and `core.end_frame` bracket each call of `Game_API.update`, and the host's loop is little more than those three calls plus the reload check:

1. **`begin_frame`** closes the profiler's frame ([Profiling](profiling.md#frames-and-costs)), pumps the window's messages, applies the editor's queued input after them, and fixes the window size for the frame (the editor's requested size in shared mode). It begins the GPU frame, which waits for the frame in flight before the previous one and resets its upload ring, command list pools and deferred destructions ([GPU](../gpu/command-buffers.md#barriers)). Then it computes `dt`, and swaps to the other frame arena and frees it, which is why frame memory is valid for exactly one frame.
2. **`update`** is the game's whole frame ([Architecture](../overview/architecture.md#frame)).
3. **`end_frame`** waits for every frame-scoped job and logs an error if any was still running, then ends the GPU frame: the backend executes the submissions in order and presents, or signals the shared fence in shared mode ([GPU](../gpu/presentation.md#presentation)).
4. **Between frames** the host checks for a new DLL build and reloads it ([Hot reload](../overview/hot-reload.md#reload-sequence)), then handles the editor's messages ([Editor](../editor/link.md#editor-link)). A soft restart runs here too: `core` closes the script VMs, destroys the `Game` scope's GPU resources, releases the game's memory reservations and frees the permanent arena between the old game's `shutdown` and the new game's `init`.

`dt` is a `time.Duration` (integer nanoseconds), so accumulated world time does not drift. The world's fixed-tick schedule depends on this ([World](../world/time.md#fixed-and-variable-rate)).
