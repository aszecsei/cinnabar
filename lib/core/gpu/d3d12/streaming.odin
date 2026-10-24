package gpu_d3d12

import "core:log"
import "core:sync"
import win "core:sys/windows"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"

// Streaming copies data on a copy queue, beside the frame's work. Each stream call adds copies to the open batch, and
// end_frame executes the batch and signals the copy fence. A transfer's id is the fence value of its batch.
//
// Copy queues cannot change texture layouts, so a streamed texture is created in the common layout. When its batch is
// complete, begin_frame moves it to the sampled layout in the frame's first command list, and only then reports the
// transfer done. Buffers have no layout: a buffer transfer is done when its batch is complete.
@(private)
Streaming :: struct {
	copy_queue:     ^d3d.ICommandQueue,
	copy_fence:     ^d3d.IFence,
	// The value of the last executed batch.
	copy_value:     u64,
	copy_batches:   [UPLOAD_BATCHES]Upload_Batch,
	copy_batch:     int,
	copy_list:      ^d3d.IGraphicsCommandList7,
	copy_open:      bool,
	// The copy fence value that covers all copies recorded so far: the open batch's value, or the last one.
	// Releases wait for it. Read and write it atomically.
	copy_horizon:   u64,
	// Transfers up to this value are done. Read and write it atomically.
	copy_done:      u64,
	// Streamed textures whose batches have not been seen complete yet.
	copy_textures:  [dynamic]Streamed_Texture,
	// Guards the open batch and copy_textures. Taken before releases_mutex, never after.
	stream_mutex:   sync.Mutex,
}

@(private)
Streamed_Texture :: struct {
	texture: gpu.Texture,
	value:   u64,
}

@(private)
init_streaming :: proc() -> bool {
	desc := d3d.COMMAND_QUEUE_DESC {
		Type = .COPY,
	}
	check(dev.device->CreateCommandQueue(&desc, d3d.ICommandQueue_UUID, (^rawptr)(&dev.copy_queue)), "CreateCommandQueue(copy)") or_return
	dev.copy_queue->SetName(win.L("copy"))
	check(dev.device->CreateFence(0, {}, d3d.IFence_UUID, (^rawptr)(&dev.copy_fence)), "CreateFence(copy)") or_return
	for &batch in dev.copy_batches {
		check(dev.device->CreateCommandAllocator(.COPY, d3d.ICommandAllocator_UUID, (^rawptr)(&batch.allocator)), "CreateCommandAllocator(copy)") or_return
	}
	dev.copy_list = create_command_list(dev.copy_batches[0].allocator, .COPY) or_return
	dev.copy_textures = make([dynamic]Streamed_Texture, dev.allocator)
	return true
}

// shutdown_streaming waits for the copy queue and drops an unsubmitted batch.
@(private)
shutdown_streaming :: proc() {
	if dev.copy_fence != nil {
		wait_copy(dev.copy_value)
	}
	if dev.copy_open {
		dev.copy_list->Close()
	}
	release(&dev.copy_list)
	for &batch in dev.copy_batches {
		release(&batch.allocator)
	}
	delete(dev.copy_textures)
	release(&dev.copy_fence)
	release(&dev.copy_queue)
}

stream_buffer :: proc(buffer: gpu.Buffer, offset: u32, data: []byte) -> gpu.Transfer {
	entry := gpu.pool_get(&dev.buffers, buffer)
	if entry == nil {
		log.error("gpu: stream to an invalid buffer")
		return {}
	}
	if err := gpu.validate_stream_buffer(entry.desc, offset, data); err != .None {
		log.errorf("gpu: buffer stream: %v", err)
		return {}
	}
	staging, mapped, ok := create_copy_staging(len(data))
	if !ok {
		return {}
	}
	copy(mapped, data)

	sync.guard(&dev.stream_mutex)
	list := open_copy_list()
	list->CopyBufferRegion(entry.resource, u64(offset), staging, 0, u64(len(data)))
	defer_release(staging, .None, 0)
	return gpu.Transfer(dev.copy_value + 1)
}

stream_texture :: proc(texture: gpu.Texture, data: []byte) -> gpu.Transfer {
	entry := gpu.pool_get(&dev.textures, texture)
	if entry == nil {
		log.error("gpu: stream to an invalid texture")
		return {}
	}
	if err := gpu.validate_stream_texture(entry.desc, entry.streamed, data); err != .None {
		log.errorf("gpu: texture stream: %v", err)
		return {}
	}
	entry.streamed = true

	resource_desc: d3d.RESOURCE_DESC
	entry.resource->GetDesc(&resource_desc)
	mips := entry.desc.mip_count
	footprints: [16]d3d.PLACED_SUBRESOURCE_FOOTPRINT
	rows: [16]u32
	row_sizes: [16]u64
	total: u64
	dev.device->GetCopyableFootprints(&resource_desc, 0, mips, 0, &footprints[0], &rows[0], &row_sizes[0], &total)

	staging, mapped, ok := create_copy_staging(int(total))
	if !ok {
		return {}
	}
	source := 0
	for mip in 0 ..< mips {
		f := footprints[mip]
		for row in 0 ..< int(rows[mip]) {
			copy(mapped[int(f.Offset) + row * int(f.Footprint.RowPitch):], data[source:][:row_sizes[mip]])
			source += int(row_sizes[mip])
		}
	}

	sync.guard(&dev.stream_mutex)
	list := open_copy_list()
	for mip in 0 ..< mips {
		dst := d3d.TEXTURE_COPY_LOCATION {
			pResource = entry.resource,
			Type      = .SUBRESOURCE_INDEX,
		}
		dst.SubresourceIndex = mip
		src := d3d.TEXTURE_COPY_LOCATION {
			pResource = staging,
			Type      = .PLACED_FOOTPRINT,
		}
		src.PlacedFootprint = footprints[mip]
		list->CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
	}
	defer_release(staging, .None, 0)
	value := dev.copy_value + 1
	append(&dev.copy_textures, Streamed_Texture{texture, value})
	return gpu.Transfer(value)
}

transfer_done :: proc(transfer: gpu.Transfer) -> bool {
	return u64(transfer) <= sync.atomic_load(&dev.copy_done)
}

// flush_streams executes the open batch on the copy queue. end_frame calls it.
@(private)
flush_streams :: proc() {
	sync.guard(&dev.stream_mutex)
	if !dev.copy_open {
		return
	}
	check(dev.copy_list->Close(), "ICommandList.Close")
	lists := [?]^d3d.ICommandList{(^d3d.ICommandList)(dev.copy_list)}
	dev.copy_queue->ExecuteCommandLists(len(lists), &lists[0])
	dev.copy_value += 1
	check(dev.copy_queue->Signal(dev.copy_fence, dev.copy_value), "ICommandQueue.Signal(copy)")
	dev.copy_batches[dev.copy_batch].fence_value = dev.copy_value
	dev.copy_batch = (dev.copy_batch + 1) % UPLOAD_BATCHES
	dev.copy_open = false
}

// finish_streams records the sampled-layout transition of each streamed texture whose batch is complete, in the
// frame's first command list, and then marks the completed transfers done. begin_frame calls it while recording.
@(private)
finish_streams :: proc(list: ^d3d.IGraphicsCommandList7) {
	completed := dev.copy_fence->GetCompletedValue()
	sync.guard(&dev.stream_mutex)
	for i := 0; i < len(dev.copy_textures); {
		streamed := dev.copy_textures[i]
		if streamed.value > completed {
			i += 1
			continue
		}
		// A texture destroyed before its transfer finished is skipped.
		if entry := gpu.pool_get(&dev.textures, streamed.texture); entry != nil {
			texture_barrier(list, entry.resource, {.NO_ACCESS}, {.SHADER_RESOURCE}, {}, {.ALL_SHADING}, .COMMON, .SHADER_RESOURCE)
		}
		unordered_remove(&dev.copy_textures, i)
	}
	sync.atomic_store(&dev.copy_done, completed)
}

// copy_completed is the copy fence's completed value. Releases wait for it too.
@(private)
copy_completed :: proc() -> u64 {
	return dev.copy_fence != nil ? dev.copy_fence->GetCompletedValue() : max(u64)
}

// open_copy_list returns the open batch's command list. The caller holds stream_mutex.
@(private = "file")
open_copy_list :: proc() -> ^d3d.IGraphicsCommandList7 {
	if !dev.copy_open {
		batch := &dev.copy_batches[dev.copy_batch]
		wait_copy(batch.fence_value)
		check(batch.allocator->Reset(), "ICommandAllocator.Reset")
		check(dev.copy_list->Reset(batch.allocator, nil), "ICommandList.Reset")
		dev.copy_open = true
		sync.atomic_store(&dev.copy_horizon, dev.copy_value + 1)
	}
	return dev.copy_list
}

@(private = "file")
wait_copy :: proc(value: u64) {
	if dev.copy_fence->GetCompletedValue() < value {
		event := win.CreateEventW(nil, false, false, nil)
		defer win.CloseHandle(event)
		check(dev.copy_fence->SetEventOnCompletion(value, event), "SetEventOnCompletion(copy)")
		win.WaitForSingleObject(event, win.INFINITE)
	}
}

// create_copy_staging creates a mapped upload buffer. The caller releases it with defer_release once its copies are in
// the open batch, so the release waits for that batch.
@(private = "file")
create_copy_staging :: proc(size: int) -> (resource: ^d3d.IResource, mapped: []byte, ok: bool) {
	resource = create_buffer_resource({size = u32(size), label = "streaming staging"}, .UPLOAD) or_return
	ptr: [^]byte
	if !check(resource->Map(0, &d3d.RANGE{}, (^rawptr)(&ptr)), "Map(streaming staging)") {
		resource->Release()
		return nil, nil, false
	}
	return resource, ptr[:size], true
}
