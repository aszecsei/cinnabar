package gpu_d3d12

import "core:fmt"
import "core:log"
import "core:strings"
import win "core:sys/windows"
import "core:time"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"

// Shared mode renders the frame target into textures that another process opens, such as the editor's viewport,
// instead of a swapchain (see docs/gpu.md#presentation). Each size of the target is a generation, whose textures and
// fence are named shared objects: <name>.g<generation>.texture0 to .texture2 and <name>.g<generation>.fence. Frame k
// of a generation renders into texture k % SHARED_TEXTURE_COUNT and then signals k on the fence, so a reader that
// sees fence value v reads texture v % SHARED_TEXTURE_COUNT. A frame ends with its texture in the common layout,
// which other processes and devices can use.
SHARED_TEXTURE_COUNT :: 3
// Nothing presents in shared mode, so this paces the frame.
SHARED_FRAME_TIME :: time.Second / 60
// The render target view slots after the bindless textures: the shared textures, then the scratch target.
SHARED_RTV_COUNT :: SHARED_TEXTURE_COUNT + 1

@(private)
Shared_Target :: struct {
	name:            string,
	generation:      u32,
	textures:        [SHARED_TEXTURE_COUNT]^d3d.IResource,
	texture_handles: [SHARED_TEXTURE_COUNT]win.HANDLE,
	fence:           ^d3d.IFence,
	fence_handle:    win.HANDLE,
	// A frame that would draw into a texture that the reader may still read goes here, and nobody sees it.
	scratch:         ^d3d.IResource,
	// The number of frames of this generation rendered into shared textures, and the fence value of the last one.
	frame:           u64,
	// While a reader paces the frames, frame k goes to a shared texture only if k <= acknowledged + 2.
	paced:           bool,
	acknowledged:    u64,
	to_scratch:      bool,
	frame_start:     time.Tick,
	// A high-resolution timer for the pacing. time.sleep has the resolution of the system tick, 15.6 ms by default,
	// so a 16.7 ms frame would sleep for two ticks.
	timer:           win.HANDLE,
}

// create_shared_target creates the first generation of the shared target, and the frame target that renders into it.
@(private)
create_shared_target :: proc(name: string, size: [2]i32) -> bool {
	shared := &dev.shared
	shared.name = strings.clone(name, dev.allocator)
	shared.timer = win.CreateWaitableTimerExW(nil, nil, win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
	if shared.timer == nil {
		log.errorf("d3d12: CreateWaitableTimerExW failed: %d", win.GetLastError())
		return false
	}
	shared.frame_start = time.tick_now()
	dev.frame_target = gpu.pool_add(&dev.textures, Texture_Entry{desc = {format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, scope = .Permanent}})
	return create_shared_objects(size)
}

@(private = "file")
create_shared_objects :: proc(size: [2]i32) -> bool {
	width, height := u32(max(size.x, 1)), u32(max(size.y, 1))
	heap_props := d3d.HEAP_PROPERTIES {
		Type = .DEFAULT,
	}
	// Typed, unlike the swapchain's typeless back buffers: D3D11 cannot open a shared typeless texture without
	// simultaneous access, and the editor opens these with D3D11 (see docs/editor.md#viewport).
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
	shared := &dev.shared
	prefix := shared_prefix()
	for &texture, i in shared.textures {
		hr := dev.device->CreateCommittedResource3(&heap_props, {.SHARED}, &desc, .COMMON, nil, nil, 0, nil, d3d.IResource_UUID, (^rawptr)(&texture))
		check(hr, "CreateCommittedResource3(shared texture)") or_return
		set_name(texture, "frame target (shared)")
		texture_name := fmt.tprintf("%s.texture%d", prefix, i)
		check(
			dev.device->CreateSharedHandle(texture, nil, win.GENERIC_ALL, win.utf8_to_wstring(texture_name), &shared.texture_handles[i]),
			"CreateSharedHandle(texture)",
		) or_return
		dev.device->CreateRenderTargetView(texture, &rtv, rtv_handle(gpu.MAX_TEXTURES + u32(i)))
	}
	hr := dev.device->CreateCommittedResource3(&heap_props, {}, &desc, .COMMON, nil, nil, 0, nil, d3d.IResource_UUID, (^rawptr)(&shared.scratch))
	check(hr, "CreateCommittedResource3(scratch frame target)") or_return
	set_name(shared.scratch, "frame target (scratch)")
	dev.device->CreateRenderTargetView(shared.scratch, &rtv, rtv_handle(gpu.MAX_TEXTURES + SHARED_TEXTURE_COUNT))
	check(dev.device->CreateFence(0, {.SHARED}, d3d.IFence_UUID, (^rawptr)(&shared.fence)), "CreateFence(shared)") or_return
	fence_name := fmt.tprintf("%s.fence", prefix)
	check(dev.device->CreateSharedHandle(shared.fence, nil, win.GENERIC_ALL, win.utf8_to_wstring(fence_name), &shared.fence_handle), "CreateSharedHandle(fence)") or_return

	shared.frame = 0
	shared.acknowledged = 0
	dev.size = {i32(width), i32(height)}
	gpu.pool_get(&dev.textures, dev.frame_target).desc.size = {width, height}
	log.infof("d3d12: rendering %dx%d into shared textures %s.texture0..%d and fence %s", width, height, prefix, SHARED_TEXTURE_COUNT - 1, fence_name)
	return true
}

@(private = "file")
release_shared_objects :: proc() {
	shared := &dev.shared
	for &texture, i in shared.textures {
		if shared.texture_handles[i] != nil {
			win.CloseHandle(shared.texture_handles[i])
			shared.texture_handles[i] = nil
		}
		release(&texture)
	}
	if shared.fence_handle != nil {
		win.CloseHandle(shared.fence_handle)
		shared.fence_handle = nil
	}
	release(&shared.fence)
	release(&shared.scratch)
}

@(private)
release_shared_target :: proc() {
	release_shared_objects()
	if dev.shared.timer != nil {
		win.CloseHandle(dev.shared.timer)
	}
	delete(dev.shared.name, dev.allocator)
}

@(private = "file")
shared_prefix :: proc() -> string {
	return fmt.tprintf("%s.g%d", dev.shared.name, dev.shared.generation)
}

// begin_shared_frame resizes the target if the size changed, paces the frame, and points the frame target at the
// next shared texture, or at the scratch target if the reader may still be reading that texture.
@(private)
begin_shared_frame :: proc(size: [2]i32) -> (texture: ^d3d.IResource, rtv: d3d.CPU_DESCRIPTOR_HANDLE) {
	shared := &dev.shared
	if size.x > 0 && size.y > 0 && size != dev.size {
		// Readers may hold the old objects. Each keeps them alive until it opens the new generation.
		wait_idle()
		release_shared_objects()
		shared.generation += 1
		if !create_shared_objects(size) {
			log.panic("d3d12: cannot create the resized shared target")
		}
	}
	if elapsed := time.tick_since(shared.frame_start); elapsed < SHARED_FRAME_TIME {
		// A negative due time is relative, in 100 ns units.
		due := win.LARGE_INTEGER(-i64((SHARED_FRAME_TIME - elapsed) / 100))
		if win.SetWaitableTimerEx(shared.timer, &due, 0, nil, nil, nil, 0) {
			win.WaitForSingleObject(shared.timer, win.INFINITE)
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
		return shared.scratch, rtv_handle(gpu.MAX_TEXTURES + SHARED_TEXTURE_COUNT)
	}
	index := u32(next % SHARED_TEXTURE_COUNT)
	return shared.textures[index], rtv_handle(gpu.MAX_TEXTURES + index)
}

// end_shared_frame signals the frame's number on the shared fence after the frame's work. A frame in the scratch
// target signals nothing.
@(private)
end_shared_frame :: proc() {
	shared := &dev.shared
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
	return shared_prefix(), dev.shared.generation, dev.size
}

// pace_shared_frames turns back-pressure on or off. Turning it on counts the last frame as acknowledged, so the
// reader starts from now.
pace_shared_frames :: proc(paced: bool) {
	dev.shared.paced = paced
	dev.shared.acknowledged = dev.shared.frame
}

// acknowledge_shared_frame records that the reader has finished with a frame. A frame of an older generation is
// ignored: its textures are gone.
acknowledge_shared_frame :: proc(generation: u32, frame: u64) {
	if generation == dev.shared.generation {
		dev.shared.acknowledged = max(dev.shared.acknowledged, frame)
	}
}
