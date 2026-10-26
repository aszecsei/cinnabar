# Queues, streaming and readback

The graphics and compute queues and how a frame orders them, the copy queue that streams asset data beside the frame, and readback buffers for results the CPU needs.

**In this document:** [Queues](#queues) · [Streaming](#streaming) · [Readback](#readback)

## Queues

- `Queue` is `Graphics` or `Compute`. `gpu_submit(buffers, queue, wait_for)` runs the command buffers on the queue, in order after the queue's earlier submissions in the frame. They start after the earlier submissions in the frame of each queue in `wait_for`.
- A compute-queue command buffer has no render passes. Its barriers use only `COMPUTE_QUEUE_SYNCS` and `COMPUTE_QUEUE_ACCESSES`, and its textures only the `Shader_Resource` and `Unordered_Access` layouts. Validation checks this.
- Work on both queues is frame-scoped: a frame's compute work starts after the previous frame's end, and the frame ends after its compute work. The upload ring and deferred destruction therefore cover both queues.
- **D3D12:** a direct and a compute queue, each with a fence. `end_frame` runs the submissions in order. Each queue's lists wait in a batch until another queue waits for them or the frame ends, and then run in one `ExecuteCommandLists` call after the batch's fence waits. A wait applies before the whole batch, which can only delay earlier lists. Each wait records the fence value at the time it is declared, so batching cannot make a wait cycle.
- **Vulkan and Metal:** queue submissions with timeline semaphores, and a Metal compute command queue with `MTLEvent`s.
- The backend has a copy queue for [streaming](#streaming). It is not a submission target: command buffers run on the graphics and compute queues, and those queues also run `cmd_copy_buffer`.

## Streaming

Streaming copies data into resources on the copy queue, beside the frame's work. The asset runtime will stream its GPU data this way.

- `gpu_stream_buffer(buffer, offset, data)` and `gpu_stream_texture(texture, data)` copy the data before they return and return a `Transfer`. Use the resource once `gpu_transfer_done(transfer)` is true.
- A streamed texture has the `Streamed` usage with `Sampled` and no other usage, and is streamed once with its whole mip chain: each mip tightly packed, mip 0 first (`mip_chain_size`). Copy queues cannot change texture layouts, so the texture is created in the common layout. When its copy is complete, the backend moves it to the sampled layout at the start of the next frame, and only then reports the transfer done.
- A failed stream logs an error and returns the zero `Transfer`. Validation rejects a range out of bounds, data of the wrong size, and a second stream of a texture.
- **D3D12:** each stream call records into the open copy batch with its own staging buffer, and `end_frame` executes the batch and signals the copy fence. A transfer's ID is its batch's fence value. A destroyed resource or a staging buffer is released only after both the frame fence and the copy fence pass, because a copy batch can outlive the frame.
- **Copies in command buffers:** `cmd_copy_buffer` copies between two different buffers, outside render passes, with the `Copy` sync and the `Copy_Source` and `Copy_Dest` accesses. The source can be the upload ring, which makes it the way to update or clear a default-heap buffer. The sample zeroes its draw count this way.

## Readback

- A buffer with the `Readback` usage is in CPU-readable memory. It has no views and no other usage, and takes no initial data. The GPU only writes it, as the destination of `cmd_copy_buffer`, so a shader writes a storage buffer and a copy moves the result.
- `gpu_read_buffer(buffer)` returns the buffer's memory once the GPU has finished every frame that copies into it, and false while one is in flight. The memory is the backend's: read it during the frame, and keep no pointer into it. Copy into a readback buffer again only after reading it.
- A buffer that nothing has copied into reads as ready. A caller that must know its copy ran, such as the editor's picks, writes a ticket into the data.
- **D3D12:** a readback buffer is a committed resource in a readback heap, mapped for its whole life. Translating a copy into one marks it in flight, `end_frame` stamps it with the frame's fence value, and `gpu_read_buffer` compares that with the fence's completed value.
- **Null backend:** a readback buffer is zeroed memory, always ready.
