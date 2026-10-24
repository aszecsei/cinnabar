package mygame

import "core:c"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/layout"
import "cinnabar:core/luau"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

TRIANGLE_VS :: #load("shaders/triangle.vs.dxil")
TRIANGLE_PS :: #load("shaders/triangle.ps.dxil")
OBJECTS_VS :: #load("shaders/objects.vs.dxil")
OBJECTS_AS :: #load("shaders/objects.as.dxil")
OBJECTS_MS :: #load("shaders/objects.ms.dxil")
OBJECTS_PS :: #load("shaders/objects.ps.dxil")
CULL_CS :: #load("shaders/cull.cs.dxil")
POST_CS :: #load("shaders/post.cs.dxil")
SHADOWS_CS :: #load("shaders/shadows.cs.dxil")
SHADOWS_RT_LIB :: #load("shaders/shadows_rt.lib.dxil")
COMPOSITE_VS :: #load("shaders/composite.vs.dxil")
COMPOSITE_PS :: #load("shaders/composite.ps.dxil")
// The loose cache that `just scripts` cooks into. Release builds read the release cache until bundles exist.
CONTENT_CACHE :: #config(CINNABAR_CONTENT_CACHE, "build/cache/dev")
// Content refers to content by GUID. Until scenes exist, the game reads its one script's GUID from the .meta file.
HELLO_META :: #load("content/scripts/hello.luau.meta", string)
PULSE_META :: #load("content/scripts/pulse.luau.meta", string)

SCENE_FORMAT :: gpu.Format.RGBA16_Float
DEPTH_FORMAT :: gpu.Format.D32_Float
// Matches numthreads in shaders/post.hlsl.
POST_GROUP_SIZE :: 8
// Matches numthreads in shaders/cull.hlsl.
CULL_GROUP_SIZE :: 64
// Matches numthreads in shaders/shadows.hlsl.
SHADOW_GROUP_SIZE :: 8

// The large triangles cast ray-traced shadows. Ray_Tracing_Pipeline traces them with a ray tracing pipeline, and
// Ray_Query with inline ray tracing in a compute pass. Without either, there are no shadows.
Shadow_Mode :: enum u8 {
	None,
	Inline,
	Pipeline,
}

// The large triangles: rotation speed in radians per second, scale, depth in front of the camera and HDR
// brightness. Instance 0 is a bright triangle in front. Instance 1 is a larger, dimmer triangle behind it that turns
// the other way, so the depth test hides the part of it that the first one covers.
TRIANGLE_INSTANCES :: [2]struct {
	speed, scale, depth, brightness: f32,
} {
	{1, 1, 0.4, 3},
	{-0.7, 1.5, 0.6, 0.6},
}

// The scene is about 1 AU from the world origin. Fixed-point positions keep it exact there: the camera-relative
// transforms that the GPU sees are small.
SCENE_ORIGIN :: [3]f64{1.5e11, 0, 0}

// The GPU culls a grid of small objects every frame and draws the visible ones with one indirect draw. With mesh
// shaders, amplification shaders cull and mesh shaders draw. Without them, a compute pass on the compute queue culls
// and an indexed indirect draw draws: the vertex fallback. CINNABAR_DISABLE_FEATURES=Mesh_Shaders forces it.
OBJECT_COLUMNS :: 64
OBJECT_ROWS :: 36
OBJECT_COUNT :: OBJECT_COLUMNS * OBJECT_ROWS
// Matches OBJECTS_PER_GROUP in shaders/objects.hlsl.
OBJECTS_PER_GROUP :: 32
#assert(OBJECT_COUNT % OBJECTS_PER_GROUP == 0)

// The scene pass is split in two: one piece draws the large triangles, the other the culled objects.
SCENE_PIECES :: 2

CHECKER_SIZE :: 64
CHECKER_CELL :: 8

// A texture of rings streams in on the copy queue after STREAM_FRAME frames, and then replaces the checker on the
// large triangles.
RINGS_SIZE :: 256
RINGS_MIPS :: 9
STREAM_FRAME :: 60

// Matches Vertex in shaders/triangle.hlsl and shaders/objects.hlsl.
Vertex :: struct {
	position: [2]f32,
	uv:       [2]f32,
	color:    [4]f32,
}

// Matches Push in shaders/triangle.hlsl.
Scene_Constants :: struct {
	vertices:        u32,
	texture:         u32,
	sampler:         u32,
	instances:       u32,
	instance_offset: u32,
}

// Matches Instance in shaders/triangle.hlsl.
Triangle_Instance :: struct {
	rows:       [3][4]f32,
	brightness: f32,
	_:          [3]f32,
}

// Spin turns an entity about the view axis, in radians per second.
Spin :: struct {
	speed: f32,
}

// Triangle marks one of the large triangles, with its HDR brightness.
Triangle :: struct {
	brightness: f32,
}

// Matches Push in shaders/objects.hlsl.
Object_Constants :: struct {
	vertices:     u32,
	visible:      u32,
	texture:      u32,
	sampler:      u32,
	grid:         [2]u32,
	object_count: u32,
}

// Matches Push in shaders/cull.hlsl.
Cull_Constants :: struct {
	arguments:    u32,
	count:        u32,
	visible:      u32,
	object_count: u32,
	grid:         [2]u32,
}

// Matches Push in shaders/post.hlsl.
Post_Constants :: struct {
	input:       u32,
	output:      u32,
	size:        [2]u32,
	shadows:     u32,
	has_shadows: u32,
}

// Matches Push in shaders/shadows.hlsl.
Shadow_Constants :: struct {
	accel:  u32,
	output: u32,
	size:   [2]u32,
}

// Matches Push in shaders/composite.hlsl.
Composite_Constants :: struct {
	input:   u32,
	sampler: u32,
}

// Matches Pass in shaders/triangle.hlsl, shaders/objects.hlsl and shaders/cull.hlsl.
Pass_Constants :: struct {
	time:   f32,
	aspect: f32,
}

// Game_State is the root of all persistent game-side state. The host owns its memory.
Game_State :: struct {
	platform:    ^core.Platform_API,
	frame_count: u64,
	elapsed:     time.Duration,
	next_report: time.Duration,
	pipelines:   Pipelines,
	// True when the device has mesh shaders and the objects take the mesh path.
	mesh_path:   bool,
	vertices:    gpu.Buffer,
	indices:     gpu.Buffer,
	// The cull pass writes these on the compute queue each frame, and the scene pass reads them.
	arguments:   gpu.Buffer,
	draw_count:  gpu.Buffer,
	visible:     gpu.Buffer,
	// The mesh path's one Draw_Mesh_Indirect_Args record.
	mesh_draw:   gpu.Buffer,
	shadow_mode: Shadow_Mode,
	// The triangle, built once, and the two large triangles as its instances, built every frame.
	blas:        gpu.Accel_Struct,
	tlas:        gpu.Accel_Struct,
	blas_built:  bool,
	checker:     gpu.Texture,
	rings:       gpu.Texture,
	// Zero until the rings are streamed, and rings_ready once the transfer is done.
	rings_transfer: gpu.Transfer,
	rings_ready: bool,
	nearest:     gpu.Sampler,
	linear:      gpu.Sampler,
	textures:    render.Texture_Cache,
	world:       ecs.World,
	camera:      ecs.Entity,
	// A registration, created again in on_reload.
	triangles:   render.Extractor,
	assets:      asset.Assets,
	scripts:     script.Runtime,
	// The thread of content/scripts/hello.luau, which the scheduler runs.
	hello:       script.Thread,
}

Pipelines :: struct {
	scene:       gpu.Pipeline,
	objects:     gpu.Pipeline,
	// Nil without mesh shaders.
	mesh:        gpu.Pipeline,
	cull:        gpu.Pipeline,
	// A compute pipeline when shadow_mode is Inline, a ray tracing pipeline when it is Pipeline, and nil otherwise.
	shadows:     gpu.Pipeline,
	post:        gpu.Pipeline,
	composite:   gpu.Pipeline,
}

// Frame is what the pass procedures need. It lives in frame memory.
Frame :: struct {
	state:          ^Game_State,
	size:           [2]u32,
	pass_constants: gpu.Upload,
	vertices:       render.Buffer,
	indices:        render.Buffer,
	arguments:      render.Buffer,
	draw_count:     render.Buffer,
	visible:        render.Buffer,
	mesh_draw:      render.Buffer,
	blas:           render.Accel,
	tlas:           render.Accel,
	// The accel instances, and the triangle instances that the scene pass draws.
	instances:      gpu.Upload,
	triangles:      gpu.Upload,
	// The number of triangle instances. The acceleration structure holds at most len(TRIANGLE_INSTANCES).
	triangle_count: int,
	checker:        render.Texture,
	scene:          render.Texture,
	shadows:        render.Texture,
	post:           render.Texture,
}

init :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	// Game_State is too large for a temporary on the stack, so it is zeroed in place.
	mem.zero_item(s)
	s.platform = platform

	vertices := [3]Vertex {
		{{0, 0.6}, {0.5, 0}, {1, 0.3, 0.3, 1}},
		{{0.52, -0.3}, {1, 1}, {0.3, 1, 0.3, 1}},
		{{-0.52, -0.3}, {0, 1}, {0.3, 0.3, 1, 1}},
	}
	// Buffer sizes are multiples of 4, so the three u16 indices have one u16 of padding.
	indices := [4]u16{0, 1, 2, 0}
	s.vertices = platform.gpu_create_buffer({size = size_of(vertices), label = "triangle vertices"}, gpu_bytes(&vertices))
	s.indices = platform.gpu_create_buffer({size = size_of(indices), usage = {.Index}, label = "triangle indices"}, gpu_bytes(&indices))
	s.arguments = platform.gpu_create_buffer(
		{size = OBJECT_COUNT * size_of(gpu.Draw_Indexed_Indirect_Args), usage = {.Storage, .Indirect}, label = "object draws"},
		nil,
	)
	s.draw_count = platform.gpu_create_buffer({size = size_of(u32), usage = {.Storage, .Indirect}, label = "object draw count"}, nil)
	s.visible = platform.gpu_create_buffer({size = OBJECT_COUNT * size_of(u32), usage = {.Storage}, label = "visible objects"}, nil)

	s.mesh_path = .Mesh_Shaders in platform.gpu_features()
	if s.mesh_path {
		mesh_draw := gpu.Draw_Mesh_Indirect_Args {
			groups = {OBJECT_COUNT / OBJECTS_PER_GROUP, 1, 1},
		}
		s.mesh_draw = platform.gpu_create_buffer({size = size_of(mesh_draw), usage = {.Indirect}, label = "mesh draw"}, gpu_bytes(&mesh_draw))
	}

	checker: [CHECKER_SIZE * CHECKER_SIZE][4]u8
	for &texel, i in checker {
		x, y := i % CHECKER_SIZE / CHECKER_CELL, i / CHECKER_SIZE / CHECKER_CELL
		texel = (x + y) % 2 == 0 ? 255 : 64
	}
	s.checker = platform.gpu_create_texture(
		{size = CHECKER_SIZE, format = .RGBA8_Unorm_Srgb, usage = {.Sampled}, label = "checker"},
		gpu_bytes(&checker),
	)
	s.rings = platform.gpu_create_texture(
		{size = RINGS_SIZE, format = .RGBA8_Unorm_Srgb, mip_count = RINGS_MIPS, usage = {.Sampled, .Streamed}, label = "rings"},
		nil,
	)
	s.nearest = platform.gpu_create_sampler({label = "nearest"})
	s.linear = platform.gpu_create_sampler({filter = .Linear, address = .Clamp, label = "linear clamp"})

	features := platform.gpu_features()
	switch {
	case .Ray_Tracing_Pipeline in features:
		s.shadow_mode = .Pipeline
	case .Ray_Query in features:
		s.shadow_mode = .Inline
	}
	if s.shadow_mode != .None {
		triangle := gpu.Accel_Geometry {
			vertices      = s.vertices,
			vertex_stride = size_of(Vertex),
			vertex_count  = 3,
			vertex_format = .RG32_Float,
			indices       = s.indices,
			index_count   = 3,
			index_format  = .U16,
			opaque        = true,
		}
		s.blas = platform.gpu_create_accel({kind = .Bottom, geometries = {triangle}, label = "triangle"})
		s.tlas = platform.gpu_create_accel({kind = .Top, max_instances = len(TRIANGLE_INSTANCES), label = "scene"})
	}
	s.pipelines = create_pipelines(platform, s.mesh_path, s.shadow_mode)

	if !ecs.init(&s.world, platform) {
		log.panic("mygame: cannot create the world")
	}
	register_world(s)
	spawn_scene(s)
	asset.init(&s.assets, platform, asset.loose_cache(CONTENT_CACHE))
	if !script.init(&s.scripts, platform, &s.world, &s.assets, register_scripts) {
		log.panic("mygame: cannot open the script VM")
	}
	if hello, ok := format.meta_guid(HELLO_META); ok {
		s.hello, _ = script.spawn_script(&s.scripts, hello)
	}
	// Until scenes exist, the game attaches the large triangles' behaviour itself.
	if pulse, ok := format.meta_guid(PULSE_META); ok {
		triangles := make([dynamic]ecs.Entity, platform.frame_allocator)
		ecs.collect(&s.world, {ecs.registry_find_type(&s.world.registry, Triangle).id}, &triangles)
		for e in triangles {
			script.attach_script(&s.scripts, e, pulse)
		}
	}
	log.infof("mygame: init, objects on the %s path, shadows %v", s.mesh_path ? "mesh" : "vertex", s.shadow_mode)
}

// register_components registers every component type. init and on_reload call it on the world's registry, and
// layout_hash on its own, so a component change restarts the game.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_engine_components(r)
	script.register_components(r)
	ecs.register_component(r, Spin)
	ecs.register_component(r, Triangle)
}

// register_world makes the world's registrations: components, systems and queries.
register_world :: proc(s: ^Game_State) {
	w := &s.world
	register_components(&w.registry)
	ecs.register_system(w, {name = "spin", stage = .Fixed, procedure = spin, terms = {ecs.write(w, ecs.Transform), ecs.read(w, Spin)}})
	s.triangles = render.extractor(w, {ecs.read(w, Triangle)})
}

// spawn_scene places the camera and the large triangles at SCENE_ORIGIN.
spawn_scene :: proc(s: ^Game_State) {
	w := &s.world
	origin := ecs.position_from_meters(SCENE_ORIGIN)
	s.camera = ecs.spawn(w)
	ecs.add(w, s.camera, ecs.Transform{position = origin, rotation = 1, scale = 1})
	for t in TRIANGLE_INSTANCES {
		pose := ecs.Transform {
			position = ecs.position_offset(origin, {0, 0, t.depth}),
			rotation = 1,
			scale    = t.scale,
		}
		e := ecs.spawn(w)
		ecs.add(w, e, pose)
		ecs.add(w, e, ecs.Previous_Transform(pose))
		ecs.add(w, e, Spin{t.speed})
		ecs.add(w, e, Triangle{t.brightness})
	}
}

// register_scripts defines the game's script bindings and exposes its components. init and on_reload call it.
register_scripts :: proc(r: ^script.Runtime) {
	script.expose(r, Spin)
	script.expose(r, Triangle)
	script.define(r, "Game.frame", proc(L: ^luau.State) -> c.int {
		luau.pushnumber(L, f64(game_of(L).frame_count))
		return 1
	})
	script.define(r, "Game.greeting", proc(L: ^luau.State) -> c.int {
		luau.pushstring(L, "hello from Luau")
		return 1
	})
}

// game_of is the Game_State of a script binding.
game_of :: proc "contextless" (L: ^luau.State) -> ^Game_State {
	return container_of(script.runtime_of(L), Game_State, "scripts")
}

spin :: proc(ctx: ^ecs.System_Context) {
	it := ecs.query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
	for view in ecs.query_next(&it) {
		spins := ecs.column(view, 1, Spin)
		for &pose, i in ecs.column(view, 0, ecs.Transform) {
			turn := linalg.quaternion_angle_axis_f32(spins[i].speed * ctx.dt, {0, 0, 1})
			pose.rotation = linalg.normalize(turn * pose.rotation)
		}
	}
}

update :: proc(state: rawptr, dt: time.Duration) -> (keep_running: bool) {
	s := (^Game_State)(state)
	defer end_frame(s)
	s.frame_count += 1
	s.elapsed += dt

	ecs.run_fixed(&s.world, dt, s)
	ecs.run_stage(&s.world, .Update, dt, s)
	// The script phase, with its structural changes (phases 5 and 6).
	script.run_phase(&s.scripts, dt, s.platform.input())
	ecs.run_stage(&s.world, .Late, dt, s)

	if s.elapsed >= s.next_report {
		s.next_report += time.Second
		title := fmt.aprintf("mygame | frame %d | %.1fs", s.frame_count, time.duration_seconds(s.elapsed), allocator = s.platform.frame_allocator)
		s.platform.set_window_title(title)
	}

	if s.frame_count == STREAM_FRAME {
		stream_rings(s)
	}
	if s.rings_transfer != 0 && !s.rings_ready && s.platform.gpu_transfer_done(s.rings_transfer) {
		s.rings_ready = true
		log.infof("mygame: rings streamed in at frame %d", s.frame_count)
	}

	// A minimized window has no size, and nothing is rendered.
	size := s.platform.window_size()
	if size.x <= 0 || size.y <= 0 {
		return true
	}
	pass, ok := s.platform.gpu_upload(size_of(Pass_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return true
	}
	(^Pass_Constants)(raw_data(pass.data))^ = {
		time   = f32(time.duration_seconds(s.elapsed)),
		aspect = f32(size.x) / f32(size.y),
	}
	render_frame(s, {u32(size.x), u32(size.y)}, pass)
	return true
}

// end_frame swaps the blobs that the cooker rewrote. Scripts take up a new version once script hot reload exists.
end_frame :: proc(s: ^Game_State) {
	if changed := asset.poll(&s.assets); len(changed) > 0 {
		log.infof("mygame: %d assets changed", len(changed))
	}
}

// stream_rings generates the rings' mip chain and streams it. The backend copies the data before the call returns.
stream_rings :: proc(s: ^Game_State) {
	desc := gpu.Texture_Desc {
		size      = RINGS_SIZE,
		format    = .RGBA8_Unorm_Srgb,
		mip_count = RINGS_MIPS,
	}
	colors := [3][4]u8{{255, 170, 60, 255}, {60, 190, 255, 255}, {40, 40, 70, 255}}
	data := make([]byte, gpu.mip_chain_size(desc), s.platform.frame_allocator)
	texels := ([^][4]u8)(raw_data(data))
	i := 0
	for mip in 0 ..< u32(RINGS_MIPS) {
		n := u32(RINGS_SIZE) >> mip
		for y in 0 ..< n {
			for x in 0 ..< n {
				d := [2]f32{(f32(x) + 0.5) / f32(n) - 0.5, (f32(y) + 0.5) / f32(n) - 0.5}
				texels[i] = colors[int(math.sqrt(d.x * d.x + d.y * d.y) * 16) % 3]
				i += 1
			}
		}
	}
	s.rings_transfer = s.platform.gpu_stream_texture(s.rings, data)
}

// render_frame culls the objects on the compute queue, draws the scene into an HDR target with depth,
// post-processes it in a compute pass, and tone maps it into the frame target. The render graph places the
// barriers between the passes and the waits between the queues.
render_frame :: proc(s: ^Game_State, size: [2]u32, pass_constants: gpu.Upload) {
	frame := new(Frame, s.platform.frame_allocator)
	frame^ = {
		state          = s,
		size           = size,
		pass_constants = pass_constants,
	}

	g := render.begin(s.platform, &s.textures)
	target := render.import_texture(&g, s.platform.gpu_frame_target(), .Color)
	// The large triangles show the rings once they are streamed in.
	frame.checker = render.import_texture(&g, s.rings_ready ? s.rings : s.checker, .Sampled)
	frame.vertices = render.import_buffer(&g, s.vertices)
	frame.indices = render.import_buffer(&g, s.indices)
	frame.arguments = render.import_buffer(&g, s.arguments)
	frame.draw_count = render.import_buffer(&g, s.draw_count)
	frame.visible = render.import_buffer(&g, s.visible)
	if s.mesh_path {
		frame.mesh_draw = render.import_buffer(&g, s.mesh_draw)
	}
	frame.scene = render.create_texture(&g, {size = size, format = SCENE_FORMAT, label = "scene"})
	depth := render.create_texture(&g, {size = size, format = DEPTH_FORMAT, label = "scene depth"})
	frame.post = render.create_texture(&g, {size = size, format = SCENE_FORMAT, label = "post"})
	extract_triangles(frame)

	// The mesh path culls in its amplification shaders, so only the vertex fallback has the compute passes.
	if !s.mesh_path {
		p := render.add_compute_pass(&g, "reset draw count", reset_count, frame, queue = .Compute)
		render.copy_dest(&g, p, frame.draw_count)

		p = render.add_compute_pass(&g, "cull", cull_objects, frame, queue = .Compute)
		render.write(&g, p, frame.draw_count)
		render.write(&g, p, frame.arguments)
		render.write(&g, p, frame.visible)
	}

	p := render.add_render_pass(&g, "scene", draw_scene, frame, pieces = SCENE_PIECES)
	render.color(&g, p, frame.scene, .Clear, {0.02, 0.02, 0.035, 1})
	render.depth(&g, p, depth, .Clear, store = .Discard)
	render.read(&g, p, frame.checker)
	render.read(&g, p, frame.vertices)
	render.index_buffer(&g, p, frame.indices)
	if s.mesh_path {
		render.indirect_buffer(&g, p, frame.mesh_draw)
	} else {
		render.indirect_buffer(&g, p, frame.arguments)
		render.indirect_buffer(&g, p, frame.draw_count)
		render.read(&g, p, frame.visible)
	}

	building_blas := false
	if s.shadow_mode != .None {
		building_blas = add_shadow_passes(&g, frame)
	}

	p = render.add_compute_pass(&g, "post", run_post, frame)
	render.read(&g, p, frame.scene)
	render.write(&g, p, frame.post)
	if frame.shadows != 0 {
		render.read(&g, p, frame.shadows)
	}

	p = render.add_render_pass(&g, "composite", draw_composite, frame)
	render.read(&g, p, frame.post)
	render.color(&g, p, target, .Discard)

	if render.execute(&g) && building_blas {
		s.blas_built = true
	}
}

// extract_triangles writes the large triangles' instances for the scene pass and the acceleration structure:
// their poses relative to the camera, interpolated between the last two ticks, and their brightness.
extract_triangles :: proc(frame: ^Frame) {
	s := frame.state
	w := &s.world
	count := render.extract_count(w, s.triangles)
	triangles, ok := s.platform.gpu_upload(max(count, 1) * size_of(Triangle_Instance), 16)
	if !ok || count == 0 {
		return
	}
	camera, _ := ecs.presented(w, s.camera)
	chunks := render.extract(w, s.triangles, camera.position, triangles.data, size_of(Triangle_Instance))
	instances := ([^]Triangle_Instance)(raw_data(triangles.data))[:count]
	for c in chunks {
		for t, i in ecs.column(c.view, render.EXTRACT_TERMS, Triangle) {
			instances[c.first + i].brightness = t.brightness
		}
	}
	frame.triangles = triangles
	frame.triangle_count = count
}

// add_shadow_passes builds the acceleration structures and traces the shadow mask. The triangle's bottom-level
// structure is built in the first frame, and the top-level structure every frame from the instances' transforms.
// It returns true if it builds the bottom-level structure this frame.
add_shadow_passes :: proc(g: ^render.Graph, frame: ^Frame) -> (building_blas: bool) {
	s := frame.state
	frame.blas = render.import_accel(g, s.blas)
	frame.tlas = render.import_accel(g, s.tlas)
	if !s.blas_built {
		p := render.add_compute_pass(g, "build triangle", build_blas, frame)
		render.build_input(g, p, frame.vertices)
		render.build_input(g, p, frame.indices)
		render.build_accel(g, p, frame.blas)
		building_blas = true
	}

	count := min(frame.triangle_count, len(TRIANGLE_INSTANCES))
	instances, ok := s.platform.gpu_upload(len(TRIANGLE_INSTANCES) * size_of(gpu.Accel_Instance), 16)
	if !ok || count == 0 {
		return
	}
	records := ([^]gpu.Accel_Instance)(raw_data(instances.data))[:count]
	triangles := ([^]Triangle_Instance)(raw_data(frame.triangles.data))[:count]
	blas := s.platform.gpu_accel_reference(s.blas)
	for t, i in triangles {
		records[i] = gpu.accel_instance(t.rows, blas, id = u32(i), flags = {.Cull_Disable, .Force_Opaque})
	}
	frame.instances = instances

	p := render.add_compute_pass(g, "build scene", build_tlas, frame)
	render.build_input(g, p, frame.blas)
	render.build_accel(g, p, frame.tlas)

	frame.shadows = render.create_texture(g, {size = frame.size, format = .R16_Float, label = "shadows"})
	if s.shadow_mode == .Pipeline {
		p = render.add_ray_tracing_pass(g, "shadows", trace_shadows, frame)
	} else {
		p = render.add_compute_pass(g, "shadows", trace_shadows, frame)
	}
	render.read_accel(g, p, frame.tlas)
	render.write(g, p, frame.shadows)
	return
}

build_blas :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	gpu.cmd_build_accel(ctx.cb, render.gpu_accel(ctx.graph, frame.blas))
}

build_tlas :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	upload := frame.instances
	count := u32(min(frame.triangle_count, len(TRIANGLE_INSTANCES)))
	gpu.cmd_build_top_accel(ctx.cb, render.gpu_accel(ctx.graph, frame.tlas), upload.buffer, upload.offset, count)
}

trace_shadows :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	g, cb := ctx.graph, ctx.cb
	constants := Shadow_Constants {
		accel  = gpu.read_index(render.gpu_accel(g, frame.tlas)),
		output = gpu.write_index(render.gpu_texture(g, frame.shadows)),
		size   = frame.size,
	}
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.shadows)
	gpu.cmd_set_pass_constants(cb, frame.pass_constants)
	gpu.cmd_push_constants(cb, &constants)
	if frame.state.shadow_mode == .Pipeline {
		gpu.cmd_dispatch_rays(cb, {frame.size.x, frame.size.y, 1})
	} else {
		groups := (frame.size + SHADOW_GROUP_SIZE - 1) / SHADOW_GROUP_SIZE
		gpu.cmd_dispatch(cb, {groups.x, groups.y, 1})
	}
}

// reset_count zeroes the draw count with a copy from the upload ring.
reset_count :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	zero, ok := frame.state.platform.gpu_upload(size_of(u32), size_of(u32))
	if !ok {
		return
	}
	(^u32)(raw_data(zero.data))^ = 0
	gpu.cmd_copy_buffer(ctx.cb, zero.buffer, zero.offset, render.gpu_buffer(ctx.graph, frame.draw_count), 0, size_of(u32))
}

cull_objects :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	g, cb := ctx.graph, ctx.cb
	constants := Cull_Constants {
		arguments    = gpu.write_index(render.gpu_buffer(g, frame.arguments)),
		count        = gpu.write_index(render.gpu_buffer(g, frame.draw_count)),
		visible      = gpu.write_index(render.gpu_buffer(g, frame.visible)),
		object_count = OBJECT_COUNT,
		grid         = {OBJECT_COLUMNS, OBJECT_ROWS},
	}
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.cull)
	gpu.cmd_set_pass_constants(cb, frame.pass_constants)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_dispatch(cb, {(OBJECT_COUNT + CULL_GROUP_SIZE - 1) / CULL_GROUP_SIZE, 1, 1})
}

// draw_scene draws the large triangles in piece 0, and the objects in piece 1. Each piece starts with nothing bound.
draw_scene :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	g, cb := ctx.graph, ctx.cb
	vertices := gpu.read_index(render.gpu_buffer(g, frame.vertices))
	checker := gpu.read_index(render.gpu_texture(g, frame.checker))
	switch ctx.piece {
	case 0:
		if frame.triangle_count == 0 {
			return
		}
		constants := Scene_Constants {
			vertices        = vertices,
			texture         = checker,
			sampler         = gpu.sampler_index(frame.state.nearest),
			instances       = gpu.read_index(frame.triangles.buffer),
			instance_offset = frame.triangles.offset,
		}
		gpu.cmd_set_pipeline(cb, frame.state.pipelines.scene)
		gpu.cmd_set_pass_constants(cb, frame.pass_constants)
		gpu.cmd_push_constants(cb, &constants)
		gpu.cmd_set_index_buffer(cb, render.gpu_buffer(g, frame.indices), .U16)
		gpu.cmd_draw_indexed(cb, 3, instance_count = u32(frame.triangle_count))
	case 1:
		constants := Object_Constants {
			vertices     = vertices,
			texture      = checker,
			sampler      = gpu.sampler_index(frame.state.nearest),
			grid         = {OBJECT_COLUMNS, OBJECT_ROWS},
			object_count = OBJECT_COUNT,
		}
		if frame.state.mesh_path {
			gpu.cmd_set_pipeline(cb, frame.state.pipelines.mesh)
			gpu.cmd_set_pass_constants(cb, frame.pass_constants)
			gpu.cmd_push_constants(cb, &constants)
			gpu.cmd_draw_mesh_indirect(cb, render.gpu_buffer(g, frame.mesh_draw), 0, 1)
			return
		}
		constants.visible = gpu.read_index(render.gpu_buffer(g, frame.visible))
		gpu.cmd_set_pipeline(cb, frame.state.pipelines.objects)
		gpu.cmd_set_pass_constants(cb, frame.pass_constants)
		gpu.cmd_push_constants(cb, &constants)
		gpu.cmd_set_index_buffer(cb, render.gpu_buffer(g, frame.indices), .U16)
		gpu.cmd_draw_indexed_indirect(cb, render.gpu_buffer(g, frame.arguments), 0, OBJECT_COUNT, render.gpu_buffer(g, frame.draw_count))
	}
}

run_post :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	g, cb := ctx.graph, ctx.cb
	constants := Post_Constants {
		input  = gpu.read_index(render.gpu_texture(g, frame.scene)),
		output = gpu.write_index(render.gpu_texture(g, frame.post)),
		size   = frame.size,
	}
	if frame.shadows != 0 {
		constants.shadows = gpu.read_index(render.gpu_texture(g, frame.shadows))
		constants.has_shadows = 1
	}
	groups := (frame.size + POST_GROUP_SIZE - 1) / POST_GROUP_SIZE
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.post)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_dispatch(cb, {groups.x, groups.y, 1})
}

draw_composite :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	g, cb := ctx.graph, ctx.cb
	constants := Composite_Constants {
		input   = gpu.read_index(render.gpu_texture(g, frame.post)),
		sampler = gpu.sampler_index(frame.state.linear),
	}
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.composite)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_draw(cb, 3)
}

shutdown :: proc(state: rawptr) {
	s := (^Game_State)(state)
	script.destroy(&s.scripts)
	asset.destroy(&s.assets)
	ecs.destroy(&s.world)
	render.cache_destroy(&s.textures, s.platform)
	destroy_pipelines(s.platform, s.pipelines)
	s.platform.gpu_destroy_sampler(s.linear)
	s.platform.gpu_destroy_sampler(s.nearest)
	s.platform.gpu_destroy_accel(s.tlas)
	s.platform.gpu_destroy_accel(s.blas)
	s.platform.gpu_destroy_texture(s.rings)
	s.platform.gpu_destroy_texture(s.checker)
	s.platform.gpu_destroy_buffer(s.mesh_draw)
	s.platform.gpu_destroy_buffer(s.visible)
	s.platform.gpu_destroy_buffer(s.draw_count)
	s.platform.gpu_destroy_buffer(s.arguments)
	s.platform.gpu_destroy_buffer(s.indices)
	s.platform.gpu_destroy_buffer(s.vertices)
	log.info("mygame: shutdown")
}

// on_reload updates the pipelines, because the new DLL may embed new shaders. The old versions keep drawing until
// the new ones compile. An update that changes a pipeline's formats is refused, so that pipeline is created again.
on_reload :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	s.platform = platform
	ecs.reload(&s.world, platform)
	register_world(s)
	asset.reload(&s.assets, platform)
	script.reload(&s.scripts, platform, register_scripts)
	reload_graphics_pipeline(platform, &s.pipelines.scene, SCENE_PIPELINE)
	reload_graphics_pipeline(platform, &s.pipelines.objects, OBJECTS_PIPELINE)
	if s.mesh_path {
		reload_graphics_pipeline(platform, &s.pipelines.mesh, OBJECTS_MESH_PIPELINE)
	}
	reload_graphics_pipeline(platform, &s.pipelines.composite, COMPOSITE_PIPELINE)
	reload_compute_pipeline(platform, &s.pipelines.cull, CULL_PIPELINE)
	reload_compute_pipeline(platform, &s.pipelines.post, POST_PIPELINE)
	switch s.shadow_mode {
	case .None:
	case .Inline:
		reload_compute_pipeline(platform, &s.pipelines.shadows, SHADOWS_PIPELINE)
	case .Pipeline:
		if !platform.gpu_update_ray_tracing_pipeline(s.pipelines.shadows, SHADOWS_RT_PIPELINE) {
			platform.gpu_destroy_pipeline(s.pipelines.shadows)
			s.pipelines.shadows = platform.gpu_create_ray_tracing_pipeline(SHADOWS_RT_PIPELINE)
		}
	}
	log.infof("mygame: reloaded at frame %d", s.frame_count)
}

reload_graphics_pipeline :: proc(platform: ^core.Platform_API, pipeline: ^gpu.Pipeline, desc: gpu.Graphics_Pipeline_Desc) {
	if !platform.gpu_update_graphics_pipeline(pipeline^, desc) {
		platform.gpu_destroy_pipeline(pipeline^)
		pipeline^ = platform.gpu_create_graphics_pipeline(desc)
	}
}

reload_compute_pipeline :: proc(platform: ^core.Platform_API, pipeline: ^gpu.Pipeline, desc: gpu.Compute_Pipeline_Desc) {
	if !platform.gpu_update_compute_pipeline(pipeline^, desc) {
		platform.gpu_destroy_pipeline(pipeline^)
		pipeline^ = platform.gpu_create_compute_pipeline(desc)
	}
}

create_pipelines :: proc(platform: ^core.Platform_API, mesh_path: bool, shadow_mode: Shadow_Mode) -> Pipelines {
	shadows: gpu.Pipeline
	switch shadow_mode {
	case .None:
	case .Inline:
		shadows = platform.gpu_create_compute_pipeline(SHADOWS_PIPELINE)
	case .Pipeline:
		shadows = platform.gpu_create_ray_tracing_pipeline(SHADOWS_RT_PIPELINE)
	}
	return {
		scene = platform.gpu_create_graphics_pipeline(SCENE_PIPELINE),
		objects = platform.gpu_create_graphics_pipeline(OBJECTS_PIPELINE),
		mesh = mesh_path ? platform.gpu_create_graphics_pipeline(OBJECTS_MESH_PIPELINE) : {},
		cull = platform.gpu_create_compute_pipeline(CULL_PIPELINE),
		shadows = shadows,
		post = platform.gpu_create_compute_pipeline(POST_PIPELINE),
		composite = platform.gpu_create_graphics_pipeline(COMPOSITE_PIPELINE),
	}
}

SCENE_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	vertex        = TRIANGLE_VS,
	pixel         = TRIANGLE_PS,
	colors        = {{format = SCENE_FORMAT}},
	depth_format  = DEPTH_FORMAT,
	depth_compare = .Less,
	depth_write   = true,
	label         = "scene",
}

OBJECTS_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	vertex        = OBJECTS_VS,
	pixel         = OBJECTS_PS,
	colors        = {{format = SCENE_FORMAT}},
	depth_format  = DEPTH_FORMAT,
	depth_compare = .Less,
	depth_write   = true,
	label         = "objects",
}

OBJECTS_MESH_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	amplification = OBJECTS_AS,
	mesh          = OBJECTS_MS,
	pixel         = OBJECTS_PS,
	colors        = {{format = SCENE_FORMAT}},
	depth_format  = DEPTH_FORMAT,
	depth_compare = .Less,
	depth_write   = true,
	label         = "objects (mesh)",
}

CULL_PIPELINE :: gpu.Compute_Pipeline_Desc {
	compute = CULL_CS,
	label   = "cull",
}

SHADOWS_PIPELINE :: gpu.Compute_Pipeline_Desc {
	compute = SHADOWS_CS,
	label   = "shadows",
}

SHADOWS_RT_PIPELINE :: gpu.Ray_Tracing_Pipeline_Desc {
	library          = SHADOWS_RT_LIB,
	ray_generation   = "ray_generation",
	miss             = {"miss"},
	hit_groups       = {{name = "hit", closest_hit = "closest_hit"}},
	max_payload_size = 4,
	label            = "shadows (ray tracing pipeline)",
}

POST_PIPELINE :: gpu.Compute_Pipeline_Desc {
	compute = POST_CS,
	label   = "post",
}

COMPOSITE_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	vertex = COMPOSITE_VS,
	pixel  = COMPOSITE_PS,
	colors = {{format = gpu.FRAME_TARGET_FORMAT}},
	label  = "composite",
}

destroy_pipelines :: proc(platform: ^core.Platform_API, pipelines: Pipelines) {
	platform.gpu_destroy_pipeline(pipelines.scene)
	platform.gpu_destroy_pipeline(pipelines.objects)
	platform.gpu_destroy_pipeline(pipelines.mesh)
	platform.gpu_destroy_pipeline(pipelines.cull)
	platform.gpu_destroy_pipeline(pipelines.shadows)
	platform.gpu_destroy_pipeline(pipelines.post)
	platform.gpu_destroy_pipeline(pipelines.composite)
}

gpu_bytes :: proc(data: ^$T) -> []byte {
	return ([^]byte)(data)[:size_of(T)]
}

state_size :: proc() -> int {
	return size_of(Game_State)
}

// layout_hash covers the component layouts too: the world stores components as bytes, so Game_State's own layout
// does not show them.
layout_hash :: proc() -> u64 {
	components: ecs.Registry
	register_components(&components)
	hashes := [2]u64{layout.hash(Game_State), ecs.registry_layout_hash(&components)}
	return hash.fnv64a(slice.to_bytes(hashes[:]))
}

@(export)
cinnabar_game_api :: proc() -> core.Game_API {
	return {
		init = init,
		update = update,
		shutdown = shutdown,
		on_reload = on_reload,
		state_size = state_size,
		layout_hash = layout_hash,
		gpu_format_hash = gpu.format_hash,
	}
}
