package gpu_d3d12

import "core:fmt"
import "core:log"
import win "core:sys/windows"
import "core:time"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"

// Shared mode renders the frame target into textures that another process opens, such as the editor's viewport,
// instead of a swapchain (see docs/editor.md#viewport). The textures and a fence are named shared objects:
// <name>.texture0 to <name>.texture2 and <name>.fence. Frame k renders into texture k % SHARED_TEXTURE_COUNT and
// then signals k on the fence, so a reader that sees fence value v reads texture v % SHARED_TEXTURE_COUNT.
// A frame ends with its texture in the common layout, which other processes and devices can use.
SHARED_TEXTURE_COUNT :: 3
// Nothing presents in shared mode, so this paces the frame.
SHARED_FRAME_TIME :: time.Second / 60

@(private)
Shared_Target :: struct {
	textures:        [SHARED_TEXTURE_COUNT]^d3d.IResource,
	texture_handles: [SHARED_TEXTURE_COUNT]win.HANDLE,
	fence:           ^d3d.IFence,
	fence_handle:    win.HANDLE,
	// The number of frames rendered, and the fence value of the last one.
	frame:           u64,
	frame_start:     time.Tick,
	// A high-resolution timer for the pacing. time.sleep has the resolution of the system tick, 15.6 ms by default,
	// so a 16.7 ms frame would sleep for two ticks.
	timer:           win.HANDLE,
}

// create_shared_target creates the named textures and fence, and the frame target that renders into them.
@(private)
create_shared_target :: proc(name: string, size: [2]i32) -> bool {
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
	for &texture, i in shared.textures {
		hr := dev.device->CreateCommittedResource3(&heap_props, {.SHARED}, &desc, .COMMON, nil, nil, 0, nil, d3d.IResource_UUID, (^rawptr)(&texture))
		check(hr, "CreateCommittedResource3(shared texture)") or_return
		set_name(texture, "frame target (shared)")
		texture_name := fmt.tprintf("%s.texture%d", name, i)
		check(
			dev.device->CreateSharedHandle(texture, nil, win.GENERIC_ALL, win.utf8_to_wstring(texture_name), &shared.texture_handles[i]),
			"CreateSharedHandle(texture)",
		) or_return
		dev.device->CreateRenderTargetView(texture, &rtv, rtv_handle(gpu.MAX_TEXTURES + u32(i)))
	}
	check(dev.device->CreateFence(0, {.SHARED}, d3d.IFence_UUID, (^rawptr)(&shared.fence)), "CreateFence(shared)") or_return
	fence_name := fmt.tprintf("%s.fence", name)
	check(dev.device->CreateSharedHandle(shared.fence, nil, win.GENERIC_ALL, win.utf8_to_wstring(fence_name), &shared.fence_handle), "CreateSharedHandle(fence)") or_return
	shared.timer = win.CreateWaitableTimerExW(nil, nil, win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
	if shared.timer == nil {
		log.errorf("d3d12: CreateWaitableTimerExW failed: %d", win.GetLastError())
		return false
	}
	shared.frame_start = time.tick_now()

	dev.size = {i32(width), i32(height)}
	dev.frame_target = gpu.pool_add(
		&dev.textures,
		Texture_Entry{desc = {size = {width, height}, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, scope = .Permanent}},
	)
	log.infof("d3d12: rendering into shared textures %s.texture0..%d and fence %s", name, SHARED_TEXTURE_COUNT - 1, fence_name)
	return true
}

@(private)
release_shared_target :: proc() {
	shared := &dev.shared
	for &texture, i in shared.textures {
		if shared.texture_handles[i] != nil {
			win.CloseHandle(shared.texture_handles[i])
		}
		release(&texture)
	}
	if shared.fence_handle != nil {
		win.CloseHandle(shared.fence_handle)
	}
	if shared.timer != nil {
		win.CloseHandle(shared.timer)
	}
	release(&shared.fence)
}

// begin_shared_frame paces the frame and points the frame target at the next shared texture.
@(private)
begin_shared_frame :: proc() -> (texture: ^d3d.IResource, rtv: d3d.CPU_DESCRIPTOR_HANDLE) {
	shared := &dev.shared
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
	index := u32((shared.frame + 1) % SHARED_TEXTURE_COUNT)
	return shared.textures[index], rtv_handle(gpu.MAX_TEXTURES + index)
}

// end_shared_frame signals the frame's number on the shared fence after the frame's work.
@(private)
end_shared_frame :: proc() {
	dev.shared.frame += 1
	check(dev.queue->Signal(dev.shared.fence, dev.shared.frame), "ICommandQueue.Signal(shared)")
}
