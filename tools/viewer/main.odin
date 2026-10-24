// tools/viewer shows the frames of a host in shared mode: run `host --shared <name>`, then `viewer <name>`. It stands in
// for the editor's viewport (docs/editor.md#viewport) and does what the editor will: open the shared textures and fence
// by name, and copy the newest frame into its own swapchain.
package viewer

import "core:fmt"
import "core:log"
import "core:os"
import win "core:sys/windows"
import "core:time"

import d3d "vendor:directx/d3d12"
import "vendor:directx/dxgi"

DEFAULT_NAME :: "cinnabar"
// Matches SHARED_TEXTURE_COUNT in lib/core/gpu/d3d12/shared.odin.
TEXTURE_COUNT :: 3
BACK_BUFFER_COUNT :: 2

state: struct {
	hwnd:          win.HWND,
	closed:        bool,
	factory:       ^dxgi.IFactory6,
	device:        ^d3d.IDevice,
	queue:         ^d3d.ICommandQueue,
	allocator:     ^d3d.ICommandAllocator,
	list:          ^d3d.IGraphicsCommandList,
	swapchain:     ^dxgi.ISwapChain3,
	back_buffers:  [BACK_BUFFER_COUNT]^d3d.IResource,
	// The viewer's own fence, which it waits on after each frame.
	fence:         ^d3d.IFence,
	fence_value:   u64,
	event:         win.HANDLE,
	// The host's fence and textures. Fence value v means texture v % TEXTURE_COUNT holds frame v.
	shared_fence:  ^d3d.IFence,
	textures:      [TEXTURE_COUNT]^d3d.IResource,
	size:          [2]u32,
}

main :: proc() {
	context.logger = log.create_console_logger()
	name := len(os.args) > 1 ? os.args[1] : DEFAULT_NAME
	if !open_shared(name) {
		log.errorf("viewer: cannot open the shared frame %q. Start the host with --shared %s first.", name, name)
		os.exit(1)
	}
	if !open_window(fmt.tprintf("cinnabar viewer | %s", name)) || !create_swapchain() {
		os.exit(1)
	}
	log.infof("viewer: showing %s, %dx%d", name, state.size.x, state.size.y)

	shown: u64
	for !state.closed {
		msg: win.MSG
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}
		// The host signals a frame's number when the frame's work is done, so its texture is ready to read.
		latest := state.shared_fence->GetCompletedValue()
		if latest == shown {
			time.sleep(time.Millisecond)
			continue
		}
		show_frame(latest)
		shown = latest
	}
	cleanup()
}

// open_shared finds the adapter that the host uses: shared objects open only on the device that created them.
open_shared :: proc(name: string) -> bool {
	if win.FAILED(dxgi.CreateDXGIFactory2({}, dxgi.IFactory6_UUID, (^rawptr)(&state.factory))) {
		return false
	}
	for i: u32 = 0;; i += 1 {
		adapter: ^dxgi.IAdapter1
		if win.FAILED(state.factory->EnumAdapterByGpuPreference(i, .HIGH_PERFORMANCE, dxgi.IAdapter1_UUID, (^rawptr)(&adapter))) {
			return false
		}
		defer adapter->Release()
		device: ^d3d.IDevice
		if win.FAILED(d3d.CreateDevice((^dxgi.IUnknown)(adapter), ._12_0, d3d.IDevice_UUID, (^rawptr)(&device))) {
			continue
		}
		state.device = device
		if open_object(fmt.tprintf("%s.fence", name), d3d.IFence_UUID, (^rawptr)(&state.shared_fence)) {
			ok := true
			for &texture, t in state.textures {
				ok &&= open_object(fmt.tprintf("%s.texture%d", name, t), d3d.IResource_UUID, (^rawptr)(&texture))
			}
			if ok {
				desc: d3d.RESOURCE_DESC
				state.textures[0]->GetDesc(&desc)
				state.size = {u32(desc.Width), desc.Height}
				return true
			}
		}
		release_shared()
		device->Release()
		state.device = nil
	}
}

open_object :: proc(name: string, iid: ^d3d.IID, object: ^rawptr) -> bool {
	handle: win.HANDLE
	if win.FAILED(state.device->OpenSharedHandleByName(win.utf8_to_wstring(name), win.GENERIC_ALL, &handle)) {
		return false
	}
	defer win.CloseHandle(handle)
	return win.SUCCEEDED(state.device->OpenSharedHandle(handle, iid, object))
}

open_window :: proc(title: string) -> bool {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		lpfnWndProc   = window_proc,
		hInstance     = instance,
		hCursor       = win.LoadCursorW(nil, transmute(win.LPCWSTR)win.IDC_ARROW),
		lpszClassName = win.L("cinnabar_viewer"),
	}
	if win.RegisterClassExW(&class) == 0 {
		return false
	}
	// The window has the shared textures' size, and does not resize.
	style := win.WS_OVERLAPPED | win.WS_CAPTION | win.WS_SYSMENU | win.WS_MINIMIZEBOX | win.WS_VISIBLE
	rect := win.RECT{0, 0, i32(state.size.x), i32(state.size.y)}
	win.AdjustWindowRect(&rect, style, false)
	state.hwnd = win.CreateWindowExW(
		0,
		win.L("cinnabar_viewer"),
		win.utf8_to_wstring(title),
		style,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		rect.right - rect.left,
		rect.bottom - rect.top,
		nil,
		nil,
		instance,
		nil,
	)
	return state.hwnd != nil
}

window_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	if msg == win.WM_CLOSE {
		state.closed = true
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

create_swapchain :: proc() -> bool {
	queue_desc := d3d.COMMAND_QUEUE_DESC {
		Type = .DIRECT,
	}
	if win.FAILED(state.device->CreateCommandQueue(&queue_desc, d3d.ICommandQueue_UUID, (^rawptr)(&state.queue))) {
		return false
	}
	desc := dxgi.SWAP_CHAIN_DESC1 {
		Width       = state.size.x,
		Height      = state.size.y,
		Format      = .R8G8B8A8_UNORM,
		SampleDesc  = {Count = 1},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = BACK_BUFFER_COUNT,
		SwapEffect  = .FLIP_DISCARD,
	}
	swapchain1: ^dxgi.ISwapChain1
	if win.FAILED(state.factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(state.queue), state.hwnd, &desc, nil, nil, &swapchain1)) {
		return false
	}
	defer swapchain1->Release()
	if win.FAILED(swapchain1->QueryInterface(dxgi.ISwapChain3_UUID, (^rawptr)(&state.swapchain))) {
		return false
	}
	for &buffer, i in state.back_buffers {
		state.swapchain->GetBuffer(u32(i), d3d.IResource_UUID, (^rawptr)(&buffer))
	}
	state.device->CreateCommandAllocator(.DIRECT, d3d.ICommandAllocator_UUID, (^rawptr)(&state.allocator))
	state.device->CreateCommandList(0, .DIRECT, state.allocator, nil, d3d.IGraphicsCommandList_UUID, (^rawptr)(&state.list))
	state.list->Close()
	state.device->CreateFence(0, {}, d3d.IFence_UUID, (^rawptr)(&state.fence))
	state.event = win.CreateEventW(nil, false, false, nil)
	return state.list != nil && state.fence != nil
}

// show_frame copies frame v into the back buffer and presents it. The shared texture is in the common layout, from
// which a copy source is promoted implicitly.
show_frame :: proc(v: u64) {
	back := state.back_buffers[state.swapchain->GetCurrentBackBufferIndex()]
	state.allocator->Reset()
	state.list->Reset(state.allocator, nil)
	transition(back, {}, {.COPY_DEST})
	state.list->CopyResource(back, state.textures[v % TEXTURE_COUNT])
	transition(back, {.COPY_DEST}, {})
	state.list->Close()
	lists := [?]^d3d.ICommandList{(^d3d.ICommandList)(state.list)}
	state.queue->ExecuteCommandLists(len(lists), &lists[0])
	state.swapchain->Present(1, {})

	// A viewer has no need to overlap frames, so it waits for each one.
	state.fence_value += 1
	state.queue->Signal(state.fence, state.fence_value)
	state.fence->SetEventOnCompletion(state.fence_value, state.event)
	win.WaitForSingleObject(state.event, win.INFINITE)
}

transition :: proc(resource: ^d3d.IResource, before, after: d3d.RESOURCE_STATES) {
	barrier := d3d.RESOURCE_BARRIER {
		Type = .TRANSITION,
	}
	barrier.Transition = {
		pResource   = resource,
		Subresource = d3d.RESOURCE_BARRIER_ALL_SUBRESOURCES,
		StateBefore = before,
		StateAfter  = after,
	}
	state.list->ResourceBarrier(1, &barrier)
}

release_shared :: proc() {
	for &texture in state.textures {
		if texture != nil {
			texture->Release()
			texture = nil
		}
	}
	if state.shared_fence != nil {
		state.shared_fence->Release()
		state.shared_fence = nil
	}
}

cleanup :: proc() {
	if state.fence != nil {
		state.fence->Release()
	}
	if state.event != nil {
		win.CloseHandle(state.event)
	}
	for buffer in state.back_buffers {
		if buffer != nil {
			buffer->Release()
		}
	}
	state.list->Release()
	state.allocator->Release()
	state.swapchain->Release()
	state.queue->Release()
	release_shared()
	state.device->Release()
	state.factory->Release()
	win.DestroyWindow(state.hwnd)
}
