// Package gpu_d3d12 is the D3D12 GPU backend. It is the only package that imports vendor:directx.
package gpu_d3d12

import "base:runtime"
import "core:log"
import "core:sync"
import win "core:sys/windows"
import "core:time"

import d3d "vendor:directx/d3d12"
import "vendor:directx/dxgi"

import "cinnabar:core/gpu"
import "cinnabar:core/jobs"

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

// Command lists are pooled per frame, not per thread: a translation job takes a list from the pool, and
// its fiber can move between threads.
@(private)
Command_List :: struct {
	allocator: ^d3d.ICommandAllocator,
	list:      ^d3d.IGraphicsCommandList7,
}

@(private)
Frame :: struct {
	// The graphics fence value of the frame's end. The graphics queue waits for the compute queue before it, so
	// the frame's work on both queues is done when it passes.
	fence_value: u64,
	upload:      Upload_Ring,
	scratch:     Scratch_Pool,
	lists:       [gpu.Queue][dynamic]Command_List,
	lists_used:  [gpu.Queue]int,
	// The frame's submissions in order, and their closed command lists.
	ops:         [dynamic]Op,
	op_lists:    [dynamic]^d3d.ICommandList,
	// end_frame batches each queue's lists here until it must execute them.
	pending:     [gpu.Queue][dynamic]^d3d.ICommandList,
}

// Op is one submission: op_lists[first:][:count] on a queue, after the earlier submissions of the wait_for queues.
@(private)
Op :: struct {
	queue:    gpu.Queue,
	wait_for: gpu.Queues,
	first:    int,
	count:    int,
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
	// The graphics queue and its fence. Frame ends, uploads and deferred releases use this fence.
	queue:             ^d3d.ICommandQueue,
	fence:             ^d3d.IFence,
	fence_event:       win.HANDLE,
	fence_value:       u64,
	compute_queue:     ^d3d.ICommandQueue,
	compute_fence:     ^d3d.IFence,
	compute_value:     u64,
	frames:            [FRAMES_IN_FLIGHT]Frame,
	frame_index:       u64,
	// Guards the current frame's lists, ops and op_lists.
	lists_mutex:       sync.Mutex,
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
	compute_desc := d3d.COMMAND_QUEUE_DESC {
		Type = .COMPUTE,
	}
	check(dev.device->CreateCommandQueue(&compute_desc, d3d.ICommandQueue_UUID, (^rawptr)(&dev.compute_queue)), "CreateCommandQueue(compute)") or_return
	check(dev.device->CreateFence(0, {}, d3d.IFence_UUID, (^rawptr)(&dev.compute_fence)), "CreateFence(compute)") or_return
	dev.queue->SetName(win.L("graphics"))
	dev.compute_queue->SetName(win.L("compute"))
	dev.fence_event = win.CreateEventW(nil, false, false, nil)
	for &frame in dev.frames {
		for &lists in frame.lists {
			lists = make([dynamic]Command_List, dev.allocator)
		}
		frame.ops = make([dynamic]Op, dev.allocator)
		frame.op_lists = make([dynamic]^d3d.ICommandList, dev.allocator)
		for &pending in frame.pending {
			pending = make([dynamic]^d3d.ICommandList, dev.allocator)
		}
	}

	init_resources() or_return
	init_pipelines() or_return
	init_uploads() or_return
	for &frame in dev.frames {
		init_upload_ring(&frame.upload) or_return
	}
	return create_swapchain(win.HWND(window), size)
}

shutdown :: proc() {
	wait_compiles()
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
	for &frame in dev.frames {
		for lists in frame.lists {
			for &l in lists {
				release(&l.list)
				release(&l.allocator)
			}
			delete(lists)
		}
		delete(frame.ops)
		delete(frame.op_lists)
		destroy_scratch_pool(&frame.scratch)
		for pending in frame.pending {
			delete(pending)
		}
	}
	if dev.fence_event != nil {
		win.CloseHandle(dev.fence_event)
	}
	release(&dev.compute_fence)
	release(&dev.compute_queue)
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

// begin_frame waits until the swapchain and the frame's command lists and upload ring are free,
// then records the frame target's transition into the render target layout.
begin_frame :: proc(size: [2]i32) {
	frame := &dev.frames[dev.frame_index % FRAMES_IN_FLIGHT]
	wait_fence(frame.fence_value)
	reset_upload_ring(&frame.upload)
	reset_scratch_pool(&frame.scratch)
	collect_releases()

	dev.recording = size.x > 0 && size.y > 0
	if !dev.recording {
		time.sleep(MINIMIZED_FRAME_TIME)
		return
	}
	if size != dev.size {
		resize_swapchain(size)
	}

	win.WaitForSingleObjectEx(dev.latency_waitable, 1000, true)
	frame.lists_used = {}
	clear(&frame.ops)
	clear(&frame.op_lists)

	dev.back_buffer_index = dev.swapchain->GetCurrentBackBufferIndex()
	target := gpu.pool_get(&dev.textures, dev.frame_target)
	target.resource = dev.back_buffers[dev.back_buffer_index]
	target.rtv = rtv_handle(gpu.MAX_TEXTURES + dev.back_buffer_index)
	list := acquire_list(frame, .Graphics)
	texture_barrier(list, target.resource, {.NO_ACCESS}, {.RENDER_TARGET}, {}, {.RENDER_TARGET}, .UNDEFINED, .RENDER_TARGET)
	check(list->Close(), "ICommandList.Close")
	append(&frame.ops, Op{queue = .Graphics, first = len(frame.op_lists), count = 1})
	append(&frame.op_lists, (^d3d.ICommandList)(list))
	when ODIN_DEBUG {
		gpu.track_layout(&dev.layouts, dev.frame_target, .Render_Target)
	}
}

// submit translates each command buffer into its own command list on a job, and adds them to the frame as one
// submission on the queue. end_frame executes the submissions in order. Debug builds validate the buffers first,
// and drop all of them if any breaks a rule. Call it from the game's frame code or from a job: it waits for the
// translation jobs.
submit :: proc(buffers: []gpu.Command_Buffer, queue := gpu.Queue.Graphics, wait_for := gpu.Queues{}) -> bool {
	when ODIN_DEBUG {
		if err, buffer, packet := gpu.validate_submission(buffers, VALIDATION_RESOURCES, &dev.layouts, queue); err != .None {
			log.errorf("gpu: command buffer %d, packet %d: %v", buffer, packet, err)
			return false
		}
	}
	if !dev.recording || len(buffers) == 0 {
		return true
	}

	frame := &dev.frames[dev.frame_index % FRAMES_IN_FLIGHT]
	tasks := make([]Translate_Task, len(buffers), dev.allocator)
	defer delete(tasks, dev.allocator)
	translate_jobs := make([]jobs.Job, len(buffers), dev.allocator)
	defer delete(translate_jobs, dev.allocator)
	for cb, i in buffers {
		tasks[i] = {frame = frame, queue = queue, cb = cb}
		translate_jobs[i] = {translate_job, &tasks[i]}
	}
	// Reserving the submission first keeps the order when several jobs submit at once.
	sync.lock(&dev.lists_mutex)
	first := len(frame.op_lists)
	resize(&frame.op_lists, first + len(buffers))
	append(&frame.ops, Op{queue, wait_for - {queue}, first, len(buffers)})
	sync.unlock(&dev.lists_mutex)

	counter: jobs.Counter
	jobs.run(translate_jobs, &counter)
	jobs.wait(&counter)

	sync.guard(&dev.lists_mutex)
	for task, i in tasks {
		frame.op_lists[first + i] = (^d3d.ICommandList)(task.list)
	}
	return true
}

@(private = "file")
Translate_Task :: struct {
	frame: ^Frame,
	queue: gpu.Queue,
	cb:    gpu.Command_Buffer,
	list:  ^d3d.IGraphicsCommandList7,
}

@(private = "file")
translate_job :: proc(data: rawptr) {
	task := (^Translate_Task)(data)
	task.list = acquire_list(task.frame, task.queue)
	translate(task.list, task.cb)
	check(task.list->Close(), "ICommandList.Close")
}

// acquire_list takes an open command list from the frame's pool, with the descriptor heaps and root signature
// bound. The frame's fence has passed, so its lists are free to reset.
@(private = "file")
acquire_list :: proc(frame: ^Frame, queue: gpu.Queue) -> ^d3d.IGraphicsCommandList7 {
	sync.lock(&dev.lists_mutex)
	lists := &frame.lists[queue]
	if frame.lists_used[queue] == len(lists) {
		type := LIST_TYPE[queue]
		entry: Command_List
		if !check(dev.device->CreateCommandAllocator(type, d3d.ICommandAllocator_UUID, (^rawptr)(&entry.allocator)), "CreateCommandAllocator") {
			log.panic("d3d12: cannot create a command allocator")
		}
		list, ok := create_command_list(entry.allocator, type)
		if !ok {
			log.panic("d3d12: cannot create a command list")
		}
		entry.list = list
		append(lists, entry)
	}
	entry := lists[frame.lists_used[queue]]
	frame.lists_used[queue] += 1
	sync.unlock(&dev.lists_mutex)

	check(entry.allocator->Reset(), "ICommandAllocator.Reset")
	check(entry.list->Reset(entry.allocator, nil), "ICommandList.Reset")
	bind_root_signature(entry.list, queue)
	return entry.list
}

@(private = "file")
LIST_TYPE := [gpu.Queue]d3d.COMMAND_LIST_TYPE {
	.Graphics = .DIRECT,
	.Compute  = .COMPUTE,
}

// end_frame executes the frame's uploads and submissions, then presents with vsync.
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
	frame := &dev.frames[dev.frame_index % FRAMES_IN_FLIGHT]
	target := gpu.pool_get(&dev.textures, dev.frame_target)
	list := acquire_list(frame, .Graphics)
	texture_barrier(list, target.resource, {.RENDER_TARGET}, {.NO_ACCESS}, {.RENDER_TARGET}, {}, .RENDER_TARGET, .PRESENT)
	check(list->Close(), "ICommandList.Close")

	// The compute queue starts after the previous frame's end and this frame's uploads, and the graphics queue
	// ends the frame after the compute queue's work. So a frame's work on either queue starts after the previous
	// frame's work on both queues (docs/gpu.md#barriers).
	e := Executor {
		frame = frame,
	}
	e.waits[.Compute][.Graphics] = dev.fence_value
	e.waited[.Graphics][.Compute] = dev.compute_value
	for op in frame.ops {
		for other in op.wait_for {
			wait_for(&e, op.queue, other)
		}
		append(&frame.pending[op.queue], ..frame.op_lists[op.first:][:op.count])
	}
	wait_for(&e, .Graphics, .Compute)
	append(&frame.pending[.Graphics], (^d3d.ICommandList)(list))
	flush(&e, .Graphics)

	hr := dev.swapchain->Present(1, {})
	if hr == dxgi.ERROR_DEVICE_REMOVED || hr == dxgi.ERROR_DEVICE_RESET {
		log.panicf("d3d12: device removed: 0x%8x", u32(dev.device->GetDeviceRemovedReason()))
	}
	check(hr, "Present")

	signal()
	frame.fence_value = dev.fence_value
	stamp_releases(dev.fence_value)
	dev.frame_index += 1
}

// Executor runs a frame's submissions. A queue's lists wait in the frame's pending batch until another queue needs
// them or the frame ends, so lists of consecutive submissions run in one ExecuteCommandLists call. In particular
// the frame target's transitions, which are lists with only a barrier, run with the frame's other graphics lists.
@(private = "file")
Executor :: struct {
	frame:  ^Frame,
	// For each queue, the fence value of each other queue that its pending lists must wait for. 0 is no wait.
	waits:  [gpu.Queue][gpu.Queue]u64,
	// The highest fence value of each other queue that each queue has waited for.
	waited: [gpu.Queue][gpu.Queue]u64,
}

// wait_for makes the queue's pending lists wait for the other queue's work so far. Waiting before lists that came
// earlier only delays them, so it is always safe. The value is taken now, so a wait never covers later work.
@(private = "file")
wait_for :: proc(e: ^Executor, queue, other: gpu.Queue) {
	flush(e, other)
	_, value := fence_of(other)
	if value > e.waited[queue][other] {
		e.waits[queue][other] = max(e.waits[queue][other], value)
	}
}

// flush executes a queue's pending lists after their waits, and signals the queue's fence.
@(private = "file")
flush :: proc(e: ^Executor, queue: gpu.Queue) {
	pending := &e.frame.pending[queue]
	if len(pending) == 0 {
		return
	}
	q := queue_of(queue)
	for other in gpu.Queue {
		if value := e.waits[queue][other]; value > 0 {
			fence, _ := fence_of(other)
			check(q->Wait(fence, value), "ICommandQueue.Wait")
			e.waited[queue][other] = max(e.waited[queue][other], value)
		}
	}
	e.waits[queue] = {}
	q->ExecuteCommandLists(u32(len(pending)), raw_data(pending^))
	signal_queue(queue)
	clear(pending)
}

@(private)
create_command_list :: proc(
	allocator: ^d3d.ICommandAllocator,
	type := d3d.COMMAND_LIST_TYPE.DIRECT,
) -> (
	list: ^d3d.IGraphicsCommandList7,
	ok: bool,
) {
	check(dev.device->CreateCommandList(0, type, allocator, nil, d3d.IGraphicsCommandList7_UUID, (^rawptr)(&list)), "CreateCommandList") or_return
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
		Texture_Entry{desc = {size = {desc.Width, desc.Height}, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, scope = .Permanent}},
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
resize_swapchain :: proc(size: [2]i32) {
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

// signal_queue advances a queue's fence after the work submitted to it so far.
@(private = "file")
signal_queue :: proc(queue: gpu.Queue) {
	switch queue {
	case .Graphics:
		signal()
	case .Compute:
		dev.compute_value += 1
		check(dev.compute_queue->Signal(dev.compute_fence, dev.compute_value), "ICommandQueue.Signal")
	}
}

@(private = "file")
queue_of :: proc(queue: gpu.Queue) -> ^d3d.ICommandQueue {
	return queue == .Graphics ? dev.queue : dev.compute_queue
}

// fence_of returns a queue's fence and the value of its last signal.
@(private = "file")
fence_of :: proc(queue: gpu.Queue) -> (^d3d.IFence, u64) {
	return queue == .Graphics ? dev.fence : dev.compute_fence, queue == .Graphics ? dev.fence_value : dev.compute_value
}

// wait_idle waits for both queues. The graphics queue waits for the compute queue, so its fence covers both.
@(private)
wait_idle :: proc() {
	if dev.compute_queue != nil {
		signal_queue(.Compute)
		check(dev.queue->Wait(dev.compute_fence, dev.compute_value), "ICommandQueue.Wait")
	}
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
