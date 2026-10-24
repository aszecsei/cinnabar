package gpu_d3d12

import "core:mem"
import "core:sync"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"

UPLOAD_RING_SIZE :: 16 * mem.Megabyte

// Initial data for new resources is copied in batches. A batch's command list runs before the frame's
// command list, so a resource is ready for any command buffer submitted in the frame that created it.
UPLOAD_BATCHES :: 3

// Upload_Ring is a frame's linear allocator in an upload-heap buffer. It resets when the frame's fence passes.
@(private)
Upload_Ring :: struct {
	buffer: gpu.Buffer,
	mapped: [^]byte,
	offset: int,
}

@(private)
Upload_Batch :: struct {
	allocator:   ^d3d.ICommandAllocator,
	fence_value: u64,
}

@(private)
Uploads :: struct {
	upload_batches: [UPLOAD_BATCHES]Upload_Batch,
	upload_batch:   int,
	upload_list:    ^d3d.IGraphicsCommandList7,
	// True while upload_list records the current batch.
	upload_open:    bool,
	upload_mutex:   sync.Mutex,
}

@(private)
init_uploads :: proc() -> bool {
	for &batch in dev.upload_batches {
		check(dev.device->CreateCommandAllocator(.DIRECT, d3d.ICommandAllocator_UUID, (^rawptr)(&batch.allocator)), "CreateCommandAllocator") or_return
	}
	dev.upload_list = create_command_list(dev.upload_batches[0].allocator) or_return
	return true
}

// shutdown_uploads drops an unsubmitted batch. Its resources are being released anyway.
@(private)
shutdown_uploads :: proc() {
	if dev.upload_open {
		dev.upload_list->Close()
	}
	release(&dev.upload_list)
	for &batch in dev.upload_batches {
		release(&batch.allocator)
	}
}

@(private)
init_upload_ring :: proc(ring: ^Upload_Ring) -> bool {
	desc := gpu.Buffer_Desc {
		size  = UPLOAD_RING_SIZE,
		scope = .Permanent,
		label = "upload ring",
	}
	resource := create_buffer_resource(desc, .UPLOAD) or_return
	// Upload heaps stay mapped for their lifetime. An empty read range means the CPU never reads.
	check(resource->Map(0, &d3d.RANGE{}, (^rawptr)(&ring.mapped)), "Map(upload ring)") or_return
	ring.buffer = add_buffer(desc, resource)
	return ring.buffer != {}
}

@(private)
reset_upload_ring :: proc(ring: ^Upload_Ring) {
	sync.atomic_store(&ring.offset, 0)
}

// upload allocates memory in the frame's upload ring. It returns false when the ring is full.
upload :: proc(size, align: int) -> (gpu.Upload, bool) {
	ring := &dev.frames[dev.frame_index % FRAMES_IN_FLIGHT].upload
	for {
		offset := sync.atomic_load(&ring.offset)
		start := mem.align_forward_int(offset, align)
		if start + size > UPLOAD_RING_SIZE {
			return {}, false
		}
		if _, ok := sync.atomic_compare_exchange_weak(&ring.offset, offset, start + size); ok {
			return {data = ring.mapped[start:][:size], buffer = ring.buffer, offset = u32(start)}, true
		}
	}
}

// upload_buffer copies data into a new buffer through a staging buffer.
@(private)
upload_buffer :: proc(resource: ^d3d.IResource, data: []byte) {
	staging, mapped, ok := create_staging(len(data))
	if !ok {
		return
	}
	copy(mapped, data)

	sync.guard(&dev.upload_mutex)
	list := open_upload_list()
	list->CopyBufferRegion(resource, 0, staging, 0, u64(len(data)))
	barrier := d3d.BUFFER_BARRIER {
		SyncBefore   = {.COPY},
		SyncAfter    = {.ALL},
		AccessBefore = {.COPY_DEST},
		AccessAfter  = {},
		pRessource   = resource,
		Size         = max(u64),
	}
	group := d3d.BARRIER_GROUP {
		Type            = .BUFFER,
		NumBarriers     = 1,
		pBufferBarriers = &barrier,
	}
	list->Barrier(1, &group)
}

// upload_texture copies mip 0 into a new texture in the COPY_DEST layout, then moves it to the sampled layout.
@(private)
upload_texture :: proc(resource: ^d3d.IResource, desc: ^d3d.RESOURCE_DESC1, data: []byte) {
	footprint: d3d.PLACED_SUBRESOURCE_FOOTPRINT
	rows: u32
	row_size, total: u64
	dev.device->GetCopyableFootprints1(desc, 0, 1, 0, &footprint, &rows, &row_size, &total)

	staging, mapped, ok := create_staging(int(total))
	if !ok {
		return
	}
	for row in 0 ..< int(rows) {
		copy(mapped[row * int(footprint.Footprint.RowPitch):], data[row * int(row_size):][:row_size])
	}

	sync.guard(&dev.upload_mutex)
	list := open_upload_list()
	dst := d3d.TEXTURE_COPY_LOCATION {
		pResource = resource,
		Type      = .SUBRESOURCE_INDEX,
	}
	src := d3d.TEXTURE_COPY_LOCATION {
		pResource = staging,
		Type      = .PLACED_FOOTPRINT,
	}
	src.PlacedFootprint = footprint
	list->CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
	texture_barrier(list, resource, {.COPY_DEST}, {.SHADER_RESOURCE}, {.COPY}, {.ALL_SHADING}, .COPY_DEST, .SHADER_RESOURCE)
}

// create_staging creates a mapped upload buffer that is released after the current batch runs.
@(private = "file")
create_staging :: proc(size: int) -> (resource: ^d3d.IResource, mapped: []byte, ok: bool) {
	resource = create_buffer_resource({size = u32(size), label = "staging"}, .UPLOAD) or_return
	ptr: [^]byte
	if !check(resource->Map(0, &d3d.RANGE{}, (^rawptr)(&ptr)), "Map(staging)") {
		resource->Release()
		return nil, nil, false
	}
	defer_release(resource, .None, 0)
	return resource, ptr[:size], true
}

// open_upload_list returns the current batch's command list. The caller holds upload_mutex.
@(private = "file")
open_upload_list :: proc() -> ^d3d.IGraphicsCommandList7 {
	if !dev.upload_open {
		batch := &dev.upload_batches[dev.upload_batch]
		wait_fence(batch.fence_value)
		check(batch.allocator->Reset(), "ICommandAllocator.Reset")
		check(dev.upload_list->Reset(batch.allocator, nil), "ICommandList.Reset")
		dev.upload_open = true
	}
	return dev.upload_list
}

// flush_uploads executes the current batch, before the frame's command list.
@(private)
flush_uploads :: proc() {
	sync.guard(&dev.upload_mutex)
	if !dev.upload_open {
		return
	}
	check(dev.upload_list->Close(), "ICommandList.Close")
	lists := [?]^d3d.ICommandList{dev.upload_list}
	dev.queue->ExecuteCommandLists(len(lists), &lists[0])
	signal()
	dev.upload_batches[dev.upload_batch].fence_value = dev.fence_value
	dev.upload_batch = (dev.upload_batch + 1) % UPLOAD_BATCHES
	dev.upload_open = false
}
