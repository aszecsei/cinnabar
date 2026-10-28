# Capture

Screenshots and GIFs of a running host, for the editor and for tools: how the host copies its frame out, the history ring behind the GIF, the sidecar that makes a screenshot debuggable, and the automation socket that `editorctl` drives.

**In this document:** [Capture](#capture) · [Screenshots](#screenshots) · [History ring](#history-ring) · [Sidecar](#sidecar) · [Automation](#automation)

## Capture

A capture is a request to a running host for an image of what it draws: its next frame as a PNG, or the last five seconds as a looping GIF. The editor asks over the editor link with `Capture_Request`, the host writes the file and answers with `Capture_Result` (see [Editor link](link.md#messages)). The host does the work, so a capture costs the frame nothing but a copy: nothing is encoded on the main thread, and the editor never reads pixels.

- **Who asks.** The editor's Screenshot (F12) and Record Last 5 s (Shift+F12) commands, on the View tab's Capture group, and the [automation](#automation) socket, through which `editorctl`, and so a terminal or an LLM tool, asks for the same. A capture needs a linked host, and one runs at a time.
- **What comes out.** The image, and beside it a [sidecar](#sidecar) JSON with the editor's state at the capture. A screenshot can bring the renderer's debug views too: the request names them, and each becomes an image of its own.
- **Where.** `build/captures` in the repository, named `<utc time>-<sequence>.<png|gif>`, with `.<view>.png` for each debug view and `.json` for the sidecar. A request can name the file instead. The host chooses `captures/<utc time>-f<frame>.<png|gif>` beside its executable when it is given no path.
- **The host's side** is `src/host/capture.odin`. The editor's is `CaptureModel` in `Cinnabar.Editor.Model`, which the shell drives; the model knows only how to send and what to write, so its tests run without a host.

## Screenshots

- **The copy.** The host asks the backend for a copy of the frame target between frames, with `core.request_frame_capture`, and the backend's `end_frame` copies the target to a readback buffer on the frame's final command list, after every submission and before the present, so the copy has the whole frame: the UI and debug layers included (see [GPU: Frame capture](../gpu/presentation.md#frame-capture)). The copy is ready when the frame's fence passes, two frames later, and `core.poll_frame_capture` gives it to the host.
- **The worker.** The host's capture worker thread turns the copy into an RGB8 image, releases the backend's slot at once, encodes a PNG with `stb_image_write`, and writes it with `core.file_write`, which writes a temporary file and moves it into place. The result goes back to the main thread, which sends `Capture_Result`. The pure parts, the conversion from each output mode, the downscale and the encoders, are `lib/core/capture`, tested on their own.
- **Output modes.** In shared mode the frame is sRGB bytes already. A standalone host in HDR10 or scRGB gets the same PNG: PQ is decoded to nits and divided by the display's SDR white, scRGB's linear halves are scaled the same way, and both are clamped and sRGB-encoded, so the display's white is the PNG's white. The result's `output` says which mode the frame had, and the sidecar keeps it.
- **A request that cannot copy** fails with a reason: a minimized window, every capture slot held, a format the conversion does not know.
- **Debug views.** For each view that a screenshot asks for, the editor sends `Viewport_Settings` with that view, waits for three frames to reach the viewport, requests another screenshot, and after the last one sends the user's settings again (see [Viewport: Rendering](viewport.md#viewport)). The views are the renderer's (see [Rendering: Debug views](../rendering/post-processing.md#debug-views)), named in snake case: `depth`, `normals`, `albedo`, `entity_ids`. The `velocity` view needs a frame of history, so its first frame can be empty. The user's settings file is never changed.

## History ring

The GIF is the host's history ring: a frame every 100 ms at half size, 50 frames, so five seconds at ten frames per second. The ring runs whenever the host runs.

- **Sampling.** When 100 ms have passed, the next frame is copied as a screenshot is, and the worker downscales it 2x with a box filter into the ring, over the oldest frame. A screenshot's frame feeds the ring too when one was due. At 1080p the ring is 78 MB of host memory, and the copy every six frames is 8 MB over the bus.
- **Encoding.** A GIF request takes the ring's frames, oldest first, that have the newest frame's size; frames from before a resize are left out, and `frames` and `duration_ms` in the result say what the GIF holds. The encoder, `capture.encode_gif`, writes GIF89a with one global palette of 252 colors, 6 levels of red, 7 of green and 6 of blue, and dithers each pixel with a 4x4 Bayer matrix, so flat gradients pattern instead of banding and no quantization pass runs over the frames. The LZW codes are the standard ones, clearing at 4096. Every frame is a full image with no disposal, so a viewer that drops frames shows whole ones.
- **Builds.** `just release` passes `-define:CAPTURE=false`, which drops the ring and the worker. The release executable has no editor link, so nothing asks it for a capture anyway. A host built that way answers a request with a reason.

## Sidecar

Beside every capture the editor writes `<name>.json`, so an image can be read back to the state that made it. A reader, a person or an LLM, gets the image and the sidecar together.

| Field | What it holds |
|---|---|
| `schema`, `time`, `kind`, `views` | The sidecar's version, the capture's UTC time, `Screenshot` or `Gif`, and the views asked for |
| `images` | Each image: its file, its view or null for the lit frame, and the host's result: the frame number, the size, the output mode, and for a GIF its frames and the milliseconds they span |
| `failures` | Why any image is missing |
| `context.mode`, `freeCamera` | Edit, Play or Paused, and whether the editor's camera flies in play |
| `context.scene` | The open scene's file |
| `context.camera` | The editor's camera: the raw `World_Position`, the same in meters, the yaw and pitch in radians, the vertical field of view and the near plane |
| `context.settings` | The viewport's `Viewport_Settings`: the debug view, the features turned off, the exposure, the helpers and the quality choices |
| `context.hostStats`, `gameStats` | The last `Host_Stats` and `Game_Stats`: frame times, memory, resource counts, entities and script memory |
| `context.game`, `hostPid`, `hostArguments`, `editorPid` | Which game, which processes |

In play mode the camera is the game's, which the sidecar does not have; `freeCamera` says whether the editor's camera was the one drawn.

## Automation

A tool outside the editor cannot link to the host: the host serves one editor at a time. So the editor serves tools instead, on a loopback socket, and forwards their requests over the link it has.

- **The file.** When its window opens, the editor listens on `127.0.0.1` at a port the OS picks and writes `build/obj/editor/automation.json`: `{"port": n, "pid": n, "started": "..."}`. It deletes the file when it closes. A tool checks that the process still runs, so a file that a crash left behind is known to be stale.
- **The protocol** is one JSON object per line each way, in UTF-8. A request has an `id`, which the response repeats, a `command`, and the command's arguments; a response has `ok`, and `files`, `status` or `error`. Requests on a connection run one at a time, and the editor runs one capture at a time across connections. The handler runs on the UI thread, as the ribbon's commands do.

| Command | Arguments | Answer |
|---|---|---|
| `status` | | `status`: `linked`, `hostState`, `mode`, `scene`, `game`, `hostPid` |
| `screenshot` | `views`: debug view names; `path`: the PNG's path, absolute | `files`: the images, then the sidecar |
| `gif` | `path`: the GIF's path, absolute | `files`: the GIF, then the sidecar |

```
{"id":1,"command":"screenshot","views":["depth","normals"]}
{"id":1,"ok":true,"files":["E:\\repos\\cinnabar\\build\\captures\\20261027-081500-01.png","…\\20261027-081500-01.depth.png","…\\20261027-081500-01.normals.png","…\\20261027-081500-01.json"]}
```

A capture that fails answers `ok` false with the reason in `error`, and still lists the sidecar, which has the reason too. An unknown command or view is an error that names the valid ones. The server is `AutomationServer` in `Cinnabar.Editor.Model`, which knows nothing of the editor: the shell gives it a handler.

### editorctl

`tools/editorctl` is the client: it finds the automation file by walking up from the working directory to the repository root, checks the editor's process, sends one request and prints the answer.

```
editorctl [--automation <file>] [--json] status
editorctl [--automation <file>] [--json] screenshot [--view <name>]... [--out <path>]
editorctl [--automation <file>] [--json] gif [--out <path>]
```

It prints the files one per line, or the status's fields, and with `--json` the editor's answer as it came. A failure goes to stderr with exit code 1, and a mistaken command line exits with 2. `--out` is made absolute before it is sent, because the editor's working directory is its own. `just editorctl` builds it into `build/tools`, and `just screenshot` and `just gif` build and run it, passing their arguments on.

An LLM tool working in the repository uses it like this: with the editor open, `just screenshot --view depth` writes the lit frame, the depth view and the sidecar and prints their paths; the tool reads the sidecar for the frame, the camera, the mode and the stats, and the images to look at them. `just gif` shows motion over the last five seconds. `build/tools/editorctl.exe status --json` says whether a host is linked before asking.
