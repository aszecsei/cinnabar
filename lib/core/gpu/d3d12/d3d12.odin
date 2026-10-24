// Package gpu_d3d12 is the D3D12 GPU backend. It is the only package that imports vendor:directx.
package gpu_d3d12

import "base:runtime"
import "core:log"
import win "core:sys/windows"
import "core:time"

import d3d "vendor:directx/d3d12"
import "vendor:directx/dxgi"

import "cinnabar:core/gpu"

FRAMES_IN_FLIGHT :: 2
BACK_BUFFER_COUNT :: 3
BACK_BUFFER_FORMAT :: dxgi.FORMAT.R8G8B8A8_UNORM
SWAP_CHAIN_FLAGS :: dxgi.SWAP_CHAIN{.FRAME_LATENCY_WAITABLE_OBJECT}

// While the window is minimized, nothing is presented, so this paces the frame instead of vsync.
MINIMIZED_FRAME_TIME :: time.Second / 60

// The D3D12 runtime reads these exports from the executable and loads the Agility SDK runtime from the path,
// relative to the executable. Enhanced Barriers need it on Windows versions whose built-in runtime is older.
// The version must match agility_version in the justfile.
AGILITY_SDK_VERSION :: 619

@(export, link_name = "D3D12SDKVersion")
agility_sdk_version: u32 = AGILITY_SDK_VERSION

@(export, link_name = "D3D12SDKPath")
agility_sdk_path: cstring = `.\D3D12\`

// BeginEvent metadata for a null-terminated ANSI string, as PIX reads it.
PIX_EVENT_ANSI_VERSION :: 1

@(private)
Frame :: struct {
	allocator:   ^d3d.ICommandAllocator,
	fence_value: u64,
	upload:      Upload_Ring,
}

@(private)
dev: struct {
	logger:            runtime.Logger,
	// Backend-owned memory uses the host's allocator, not the allocator of whichever caller arrives first.
	allocator:         runtime.Allocator,
	factory:           ^dxgi.IFactory6,
	adapter:           ^dxgi.IAdapter1,
	device:            ^d3d.IDevice10,
	info_queue:        ^d3d.IInfoQueue1,
	callback_cookie:   u32,
	features:          gpu.Features,
	queue:             ^d3d.ICommandQueue,
	fence:             ^d3d.IFence,
	fence_event:       win.HANDLE,
	fence_value:       u64,
	frames:            [FRAMES_IN_FLIGHT]Frame,
	frame_index:       u64,
	list:              ^d3d.IGraphicsCommandList7,
	swapchain:         ^dxgi.ISwapChain3,
	latency_waitable:  win.HANDLE,
	size:              [2]i32,
	back_buffers:      [BACK_BUFFER_COUNT]^d3d.IResource,
	back_buffer_index: u32,
	frame_target:      gpu.Texture,
	// False while the window is minimized: submissions are dropped and nothing is presented.
	recording:         bool,
	using resources:   Resources,
	using pipelines:   Pipelines,
	using uploads:     Uploads,
}

init :: proc(window: rawptr, size: [2]i32) -> bool {
	dev.logger = context.logger
	dev.allocator = context.allocator
	when ODIN_DEBUG {
		enable_debug_layer()
	}

	factory_flags: dxgi.CREATE_FACTORY
	when ODIN_DEBUG {
		factory_flags = {.DEBUG}
	}
	if win.FAILED(dxgi.CreateDXGIFactory2(factory_flags, dxgi.IFactory6_UUID, (^rawptr)(&dev.factory))) {
		// The DXGI debug layer is missing unless Graphics Tools are installed.
		if !check(dxgi.CreateDXGIFactory2({}, dxgi.IFactory6_UUID, (^rawptr)(&dev.factory)), "CreateDXGIFactory2") {
			return false
		}
	}
	if !create_device() {
		return false
	}
	when ODIN_DEBUG {
		register_debug_callback()
	}

	queue_desc := d3d.COMMAND_QUEUE_DESC {
		Type = .DIRECT,
	}
	check(dev.device->CreateCommandQueue(&queue_desc, d3d.ICommandQueue_UUID, (^rawptr)(&dev.queue)), "CreateCommandQueue") or_return
	check(dev.device->CreateFence(0, {}, d3d.IFence_UUID, (^rawptr)(&dev.fence)), "CreateFence") or_return
	dev.fence_event = win.CreateEventW(nil, false, false, nil)
	for &frame in dev.frames {
		check(dev.device->CreateCommandAllocator(.DIRECT, d3d.ICommandAllocator_UUID, (^rawptr)(&frame.allocator)), "CreateCommandAllocator") or_return
	}
	dev.list = create_command_list(dev.frames[0].allocator) or_return

	init_resources() or_return
	init_pipelines() or_return
	init_uploads() or_return
	for &frame in dev.frames {
		init_upload_ring(&frame.upload) or_return
	}
	return create_swapchain(win.HWND(window), size)
}

shutdown :: proc() {
	if dev.queue != nil {
		wait_idle()
	}
	release_back_buffers()
	if dev.latency_waitable != nil {
		win.CloseHandle(dev.latency_waitable)
	}
	release(&dev.swapchain)
	shutdown_uploads()
	shutdown_pipelines()
	shutdown_resources()
	release(&dev.list)
	for &frame in dev.frames {
		release(&frame.allocator)
	}
	if dev.fence_event != nil {
		win.CloseHandle(dev.fence_event)
	}
	release(&dev.fence)
	release(&dev.queue)
	if dev.info_queue != nil {
		dev.info_queue->UnregisterMessageCallback(dev.callback_cookie)
	}
	release(&dev.info_queue)
	release(&dev.device)
	release(&dev.adapter)
	release(&dev.factory)
	dev = {}

	when ODIN_DEBUG {
		// The report goes to the debugger output.
		debug: ^dxgi.IDebug
		if win.SUCCEEDED(dxgi.GetDebugInterface1(0, dxgi.IDebug_UUID, (^rawptr)(&debug))) {
			debug->ReportLiveObjects(dxgi.DEBUG_ALL, dxgi.DEBUG_RLO_FLAGS(u32(dxgi.DEBUG_RLO_FLAGS.DETAIL) | u32(dxgi.DEBUG_RLO_FLAGS.IGNORE_INTERNAL)))
			debug->Release()
		}
	}
}

features :: proc() -> gpu.Features {
	return dev.features
}

frame_target :: proc() -> gpu.Texture {
	return dev.frame_target
}

// begin_frame waits until the swapchain and the frame's command allocator and upload ring are free,
// then opens the frame's command list.
begin_frame :: proc(size: [2]i32) {
	frame := &dev.frames[dev.frame_index % FRAMES_IN_FLIGHT]
	wait_fence(frame.fence_value)
	reset_upload_ring(&frame.upload)
	collect_releases()

	dev.recording = size.x > 0 && size.y > 0
	if !dev.recording {
		time.sleep(MINIMIZED_FRAME_TIME)
		return
	}
	if size != dev.size {
		resize(size)
	}

	win.WaitForSingleObjectEx(dev.latency_waitable, 1000, true)
	check(frame.allocator->Reset(), "ICommandAllocator.Reset")
	check(dev.list->Reset(frame.allocator, nil), "ICommandList.Reset")
	bind_root_signature(dev.list)

	dev.back_buffer_index = dev.swapchain->GetCurrentBackBufferIndex()
	target := gpu.pool_get(&dev.textures, dev.frame_target)
	target.resource = dev.back_buffers[dev.back_buffer_index]
	target.rtv = rtv_handle(gpu.MAX_TEXTURES + dev.back_buffer_index)
	texture_barrier(dev.list, target.resource, {.NO_ACCESS}, {.RENDER_TARGET}, {}, {.RENDER_TARGET}, .UNDEFINED, .RENDER_TARGET)
	when ODIN_DEBUG {
		gpu.track_layout(&dev.layouts, dev.frame_target, .Render_Target)
	}
}

// submit translates the command buffers into the frame's command list.
// Debug builds validate them first, and drop all of them if any breaks a rule.
submit :: proc(buffers: []gpu.Command_Buffer) -> bool {
	when ODIN_DEBUG {
		for cb, i in buffers {
			if err, packet := gpu.validate(cb, VALIDATION_RESOURCES, &dev.layouts); err != .None {
				log.errorf("gpu: command buffer %d, packet %d: %v", i, packet, err)
				return false
			}
		}
	}
	if !dev.recording {
		return true
	}
	for cb in buffers {
		translate(dev.list, cb)
	}
	return true
}

// end_frame executes the frame's uploads and command list, then presents with vsync.
end_frame :: proc() {
	flush_uploads()
	if !dev.recording {
		// Resources destroyed this frame were last used by work that has already been signaled.
		stamp_releases(dev.fence_value)
		return
	}
	when ODIN_DEBUG {
		if layout, _ := gpu.tracked_layout(&dev.layouts, dev.frame_target); layout != .Render_Target {
			log.errorf("gpu: the frame target ends the frame in the %v layout", layout)
		}
	}
	target := gpu.pool_get(&dev.textures, dev.frame_target)
	texture_barrier(dev.list, target.resource, {.RENDER_TARGET}, {.NO_ACCESS}, {.RENDER_TARGET}, {}, .RENDER_TARGET, .PRESENT)
	check(dev.list->Close(), "ICommandList.Close")
	lists := [?]^d3d.ICommandList{dev.list}
	dev.queue->ExecuteCommandLists(len(lists), &lists[0])

	hr := dev.swapchain->Present(1, {})
	if hr == dxgi.ERROR_DEVICE_REMOVED || hr == dxgi.ERROR_DEVICE_RESET {
		log.panicf("d3d12: device removed: 0x%8x", u32(dev.device->GetDeviceRemovedReason()))
	}
	check(hr, "Present")

	signal()
	dev.frames[dev.frame_index % FRAMES_IN_FLIGHT].fence_value = dev.fence_value
	stamp_releases(dev.fence_value)
	dev.frame_index += 1
}

@(private)
create_command_list :: proc(allocator: ^d3d.ICommandAllocator) -> (list: ^d3d.IGraphicsCommandList7, ok: bool) {
	check(dev.device->CreateCommandList(0, .DIRECT, allocator, nil, d3d.IGraphicsCommandList7_UUID, (^rawptr)(&list)), "CreateCommandList") or_return
	check(list->Close(), "Close") or_return
	return list, true
}

@(private = "file")
create_device :: proc() -> bool {
	for i: u32 = 0;; i += 1 {
		adapter: ^dxgi.IAdapter1
		if win.FAILED(dev.factory->EnumAdapterByGpuPreference(i, .HIGH_PERFORMANCE, dxgi.IAdapter1_UUID, (^rawptr)(&adapter))) {
			break
		}
		desc: dxgi.ADAPTER_DESC1
		adapter->GetDesc1(&desc)
		name, _ := win.wstring_to_utf8(cstring16(&desc.Description[0]), -1, context.temp_allocator)
		if .SOFTWARE in desc.Flags {
			adapter->Release()
			continue
		}

		// IDevice10 needs the Agility SDK runtime on older Windows versions, like Enhanced Barriers.
		device: ^d3d.IDevice10
		if win.FAILED(d3d.CreateDevice((^d3d.IUnknown)(adapter), ._12_0, d3d.IDevice10_UUID, (^rawptr)(&device))) {
			adapter->Release()
			continue
		}
		if missing := missing_floor_feature(device); missing != "" {
			log.infof("d3d12: skipping %s: no %s", name, missing)
			device->Release()
			adapter->Release()
			continue
		}

		dev.adapter = adapter
		dev.device = device
		dev.features = query_features(device)
		log.infof("d3d12: using %s, optional features %v", name, dev.features)
		return true
	}
	log.error("d3d12: no adapter supports Shader Model 6.6, resource binding tier 3 and Enhanced Barriers")
	return false
}

// missing_floor_feature checks the hardware floor in docs/gpu.md#hardware-floor.
@(private = "file")
missing_floor_feature :: proc(device: ^d3d.IDevice10) -> string {
	shader_model := d3d.FEATURE_DATA_SHADER_MODEL {
		HighestShaderModel = ._6_6,
	}
	if win.FAILED(device->CheckFeatureSupport(.SHADER_MODEL, &shader_model, size_of(shader_model))) ||
	   shader_model.HighestShaderModel < ._6_6 {
		return "Shader Model 6.6"
	}
	options: d3d.FEATURE_DATA_OPTIONS
	device->CheckFeatureSupport(.OPTIONS, &options, size_of(options))
	if options.ResourceBindingTier < ._3 {
		return "resource binding tier 3"
	}
	options12: d3d.FEATURE_DATA_OPTIONS12
	device->CheckFeatureSupport(.OPTIONS12, &options12, size_of(options12))
	if !options12.EnhancedBarriersSupported {
		return "Enhanced Barriers"
	}
	return ""
}

@(private = "file")
query_features :: proc(device: ^d3d.IDevice10) -> (features: gpu.Features) {
	options5: d3d.FEATURE_DATA_OPTIONS5
	if win.SUCCEEDED(device->CheckFeatureSupport(.OPTIONS5, &options5, size_of(options5))) {
		if options5.RaytracingTier >= ._1_0 {
			features += {.Ray_Tracing_Pipeline}
		}
		if options5.RaytracingTier >= ._1_1 {
			features += {.Ray_Query}
		}
	}
	options7: d3d.FEATURE_DATA_OPTIONS7
	if win.SUCCEEDED(device->CheckFeatureSupport(.OPTIONS7, &options7, size_of(options7))) && options7.MeshShaderTier >= ._1 {
		features += {.Mesh_Shaders}
	}
	return
}

@(private = "file")
create_swapchain :: proc(hwnd: win.HWND, size: [2]i32) -> bool {
	desc := dxgi.SWAP_CHAIN_DESC1 {
		Width = u32(max(size.x, 1)),
		Height = u32(max(size.y, 1)),
		Format = BACK_BUFFER_FORMAT,
		SampleDesc = {Count = 1},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = BACK_BUFFER_COUNT,
		Scaling = .NONE,
		SwapEffect = .FLIP_DISCARD,
		Flags = SWAP_CHAIN_FLAGS,
	}
	swapchain1: ^dxgi.ISwapChain1
	check(dev.factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(dev.queue), hwnd, &desc, nil, nil, &swapchain1), "CreateSwapChainForHwnd") or_return
	defer swapchain1->Release()
	check(swapchain1->QueryInterface(dxgi.ISwapChain3_UUID, (^rawptr)(&dev.swapchain)), "QueryInterface(ISwapChain3)") or_return
	dev.factory->MakeWindowAssociation(hwnd, {.NO_ALT_ENTER})

	check(dev.swapchain->SetMaximumFrameLatency(FRAMES_IN_FLIGHT), "SetMaximumFrameLatency") or_return
	dev.latency_waitable = dev.swapchain->GetFrameLatencyWaitableObject()

	dev.size = {i32(desc.Width), i32(desc.Height)}
	// The frame target's resource and view change every frame to the current back buffer.
	dev.frame_target = gpu.pool_add(
		&dev.textures,
		Texture_Entry{desc = {size = {desc.Width, desc.Height}, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}}},
	)
	return create_back_buffers()
}

@(private = "file")
create_back_buffers :: proc() -> bool {
	view := d3d.RENDER_TARGET_VIEW_DESC {
		Format        = view_format(gpu.FRAME_TARGET_FORMAT),
		ViewDimension = .TEXTURE2D,
	}
	for &buffer, i in dev.back_buffers {
		check(dev.swapchain->GetBuffer(u32(i), d3d.IResource_UUID, (^rawptr)(&buffer)), "GetBuffer") or_return
		buffer->SetName(win.L("frame target"))
		dev.device->CreateRenderTargetView(buffer, &view, rtv_handle(gpu.MAX_TEXTURES + u32(i)))
	}
	return true
}

@(private = "file")
release_back_buffers :: proc() {
	for &buffer in dev.back_buffers {
		release(&buffer)
	}
}

@(private = "file")
resize :: proc(size: [2]i32) {
	wait_idle()
	release_back_buffers()
	if !check(dev.swapchain->ResizeBuffers(0, u32(size.x), u32(size.y), .UNKNOWN, SWAP_CHAIN_FLAGS), "ResizeBuffers") {
		log.panic("d3d12: cannot resize the swapchain")
	}
	create_back_buffers()
	dev.size = size
	gpu.pool_get(&dev.textures, dev.frame_target).desc.size = {u32(size.x), u32(size.y)}
}

@(private)
texture_barrier :: proc(
	list: ^d3d.IGraphicsCommandList7,
	resource: ^d3d.IResource,
	access_before, access_after: d3d.BARRIER_ACCESS_FLAGS,
	sync_before, sync_after: d3d.BARRIER_SYNC_FLAGS,
	layout_before, layout_after: d3d.BARRIER_LAYOUT,
) {
	barrier := d3d.TEXTURE_BARRIER {
		SyncBefore = sync_before,
		SyncAfter = sync_after,
		AccessBefore = access_before,
		AccessAfter = access_after,
		LayoutBefore = layout_before,
		LayoutAfter = layout_after,
		pResource = resource,
		// 0xffffffff selects all subresources.
		Subresources = {IndexOrFirstMipLevel = 0xffffffff},
	}
	group := d3d.BARRIER_GROUP {
		Type             = .TEXTURE,
		NumBarriers      = 1,
		pTextureBarriers = &barrier,
	}
	list->Barrier(1, &group)
}

// signal advances the queue's fence after the work submitted so far.
@(private)
signal :: proc() {
	dev.fence_value += 1
	check(dev.queue->Signal(dev.fence, dev.fence_value), "ICommandQueue.Signal")
}

@(private)
wait_fence :: proc(value: u64) {
	if dev.fence->GetCompletedValue() < value {
		check(dev.fence->SetEventOnCompletion(value, dev.fence_event), "SetEventOnCompletion")
		win.WaitForSingleObject(dev.fence_event, win.INFINITE)
	}
}

@(private)
wait_idle :: proc() {
	signal()
	wait_fence(dev.fence_value)
}

@(private = "file")
enable_debug_layer :: proc() {
	debug: ^d3d.IDebug1
	if win.FAILED(d3d.GetDebugInterface(d3d.IDebug1_UUID, (^rawptr)(&debug))) {
		log.warn("d3d12: the debug layer is unavailable. Install the Graphics Tools optional feature.")
		return
	}
	debug->EnableDebugLayer()
	debug->Release()

	dred: ^d3d.IDeviceRemovedExtendedDataSettings
	if win.SUCCEEDED(d3d.GetDebugInterface(d3d.IDeviceRemovedExtendedDataSettings_UUID, (^rawptr)(&dred))) {
		dred->SetAutoBreadcrumbsEnablement(.FORCED_ON)
		dred->SetPageFaultEnablement(.FORCED_ON)
		dred->Release()
	}
}

// register_debug_callback sends debug layer messages to the log.
@(private = "file")
register_debug_callback :: proc() {
	if win.FAILED(dev.device->QueryInterface(d3d.IInfoQueue1_UUID, (^rawptr)(&dev.info_queue))) {
		return
	}
	dev.info_queue->RegisterMessageCallback(on_debug_message, {}, nil, &dev.callback_cookie)
}

@(private = "file")
on_debug_message :: proc "c" (
	category: d3d.MESSAGE_CATEGORY,
	severity: d3d.MESSAGE_SEVERITY,
	id: d3d.MESSAGE_ID,
	description: cstring,
	ctx: rawptr,
) {
	context = runtime.default_context()
	context.logger = dev.logger
	switch severity {
	case .CORRUPTION, .ERROR:
		log.errorf("d3d12: %v: %s", id, description)
	case .WARNING:
		log.warnf("d3d12: %v: %s", id, description)
	case .INFO, .MESSAGE:
		log.debugf("d3d12: %s", description)
	}
}

@(private)
check :: proc(hr: win.HRESULT, what: string) -> bool {
	if win.FAILED(hr) {
		log.errorf("d3d12: %s failed: 0x%8x", what, u32(hr))
		return false
	}
	return true
}

@(private)
release :: proc(object: ^^$T) {
	if object^ != nil {
		object^->Release()
		object^ = nil
	}
}

// set_name gives a D3D12 object a debug name for the debug layer and PIX.
@(private)
set_name :: proc(object: ^d3d.IObject, label: string) {
	if label == "" {
		return
	}
	buf: [256]u16
	object->SetName(win.utf8_to_wstring(buf[:], label))
}
