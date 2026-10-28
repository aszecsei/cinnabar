package core

import "base:runtime"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:sync"
import "core:time"

import "cinnabar:core/gpu"
import "cinnabar:core/jobs"
import physics "cinnabar:core/physics"
import physics_host "cinnabar:core/physics/host"
import physics_null "cinnabar:core/physics/null"
import "cinnabar:core/profile"
import script_host "cinnabar:core/script"

// A comma-separated list of gpu.Feature names that core hides from the game, to test fallback paths on hardware
// that has the features. For example: CINNABAR_DISABLE_FEATURES=Mesh_Shaders.
DISABLE_FEATURES_VARIABLE :: "CINNABAR_DISABLE_FEATURES"
// A gpu.Output_Request name that replaces the game's requests, to see an output mode without the game's settings. For
// example: CINNABAR_OUTPUT=Scrgb.
OUTPUT_VARIABLE :: "CINNABAR_OUTPUT"

// The build selects the GPU backend by pointing this collection at a backend package.
import backend "gpu_backend:."
// And the physics backend's loader the same way: a backend that the build links, or the plugin loader, which loads the
// project's choice (see docs/physics/backends.md#loading).
import physics_backend "physics_backend:."

PERMANENT_RESERVE :: 4 * mem.Gigabyte
FRAME_RESERVE :: 256 * mem.Megabyte

@(private)
Platform :: struct {
	permanent:   virtual.Arena,
	frame:       [2]virtual.Arena,
	frame_index: u64,
	start:       time.Tick,
	last_frame:  time.Tick,
	// Read once per frame, so the game and the GPU backend agree on it.
	window_size: [2]i32,
	// In shared mode, the size that the reader asked for, which replaces the hidden window's. Zero until it asks.
	shared_size: [2]i32,
	disabled_features: gpu.Features,
	// From OUTPUT_VARIABLE, which then ignores the game's requests.
	output_override: Maybe(gpu.Output_Request),
	// The game's virtual memory reservations, released at a soft restart.
	reservations: [dynamic][]byte,
	reservations_mutex: sync.Mutex,
	// The most that a frame's arena used since memory_stats last read it.
	frame_peak:  uint,
	// Input from the editor, for the next frame.
	input_queue: [dynamic]Input_Event,
	// What the physics backend calls. The backend keeps its address.
	physics_host: physics.Host,
	api:         Platform_API,
}

@(private)
platform: Platform

// A non-empty shared_target renders into shared textures for another process, such as the editor, with the window
// hidden (see docs/gpu/presentation.md#presentation). A non-zero adapter is the LUID of the GPU to use. content_dir and
// project_path are where the game's files are; empty, they are beside the executable (see game_paths). physics is the
// physics backend's name; empty, it is the project's physics.backend, or jolt.
init :: proc(
	title: string,
	width: i32 = 1280,
	height: i32 = 720,
	shared_target := "",
	adapter: u64 = 0,
	content_dir := "",
	project_path := "",
	physics_backend_name := "",
) -> bool {
	if err := virtual.arena_init_static(&platform.permanent, PERMANENT_RESERVE); err != nil {
		log.errorf("core: permanent arena: %v", err)
		return false
	}
	exe_dir, exe_err := os.get_executable_directory(context.temp_allocator)
	if exe_err != nil {
		log.errorf("core: cannot find the executable's directory: %v", exe_err)
		return false
	}
	content, project := game_paths(exe_dir, content_dir, project_path, virtual.arena_allocator(&platform.permanent))
	for &arena in platform.frame {
		if err := virtual.arena_init_static(&arena, FRAME_RESERVE); err != nil {
			log.errorf("core: frame arena: %v", err)
			return false
		}
	}
	if !profile.init() {
		log.error("core: failed to start the profiler")
		return false
	}
	if !jobs.init() {
		log.error("core: failed to start the job system")
		return false
	}
	platform.physics_host = physics_host.table()
	backend_name := physics_backend_name if physics_backend_name != "" else physics_host.backend_setting(project, context.temp_allocator)
	physics_api := load_physics(&platform.physics_host, backend_name)
	physics_host.bind(physics_api)
	info := physics_api.info()
	log.infof("core: physics %s %s", info.name, info.version)
	if !_window_open(title, width, height, visible = shared_target == "") {
		log.error("core: failed to open window")
		return false
	}
	platform.window_size = _window_size()
	if !backend.init(_window_native_handle(), platform.window_size, shared_target, adapter) {
		log.error("core: failed to initialize the GPU backend")
		return false
	}

	platform.disabled_features = read_disabled_features()
	platform.output_override = read_output_override()
	if request, ok := platform.output_override.?; ok {
		backend.request_output(request)
	}
	platform.reservations = make([dynamic][]byte)

	platform.start = time.tick_now()
	platform.last_frame = platform.start
	platform.api = {
		permanent_allocator          = virtual.arena_allocator(&platform.permanent),
		frame_allocator              = virtual.arena_allocator(&platform.frame[0]),
		asset_allocator              = runtime.heap_allocator(),
		heap_allocator               = runtime.heap_allocator(),
		content_dir                  = content,
		project_path                 = project,
		memory_reserve               = memory_reserve,
		memory_commit                = memory_commit,
		memory_release               = memory_release,
		time_seconds                 = time_seconds,
		input                        = _window_input,
		file_read                    = file_read,
		file_modified                = file_modified,
		file_write                   = file_write,
		window_size                  = window_size,
		set_window_title             = _window_set_title,
		jobs_run                     = jobs.run,
		jobs_wait                    = jobs.wait,
		jobs_lock                    = jobs.lock,
		jobs_unlock                  = jobs.unlock,
		jobs_worker_count            = jobs.worker_count,
		profile                      = profile.procs(),
		gpu_features                 = gpu_features,
		gpu_adapter                  = backend.adapter,
		gpu_frame_target             = backend.frame_target,
		gpu_output                   = backend.output,
		gpu_request_output           = gpu_request_output,
		gpu_preview_target           = backend.preview_target,
		gpu_release_preview_target   = backend.release_preview_target,
		gpu_pipeline_ready           = backend.pipeline_ready,
		gpu_submit                   = backend.submit,
		gpu_upload                   = backend.upload,
		gpu_stream_buffer            = backend.stream_buffer,
		gpu_stream_texture           = backend.stream_texture,
		gpu_transfer_done            = backend.transfer_done,
		gpu_read_buffer              = backend.read_buffer,
		gpu_create_buffer            = backend.create_buffer,
		gpu_create_texture           = backend.create_texture,
		gpu_create_sampler           = backend.create_sampler,
		gpu_create_graphics_pipeline = backend.create_graphics_pipeline,
		gpu_create_compute_pipeline  = backend.create_compute_pipeline,
		gpu_update_graphics_pipeline = backend.update_graphics_pipeline,
		gpu_update_compute_pipeline  = backend.update_compute_pipeline,
		gpu_create_ray_tracing_pipeline = backend.create_ray_tracing_pipeline,
		gpu_update_ray_tracing_pipeline = backend.update_ray_tracing_pipeline,
		gpu_create_accel             = backend.create_accel,
		gpu_accel_reference          = backend.accel_reference,
		gpu_upscalers                = backend.upscalers,
		gpu_create_upscaler          = backend.create_upscaler,
		gpu_destroy_buffer           = backend.destroy_buffer,
		gpu_destroy_texture          = backend.destroy_texture,
		gpu_destroy_sampler          = backend.destroy_sampler,
		gpu_destroy_pipeline         = backend.destroy_pipeline,
		gpu_destroy_accel            = backend.destroy_accel,
		gpu_destroy_upscaler         = backend.destroy_upscaler,
		gpu_destroy_scope            = backend.destroy_scope,
		script_open                  = script_host.open,
		script_close                 = script_host.close,
		script_push_binding          = script_host.push_binding,
		script_atom                  = script_host.atom,
		script_direct_access         = script_host.direct_access,
		physics                      = physics_api^,
	}
	return true
}

// load_physics loads the named physics backend and checks that it has this build's API version and layouts, or gives
// the null backend, with an error, so that the game runs without physics rather than not at all.
@(private = "file")
load_physics :: proc(host: ^physics.Host, name: string) -> ^physics.Physics_API {
	api := physics_backend.load(host, name)
	if api == nil {
		log.errorf("core: physics backend %q did not load, so the game runs without physics", name)
		return physics_null.load(host)
	}
	info := api.info()
	if info.api_version != physics.API_VERSION || info.layout != physics.layout_signature() {
		log.errorf(
			"core: physics backend %q has physics API version %d and layout %x, not %d and %x, so the game runs without physics",
			name,
			info.api_version,
			info.layout,
			physics.API_VERSION,
			physics.layout_signature(),
		)
		return physics_null.load(host)
	}
	return api
}

// game_paths resolves where the game's files are: content_dir and project_path as given, or content and
// project.settings in the executable's directory when empty. Both come back absolute, so a change of the working
// directory later cannot move them, and in allocator.
game_paths :: proc(exe_dir, content_dir, project_path: string, allocator: runtime.Allocator) -> (content, project: string) {
	content, project = content_dir, project_path
	if content == "" {
		content, _ = filepath.join({exe_dir, "content"}, context.temp_allocator)
	}
	if project == "" {
		project, _ = filepath.join({exe_dir, "project.settings"}, context.temp_allocator)
	}
	return absolute(content, allocator), absolute(project, allocator)
}

@(private)
absolute :: proc(path: string, allocator: runtime.Allocator) -> string {
	if full, err := os.get_absolute_path(path, allocator); err == nil {
		return full
	}
	return strings.clone(path, allocator)
}

shutdown :: proc() {
	platform.api.physics.shutdown()
	backend.shutdown()
	_window_close()
	jobs.shutdown()
	profile.shutdown()
	release_reservations()
	delete(platform.reservations)
	delete(platform.input_queue)
	for &arena in platform.frame {
		virtual.arena_destroy(&arena)
	}
	virtual.arena_destroy(&platform.permanent)
}

platform_api :: proc() -> ^Platform_API {
	return &platform.api
}

// begin_frame polls platform events, waits for the GPU backend to accept a new frame
// and swaps the frame arena. It returns false when the window was closed.
begin_frame :: proc() -> (dt: time.Duration, keep_running: bool) {
	profile.frame_boundary()
	profile.zone_text("Begin frame", .Frame)
	keep_running = _window_poll()
	_window_apply_input(platform.input_queue[:])
	clear(&platform.input_queue)
	platform.window_size = platform.shared_size if platform.shared_size != {} else _window_size()
	backend.begin_frame(platform.window_size)

	now := time.tick_now()
	dt = time.tick_diff(platform.last_frame, now)
	platform.last_frame = now

	platform.frame_index += 1
	frame := &platform.frame[platform.frame_index % len(platform.frame)]
	platform.frame_peak = max(platform.frame_peak, frame.total_used)
	virtual.arena_free_all(frame)
	platform.api.frame_allocator = virtual.arena_allocator(frame)
	return
}

// end_frame presents the frame. The GPU backend paces frames to vsync.
end_frame :: proc() {
	profile.zone_text("End frame", .Frame)
	if !drain_jobs() {
		log.error("core: jobs ran past the end of the frame. Wait for every counter before the frame ends.")
	}
	backend.end_frame()
}

@(private = "file")
drain_jobs :: proc() -> bool {
	profile.zone_text("Drain jobs", .Frame)
	return jobs.drain_frame()
}

// alloc_game_state allocates zeroed root game state from the permanent arena.
alloc_game_state :: proc(size: int) -> rawptr {
	ptr, err := mem.alloc(size, GAME_STATE_ALIGN, platform.api.permanent_allocator)
	if err != nil {
		log.panicf("core: failed to allocate %d bytes of game state: %v", size, err)
	}
	return ptr
}

// soft_restart runs between the old game's shutdown and the new game's init. It destroys the GPU resources in the
// Game scope, the virtual memory reservations, the script VMs and the physics worlds, which the old game may have left,
// and frees all permanent allocations.
soft_restart :: proc() {
	if count := script_host.close_all(); count > 0 {
		log.debugf("core: closed %d script VMs that the game left open", count)
	}
	if count := platform.api.physics.world_destroy_all(); count > 0 {
		log.debugf("core: destroyed %d physics worlds that the game left", count)
	}
	if count := backend.destroy_scope(.Game); count > 0 {
		log.debugf("core: destroyed %d GPU resources that the game left in the Game scope", count)
	}
	if count := release_reservations(); count > 0 {
		log.debugf("core: released %d memory reservations that the game left", count)
	}
	virtual.arena_free_all(&platform.permanent)
}

// gpu_features is the backend's optional features without those that CINNABAR_DISABLE_FEATURES hides.
gpu_features :: proc() -> gpu.Features {
	return backend.features() - platform.disabled_features
}

@(private = "file")
gpu_request_output :: proc(request: gpu.Output_Request) {
	if platform.output_override == nil {
		backend.request_output(request)
	}
}

@(private = "file")
read_output_override :: proc() -> Maybe(gpu.Output_Request) {
	value := strings.trim_space(os.get_env(OUTPUT_VARIABLE, context.temp_allocator))
	if value == "" {
		return nil
	}
	request, ok := reflect.enum_from_name(gpu.Output_Request, value)
	if !ok {
		log.warnf("core: %s: unknown output %q", OUTPUT_VARIABLE, value)
		return nil
	}
	log.infof("core: output %v", request)
	return request
}

@(private = "file")
read_disabled_features :: proc() -> (disabled: gpu.Features) {
	value := os.get_env(DISABLE_FEATURES_VARIABLE, context.temp_allocator)
	for name in strings.split_iterator(&value, ",") {
		trimmed := strings.trim_space(name)
		if feature, ok := reflect.enum_from_name(gpu.Feature, trimmed); ok {
			disabled += {feature}
		} else if trimmed != "" {
			log.warnf("core: %s: unknown feature %q", DISABLE_FEATURES_VARIABLE, trimmed)
		}
	}
	if disabled != {} {
		log.infof("core: hiding GPU features %v", disabled)
	}
	return
}

// queue_input adds input that does not come from the window, such as the editor's, to the next frame's. Call it from
// the main thread between frames.
queue_input :: proc(events: []Input_Event) {
	append(&platform.input_queue, ..events)
}

// The largest shared target side. A reader that asks for more gets this.
MAX_SHARED_SIZE :: 8192

// resize_shared_target sets the size of the shared target from the next frame (see docs/editor/viewport.md#viewport). The
// game sees it as the window size.
resize_shared_target :: proc(size: [2]i32) {
	platform.shared_size = {clamp(size.x, 1, MAX_SHARED_SIZE), clamp(size.y, 1, MAX_SHARED_SIZE)}
}

// shared_target is the shared target's current generation: its object name prefix, in temporary memory, its
// generation number and its size. It is empty outside shared mode.
shared_target :: backend.shared_target

// gpu_stats is the GPU backend's resource counts and memory, for the host's stats. Call it between frames.
gpu_stats :: backend.stats

// memory_stats is the permanent arena's bytes in use, and the most that a frame's arena used since the last call.
memory_stats :: proc() -> (permanent, frame_max: u64) {
	permanent, frame_max = u64(platform.permanent.total_used), u64(platform.frame_peak)
	platform.frame_peak = 0
	return
}

// Frame captures copy a frame's final frame target to CPU memory (see docs/gpu/presentation.md#frame-capture). The
// host drives them for its screenshots and history ring; the game has no part in them. request_frame_capture asks
// for this frame's, poll_frame_capture returns the oldest finished one, and release_frame_capture frees its slot,
// from any thread.
request_frame_capture :: backend.request_frame_capture
poll_frame_capture :: backend.poll_frame_capture
release_frame_capture :: backend.release_frame_capture

// pace_shared_frames turns the reader's back-pressure on or off (see docs/editor/viewport.md#viewport).
pace_shared_frames :: backend.pace_shared_frames

// acknowledge_shared_frame records that the reader has finished with a frame of a generation.
acknowledge_shared_frame :: backend.acknowledge_shared_frame

// acknowledge_preview_frame records that the reader has finished with a frame of a generation of a preview target
// (see docs/rendering/materials.md#material-previews).
acknowledge_preview_frame :: backend.acknowledge_preview_frame

// window_size is the client area size at the start of the frame. It is zero while the window is minimized.
window_size :: proc() -> [2]i32 {
	return platform.window_size
}

time_seconds :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(platform.start))
}

@(private = "file")
memory_reserve :: proc(size: int) -> rawptr {
	data, err := virtual.reserve(uint(size))
	if err != nil {
		log.errorf("core: cannot reserve %d bytes: %v", size, err)
		return nil
	}
	sync.guard(&platform.reservations_mutex)
	append(&platform.reservations, data)
	return raw_data(data)
}

@(private = "file")
memory_commit :: proc(ptr: rawptr, size: int) -> bool {
	if err := virtual.commit(ptr, uint(size)); err != nil {
		log.errorf("core: cannot commit %d bytes: %v", size, err)
		return false
	}
	return true
}

@(private = "file")
memory_release :: proc(ptr: rawptr, size: int) {
	sync.guard(&platform.reservations_mutex)
	for r, i in platform.reservations {
		if raw_data(r) == ptr {
			assert(len(r) == size, "core: released size differs from the reserved size")
			virtual.release(ptr, uint(size))
			unordered_remove(&platform.reservations, i)
			return
		}
	}
	log.error("core: released memory that was not reserved")
}

@(private = "file")
release_reservations :: proc() -> int {
	sync.guard(&platform.reservations_mutex)
	count := len(platform.reservations)
	for r in platform.reservations {
		virtual.release(raw_data(r), uint(len(r)))
	}
	clear(&platform.reservations)
	return count
}
