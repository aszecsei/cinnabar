package gpu_d3d12

import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:time"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"
import "cinnabar:core/profile"

// Shared mode renders the frame target into textures that another process opens, such as the editor's viewport,
// instead of a swapchain (see docs/gpu/presentation.md#presentation). Each size of the target is a generation, whose textures and
// fence are named shared objects: <name>.g<generation>.texture0 to .texture2 and <name>.g<generation>.fence. Frame k
// of a generation renders into texture k % SHARED_TEXTURE_COUNT and then signals k on the fence, so a reader that
// sees fence value v reads texture v % SHARED_TEXTURE_COUNT. A frame ends with its texture in the common layout,
// which other processes and devices can use. The editor's previews and its viewports have shared targets of their
// own beside the frame target, the side targets, named <name>.preview<id>.g<generation> (see
// docs/rendering/materials.md#material-previews) and <name>.viewport<id>.g<generation> (see
// docs/editor/viewport.md#views).
SHARED_TEXTURE_COUNT :: 3
// Nothing presents in shared mode, so this paces the frame.
SHARED_FRAME_TIME :: time.Second / 60
// The side targets: the previews' first, then the viewports'.
@(private)
SIDE_TARGETS :: gpu.MAX_PREVIEW_TARGETS + gpu.MAX_VIEWPORT_TARGETS
// The render target view slots after the bindless textures: the shared textures, then the scratch target, then each
// side target's textures.
SHARED_RTV_COUNT :: SHARED_TEXTURE_COUNT + 1 + SIDE_TARGETS * SHARED_TEXTURE_COUNT

// Side_Kind is what a side target shows, which gives it its name and its largest side.
@(private)
Side_Kind :: enum {
	Preview,
	Viewport,
}

@(private)
Shared_Target :: struct {
	name:            string,
	generation:      u32,
	size:            [2]i32,
	textures:        [SHARED_TEXTURE_COUNT]^d3d.IResource,
	texture_handles: [SHARED_TEXTURE_COUNT]win.HANDLE,
	fence:           ^d3d.IFence,
	fence_handle:    win.HANDLE,
	// The frame target's: a frame that would draw into a texture that the reader may still read goes here, and nobody
	// sees it. A side target has none: its frame draws nothing instead.
	scratch:         ^d3d.IResource,
	// The first render target view slot of the textures.
	rtv_base:        u32,
	// The number of frames of this generation rendered into shared textures, and the fence value of the last one.
	frame:           u64,
	// While a reader paces the frames, frame k goes to a shared texture only if k <= acknowledged + 2.
	acknowledged:    u64,
	to_scratch:      bool,
	// A side target's texture handle, and whether this frame renders into it.
	texture:         gpu.Texture,
	used:            bool,
}

// Shared_State is shared mode's state: the frame target's shared target, the side targets, and the pacing.
@(private)
Shared_State :: struct {
	using target: Shared_Target,
	sides:        [SIDE_TARGETS]Shared_Target,
	paced:        bool,
	frame_start:  time.Tick,
	// A high-resolution timer for the pacing. time.sleep has the resolution of the system tick, 15.6 ms by default,
	// so a 16.7 ms frame would sleep for two ticks.
	timer:        win.HANDLE,
}

// create_shared_target creates the first generation of the shared target, and the frame target that renders into it.
@(private)
create_shared_target :: proc(name: string, size: [2]i32) -> bool {
	shared := &dev.shared
	shared.name = strings.clone(name, dev.allocator)
	shared.rtv_base = gpu.MAX_TEXTURES
	shared.timer = win.CreateWaitableTimerExW(nil, nil, win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
	if shared.timer == nil {
		log.errorf("d3d12: CreateWaitableTimerExW failed: %d", win.GetLastError())
		return false
	}
	shared.frame_start = time.tick_now()
	dev.frame_target = gpu.pool_add(&dev.textures, Texture_Entry{desc = {format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, scope = .Permanent}})
	if !create_shared_objects(&shared.target, size, scratch = true) {
		return false
	}
	dev.size = shared.size
	gpu.pool_get(&dev.textures, dev.frame_target).desc.size = {u32(shared.size.x), u32(shared.size.y)}
	return true
}

@(private = "file")
create_shared_objects :: proc(t: ^Shared_Target, size: [2]i32, scratch: bool) -> bool {
	width, height := u32(max(size.x, 1)), u32(max(size.y, 1))
	heap_props := d3d.HEAP_PROPERTIES {
		Type = .DEFAULT,
	}
	// Typed, unlike the swapchain's typeless back buffers: D3D11 cannot open a shared typeless texture without
	// simultaneous access, and the editor opens these with D3D11 (see docs/editor/viewport.md#viewport).
	desc := d3d.RESOURCE_DESC1 {
		Dimension        = .TEXTURE2D,
		Width            = u64(width),
		Height           = height,
		DepthOrArraySize = 1,
		MipLevels        = 1,
		Format           = view_format(gpu.FRAME_TARGET_FORMAT),
		SampleDesc       = {Count = 1},
		Flags            = {.ALLOW_RENDER_TARGET},
	}
	rtv := d3d.RENDER_TARGET_VIEW_DESC {
		Format        = view_format(gpu.FRAME_TARGET_FORMAT),
		ViewDimension = .TEXTURE2D,
	}
	prefix := shared_prefix(t)
	for &texture, i in t.textures {
		hr := dev.device->CreateCommittedResource3(&heap_props, {.SHARED}, &desc, .COMMON, nil, nil, 0, nil, d3d.IResource_UUID, (^rawptr)(&texture))
		check(hr, "CreateCommittedResource3(shared texture)") or_return
		set_name(texture, "frame target (shared)")
		texture_name := fmt.tprintf("%s.texture%d", prefix, i)
		check(
			dev.device->CreateSharedHandle(texture, nil, win.GENERIC_ALL, win.utf8_to_wstring(texture_name), &t.texture_handles[i]),
			"CreateSharedHandle(texture)",
		) or_return
		dev.device->CreateRenderTargetView(texture, &rtv, rtv_handle(t.rtv_base + u32(i)))
	}
	if scratch {
		hr := dev.device->CreateCommittedResource3(&heap_props, {}, &desc, .COMMON, nil, nil, 0, nil, d3d.IResource_UUID, (^rawptr)(&t.scratch))
		check(hr, "CreateCommittedResource3(scratch frame target)") or_return
		set_name(t.scratch, "frame target (scratch)")
		dev.device->CreateRenderTargetView(t.scratch, &rtv, rtv_handle(t.rtv_base + SHARED_TEXTURE_COUNT))
	}
	check(dev.device->CreateFence(0, {.SHARED}, d3d.IFence_UUID, (^rawptr)(&t.fence)), "CreateFence(shared)") or_return
	fence_name := fmt.tprintf("%s.fence", prefix)
	check(dev.device->CreateSharedHandle(t.fence, nil, win.GENERIC_ALL, win.utf8_to_wstring(fence_name), &t.fence_handle), "CreateSharedHandle(fence)") or_return

	t.frame = 0
	t.acknowledged = 0
	t.size = {i32(width), i32(height)}
	log.infof("d3d12: rendering %dx%d into shared textures %s.texture0..%d and fence %s", width, height, prefix, SHARED_TEXTURE_COUNT - 1, fence_name)
	return true
}

@(private = "file")
release_shared_objects :: proc(t: ^Shared_Target) {
	for &texture, i in t.textures {
		if t.texture_handles[i] != nil {
			win.CloseHandle(t.texture_handles[i])
			t.texture_handles[i] = nil
		}
		release(&texture)
	}
	if t.fence_handle != nil {
		win.CloseHandle(t.fence_handle)
		t.fence_handle = nil
	}
	release(&t.fence)
	release(&t.scratch)
}

@(private)
release_shared_target :: proc() {
	release_shared_objects(&dev.shared.target)
	for &p in dev.shared.sides {
		release_shared_objects(&p)
		delete(p.name, dev.allocator)
		// The entry's resource was one of the target's textures, which are released.
		if entry := gpu.pool_get(&dev.textures, p.texture); entry != nil {
			entry.resource = nil
		}
	}
	if dev.shared.timer != nil {
		win.CloseHandle(dev.shared.timer)
	}
	delete(dev.shared.name, dev.allocator)
}

@(private = "file")
shared_prefix :: proc(t: ^Shared_Target) -> string {
	return fmt.tprintf("%s.g%d", t.name, t.generation)
}

// begin_shared_frame resizes the target if the size changed, paces the frame, and points the frame target at the
// next shared texture, or at the scratch target if the reader may still be reading that texture.
@(private)
begin_shared_frame :: proc(size: [2]i32) -> (texture: ^d3d.IResource, rtv: d3d.CPU_DESCRIPTOR_HANDLE) {
	shared := &dev.shared
	if size.x > 0 && size.y > 0 && size != dev.size {
		// Readers may hold the old objects. Each keeps them alive until it opens the new generation.
		wait_idle()
		release_shared_objects(&shared.target)
		shared.generation += 1
		if !create_shared_objects(&shared.target, size, scratch = true) {
			log.panic("d3d12: cannot create the resized shared target")
		}
		dev.size = shared.size
		gpu.pool_get(&dev.textures, dev.frame_target).desc.size = {u32(shared.size.x), u32(shared.size.y)}
	}
	if elapsed := time.tick_since(shared.frame_start); elapsed < SHARED_FRAME_TIME {
		// A negative due time is relative, in 100 ns units.
		due := win.LARGE_INTEGER(-i64((SHARED_FRAME_TIME - elapsed) / 100))
		if win.SetWaitableTimerEx(shared.timer, &due, 0, nil, nil, nil, 0) {
			begin_wait("Shared frame pacing")
			win.WaitForSingleObject(shared.timer, win.INFINITE)
			profile.end_zone()
		}
		// On schedule, so the timer's wake-up latency does not add up from frame to frame.
		shared.frame_start = time.tick_add(shared.frame_start, SHARED_FRAME_TIME)
	} else {
		// A late frame starts a new schedule instead of rushing to catch up.
		shared.frame_start = time.tick_now()
	}
	next := shared.frame + 1
	shared.to_scratch = shared.paced && next > shared.acknowledged + 2
	if shared.to_scratch {
		return shared.scratch, rtv_handle(shared.rtv_base + SHARED_TEXTURE_COUNT)
	}
	index := u32(next % SHARED_TEXTURE_COUNT)
	return shared.textures[index], rtv_handle(shared.rtv_base + index)
}

// drawn_viewport_target is the texture of viewport id's target if this frame drew into it, and otherwise nil: the target
// does not exist, or the frame skipped it.
@(private)
drawn_viewport_target :: proc(id: int) -> ^Texture_Entry {
	slot, _, _, ok := side_slot(.Viewport, id)
	if !ok || !dev.shared.sides[slot].used {
		return nil
	}
	return gpu.pool_get(&dev.textures, dev.shared.sides[slot].texture)
}

// end_shared_sides moves the side targets that the frame drew into the common layout on list, the frame's last.
@(private)
end_shared_sides :: proc(list: ^d3d.IGraphicsCommandList7) {
	for &p in dev.shared.sides {
		if p.used {
			entry := gpu.pool_get(&dev.textures, p.texture)
			texture_barrier(list, entry.resource, {.RENDER_TARGET}, {.NO_ACCESS}, {.RENDER_TARGET}, {}, .RENDER_TARGET, .COMMON)
			when ODIN_DEBUG {
				if layout, _ := gpu.tracked_layout(&dev.layouts, p.texture); layout != .Render_Target {
					log.errorf("gpu: a side target ends the frame in the %v layout", layout)
				}
			}
		}
	}
}

// end_shared_frame, after the frame's work, signals the frame's number on each fence that it drew for. A frame in the
// scratch target signals nothing for it.
@(private)
end_shared_frame :: proc() {
	shared := &dev.shared
	for &p in shared.sides {
		if p.used {
			p.used = false
			p.frame += 1
			check(dev.queue->Signal(p.fence, p.frame), "ICommandQueue.Signal(side target)")
		}
	}
	if shared.to_scratch {
		return
	}
	shared.frame += 1
	check(dev.queue->Signal(shared.fence, shared.frame), "ICommandQueue.Signal(shared)")
}

// shared_target is the current generation of the shared target, its object name prefix and its size. The prefix is
// in temporary memory.
shared_target :: proc() -> (prefix: string, generation: u32, size: [2]i32) {
	if !dev.shared_mode {
		return
	}
	return shared_prefix(&dev.shared.target), dev.shared.generation, dev.size
}

// pace_shared_frames turns back-pressure on or off. Turning it on counts the last frame as acknowledged, so the
// reader starts from now. It paces the side targets too.
pace_shared_frames :: proc(paced: bool) {
	dev.shared.paced = paced
	dev.shared.acknowledged = dev.shared.frame
	for &p in dev.shared.sides {
		p.acknowledged = p.frame
	}
}

// side_slot is a side target's slot, its name and its largest side, or ok false for an id that its kind does not have.
@(private = "file")
side_slot :: proc(kind: Side_Kind, id: int) -> (slot: int, name: string, max_size: u32, ok: bool) {
	switch kind {
	case .Preview:
		return id, "preview", gpu.MAX_PREVIEW_SIZE, id >= 0 && id < gpu.MAX_PREVIEW_TARGETS
	case .Viewport:
		return gpu.MAX_PREVIEW_TARGETS + id, "viewport", gpu.MAX_VIEWPORT_SIZE, id >= 0 && id < gpu.MAX_VIEWPORT_TARGETS
	}
	return
}

// preview_target gives the texture that preview target id renders into this frame, at a size, in the render target
// layout. It makes the target the first time, and a new generation of it when the size changes. It gives false
// outside shared mode, and while the reader may still read the texture that the frame would draw into. The frame's end
// moves the texture to the common layout and signals the target's fence.
preview_target :: proc(id: int, size: [2]u32) -> (target: gpu.Preview_Target, ok: bool) {
	return side_target(.Preview, id, size)
}

// viewport_target is preview_target for viewport id, whose target can be as large as the frame target.
viewport_target :: proc(id: int, size: [2]u32) -> (target: gpu.Preview_Target, ok: bool) {
	return side_target(.Viewport, id, size)
}

@(private = "file")
side_target :: proc(kind: Side_Kind, id: int, size: [2]u32) -> (target: gpu.Preview_Target, ok: bool) {
	slot, name, max_size := side_slot(kind, id) or_return
	if !dev.shared_mode || !dev.recording || size.x == 0 || size.y == 0 {
		return
	}
	p := &dev.shared.sides[slot]
	want := [2]i32{i32(min(size.x, max_size)), i32(min(size.y, max_size))}
	if p.texture == {} {
		p.name = fmt.aprintf("%s.%s%d", dev.shared.name, name, id, allocator = dev.allocator)
		p.rtv_base = gpu.MAX_TEXTURES + SHARED_TEXTURE_COUNT + 1 + u32(slot) * SHARED_TEXTURE_COUNT
		p.texture = gpu.pool_add(&dev.textures, Texture_Entry{desc = {format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, scope = .Permanent}})
	}
	if p.fence == nil || p.size != want {
		if p.fence != nil {
			// The reader keeps the old objects alive until it opens the new generation.
			wait_idle()
			release_shared_objects(p)
			p.generation += 1
		}
		if !create_shared_objects(p, want, scratch = false) {
			release_shared_objects(p)
			return
		}
		p.acknowledged = p.frame
	}
	entry := gpu.pool_get(&dev.textures, p.texture)
	target = {texture = p.texture, prefix = shared_prefix(p), generation = p.generation, size = {u32(p.size.x), u32(p.size.y)}}
	if p.used {
		return target, true
	}
	next := p.frame + 1
	if dev.shared.paced && next > p.acknowledged + 2 {
		return
	}
	index := u32(next % SHARED_TEXTURE_COUNT)
	entry.resource, entry.rtv, entry.desc.size = p.textures[index], rtv_handle(p.rtv_base + index), target.size
	frame := &dev.frames[dev.frame_index % FRAMES_IN_FLIGHT]
	list := acquire_list(frame, .Graphics)
	texture_barrier(list, entry.resource, {.NO_ACCESS}, {.RENDER_TARGET}, {}, {.RENDER_TARGET}, .UNDEFINED, .RENDER_TARGET)
	check(list->Close(), "ICommandList.Close")
	add_op(frame, .Graphics, (^d3d.ICommandList)(list))
	when ODIN_DEBUG {
		gpu.track_layout(&dev.layouts, p.texture, .Render_Target)
	}
	p.used = true
	return target, true
}

@(private = "file")
add_op :: proc(frame: ^Frame, queue: gpu.Queue, list: ^d3d.ICommandList) {
	sync.guard(&dev.lists_mutex)
	append(&frame.ops, Op{queue = queue, first = len(frame.op_lists), count = 1})
	append(&frame.op_lists, list)
}

// release_preview_target releases a preview target's objects, after the GPU has finished with them.
release_preview_target :: proc(id: int) {
	release_side_target(.Preview, id)
}

// release_viewport_target releases a viewport's target's objects, after the GPU has finished with them.
release_viewport_target :: proc(id: int) {
	release_side_target(.Viewport, id)
}

@(private = "file")
release_side_target :: proc(kind: Side_Kind, id: int) {
	slot, _, _, ok := side_slot(kind, id)
	if !ok || dev.shared.sides[slot].fence == nil {
		return
	}
	p := &dev.shared.sides[slot]
	wait_idle()
	release_shared_objects(p)
	p.generation += 1
	p.size = {}
	p.used = false
}

// acknowledge_preview_frame records that the reader has finished with a frame of a preview target.
acknowledge_preview_frame :: proc(id: int, generation: u32, frame: u64) {
	acknowledge_side_frame(.Preview, id, generation, frame)
}

// acknowledge_viewport_frame records that the reader has finished with a frame of a viewport's target.
acknowledge_viewport_frame :: proc(id: int, generation: u32, frame: u64) {
	acknowledge_side_frame(.Viewport, id, generation, frame)
}

@(private = "file")
acknowledge_side_frame :: proc(kind: Side_Kind, id: int, generation: u32, frame: u64) {
	slot, _, _, ok := side_slot(kind, id)
	if ok && generation == dev.shared.sides[slot].generation {
		p := &dev.shared.sides[slot]
		p.acknowledged = max(p.acknowledged, frame)
	}
}
