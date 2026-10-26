# Platform

How `core` selects the platform and the GPU backend at compile time, the `Platform_API` struct that is the whole porting surface, and what `core` does at the start and end of every frame. Read [Hot reload](../overview/hot-reload.md) first for why the host owns everything here.

**In this document:** [Platform and backend abstraction](#platform-and-backend-abstraction) · [Platform_API](#platform_api) · [The frame](#the-frame)

## Platform and backend abstraction

Windows and D3D12 are the first targets. A later port must only add files to `core`.

- **OS layer:** Odin's file-suffix convention (`*_windows.odin`) selects the platform implementation at compile time.
- **GPU backend:** the `gpu_backend` collection selects the backend at compile time. There is no runtime dispatch. See [GPU](../gpu/interface.md#packages).
- **Rules:** `lib/engine` and games never import `core:sys/windows`, `vendor:directx` or any backend package. `lib/core/gpu/d3d12` is the only code that imports `vendor:directx`.

The porting surface is therefore exactly: the `*_windows.odin` files of `core`, `jobs` and `tools/cook`, and one backend package. A port that needs a new procedure in `Platform_API` is a sign that the engine has taken on a platform assumption, and the assumption should move into `core` instead.

## Platform_API

`Platform_API` is a struct of procedure pointers, filled by `core` and handed to `init` and `on_reload`. The game stores the struct in `Game_State` (the pointers are host code, so they are safe there). Its fields fall into groups:

| Group | Procedures | Notes |
|---|---|---|
| Memory | `permanent_allocator`, `frame_allocator`, `asset_allocator`, `heap_allocator`, `memory_reserve`, `memory_commit`, `memory_release` | See [Memory](jobs-and-memory.md#memory). |
| Time and input | `time_seconds`, `input` | `input` is the state at the start of the frame. See [Input](input.md#input). |
| Files | `file_read`, `file_modified` | What the asset runtime reads the loose cache with. |
| Window | `window_size`, `set_window_title` | The size is read once per frame. |
| Jobs | `jobs_run`, `jobs_wait`, `jobs_lock`, `jobs_unlock`, `jobs_worker_count` | See [Job system](jobs-and-memory.md#job-system). Background jobs are deliberately absent. |
| GPU | `gpu_features`, `gpu_frame_target`, `gpu_output`, `gpu_request_output`, `gpu_preview_target`, `gpu_release_preview_target`, `gpu_submit`, `gpu_upload`, `gpu_stream_*`, `gpu_transfer_done`, `gpu_read_buffer`, `gpu_create_*`, `gpu_update_*`, `gpu_pipeline_ready`, `gpu_accel_reference`, `gpu_destroy_*`, `gpu_destroy_scope` | One field per backend procedure. See [GPU](../gpu/interface.md#packages). |
| Scripting | `script_open`, `script_close`, `script_push_binding`, `script_atom`, `script_direct_access` | The host trampolines. See [Scripting](../scripting/embedding.md#host-trampolines). |

In release, `main_release` fills the same struct with direct references, so a game never knows which configuration it is in.

## The frame

`core.begin_frame` and `core.end_frame` bracket each call of `Game_API.update`, and the host's loop is little more than those three calls plus the reload check:

1. **`begin_frame`** pumps the window's messages, applies the editor's queued input after them, and fixes the window size for the frame (the editor's requested size in shared mode). It begins the GPU frame, which waits for the frame in flight before the previous one and resets its upload ring, command list pools and deferred destructions ([GPU](../gpu/command-buffers.md#barriers)). Then it computes `dt`, and swaps to the other frame arena and frees it, which is why frame memory is valid for exactly one frame.
2. **`update`** is the game's whole frame ([Architecture](../overview/architecture.md#frame)).
3. **`end_frame`** waits for every frame-scoped job and logs an error if any was still running, then ends the GPU frame: the backend executes the submissions in order and presents, or signals the shared fence in shared mode ([GPU](../gpu/presentation.md#presentation)).
4. **Between frames** the host checks for a new DLL build and reloads it ([Hot reload](../overview/hot-reload.md#reload-sequence)), then handles the editor's messages ([Editor](../editor/link.md#editor-link)). A soft restart runs here too: `core` closes the script VMs, destroys the `Game` scope's GPU resources, releases the game's memory reservations and frees the permanent arena between the old game's `shutdown` and the new game's `init`.

`dt` is a `time.Duration` (integer nanoseconds), so accumulated world time does not drift. The world's fixed-tick schedule depends on this ([World](../world/time.md#fixed-and-variable-rate)).
