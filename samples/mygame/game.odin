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
import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/project"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"
import "cinnabar:engine/volume"

// The shaders are assets, which the cooker compiles (see docs/content/kinds/shaders.md#shaders). The game finds them by the
// GUIDs in their .meta files.
TRIANGLE_SHADER :: #load("content/shaders/triangle.hlsl.meta", string)
OBJECTS_SHADER :: #load("content/shaders/objects.hlsl.meta", string)
CULL_SHADER :: #load("content/shaders/cull.hlsl.meta", string)
POST_SHADER :: #load("content/shaders/post.hlsl.meta", string)
LENS_SHADER :: #load("content/shaders/lens.hlsl.meta", string)
SHADOWS_SHADER :: #load("content/shaders/shadows.hlsl.meta", string)
SHADOWS_RT_SHADER :: #load("content/shaders/shadows_rt.hlsl.meta", string)
UI_SHADER :: #load("content/shaders/ui.hlsl.meta", string)
// The loose cache that `just scripts` cooks into. Release builds read the release cache until bundles exist.
CONTENT_CACHE :: #config(CINNABAR_CONTENT_CACHE, "build/cache/dev")
// The project's settings, which the editor edits, and the user's file beside them (see docs/overview/architecture.md#project-settings).
PROJECT_SETTINGS :: #config(CINNABAR_PROJECT, "samples/mygame/project.settings")
// How often the game looks for a change to the settings' files, in seconds.
PROJECT_CHECK_INTERVAL :: 0.5
// Content refers to content by GUID. The game reads the GUIDs of its main script and its scene from their .meta files.
HELLO_META :: #load("content/scripts/hello.luau.meta", string)
MAIN_SCENE_META :: #load("content/scenes/main.scene.meta", string)
// The transparency scene, which F7 switches to and back (see docs/rendering/transparency.md#transparency).
GLASS_SCENE_META :: #load("content/scenes/glass.scene.meta", string)

// Matches numthreads in content/shaders/post.hlsl.
POST_GROUP_SIZE :: 8
// Matches numthreads in content/shaders/cull.hlsl.
CULL_GROUP_SIZE :: 64
// Matches numthreads in content/shaders/shadows.hlsl.
SHADOW_GROUP_SIZE :: 8

// The large triangles cast ray-traced shadows. Ray_Tracing_Pipeline traces them with a ray tracing pipeline, and
// Ray_Query with inline ray tracing in a compute pass. Without either, there are no shadows.
Shadow_Mode :: enum u8 {
	None,
	Inline,
	Pipeline,
}

// The large triangles are the scene's entities with a Triangle, which the editor's Add Triangle command makes; the
// sample's own scene, a Cornell box, has none. Scenes are about 1 AU from the world origin. Fixed-point positions keep
// them exact there: the camera-relative transforms that the GPU sees are small. The acceleration structure holds at
// most this many.
MAX_TRIANGLES :: 2

// The GPU culls a grid of small objects every frame and draws the visible ones with one indirect draw. With mesh
// shaders, amplification shaders cull and mesh shaders draw. Without them, a compute pass on the compute queue culls
// and an indexed indirect draw draws: the vertex fallback. CINNABAR_DISABLE_FEATURES=Mesh_Shaders forces it.
OBJECT_COLUMNS :: 64
OBJECT_ROWS :: 36
OBJECT_COUNT :: OBJECT_COLUMNS * OBJECT_ROWS
// Matches OBJECTS_PER_GROUP in content/shaders/objects.hlsl.
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

// Matches Vertex in content/shaders/triangle.hlsl and shaders/objects.hlsl.
Vertex :: struct {
	position: [2]f32,
	uv:       [2]f32,
	color:    [4]f32,
}

// Matches Push in content/shaders/triangle.hlsl.
Scene_Constants :: struct {
	vertices:        u32,
	texture:         u32,
	sampler:         u32,
	instances:       u32,
	instance_offset: u32,
}

// Matches Instance in content/shaders/triangle.hlsl.
Triangle_Instance :: struct {
	rows:       [3][4]f32,
	brightness: f32,
	// The entity's value in the editor's ID buffer.
	id:         u32,
	_:          [2]f32,
}

// The game's components have explicit IDs, because the scene refers to them by ID (see docs/world/ecs.md#component-registry).
SPIN_ID :: ecs.Component_Id(1001)
TRIANGLE_ID :: ecs.Component_Id(1002)
LENS_ID :: ecs.Component_Id(1003)

// Spin turns an entity about the view axis, in radians per second.
Spin :: struct {
	speed: f32,
}

// Triangle marks one of the large triangles, with its HDR brightness.
Triangle :: struct {
	brightness: f32,
}

// Lens is the sample's post effect, on volumes (see docs/rendering/post-processing.md#post-effects): chromatic aberration and a
// vignette, from DEFAULT_LENS unless a volume overrides them.
Lens :: struct {
	// How far red and blue move apart toward the frame's edges, in pixels for each unit of the frame's size from its
	// center.
	chromatic_aberration: volume.Value(f32) `editor:"range=0,64"`,
	// How fast the vignette darkens toward the corners.
	vignette:             volume.Value(f32) `editor:"range=0,4"`,
}

DEFAULT_LENS :: Lens {
	chromatic_aberration = {value = 24},
	vignette = {value = 1.6},
}

// Matches Push in content/shaders/objects.hlsl.
Object_Constants :: struct {
	vertices:     u32,
	visible:      u32,
	texture:      u32,
	sampler:      u32,
	grid:         [2]u32,
	object_count: u32,
}

// Matches Push in content/shaders/cull.hlsl.
Cull_Constants :: struct {
	arguments:    u32,
	count:        u32,
	visible:      u32,
	object_count: u32,
	grid:         [2]u32,
}

// Matches Push in content/shaders/post.hlsl.
Post_Constants :: struct {
	input:       u32,
	output:      u32,
	size:        [2]u32,
	shadows:     u32,
	has_shadows: u32,
}

// Matches Push in content/shaders/lens.hlsl.
Lens_Constants :: struct {
	input:      u32,
	output:     u32,
	size:       [2]u32,
	aberration: f32,
	vignette:   f32,
	_:          [2]u32,
}

// Matches Push in content/shaders/shadows.hlsl.
Shadow_Constants :: struct {
	accel:  u32,
	output: u32,
	size:   [2]u32,
}

// Matches Push in content/shaders/ui.hlsl.
UI_Constants :: struct {
	origin:       [2]f32,
	size:         [2]f32,
	color:        [4]f32,
	accent:       [4]f32,
	radius:       f32,
	accent_width: f32,
}

// The HUD panel in the frame's top left corner, in pixels, and its colors as a designer picks them, sRGB-encoded. It
// shows the UI layer, which blends over the tone-mapped scene as encoded values.
HUD_ORIGIN :: [2]f32{16, 16}
HUD_SIZE :: [2]f32{240, 44}
HUD_COLOR :: [4]f32{0.08, 0.09, 0.12, 0.72}
HUD_ACCENT :: [4]f32{0.89, 0.26, 0.2, 1}

// The sample draws each spinning entity's axes into the debug layer, which shows them in exact colors, and faintly where
// the scene hides them.
DEBUG_AXES :: true
DEBUG_AXES_SIZE :: 0.25

// Matches Pass in content/shaders/pass.hlsli.
Pass_Constants :: struct {
	view_projection: matrix[4, 4]f32,
	right:           [4]f32,
	up:              [4]f32,
	forward:         [4]f32,
	time:            f32,
	aspect:          f32,
	tan_half_fov:    f32,
	near:            f32,
	exposure:        u32,
	padding:         [3]u32,
}

// Game_State is the root of all persistent game-side state. The host owns its memory.
Game_State :: struct {
	platform:           ^core.Platform_API,
	frame_count:        u64,
	// The project's settings, read again when their files change.
	project:            project.Watch,
	next_project_check: f64,
	// F8 cycles the output mode for this run, until the settings' files change.
	output_override:    Maybe(gpu.Output_Request),
	// F7 switches between the main scene and the glass scene.
	glass_scene:        bool,
	elapsed:            time.Duration,
	next_report:        time.Duration,
	pipelines:          Pipelines,
	// True when the device has mesh shaders and the objects take the mesh path.
	mesh_path:          bool,
	vertices:           gpu.Buffer,
	indices:            gpu.Buffer,
	// The cull pass writes these on the compute queue each frame, and the scene pass reads them.
	arguments:          gpu.Buffer,
	draw_count:         gpu.Buffer,
	visible:            gpu.Buffer,
	// The mesh path's one Draw_Mesh_Indirect_Args record.
	mesh_draw:          gpu.Buffer,
	shadow_mode:        Shadow_Mode,
	// The triangle, built once, and the two large triangles as its instances, built every frame.
	blas:               gpu.Accel_Struct,
	tlas:               gpu.Accel_Struct,
	blas_built:         bool,
	checker:            gpu.Texture,
	rings:              gpu.Texture,
	// Zero until the rings are streamed, and rings_ready once the transfer is done.
	rings_transfer:     gpu.Transfer,
	rings_ready:        bool,
	nearest:            gpu.Sampler,
	world:              ecs.World,
	// The scene's render.Camera entity. A new scene replaces it, so find_camera looks for it again.
	camera:             ecs.Entity,
	// The built-in renderer, which draws the frame (see docs/rendering/frame.md#frame).
	renderer:           render.Renderer,
	// A registration, created again in on_reload.
	triangles:          render.Extractor,
	assets:             asset.Assets,
	scripts:            script.Runtime,
	// content/scripts/hello.luau, which the scheduler runs.
	hello:              script.Main_Script,
	// What the editor knows of the world (see docs/editor/link.md#world).
	editor:             editor.Editor,
}

Pipelines :: struct {
	scene:     render.Shader_Pipeline,
	objects:   render.Shader_Pipeline,
	// Not created without mesh shaders.
	mesh:      render.Shader_Pipeline,
	cull:      render.Shader_Pipeline,
	// A compute pipeline when shadow_mode is Inline, a ray tracing pipeline when it is Pipeline, and not created
	// otherwise.
	shadows:   render.Shader_Pipeline,
	post:      render.Shader_Pipeline,
	lens:      render.Shader_Pipeline,
	ui:        render.Shader_Pipeline,
}

// Frame is what the pass procedures need. It lives in frame memory.
Frame :: struct {
	state:          ^Game_State,
	size:           [2]u32,
	view:           render.View,
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
	// The number of triangle instances. The acceleration structure holds at most MAX_TRIANGLES.
	triangle_count: int,
	checker:        render.Texture,
	// The renderer's scene color, which the post pass reads, and the post pass's, which replaces it.
	scene:          render.Texture,
	shadows:        render.Texture,
	post:           render.Texture,
	// The ray tracing pass built the triangle's acceleration structure.
	building_blas:  bool,
}

init :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	// Game_State is too large for a temporary on the stack, so it is zeroed in place.
	mem.zero_item(s)
	s.platform = platform
	editor.init(&s.editor, platform, &s.assets)
	register_editor_commands(s)

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
		s.tlas = platform.gpu_create_accel({kind = .Top, max_instances = MAX_TRIANGLES, label = "scene"})
	}
	s.pipelines = {
		scene     = render.shader_pipeline(TRIANGLE_SHADER),
		objects   = render.shader_pipeline(OBJECTS_SHADER),
		mesh      = render.shader_pipeline(OBJECTS_SHADER),
		cull      = render.shader_pipeline(CULL_SHADER),
		shadows   = render.shader_pipeline(s.shadow_mode == .Pipeline ? SHADOWS_RT_SHADER : SHADOWS_SHADER),
		post      = render.shader_pipeline(POST_SHADER),
		lens      = render.shader_pipeline(LENS_SHADER),
		ui        = render.shader_pipeline(UI_SHADER),
	}

	if !ecs.init(&s.world, platform) {
		log.panic("mygame: cannot create the world")
	}
	register_world(s)
	asset.init(&s.assets, platform, asset.loose_cache(CONTENT_CACHE))
	render.renderer_init(&s.renderer, platform, &s.assets, &s.world)
	register_post_effects(s)
	sync_pipelines(s)
	if !script.init(&s.scripts, platform, &s.world, &s.assets, register_scripts) {
		log.panic("mygame: cannot open the script VM")
	}
	if hello, ok := format.meta_guid(HELLO_META); ok {
		s.hello, _ = script.spawn_script(&s.scripts, hello)
	}
	// An editor replaces this scene with its own document when it links (see docs/editor/document-and-scenes.md#document-model).
	if main_scene, ok := format.meta_guid(MAIN_SCENE_META); ok {
		scene.load_asset(&s.world, &s.scripts, &s.assets, main_scene)
	}
	log.infof("mygame: init, objects on the %s path, shadows %v", s.mesh_path ? "mesh" : "vertex", s.shadow_mode)
}

// register_components registers every component type. init and on_reload call it on the world's registry, and
// layout_hash on its own, so a component change restarts the game.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_engine_components(r)
	render.register_components(r)
	script.register_components(r)
	scene.register_components(r)
	volume.register_components(r)
	ecs.register_component(r, Spin, SPIN_ID)
	ecs.register_component(r, Triangle, TRIANGLE_ID)
	ecs.register_component(r, Lens, LENS_ID, DEFAULT_LENS)
}

// register_post_effects adds the sample's lens to the post-processing, before tone mapping, where a volume with a Lens
// reaches the camera. init and on_reload call it after the renderer's.
register_post_effects :: proc(s: ^Game_State) {
	render.register_post_effect(&s.renderer, &s.world, "lens", .Before_Tone_Mapping, Lens, add_lens)
}

// Lens_Pass is the lens's pass, in frame memory.
Lens_Pass :: struct {
	frame:  ^Frame,
	lens:   Lens,
	input:  render.Texture,
	output: render.Texture,
}

add_lens :: proc(f: ^render.Frame, settings: rawptr) {
	frame := (^Frame)(f.data)
	if !render.pipeline_ready(f.renderer.platform, &frame.state.pipelines.lens) {
		return
	}
	g := f.graph
	pass := new(Lens_Pass, frame.state.platform.frame_allocator)
	pass^ = {
		frame  = frame,
		lens   = (^Lens)(settings)^,
		input  = f.scene,
		output = render.create_texture(g, {size = frame.size, format = render.SCENE_FORMAT, label = "lens"}),
	}
	p := render.add_compute_pass(g, "lens", run_lens, pass)
	render.read(g, p, pass.input)
	render.write(g, p, pass.output)
	f.scene = pass.output
}

run_lens :: proc(ctx: ^render.Pass_Context) {
	pass := (^Lens_Pass)(ctx.data)
	g, cb := ctx.graph, ctx.cb
	constants := Lens_Constants {
		input      = gpu.read_index(render.gpu_texture(g, pass.input)),
		output     = gpu.write_index(render.gpu_texture(g, pass.output)),
		size       = pass.frame.size,
		aberration = pass.lens.chromatic_aberration.value,
		vignette   = pass.lens.vignette.value,
	}
	groups := (pass.frame.size + POST_GROUP_SIZE - 1) / POST_GROUP_SIZE
	gpu.cmd_set_pipeline(cb, pass.frame.state.pipelines.lens.pipeline)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_dispatch(cb, {groups.x, groups.y, 1})
}

// register_world makes the world's registrations: components, systems and queries.
register_world :: proc(s: ^Game_State) {
	w := &s.world
	register_components(&w.registry)
	ecs.register_system(w, {name = "spin", stage = .Fixed, procedure = spin, terms = {ecs.write(w, ecs.Transform), ecs.read(w, Spin)}})
	s.triangles = render.extractor(w, {ecs.read(w, Triangle)})
}

// find_camera finds the scene's camera, after a scene load replaced the one that the game knew.
find_camera :: proc(s: ^Game_State) {
	if ecs.is_alive(&s.world, s.camera) {
		return
	}
	cameras := make([dynamic]ecs.Entity, s.platform.frame_allocator)
	ecs.collect(&s.world, {render.CAMERA_ID}, &cameras)
	s.camera = cameras[0] if len(cameras) > 0 else 0
}

// register_scripts defines the game's script bindings and exposes its components. init and on_reload call it.
register_scripts :: proc(r: ^script.Runtime) {
	script.expose(r, Spin)
	script.expose(r, Triangle)
	script.define(r, "Game.frame", proc(L: ^luau.State) -> c.int {
		luau.pushnumber(L, f64(game_of(L).frame_count))
		return 1
	}, "() -> number")
	script.define(r, "Game.greeting", proc(L: ^luau.State) -> c.int {
		luau.pushstring(L, "hello from Luau")
		return 1
	}, "() -> string")
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

	// In the editor's edit mode, and while it pauses, the world stands still and only its transforms propagate, so
	// edits show. No script code runs then, not even on_disable and on_destroy for the behaviours that a new scene
	// despawns (see docs/editor/document-and-scenes.md#modes).
	update_output(s)
	switch_scene(s)
	run, step := editor.simulation(&s.editor, &s.world, dt)
	script.set_quiet(&s.scripts, !run)
	if run {
		s.elapsed += step
		ecs.run_fixed(&s.world, step, s)
		ecs.run_stage(&s.world, .Update, step, s)
		// The script phase, with its structural changes (phases 5 and 6).
		script.run_phase(&s.scripts, step, s.platform.input())
		ecs.run_stage(&s.world, .Late, step, s)
	} else {
		ecs.update_transforms(&s.world)
		script.settle(&s.scripts)
	}

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

	find_camera(s)
	sync_pipelines(s)
	when DEBUG_AXES {
		draw_spin_axes(s)
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
	view := camera_view(s)
	aspect := f32(size.x) / f32(size.y)
	right, up, forward := render.view_axes(view)
	(^Pass_Constants)(raw_data(pass.data))^ = {
		view_projection = render.view_projection(view, aspect),
		right           = {right.x, right.y, right.z, 0},
		up              = {up.x, up.y, up.z, 0},
		forward         = {forward.x, forward.y, forward.z, 0},
		time            = f32(time.duration_seconds(s.elapsed)),
		aspect          = aspect,
		tan_half_fov    = math.tan(view.vertical_fov * 0.5),
		near            = view.near,
	}
	render_frame(s, {u32(size.x), u32(size.y)}, view, pass)
	return true
}

// draw_spin_axes draws the axes of each spinning entity into the debug layer.
draw_spin_axes :: proc(s: ^Game_State) {
	spinning := make([dynamic]ecs.Entity, s.platform.frame_allocator)
	ecs.collect(&s.world, {SPIN_ID}, &spinning)
	for e in spinning {
		if pose, ok := ecs.presented(&s.world, e); ok {
			debug.axes(&s.renderer.debug, pose, DEBUG_AXES_SIZE)
		}
	}
}

// camera_view is the editor's camera while an editor is linked, and the scene's camera otherwise.
camera_view :: proc(s: ^Game_State) -> render.View {
	if view, ok := editor.view(&s.editor); ok {
		return view
	}
	if view, ok := render.camera_view(&s.world, s.camera); ok {
		return view
	}
	return {rotation = 1, vertical_fov = render.DEFAULT_VERTICAL_FOV, near = render.DEFAULT_NEAR}
}

// end_frame swaps the blobs that the cooker rewrote, and reloads the scripts among them.
end_frame :: proc(s: ^Game_State) {
	script.reload_changed(&s.scripts, asset.poll(&s.assets))
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

// render_frame draws the frame with the built-in renderer, which draws the Mesh_Renderers, and adds the sample's own
// work through its hooks: the objects' culling on the compute queue, the triangles and the objects in the world pass,
// the ray-traced shadows and the post pass after it, the HUD panel in the UI layer, and the editor's tools in the
// debug layer. The render graph places the barriers between the passes and the waits between the queues.
render_frame :: proc(s: ^Game_State, size: [2]u32, view: render.View, pass_constants: gpu.Upload) {
	frame := new(Frame, s.platform.frame_allocator)
	frame^ = {
		state          = s,
		size           = size,
		view           = view,
		pass_constants = pass_constants,
	}
	extract_triangles(frame)
	editing := editor.active(&s.editor)
	// The editor's viewport settings and the shapes of lights, volumes and cameras (see docs/editor/viewport.md#viewport), or
	// none without an editor.
	overrides := editor.render_overrides(&s.editor)
	editor.draw_helpers(&s.editor, &s.world, &s.renderer.debug)
	desc := render.Frame_Desc {
		view            = view,
		size            = size,
		keep_ids        = editing,
		hidden          = editor.visibility(&s.editor, &s.world).hidden,
		debug_view      = overrides.debug_view,
		disable         = overrides.disable,
		exposure_offset = overrides.exposure_offset,
		// The material editor's previews (see docs/rendering/materials.md#material-previews).
		previews        = editor.previews(&s.editor),
		hooks           = {
			data         = frame,
			before_world = before_world,
			world_uses   = world_uses,
			world_draw   = draw_scene,
			world_pieces = SCENE_PIECES,
			after_world  = after_world,
			ui           = draw_ui_layer,
			debug        = editing ? draw_editor_tools : nil,
		},
	}
	if render.draw_frame(&s.renderer, &s.world, desc) && frame.building_blas {
		s.blas_built = true
	}
}

// before_world imports the sample's resources, and culls the objects on the compute queue. The mesh path culls in its
// amplification shaders, so only the vertex fallback has the compute passes.
before_world :: proc(f: ^render.Frame) {
	frame := (^Frame)(f.data)
	s := frame.state
	g := f.graph
	// The large triangles show the rings once they are streamed in.
	// The sample's own draws cover the same pixels as the renderer's, with its jitter, and pre-expose their colors.
	constants := (^Pass_Constants)(raw_data(frame.pass_constants.data))
	constants.view_projection = render.jittered_view_projection(f)
	constants.exposure = gpu.read_index(render.gpu_buffer(g, f.exposure))
	frame.checker = render.import_texture(g, s.rings_ready ? s.rings : s.checker, .Sampled)
	frame.vertices = render.import_buffer(g, s.vertices)
	frame.indices = render.import_buffer(g, s.indices)
	frame.arguments = render.import_buffer(g, s.arguments)
	frame.draw_count = render.import_buffer(g, s.draw_count)
	frame.visible = render.import_buffer(g, s.visible)
	if s.mesh_path {
		frame.mesh_draw = render.import_buffer(g, s.mesh_draw)
		return
	}
	p := render.add_compute_pass(g, "reset draw count", reset_count, frame, queue = .Compute)
	render.copy_dest(g, p, frame.draw_count)

	p = render.add_compute_pass(g, "cull", cull_objects, frame, queue = .Compute)
	render.write(g, p, frame.draw_count)
	render.write(g, p, frame.arguments)
	render.write(g, p, frame.visible)
}

// world_uses declares what draw_scene reads in the world pass.
world_uses :: proc(f: ^render.Frame, p: render.Pass) {
	frame := (^Frame)(f.data)
	g := f.graph
	render.read(g, p, frame.checker)
	render.read(g, p, frame.vertices)
	render.index_buffer(g, p, frame.indices)
	if frame.state.mesh_path {
		render.indirect_buffer(g, p, frame.mesh_draw)
	} else {
		render.indirect_buffer(g, p, frame.arguments)
		render.indirect_buffer(g, p, frame.draw_count)
		render.read(g, p, frame.visible)
	}
}

// after_world traces the triangles' shadows, and multiplies them into a new scene color, before temporal AA.
after_world :: proc(f: ^render.Frame) {
	frame := (^Frame)(f.data)
	s := frame.state
	g := f.graph
	frame.scene = f.scene
	if s.shadow_mode != .None {
		frame.building_blas = add_shadow_passes(g, frame)
	}
	frame.post = render.create_texture(g, {size = frame.size, format = render.SCENE_FORMAT, label = "post"})
	p := render.add_compute_pass(g, "post", run_post, frame)
	render.read(g, p, frame.scene)
	render.write(g, p, frame.post)
	if frame.shadows != 0 {
		render.read(g, p, frame.shadows)
	}
	f.scene = frame.post
}

// draw_ui_layer draws the HUD panel into the UI layer.
draw_ui_layer :: proc(f: ^render.Frame) {
	p := render.add_render_pass(f.graph, "hud", draw_hud, f.data)
	render.color(f.graph, p, f.ui, .Load)
}

draw_hud :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	constants := UI_Constants {
		origin       = HUD_ORIGIN,
		size         = HUD_SIZE,
		color        = HUD_COLOR,
		accent       = HUD_ACCENT,
		radius       = 8,
		accent_width = 6,
	}
	gpu.cmd_set_pipeline(ctx.cb, frame.state.pipelines.ui.pipeline)
	gpu.cmd_push_constants(ctx.cb, &constants)
	gpu.cmd_draw(ctx.cb, 3)
}

// draw_editor_tools adds the editor's pick and its outline and gizmo, which draw into the debug layer.
draw_editor_tools :: proc(f: ^render.Frame) {
	s := (^Frame)(f.data).state
	editor.add_viewport_passes(&s.editor, f.graph, &s.world, {view = f.view, size = f.size, target = f.debug, ids = f.ids, depth = f.depth})
}

// extract_triangles writes the large triangles' instances for the scene pass and the acceleration structure:
// their poses relative to the camera, interpolated between the last two ticks, their brightness and their IDs.
extract_triangles :: proc(frame: ^Frame) {
	s := frame.state
	w := &s.world
	count := render.extract_count(w, s.triangles)
	triangles, ok := s.platform.gpu_upload(max(count, 1) * size_of(Triangle_Instance), 16)
	if !ok || count == 0 {
		return
	}
	chunks := render.extract(w, s.triangles, frame.view.position, triangles.data, size_of(Triangle_Instance))
	instances := ([^]Triangle_Instance)(raw_data(triangles.data))[:count]
	// The triangles that the editor hides are left out, and the others close up behind them.
	visibility := editor.visibility(&s.editor, w)
	kept := 0
	for c in chunks {
		entities := ecs.entities(c.view)
		for t, i in ecs.column(c.view, render.EXTRACT_TERMS, Triangle) {
			if !editor.is_visible(visibility, entities[i]) {
				continue
			}
			instance := instances[c.first + i]
			instance.brightness = t.brightness
			instance.id = editor.entity_id(entities[i])
			instances[kept] = instance
			kept += 1
		}
	}
	count = kept
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

	count := min(frame.triangle_count, MAX_TRIANGLES)
	instances, ok := s.platform.gpu_upload(MAX_TRIANGLES * size_of(gpu.Accel_Instance), 16)
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
	count := u32(min(frame.triangle_count, MAX_TRIANGLES))
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
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.shadows.pipeline)
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
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.cull.pipeline)
	gpu.cmd_set_pass_constants(cb, frame.pass_constants)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_dispatch(cb, {(OBJECT_COUNT + CULL_GROUP_SIZE - 1) / CULL_GROUP_SIZE, 1, 1})
}

// draw_scene draws the large triangles in piece 0, and the objects in piece 1. Each piece starts with nothing bound.
draw_scene :: proc(f: ^render.Frame, ctx: ^render.Pass_Context) {
	frame := (^Frame)(f.data)
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
		gpu.cmd_set_pipeline(cb, frame.state.pipelines.scene.pipeline)
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
			gpu.cmd_set_pipeline(cb, frame.state.pipelines.mesh.pipeline)
			gpu.cmd_set_pass_constants(cb, frame.pass_constants)
			gpu.cmd_push_constants(cb, &constants)
			gpu.cmd_draw_mesh_indirect(cb, render.gpu_buffer(g, frame.mesh_draw), 0, 1)
			return
		}
		constants.visible = gpu.read_index(render.gpu_buffer(g, frame.visible))
		gpu.cmd_set_pipeline(cb, frame.state.pipelines.objects.pipeline)
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
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.post.pipeline)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_dispatch(cb, {groups.x, groups.y, 1})
}

shutdown :: proc(state: rawptr) {
	s := (^Game_State)(state)
	editor.destroy(&s.editor)
	script.destroy(&s.scripts)
	render.renderer_destroy(&s.renderer)
	asset.destroy(&s.assets)
	ecs.destroy(&s.world)
	destroy_pipelines(s.platform, &s.pipelines)
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

// update_output asks for the output mode and the render quality of the project's settings, and reads them again when
// their files change, so the editor's change shows at once. F8 cycles the mode for this run.
update_output :: proc(s: ^Game_State) {
	now := s.platform.time_seconds()
	changed := false
	if now >= s.next_project_check {
		s.next_project_check = now + PROJECT_CHECK_INTERVAL
		if project.refresh(&s.project, s.platform, PROJECT_SETTINGS) {
			changed = true
			s.output_override = nil
			render.set_quality(&s.renderer, project.quality(s.project.settings, s.renderer.caps))
		}
	}
	update_quality(s)
	if .F8 in s.platform.input().pressed {
		current := s.output_override.? or_else s.project.settings.output
		next := gpu.Output_Request((int(current) + 1) % len(gpu.Output_Request))
		s.output_override = next
		changed = true
		log.infof("mygame: output %v until the project's settings change (F8 cycles it)", next)
	}
	if changed {
		s.platform.gpu_request_output(s.output_override.? or_else s.project.settings.output)
	}
}

// update_quality changes the render quality, as a game's settings menu would, and saves it to the user's settings
// file, from which update_output reads it back (see docs/rendering/quality.md#quality): F9 takes the next preset, and
// Shift+F9 turns traced shadows on or off.
update_quality :: proc(s: ^Game_State) {
	input := s.platform.input()
	if .F9 not_in input.pressed {
		return
	}
	caps := s.renderer.caps
	q := s.renderer.quality
	if .Left_Shift in input.down || .Right_Shift in input.down {
		q.shadows.ray_traced = !q.shadows.ray_traced
	} else {
		preset := render.quality_preset(q, caps)
		next := preset >= .Ultra ? render.Quality_Preset.Low : render.Quality_Preset(int(preset) + 1)
		q = render.preset_quality(next, caps)
	}
	render.set_quality(&s.renderer, q)
	q = s.renderer.quality
	log.infof("mygame: quality %v, traced shadows %v (F9 takes the next preset, Shift+F9 turns traced shadows on or off)", render.quality_preset(q, caps), q.shadows.ray_traced)
	project.save_quality(s.platform, PROJECT_SETTINGS, q, caps)
}

// switch_scene loads the glass scene, or the main scene again, when F7 is pressed. A linked editor owns the scene, so
// the key does nothing then.
switch_scene :: proc(s: ^Game_State) {
	if .F7 not_in s.platform.input().pressed || editor.active(&s.editor) {
		return
	}
	s.glass_scene = !s.glass_scene
	if guid, ok := format.meta_guid(s.glass_scene ? GLASS_SCENE_META : MAIN_SCENE_META); ok {
		scene.load_asset(&s.world, &s.scripts, &s.assets, guid)
		log.infof("mygame: the %s scene (F7 switches it)", s.glass_scene ? "glass" : "main")
	}
}

// on_reload updates the pipelines, because the new DLL may describe them differently. The old versions keep drawing
// until the new ones compile.
on_reload :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	s.platform = platform
	ecs.reload(&s.world, platform)
	register_world(s)
	render.renderer_reload(&s.renderer, platform, &s.world)
	register_post_effects(s)
	asset.reload(&s.assets, platform)
	script.reload(&s.scripts, platform, register_scripts)
	editor.reload(&s.editor, platform)
	register_editor_commands(s)
	sync_pipelines(s, force = true)
	log.infof("mygame: reloaded at frame %d", s.frame_count)
}

// sync_pipelines creates the pipelines from their shader assets, and updates each one whose shader the cooker
// compiled again, so a shader change shows in the next frame without a code reload. force updates them all.
sync_pipelines :: proc(s: ^Game_State, force := false) {
	p, platform, assets := &s.pipelines, s.platform, &s.assets
	render.sync_graphics_pipeline(&p.scene, platform, assets, {.Vertex, .Pixel}, SCENE_PIPELINE, force)
	render.sync_graphics_pipeline(&p.objects, platform, assets, {.Vertex, .Pixel}, OBJECTS_PIPELINE, force)
	if s.mesh_path {
		render.sync_graphics_pipeline(&p.mesh, platform, assets, {.Amplification, .Mesh, .Pixel}, OBJECTS_MESH_PIPELINE, force)
	}
	render.sync_compute_pipeline(&p.cull, platform, assets, CULL_PIPELINE, force)
	render.sync_compute_pipeline(&p.post, platform, assets, POST_PIPELINE, force)
	render.sync_compute_pipeline(&p.lens, platform, assets, LENS_PIPELINE, force)
	render.sync_graphics_pipeline(&p.ui, platform, assets, {.Vertex, .Pixel}, UI_PIPELINE, force)
	switch s.shadow_mode {
	case .None:
	case .Inline:
		render.sync_compute_pipeline(&p.shadows, platform, assets, SHADOWS_PIPELINE, force)
	case .Pipeline:
		render.sync_ray_tracing_pipeline(&p.shadows, platform, assets, SHADOWS_RT_PIPELINE, force)
	}
}


SCENE_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors        = render.WORLD_COLORS,
	depth_format  = render.DEPTH_FORMAT,
	stencil       = render.WORLD_STENCIL,
	depth_compare = .Greater,
	depth_write   = true,
	label         = "scene",
}

OBJECTS_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors        = render.WORLD_COLORS,
	depth_format  = render.DEPTH_FORMAT,
	stencil       = render.WORLD_STENCIL,
	depth_compare = .Greater,
	depth_write   = true,
	label         = "objects",
}

OBJECTS_MESH_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors        = render.WORLD_COLORS,
	depth_format  = render.DEPTH_FORMAT,
	stencil       = render.WORLD_STENCIL,
	depth_compare = .Greater,
	depth_write   = true,
	label         = "objects (mesh)",
}

CULL_PIPELINE :: gpu.Compute_Pipeline_Desc {
	label   = "cull",
}

SHADOWS_PIPELINE :: gpu.Compute_Pipeline_Desc {
	label   = "shadows",
}

SHADOWS_RT_PIPELINE :: gpu.Ray_Tracing_Pipeline_Desc {
	ray_generation   = "ray_generation",
	miss             = {"miss"},
	hit_groups       = {{name = "hit", closest_hit = "closest_hit"}},
	max_payload_size = 4,
	label            = "shadows (ray tracing pipeline)",
}

POST_PIPELINE :: gpu.Compute_Pipeline_Desc {
	label   = "post",
}

LENS_PIPELINE :: gpu.Compute_Pipeline_Desc {
	label   = "lens",
}

// The HUD panel, blended into the UI layer.
UI_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors = {{format = render.UI_FORMAT, blend = .Premultiplied}},
	label  = "hud",
}

destroy_pipelines :: proc(platform: ^core.Platform_API, pipelines: ^Pipelines) {
	render.destroy_shader_pipeline(&pipelines.scene, platform)
	render.destroy_shader_pipeline(&pipelines.objects, platform)
	render.destroy_shader_pipeline(&pipelines.mesh, platform)
	render.destroy_shader_pipeline(&pipelines.cull, platform)
	render.destroy_shader_pipeline(&pipelines.shadows, platform)
	render.destroy_shader_pipeline(&pipelines.post, platform)
	render.destroy_shader_pipeline(&pipelines.lens, platform)
	render.destroy_shader_pipeline(&pipelines.ui, platform)
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

// script_types writes the scripts' definition file from a world and a script runtime of its own, so it makes no
// game state and no GPU resources.
script_types :: proc(platform: ^core.Platform_API) -> string {
	world := new(ecs.World, platform.permanent_allocator)
	if !ecs.init(world, platform) {
		log.panic("mygame: cannot create a world for the script types")
	}
	defer ecs.destroy(world)
	register_components(&world.registry)
	r := new(script.Runtime, platform.permanent_allocator)
	if !script.init(r, platform, world, nil, register_scripts) {
		log.panic("mygame: cannot open a script VM for the script types")
	}
	defer script.destroy(r)
	return script.definitions(r, platform.permanent_allocator)
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
		script_types = script_types,
		editor_poll = editor_poll,
	}
}

// register_editor_commands describes the game's commands, which the editor shows on its Game tab (see
// docs/editor/shell-and-panels.md#commands). init and on_reload call it.
register_editor_commands :: proc(s: ^Game_State) {
	editor.register_command(&s.editor, {
		id = "mygame.add_triangle",
		label = "Add Triangle",
		description = "Add a spinning triangle 2 m in front of the editor's camera.",
		tab = "Game",
		group = "Triangles",
		icon = "add",
		edits = true,
		procedure = add_triangle,
	})
	editor.register_command(&s.editor, {
		id = "mygame.reverse_spin",
		label = "Reverse Spin",
		description = "Turn the selected triangles the other way.",
		tab = "Game",
		group = "Triangles",
		icon = "rotate",
		edits = true,
		procedure = reverse_spin,
	})
	editor.register_command(&s.editor, {
		id = "mygame.world_report",
		label = "World Report",
		description = "Write the number of entities and triangles to the console.",
		tab = "Game",
		group = "Debug",
		icon = "stats",
		procedure = world_report,
	})
}

// add_triangle creates an entity with the triangle's components, as an operation, so the editor can undo it.
add_triangle :: proc(ctx: ^editor.Command_Context) {
	c := ctx.camera
	rotation := quaternion(x = c.rotation.x, y = c.rotation.y, z = c.rotation.z, w = c.rotation.w)
	forward := linalg.quaternion128_mul_vector3(rotation, [3]f32{0, 0, 1})
	position := ecs.position_offset({c.position}, forward * 2)
	id := editor.new_scene_id()
	triangle := link.Scene_Entity {
		id     = id,
		name   = "Triangle",
		active = true,
		components = slice.clone([]link.Scene_Component{
			{
				id = u64(ecs.TRANSFORM_ID),
				name = "Transform",
				fields = slice.clone([]link.Scene_Field{
					editor.scene_field("position", editor.scene_position(position)),
					editor.scene_field("rotation", editor.scene_numbers(0, 0, 0, 1)),
					editor.scene_field("scale", editor.scene_numbers(1, 1, 1)),
				}),
			},
			{id = u64(ecs.PREVIOUS_TRANSFORM_ID), name = "Previous_Transform"},
			{id = u64(SPIN_ID), name = "Spin", fields = slice.clone([]link.Scene_Field{editor.scene_field("speed", editor.scene_numbers(1))})},
			{id = u64(TRIANGLE_ID), name = "Triangle", fields = slice.clone([]link.Scene_Field{editor.scene_field("brightness", editor.scene_numbers(2))})},
		}),
	}
	append(&ctx.operations, link.Operation{kind = .Create_Entity, entity = id, created = slice.clone([]link.Scene_Entity{triangle})})
}

// reverse_spin sets the negated speed of each selected entity that spins.
reverse_spin :: proc(ctx: ^editor.Command_Context) {
	for entity in ctx.selection {
		id := editor.scene_id(ctx.world, entity)
		if spin := ecs.get(ctx.world, entity, Spin); spin != nil && id != 0 {
			field := editor.scene_field("speed", editor.scene_numbers(f64(-spin.speed)))
			append(&ctx.operations, link.Operation{kind = .Set_Field, entity = id, component = u64(SPIN_ID), fields = slice.clone([]link.Scene_Field{field})})
		}
	}
	if len(ctx.operations) == 0 {
		ctx.message = "mygame: select a triangle of the scene to reverse its spin"
	}
}

// world_report counts, and changes nothing.
world_report :: proc(ctx: ^editor.Command_Context) {
	s := (^Game_State)(ctx.user)
	ctx.message = fmt.aprintf("mygame: %d entities, %d triangles, frame %d", ecs.entity_count(ctx.world), render.extract_count(ctx.world, s.triangles), s.frame_count, allocator = ctx.allocator)
}

editor_poll :: proc(state: rawptr, connection: u64, incoming: []core.Editor_Message, out: ^[dynamic]byte) {
	s := (^Game_State)(state)
	editor.poll(&s.editor, &s.world, &s.scripts, connection, incoming, out, s)
}
