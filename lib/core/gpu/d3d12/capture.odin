package gpu_d3d12

import "core:sync"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"

// Frame captures copy the frame target to CPU memory for the host's screenshots and history ring (see
// docs/gpu/presentation.md#frame-capture). A capture takes a slot: a readback buffer, grown to the frame target's
// copyable footprint, that stays mapped. The copy goes on the frame's final graphics list, so it sees the whole
// frame, and the slot is ready once the frame's fence passes. The host's worker thread frees it, so a slot's state is
// atomic.
@(private)
CAPTURE_SLOTS :: FRAMES_IN_FLIGHT + 2

@(private)
Capture_State :: enum u32 {
	Free,
	// request_frame_capture took it for this frame; end_frame records the copy.
	Requested,
	// The copy is recorded. fence_value is 0 until end_frame signals the frame.
	Copying,
	// poll_frame_capture gave it to the host, which holds the memory until release_frame_capture.
	Taken,
}

@(private)
Capture_Slot :: struct {
	state:       Capture_State,
	resource:    ^d3d.IResource,
	mapped:      [^]byte,
	capacity:    u32,
	fence_value: u64,
	size:        [2]u32,
	format:      gpu.Format,
	mode:        gpu.Output_Mode,
	sdr_white:   f32,
	row_pitch:   u32,
	ticket:      u32,
}

@(private)
Captures :: struct {
	slots:   [CAPTURE_SLOTS]Capture_Slot,
	// The slot that this frame's end_frame copies into, or -1.
	pending: i32,
	// The slot that this frame's end_frame copies a texture into, or -1, the texture and what to call the copy.
	texture_pending: i32,
	texture:         gpu.Texture,
	texture_ticket:  u32,
}

// request_frame_capture asks for a copy of this frame's frame target. False when the window is minimized or every
// slot is in use; true, without a second copy, when one is already requested for this frame. Call it on the main
// thread between frames.
request_frame_capture :: proc() -> bool {
	c := &dev.captures
	if !dev.recording {
		return false
	}
	if c.pending >= 0 {
		return true
	}
	for &slot, i in c.slots {
		if sync.atomic_load(&slot.state) == .Free {
			sync.atomic_store(&slot.state, .Requested)
			c.pending = i32(i)
			return true
		}
	}
	return false
}

// poll_frame_capture returns the oldest copy whose frame the GPU has finished. The host owns the pixels until it
// calls release_frame_capture. Call it on the main thread.
poll_frame_capture :: proc() -> (capture: gpu.Frame_Capture, ok: bool) {
	c := &dev.captures
	completed := dev.fence->GetCompletedValue()
	best := -1
	for &slot, i in c.slots {
		if sync.atomic_load(&slot.state) != .Copying ||
		   slot.fence_value == 0 ||
		   slot.fence_value > completed {
			continue
		}
		if best < 0 || slot.fence_value < c.slots[best].fence_value {
			best = i
		}
	}
	if best < 0 {
		return
	}
	slot := &c.slots[best]
	sync.atomic_store(&slot.state, .Taken)
	return gpu.Frame_Capture {
			slot = u32(best),
			size = slot.size,
			format = slot.format,
			mode = slot.mode,
			sdr_white = slot.sdr_white,
			row_pitch = slot.row_pitch,
			pixels = slot.mapped[:int(slot.row_pitch) * int(slot.size.y)],
				ticket = slot.ticket,
		},
		true
}

// release_frame_capture frees a capture's slot. Any thread can call it.
release_frame_capture :: proc(capture: gpu.Frame_Capture) {
	if capture.slot < CAPTURE_SLOTS {
		sync.atomic_store(&dev.captures.slots[capture.slot].state, .Free)
	}
}

@(private)
init_captures :: proc() {
	dev.captures.pending = -1
	dev.captures.texture_pending = -1
}

@(private)
shutdown_captures :: proc() {
	for &slot in dev.captures.slots {
		release(&slot.resource)
	}
	dev.captures = {
		pending         = -1,
		texture_pending = -1,
	}
}

// pending_capture is the slot that this frame's end_frame copies into, or nil.
@(private)
pending_capture :: proc() -> ^Capture_Slot {
	c := &dev.captures
	if c.pending < 0 {
		return nil
	}
	return &c.slots[c.pending]
}

// cancel_capture frees the frame's requested slot, when the frame recorded nothing.
@(private)
cancel_capture :: proc() {
	if slot := pending_capture(); slot != nil {
		sync.atomic_store(&slot.state, .Free)
		dev.captures.pending = -1
	}
	if i := dev.captures.texture_pending; i >= 0 {
		sync.atomic_store(&dev.captures.slots[i].state, .Free)
		dev.captures.texture_pending = -1
	}
}

// request_texture_capture asks for a copy of a texture at this frame's end, which poll_frame_capture gives with the
// ticket. The texture must end the frame in the render target layout, and stays there. It is false when every slot is
// in use or a copy is already asked for this frame, so ask again next frame. Call it on the main thread while the frame
// records.
request_texture_capture :: proc(texture: gpu.Texture, ticket: u32) -> bool {
	c := &dev.captures
	if !dev.recording || c.texture_pending >= 0 {
		return false
	}
	for &slot, i in c.slots {
		if sync.atomic_load(&slot.state) == .Free {
			sync.atomic_store(&slot.state, .Requested)
			c.texture_pending = i32(i)
			c.texture, c.texture_ticket = texture, ticket
			return true
		}
	}
	return false
}

// record_texture_capture copies the asked texture into its slot on the frame's final list, and leaves it as it was.
@(private)
record_texture_capture :: proc(list: ^d3d.IGraphicsCommandList7) {
	c := &dev.captures
	if c.texture_pending < 0 {
		return
	}
	slot := &c.slots[c.texture_pending]
	target := gpu.pool_get(&dev.textures, c.texture)
	desc: d3d.RESOURCE_DESC
	target.resource->GetDesc(&desc)
	footprint: d3d.PLACED_SUBRESOURCE_FOOTPRINT
	rows: u32
	row_size, total: u64
	dev.device->GetCopyableFootprints(&desc, 0, 1, 0, &footprint, &rows, &row_size, &total)
	if slot.resource == nil || slot.capacity < u32(total) {
		if slot.resource != nil {
			slot.resource->Release()
			slot.resource = nil
			slot.mapped = nil
			slot.capacity = 0
		}
		resource, ok := create_buffer_resource({size = u32(total), usage = {.Readback}, label = "texture capture"}, .READBACK)
		if !ok || !check(resource->Map(0, nil, (^rawptr)(&slot.mapped)), "IResource.Map(texture capture)") {
			if ok {
				resource->Release()
			}
			sync.atomic_store(&slot.state, .Free)
			c.texture_pending = -1
			return
		}
		slot.resource = resource
		slot.capacity = u32(total)
	}
	texture_barrier(list, target.resource, {.RENDER_TARGET}, {.COPY_SOURCE}, {.RENDER_TARGET}, {.COPY}, .RENDER_TARGET, .COPY_SOURCE)
	dst := d3d.TEXTURE_COPY_LOCATION {
		pResource = slot.resource,
		Type      = .PLACED_FOOTPRINT,
	}
	dst.PlacedFootprint = footprint
	src := d3d.TEXTURE_COPY_LOCATION {
		pResource = target.resource,
		Type      = .SUBRESOURCE_INDEX,
	}
	list->CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
	texture_barrier(list, target.resource, {.COPY_SOURCE}, {.RENDER_TARGET}, {.COPY}, {.RENDER_TARGET}, .COPY_SOURCE, .RENDER_TARGET)
	slot.size = {u32(desc.Width), desc.Height}
	slot.format = target.desc.format
	slot.mode = .Sdr
	slot.sdr_white = 1
	slot.row_pitch = footprint.Footprint.RowPitch
	slot.fence_value = 0
	slot.ticket = c.texture_ticket
	sync.atomic_store(&slot.state, .Copying)
}

// record_capture copies the frame target into the slot on the frame's final list, and leaves the target in the
// present layout, as the frame's end does without a capture. A slot whose buffer is too small gets a new one.
@(private)
record_capture :: proc(
	slot: ^Capture_Slot,
	list: ^d3d.IGraphicsCommandList7,
	target: ^Texture_Entry,
) {
	desc: d3d.RESOURCE_DESC
	target.resource->GetDesc(&desc)
	footprint: d3d.PLACED_SUBRESOURCE_FOOTPRINT
	rows: u32
	row_size, total: u64
	dev.device->GetCopyableFootprints(&desc, 0, 1, 0, &footprint, &rows, &row_size, &total)

	if slot.resource == nil || slot.capacity < u32(total) {
		if slot.resource != nil {
			// Its last copy was read before the slot came free, so nothing uses it.
			slot.resource->Release()
			slot.resource = nil
			slot.mapped = nil
			slot.capacity = 0
		}
		resource, ok := create_buffer_resource(
			{size = u32(total), usage = {.Readback}, label = "frame capture"},
			.READBACK,
		)
		if !ok ||
		   !check(resource->Map(0, nil, (^rawptr)(&slot.mapped)), "IResource.Map(frame capture)") {
			if ok {
				resource->Release()
			}
			texture_barrier(
				list,
				target.resource,
				{.RENDER_TARGET},
				{.NO_ACCESS},
				{.RENDER_TARGET},
				{},
				.RENDER_TARGET,
				.PRESENT,
			)
			cancel_capture()
			return
		}
		slot.resource = resource
		slot.capacity = u32(total)
	}

	texture_barrier(
		list,
		target.resource,
		{.RENDER_TARGET},
		{.COPY_SOURCE},
		{.RENDER_TARGET},
		{.COPY},
		.RENDER_TARGET,
		.COPY_SOURCE,
	)
	dst := d3d.TEXTURE_COPY_LOCATION {
		pResource = slot.resource,
		Type      = .PLACED_FOOTPRINT,
	}
	dst.PlacedFootprint = footprint
	src := d3d.TEXTURE_COPY_LOCATION {
		pResource = target.resource,
		Type      = .SUBRESOURCE_INDEX,
	}
	list->CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
	texture_barrier(
		list,
		target.resource,
		{.COPY_SOURCE},
		{.NO_ACCESS},
		{.COPY},
		{},
		.COPY_SOURCE,
		.PRESENT,
	)

	slot.size = {u32(dev.size.x), u32(dev.size.y)}
	slot.format = target.desc.format
	slot.mode = dev.output.mode
	slot.sdr_white = dev.output.display.sdr_white
	slot.row_pitch = footprint.Footprint.RowPitch
	slot.fence_value = 0
	slot.ticket = 0
	sync.atomic_store(&slot.state, .Copying)
}

// stamp_capture gives the frame's copy the fence value that the frame signals.
@(private)
stamp_capture :: proc(fence_value: u64) {
	if slot := pending_capture(); slot != nil {
		slot.fence_value = fence_value
		dev.captures.pending = -1
	}
	if i := dev.captures.texture_pending; i >= 0 {
		dev.captures.slots[i].fence_value = fence_value
		dev.captures.texture_pending = -1
	}
}
