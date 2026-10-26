# Command buffers

The packet format the engine records into frame memory, the pass rules that come from Metal's encoder model, split passes for parallel recording, the barrier model, and how the backend translates and submits.

**In this document:** [Command buffers](#command-buffers) · [Submission](#submission) · [Debugging](#debugging)

## Command buffers

The engine records commands into `Command_Buffer`s in frame memory.

- **Format:** a stream of packets. Each packet has a `{kind: u16, size: u16}` header and an inline payload. Push constants are part of the payload.
- **Plain data:** packets contain only handles, indices and POD data. Debug label strings are copied into frame memory. Packets never point into the DLL image (see [Hot reload](../overview/hot-reload.md#rules), rule 3).
- **Parallel recording:** each job records into its own `Command_Buffer`. A submission is an ordered list of command buffers for one queue.
- **Format hash:** `lib/core/gpu` is compiled into both the host and the game DLL. `Game_API` exports a hash of the packet layouts. If the hash differs from the host's, the host refuses the reload and asks for a restart.

### Pass rules

These rules come from Metal's encoder model. All backends enforce them.

- A pass begins and ends in the same command buffer. Debug markers also begin and end in the same command buffer, and they nest with passes. A [split pass](#split-passes) is a chain of such pieces.
- Draws occur only inside a render pass.
- Bindings reset at every pass boundary: the pipeline, pass constants and index buffer. Bind them again in each pass, and bind compute pipelines again after a pass. A render pass begins with the viewport and scissor set to the attachment size.
- A graphics pipeline's attachment formats must match the pass. A compute pipeline is bound only outside a pass.
- Copies, dispatches and acceleration structure builds occur only outside a render pass.
- A render pass declares its attachments with load and store operations. It maps to `BeginRenderPass` (D3D12), dynamic rendering (Vulkan) and a render command encoder (Metal).

### Split passes

A large render pass can be recorded in parallel as pieces, in consecutive command buffers of one submission. On the GPU, the pieces are one render pass.

- `Begin_Pass` has `Pass_Flags`. Each piece but the last is `Suspending`, and each piece but the first is `Resuming`.
- A suspending piece ends its command buffer and stores its attachments. A resuming piece starts its command buffer, loads its attachments, and has the same attachments as the piece before it. Only the first piece clears, and only the last piece can discard.
- Nothing runs between the pieces: no barriers and no debug markers. Each piece starts with nothing bound, like any pass.
- `validate_submission` checks the chains: every suspended piece is resumed by the next command buffer, and no chain crosses the end of a submission.
- **Mapping:** D3D12 `SUSPENDING_PASS` and `RESUMING_PASS`, in consecutive lists of one `ExecuteCommandLists` call. Vulkan dynamic rendering with `VK_RENDERING_SUSPENDING_BIT` and `VK_RENDERING_RESUMING_BIT` in one submission. Metal: the chain becomes one `MTLParallelRenderCommandEncoder`, with one child encoder per piece.
- **Instance IDs:** `SV_InstanceID` starts at 0 in each draw on D3D12 but includes the first instance on Vulkan. A piece that draws part of an instance range passes its first instance to the shader, for example in push constants.

### Barriers

- Barriers use the Enhanced Barriers model: sync stages (`Syncs`), access flags (`Accesses`) and texture layouts (`Texture_Layout`). This model maps one-to-one to Vulkan `synchronization2`. On Metal, most barriers become nothing or fences.
- `cmd_barriers` records buffer, texture and acceleration structure barriers. Barriers occur only outside a render pass. A barrier covers the whole resource. Acceleration structures have only the `Accel_Read` and `Accel_Write` accesses.
- An empty `Syncs` means no synchronization, and an empty `Accesses` means no access. A side with no synchronization has no access.
- `Undefined` as the layout before discards the contents, whatever the texture's layout is.
- The backend does not track resource states to translate barriers. State tracking would serialize parallel recording.
- Validation in debug builds and in the null backend tracks texture layouts. It rejects a barrier whose layout before is wrong, and a render pass whose attachments are not in the render target or depth write layout.
- **Frame boundary:** a frame starts after the GPU completes the work of the previous frame, on both queues. A resource therefore needs no barrier for work in an earlier frame, only a layout change. In D3D12, the completion of an `ExecuteCommandLists` call finishes all work and flushes all caches, and the compute queue's first work in a frame waits for the previous frame's end. A Vulkan backend adds a full barrier at the start of each frame.
- **Cross-queue use** works the same way: after a fence wait, the earlier work of the other queue is complete and visible, so only a layout change needs a barrier (see [Queues](queues-streaming-readback.md#queues)).
- The render graph in `lib/engine/render` records all barriers.

## Submission

- `submit` translates each `Command_Buffer` into one native command list, each on its own job, and waits for them. The lists keep the submission order. Call `submit` from the frame code or from a job.
- Native command lists and allocators are pooled per frame in flight, not per thread, because a fiber can resume on a different thread (see [Core](../core/jobs-and-memory.md#job-system)). A translation job takes a list from the pool. The pool grows when a frame needs more lists.
- Command lists are pooled per queue type. `end_frame` executes the submissions as described in [Queues](queues-streaming-readback.md#queues). The frame target's transitions in and out run in the first and last graphics batches.

## Debugging

- Development builds enable the D3D12 debug layer and DRED. They also validate each command buffer, including barrier layouts, before translation.
- Every resource and pipeline has a debug name. Command buffers carry debug markers for PIX.
- The null backend is the first tool for a bug in recording: `just test` runs the engine's render tests on it, and it rejects what only D3D12 would accept. `CINNABAR_DISABLE_FEATURES` tests the fallback paths on hardware that has the features.
