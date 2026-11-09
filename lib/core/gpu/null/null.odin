// Package gpu_null is a GPU backend that validates command buffers and executes nothing.
// It runs headless tests and catches code that only one real backend accepts.
package gpu_null

import "core:log"
import "core:mem"
import "core:sync"
import "core:time"

import "cinnabar:core/gpu"
import "cinnabar:core/profile"

// Stands in for vsync, so a host on this backend does not spin.
FRAME_TIME :: time.Second / 60
UPLOAD_RING_SIZE :: 4 * mem.Megabyte
// The fake GPU time of a packet, which times the timed markers.
PACKET_TIME :: 1000
// A frame's GPU spans reach the profiler this many frames later, as on a real backend.
FRAMES_IN_FLIGHT :: 2

// A frame capture's slots, as on a real backend (see docs/gpu/presentation.md#frame-capture).
CAPTURE_SLOTS :: FRAMES_IN_FLIGHT + 2

// Null_Capture is a capture's slot. A copy is zeroed pixels with rows aligned as D3D12 aligns a copyable footprint,
// ready at the end of its frame.
@(private = "file")
Null_Capture :: struct {
	state:   Null_Capture_State,
	status:  gpu.Capture_Status,
	source:  gpu.Capture_Source,
	ticket:  u32,
	size:    [2]u32,
	format:  gpu.Format,
	mode:    gpu.Output_Mode,
	pixels:  []byte,
}

@(private = "file")
Null_Capture_State :: enum u8 {
	Free,
	// A request took it; end_frame makes the copy or cancels it.
	Requested,
	// end_frame finished it, ready or cancelled; poll_frame_capture gives it out.
	Done,
	// The caller holds it until release_frame_capture.
	Taken,
}

// Null_Frame is a frame's fake GPU spans, until begin_frame gives them to the profiler.
@(private = "file")
Null_Frame :: struct {
	frame:      u64,
	begin, end: u64,
	spans:      [dynamic]profile.Gpu_Span,
}

@(private = "file")
Pipeline_Entry :: struct {
	info:  gpu.Pipeline_Info,
	scope: gpu.Scope,
}

// Accel_Entry keeps the geometry buffers of a bottom-level structure, so validation sees when one is destroyed.
@(private = "file")
Accel_Entry :: struct {
	info:           gpu.Accel_Info,
	scope:          gpu.Scope,
	geometry_count: int,
	geometries:     [gpu.MAX_ACCEL_GEOMETRIES][2]gpu.Buffer,
}

@(private = "file")
state: struct {
	frame_start:   time.Tick,
	frame_target:  gpu.Texture,
	// The null backend has no display, so Auto gives Sdr, but the other requests change the frame target's format.
	request:       gpu.Output_Request,
	output:        gpu.Output,
	buffers:       gpu.Pool(gpu.Buffer, gpu.Buffer_Desc),
	textures:      gpu.Pool(gpu.Texture, gpu.Texture_Desc),
	samplers:      gpu.Pool(gpu.Sampler, gpu.Sampler_Desc),
	pipelines:     gpu.Pool(gpu.Pipeline, Pipeline_Entry),
	accels:        gpu.Pool(gpu.Accel_Struct, Accel_Entry),
	upscalers:     gpu.Pool(gpu.Upscaler, gpu.Upscaler_Desc),
	upload_buffer: gpu.Buffer,
	upload_memory: []byte,
	upload_offset: int,
	upload_peak:   int,
	layouts:       gpu.Layout_Tracker,
	// Textures that have been streamed. Each is streamed once.
	streamed:      map[gpu.Texture]bool,
	// The texture views (see gpu.Texture_View_Desc), which have no layout.
	views:         map[gpu.Texture]bool,
	transfers:     u64,
	// The memory of each Readback buffer. Nothing copies into it, so it stays zero.
	readbacks:     map[gpu.Buffer][]byte,
	// A fake clock for each queue, in nanoseconds from the frame's start, and the frames in flight.
	clock:         [gpu.Queue]u64,
	frames:        [FRAMES_IN_FLIGHT]Null_Frame,
	frame_index:   int,
	timing_mutex:  sync.Mutex,
	// Whether the last begin_frame records, as D3D12's does unless the window is minimized.
	recording:         bool,
	// The slots that this frame's end_frame copies the frame target and a texture into, or -1, and the texture.
	frame_pending:     int,
	texture_pending:   int,
	texture:           gpu.Texture,
	// Whether the next frame copy fails, as D3D12's does when it cannot make its readback buffer, for tests.
	fail_frame_copy:   bool,
	captures:          [CAPTURE_SLOTS]Null_Capture,
}

// The null backend has no shared mode and no adapter: it renders nothing to share.
init :: proc(window: rawptr, size: [2]i32, shared_name := "", adapter: u64 = 0) -> bool {
	state = {
		frame_start     = time.tick_now(),
		output          = {format = gpu.FRAME_TARGET_FORMAT},
		recording       = true,
		frame_pending   = -1,
		texture_pending = -1,
	}
	gpu.pool_init(&state.buffers, gpu.MAX_BUFFERS)
	gpu.pool_init(&state.textures, gpu.MAX_TEXTURES)
	gpu.pool_init(&state.samplers, gpu.MAX_SAMPLERS)
	gpu.pool_init(&state.pipelines, gpu.MAX_PIPELINES)
	gpu.pool_init(&state.accels, gpu.MAX_ACCEL_STRUCTS)
	gpu.pool_init(&state.upscalers, gpu.MAX_UPSCALERS)
	gpu.layout_tracker_init(&state.layouts)
	state.frame_target = gpu.pool_add(&state.textures, frame_target_desc(size))
	gpu.track_layout(&state.layouts, state.frame_target, .Render_Target)
	state.upload_buffer = gpu.pool_add(&state.buffers, gpu.Buffer_Desc{size = UPLOAD_RING_SIZE, scope = .Permanent})
	state.upload_memory = make([]byte, UPLOAD_RING_SIZE)
	return true
}

shutdown :: proc() {
	delete(state.upload_memory)
	gpu.layout_tracker_destroy(&state.layouts)
	delete(state.streamed)
	delete(state.views)
	for _, memory in state.readbacks {
		delete(memory)
	}
	delete(state.readbacks)
	for f in state.frames {
		delete(f.spans)
	}
	for c in state.captures {
		delete(c.pixels)
	}
	gpu.pool_destroy(&state.buffers)
	gpu.pool_destroy(&state.textures)
	gpu.pool_destroy(&state.samplers)
	gpu.pool_destroy(&state.pipelines)
	gpu.pool_destroy(&state.accels)
	gpu.pool_destroy(&state.upscalers)
}

// The null backend validates every optional feature's commands, so it reports all of them.
FEATURES :: gpu.Features{.Mesh_Shaders, .Ray_Query, .Ray_Tracing_Pipeline, .Conservative_Raster}

features :: proc() -> gpu.Features {
	return FEATURES
}

// The null backend validates every upscaler's commands, so it reports all of them.
UPSCALERS :: gpu.Upscaler_Kinds{.Fsr}

upscalers :: proc() -> gpu.Upscaler_Kinds {
	return UPSCALERS
}

// adapter is a fixed adapter with no video memory of its own.
adapter :: proc() -> gpu.Adapter {
	a := gpu.Adapter{}
	copy(a.name[:], "null")
	return a
}

// stats counts the live resources. The null backend has no video memory.
stats :: proc() -> gpu.Stats {
	s := gpu.Stats {
		buffers          = gpu.pool_live(&state.buffers),
		textures         = gpu.pool_live(&state.textures),
		samplers         = gpu.pool_live(&state.samplers),
		pipelines        = gpu.pool_live(&state.pipelines),
		accels           = gpu.pool_live(&state.accels),
		upload_bytes_max = u64(state.upload_peak),
	}
	state.upload_peak = 0
	return s
}

frame_target :: proc() -> gpu.Texture {
	return state.frame_target
}

output :: proc() -> gpu.Output {
	return state.output
}

// request_output changes the output from the next frame on.
request_output :: proc(request: gpu.Output_Request) {
	state.request = request
}

// The null backend has no shared target, so these do nothing.
shared_target :: proc() -> (prefix: string, generation: u32, size: [2]i32) {
	return
}

pace_shared_frames :: proc(paced: bool) {}

acknowledge_shared_frame :: proc(generation: u32, frame: u64) {}

preview_target :: proc(id: int, size: [2]u32) -> (target: gpu.Preview_Target, ok: bool) {
	return
}

release_preview_target :: proc(id: int) {}

acknowledge_preview_frame :: proc(id: int, generation: u32, frame: u64) {}

viewport_target :: proc(id: int, size: [2]u32) -> (target: gpu.Preview_Target, ok: bool) {
	return
}

release_viewport_target :: proc(id: int) {}

acknowledge_viewport_frame :: proc(id: int, generation: u32, frame: u64) {}

// Nothing compiles, so a pipeline is Ready once it exists, and a handle that is not a pipeline's is Failed.
pipeline_status :: proc(pipeline: gpu.Pipeline) -> gpu.Pipeline_Status {
	_, ok := gpu.pool_lookup(&state.pipelines, pipeline)
	return ok ? .Ready : .Failed
}

pipeline_ready :: proc(pipeline: gpu.Pipeline) -> bool {
	return pipeline_status(pipeline) == .Ready
}

begin_frame :: proc(size: [2]i32) {
	if elapsed := time.tick_since(state.frame_start); elapsed < FRAME_TIME {
		time.sleep(FRAME_TIME - elapsed)
	}
	state.frame_start = time.tick_now()
	state.recording = size.x > 0 && size.y > 0
	mode := gpu.output_mode(state.request, {})
	state.output = {mode = mode, format = gpu.output_format(mode)}
	gpu.pool_get(&state.textures, state.frame_target)^ = frame_target_desc(size)
	gpu.track_layout(&state.layouts, state.frame_target, .Render_Target)
	state.upload_peak = max(state.upload_peak, state.upload_offset)
	state.upload_offset = 0

	state.frame_index += 1
	f := &state.frames[state.frame_index % FRAMES_IN_FLIGHT]
	if f.frame != 0 {
		profile.add_gpu(f.frame, f.spans[:], f.begin, f.end)
	}
	clear(&f.spans)
	start := u64(state.frame_start._nsec)
	f^ = {frame = profile.current_frame(), begin = start, end = start, spans = f.spans}
	state.clock = {.Graphics = start, .Compute = start}
}

// submit returns false if any command buffer breaks a rule. It then drops all of them.
// Nothing runs, so the queues and waits only affect validation.
submit :: proc(buffers: []gpu.Command_Buffer, queue := gpu.Queue.Graphics, wait_for := gpu.Queues{}) -> bool {
	if err, buffer, packet := gpu.validate_submission(buffers, RESOURCES, &state.layouts, queue); err != .None {
		log.errorf("gpu: command buffer %d, packet %d: %v", buffer, packet, err)
		return false
	}
	time_markers(buffers, queue)
	return true
}

// time_markers gives each timed marker a span on the queue's fake clock, which advances PACKET_TIME per packet.
@(private = "file")
time_markers :: proc(buffers: []gpu.Command_Buffer, queue: gpu.Queue) {
	Open :: struct {
		start: u64,
		name:  profile.Name,
		timed: bool,
	}
	sync.guard(&state.timing_mutex)
	f := &state.frames[state.frame_index % FRAMES_IN_FLIGHT]
	clock := &state.clock[queue]
	for cb in buffers {
		open: [dynamic]Open
		open.allocator = context.temp_allocator
		timed := 0
		it := gpu.packet_iterator(cb)
		for p in gpu.next_packet(&it) {
			clock^ += PACKET_TIME
			#partial switch p.kind {
			case .Begin_Marker:
				o := Open{start = clock^, timed = gpu.marker_timed(p)}
				if o.timed {
					o.name = profile.intern(gpu.marker_label(p), .Render)
				}
				append(&open, o)
				timed += 1 if o.timed else 0
			case .End_Marker:
				o := pop(&open)
				if o.timed {
					timed -= 1
					append(&f.spans, profile.Gpu_Span{start = o.start, end = clock^, name = o.name, queue = u8(queue), depth = u8(timed)})
				}
			}
		}
	}
	f.end = max(f.end, clock^)
}

// end_frame checks that the game left the frame target in the render target layout, and finishes the frame's captures:
// a frame that records nothing cancels them.
end_frame :: proc() {
	if layout, _ := gpu.tracked_layout(&state.layouts, state.frame_target); layout != .Render_Target {
		log.errorf("gpu: the frame target ends the frame in the %v layout", layout)
	}
	if state.texture_pending >= 0 {
		finish_capture(state.texture_pending, state.texture, .Sdr, state.recording)
		state.texture_pending = -1
	}
	if state.frame_pending >= 0 {
		copied := state.recording && !state.fail_frame_copy
		state.fail_frame_copy = false
		finish_capture(state.frame_pending, state.frame_target, state.output.mode, copied)
		state.frame_pending = -1
	}
}

// finish_capture fills a requested slot with a copy of the texture, or cancels it.
@(private = "file")
finish_capture :: proc(slot: int, texture: gpu.Texture, mode: gpu.Output_Mode, copied: bool) {
	c := &state.captures[slot]
	c.state = .Done
	if !copied {
		c.status = .Cancelled
		return
	}
	desc := gpu.pool_get(&state.textures, texture)
	c.status, c.size, c.format, c.mode = .Ready, desc.size, desc.format, mode
	c.pixels = make([]byte, int(capture_row_pitch(desc.size.x)) * int(desc.size.y))
}

// fail_next_frame_copy makes the next frame copy fail, as D3D12's does when it cannot make its readback buffer, so a
// test can cancel a capture in a frame that records.
@(private)
fail_next_frame_copy :: proc() {
	state.fail_frame_copy = true
}

// take_capture_slot gives a free slot to a request, or -1.
@(private = "file")
take_capture_slot :: proc(source: gpu.Capture_Source, ticket: u32) -> int {
	for &c, i in state.captures {
		if c.state == .Free {
			c = {state = .Requested, source = source, ticket = ticket}
			return i
		}
	}
	return -1
}

// request_texture_capture takes a slot for a copy of a texture at this frame's end, or is false when the frame records
// nothing, every slot is in use or a copy is already asked for this frame.
request_texture_capture :: proc(texture: gpu.Texture, ticket: u32) -> bool {
	if !state.recording || state.texture_pending >= 0 {
		return false
	}
	state.texture_pending = take_capture_slot(.Texture, ticket)
	state.texture = texture
	return state.texture_pending >= 0
}

// capture_row_pitch is a captured row's bytes: four per pixel, aligned to 256 as D3D12's footprints are.
capture_row_pitch :: proc(width: u32) -> u32 {
	return (width * 4 + 255) &~ 255
}

// request_frame_capture takes a slot for this frame's frame target, or is false when the last frame recorded nothing,
// every slot is held or a copy is already asked for this frame. Like D3D12's, it sees the last frame, so a frame that
// then records nothing cancels the copy.
request_frame_capture :: proc(ticket: u32) -> bool {
	if !state.recording || state.frame_pending >= 0 {
		return false
	}
	state.frame_pending = take_capture_slot(.Frame, ticket)
	return state.frame_pending >= 0
}

// poll_frame_capture gives a finished capture, ready or cancelled, to the caller, which holds it until
// release_frame_capture.
poll_frame_capture :: proc() -> (capture: gpu.Frame_Capture, ok: bool) {
	for &c, i in state.captures {
		if c.state != .Done {
			continue
		}
		c.state = .Taken
		capture = {slot = u32(i), status = c.status, source = c.source, ticket = c.ticket}
		if c.status == .Ready {
			capture.size, capture.format, capture.mode = c.size, c.format, c.mode
			capture.row_pitch, capture.pixels = capture_row_pitch(c.size.x), c.pixels
		}
		return capture, true
	}
	return
}

release_frame_capture :: proc(capture: gpu.Frame_Capture) {
	if capture.slot < CAPTURE_SLOTS {
		c := &state.captures[capture.slot]
		delete(c.pixels)
		c^ = {}
	}
}

create_buffer :: proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer {
	if err := gpu.validate_buffer_desc(desc, data); err != .None {
		log.errorf("gpu: buffer %q: %v", desc.label, err)
		return {}
	}
	buffer := gpu.pool_add(&state.buffers, gpu.Buffer_Desc{size = desc.size, usage = desc.usage, scope = desc.scope})
	if buffer != {} && .Readback in desc.usage {
		state.readbacks[buffer] = make([]byte, desc.size)
	}
	return buffer
}

create_texture :: proc(desc: gpu.Texture_Desc, data: []byte) -> gpu.Texture {
	if err := gpu.validate_texture_desc(desc, data); err != .None {
		log.errorf("gpu: texture %q: %v", desc.label, err)
		return {}
	}
	stored := desc
	stored.label = ""
	texture := gpu.pool_add(&state.textures, stored)
	if texture != {} {
		gpu.track_layout(&state.layouts, texture, gpu.initial_layout(desc.usage, data != nil))
	}
	return texture
}

// A view keeps its texture's description with the mip's size and the Storage usage alone.
create_texture_view :: proc(desc: gpu.Texture_View_Desc) -> gpu.Texture {
	parent, ok := gpu.pool_lookup(&state.textures, desc.texture)
	if !ok {
		log.errorf("gpu: texture view %q: an invalid texture", desc.label)
		return {}
	}
	if err := gpu.validate_texture_view(desc, parent, desc.texture in state.views); err != .None {
		log.errorf("gpu: texture view %q: %v", desc.label, err)
		return {}
	}
	stored := parent
	stored.size = {max(parent.size.x >> desc.mip, 1), max(parent.size.y >> desc.mip, 1)}
	stored.mip_count, stored.usage, stored.scope, stored.label = 1, {.Storage}, desc.scope, ""
	view := gpu.pool_add(&state.textures, stored)
	if view != {} {
		state.views[view] = true
	}
	return view
}

create_sampler :: proc(desc: gpu.Sampler_Desc) -> gpu.Sampler {
	stored := desc
	stored.label = ""
	return gpu.pool_add(&state.samplers, stored)
}

create_graphics_pipeline :: proc(desc: gpu.Graphics_Pipeline_Desc) -> gpu.Pipeline {
	if err := gpu.validate_graphics_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return {}
	}
	if len(desc.mesh) > 0 && .Mesh_Shaders not_in FEATURES {
		log.errorf("gpu: pipeline %q: mesh shaders are not supported", desc.label)
		return {}
	}
	return gpu.pool_add(&state.pipelines, Pipeline_Entry{gpu.pipeline_info(desc), desc.scope})
}

create_compute_pipeline :: proc(desc: gpu.Compute_Pipeline_Desc) -> gpu.Pipeline {
	if err := gpu.validate_compute_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return {}
	}
	return gpu.pool_add(&state.pipelines, Pipeline_Entry{{kind = .Compute}, desc.scope})
}

create_ray_tracing_pipeline :: proc(desc: gpu.Ray_Tracing_Pipeline_Desc) -> gpu.Pipeline {
	if err := gpu.validate_ray_tracing_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return {}
	}
	return gpu.pool_add(&state.pipelines, Pipeline_Entry{{kind = .Ray_Tracing}, desc.scope})
}

update_ray_tracing_pipeline :: proc(pipeline: gpu.Pipeline, desc: gpu.Ray_Tracing_Pipeline_Desc) -> bool {
	if err := gpu.validate_ray_tracing_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return false
	}
	return update_pipeline(pipeline, {kind = .Ray_Tracing}, desc.label)
}

// An update must keep the pipeline's attachment formats, as in the real backends. Nothing compiles, so the new
// version is ready at once.
update_graphics_pipeline :: proc(pipeline: gpu.Pipeline, desc: gpu.Graphics_Pipeline_Desc) -> bool {
	if err := gpu.validate_graphics_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return false
	}
	return update_pipeline(pipeline, gpu.pipeline_info(desc), desc.label)
}

update_compute_pipeline :: proc(pipeline: gpu.Pipeline, desc: gpu.Compute_Pipeline_Desc) -> bool {
	if err := gpu.validate_compute_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return false
	}
	return update_pipeline(pipeline, {kind = .Compute}, desc.label)
}

@(private = "file")
update_pipeline :: proc(pipeline: gpu.Pipeline, info: gpu.Pipeline_Info, label: string) -> bool {
	entry, ok := gpu.pool_lookup(&state.pipelines, pipeline)
	if !ok {
		log.errorf("gpu: pipeline %q: update of an invalid handle", label)
		return false
	}
	if entry.info != info {
		log.errorf("gpu: pipeline %q: an update must keep the attachment formats. Create a new pipeline instead.", label)
		return false
	}
	return true
}

// Nothing runs on a GPU, so destroyed slots are free at once.
destroy_buffer :: proc(buffer: gpu.Buffer) {
	if _, ok := gpu.pool_remove(&state.buffers, buffer); ok {
		gpu.pool_free(&state.buffers, buffer.index)
		if memory, readback := state.readbacks[buffer]; readback {
			delete(memory)
			delete_key(&state.readbacks, buffer)
		}
	}
}

destroy_texture :: proc(texture: gpu.Texture) {
	assert(texture != state.frame_target, "gpu: the frame target cannot be destroyed")
	if _, ok := gpu.pool_remove(&state.textures, texture); ok {
		gpu.pool_free(&state.textures, texture.index)
		gpu.untrack_layout(&state.layouts, texture)
		delete_key(&state.streamed, texture)
		delete_key(&state.views, texture)
	}
}

destroy_sampler :: proc(sampler: gpu.Sampler) {
	if _, ok := gpu.pool_remove(&state.samplers, sampler); ok {
		gpu.pool_free(&state.samplers, sampler.index)
	}
}

create_accel :: proc(desc: gpu.Accel_Struct_Desc) -> gpu.Accel_Struct {
	if err := gpu.validate_accel_desc(desc); err != .None {
		log.errorf("gpu: acceleration structure %q: %v", desc.label, err)
		return {}
	}
	entry := Accel_Entry {
		info           = gpu.accel_info(desc),
		scope          = desc.scope,
		geometry_count = len(desc.geometries),
	}
	for g, i in desc.geometries {
		_, vertices_ok := gpu.pool_lookup(&state.buffers, g.vertices)
		_, indices_ok := gpu.pool_lookup(&state.buffers, g.indices)
		if !vertices_ok || (g.indices != {} && !indices_ok) {
			log.errorf("gpu: acceleration structure %q: geometry %d has an invalid buffer", desc.label, i)
			return {}
		}
		entry.geometries[i] = {g.vertices, g.indices}
	}
	return gpu.pool_add(&state.accels, entry)
}

destroy_accel :: proc(accel: gpu.Accel_Struct) {
	if _, ok := gpu.pool_remove(&state.accels, accel); ok {
		gpu.pool_free(&state.accels, accel.index)
	}
}

// Nothing is built, so a reference only has to be unique.
accel_reference :: proc(accel: gpu.Accel_Struct) -> u64 {
	return u64(accel.index) << 32 | u64(accel.generation)
}

create_upscaler :: proc(desc: gpu.Upscaler_Desc) -> gpu.Upscaler {
	if err := gpu.validate_upscaler_desc(desc); err != .None {
		log.errorf("gpu: upscaler %q: %v", desc.label, err)
		return {}
	}
	stored := desc
	stored.label = ""
	return gpu.pool_add(&state.upscalers, stored)
}

destroy_upscaler :: proc(upscaler: gpu.Upscaler) {
	if _, ok := gpu.pool_remove(&state.upscalers, upscaler); ok {
		gpu.pool_free(&state.upscalers, upscaler.index)
	}
}

destroy_pipeline :: proc(pipeline: gpu.Pipeline) {
	if _, ok := gpu.pool_remove(&state.pipelines, pipeline); ok {
		gpu.pool_free(&state.pipelines, pipeline.index)
	}
}

destroy_scope :: proc(scope: gpu.Scope) -> (count: int) {
	assert(scope != .Permanent, "gpu: the Permanent scope belongs to core")
	for i in 0 ..< state.buffers.count {
		if buffer, ok := gpu.pool_handle(&state.buffers, i); ok && state.buffers.items[i].scope == scope {
			destroy_buffer(buffer)
			count += 1
		}
	}
	for i in 0 ..< state.textures.count {
		if texture, ok := gpu.pool_handle(&state.textures, i); ok && state.textures.items[i].scope == scope {
			destroy_texture(texture)
			count += 1
		}
	}
	for i in 0 ..< state.samplers.count {
		if sampler, ok := gpu.pool_handle(&state.samplers, i); ok && state.samplers.items[i].scope == scope {
			destroy_sampler(sampler)
			count += 1
		}
	}
	for i in 0 ..< state.accels.count {
		if accel, ok := gpu.pool_handle(&state.accels, i); ok && state.accels.items[i].scope == scope {
			destroy_accel(accel)
			count += 1
		}
	}
	for i in 0 ..< state.upscalers.count {
		if upscaler, ok := gpu.pool_handle(&state.upscalers, i); ok && state.upscalers.items[i].scope == scope {
			destroy_upscaler(upscaler)
			count += 1
		}
	}
	for i in 0 ..< state.pipelines.count {
		if pipeline, ok := gpu.pool_handle(&state.pipelines, i); ok && state.pipelines.items[i].scope == scope {
			destroy_pipeline(pipeline)
			count += 1
		}
	}
	return
}

// Nothing runs, so a transfer is done at once. The calls are validated as in the real backends.
stream_buffer :: proc(buffer: gpu.Buffer, offset: u32, data: []byte) -> gpu.Transfer {
	desc, ok := gpu.pool_lookup(&state.buffers, buffer)
	if !ok {
		log.error("gpu: stream to an invalid buffer")
		return {}
	}
	if err := gpu.validate_stream_buffer(desc, offset, data); err != .None {
		log.errorf("gpu: buffer stream: %v", err)
		return {}
	}
	state.transfers += 1
	return gpu.Transfer(state.transfers)
}

stream_texture :: proc(texture: gpu.Texture, data: []byte) -> gpu.Transfer {
	desc, ok := gpu.pool_lookup(&state.textures, texture)
	if !ok {
		log.error("gpu: stream to an invalid texture")
		return {}
	}
	if err := gpu.validate_stream_texture(desc, state.streamed[texture], data); err != .None {
		log.errorf("gpu: texture stream: %v", err)
		return {}
	}
	state.streamed[texture] = true
	state.transfers += 1
	return gpu.Transfer(state.transfers)
}

transfer_done :: proc(transfer: gpu.Transfer) -> bool {
	return true
}

// read_buffer returns a Readback buffer's memory, which is always ready.
read_buffer :: proc(buffer: gpu.Buffer) -> ([]byte, bool) {
	memory, ok := state.readbacks[buffer]
	return memory, ok
}

// upload returns false when the frame's upload ring is full.
upload :: proc(size, align: int) -> (gpu.Upload, bool) {
	for {
		offset := sync.atomic_load(&state.upload_offset)
		start := mem.align_forward_int(offset, align)
		if start + size > len(state.upload_memory) {
			return {}, false
		}
		if _, ok := sync.atomic_compare_exchange_weak(&state.upload_offset, offset, start + size); ok {
			return {data = state.upload_memory[start:][:size], buffer = state.upload_buffer, offset = u32(start)}, true
		}
	}
}

@(private = "file")
frame_target_desc :: proc(size: [2]i32) -> gpu.Texture_Desc {
	return {size = {u32(max(size.x, 1)), u32(max(size.y, 1))}, format = state.output.format, usage = {.Render_Target}, scope = .Permanent}
}

@(private)
RESOURCES :: gpu.Resources {
	texture = proc(texture: gpu.Texture) -> (gpu.Texture_Desc, bool) {
		return gpu.pool_lookup(&state.textures, texture)
	},
	buffer = proc(buffer: gpu.Buffer) -> (gpu.Buffer_Desc, bool) {
		return gpu.pool_lookup(&state.buffers, buffer)
	},
	pipeline = proc(pipeline: gpu.Pipeline) -> (gpu.Pipeline_Info, bool) {
		entry, ok := gpu.pool_lookup(&state.pipelines, pipeline)
		return entry.info, ok
	},
	accel = proc(accel: gpu.Accel_Struct) -> (gpu.Accel_Info, bool) {
		entry, ok := gpu.pool_lookup(&state.accels, accel)
		for buffers in entry.geometries[:entry.geometry_count] {
			_, vertices_ok := gpu.pool_lookup(&state.buffers, buffers[0])
			_, indices_ok := gpu.pool_lookup(&state.buffers, buffers[1])
			entry.info.inputs_valid &&= vertices_ok && (buffers[1] == {} || indices_ok)
		}
		return entry.info, ok
	},
	upscaler = proc(upscaler: gpu.Upscaler) -> (gpu.Upscaler_Desc, bool) {
		return gpu.pool_lookup(&state.upscalers, upscaler)
	},
}
