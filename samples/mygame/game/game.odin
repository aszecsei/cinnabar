// mygame, the sample that exercises most of the engine. The standard game runs it (see docs/world/game-package.md), and
// these hooks add the sample's own: its components and their system, its bindings, its editor commands, its triangles
// and their ray-traced shadows, its post pass and lens, and the F7 and F8 keys.
package mygame

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/luau"
import "cinnabar:engine/audio"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/game"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"
import "cinnabar:engine/volume"

// The shaders are assets, which the cooker compiles (see docs/content/kinds/shaders.md#shaders). The game finds them by the
// GUIDs in their .meta files.
TRIANGLE_SHADER :: #load("../content/shaders/triangle.hlsl.meta", string)
POST_SHADER :: #load("../content/shaders/post.hlsl.meta", string)
LENS_SHADER :: #load("../content/shaders/lens.hlsl.meta", string)
SHADOWS_SHADER :: #load("../content/shaders/shadows.hlsl.meta", string)
SHADOWS_RT_SHADER :: #load("../content/shaders/shadows_rt.hlsl.meta", string)
// Content refers to content by GUID. The game reads the GUIDs of its main script and its scenes from their .meta files.
// The settings' game.main_scene names the main scene, which the standard game loads, and F7 cycles from it.
HELLO_META :: #load("../content/scripts/hello.luau.meta", string)
MAIN_SCENE_META :: #load("../content/scenes/main.scene.meta", string)
// The sample's scenes are 1.5e11 m from the origin, to test large worlds, so the physics world is anchored there: its
// broad phase is f32, which would have a resolution of 16 km so far out (see docs/physics/design.md#positions-and-precision).
PHYSICS_ANCHOR :: ecs.World_Position{raw = {2516582400000000000, 0, 0}}
// The transparency scene, which F7 switches to and back (see docs/rendering/transparency.md#transparency).
GLASS_SCENE_META :: #load("../content/scenes/glass.scene.meta", string)
// The patch surfaces scene, a lake with an island (see docs/rendering/surfaces.md#surfaces).
SURFACES_SCENE_META :: #load("../content/scenes/surfaces.scene.meta", string)
// The room scene, a room built as a .mesh file (see docs/content/kinds/meshes.md#mesh-files).
ROOM_SCENE_META :: #load("../content/scenes/room.scene.meta", string)
// The billboards scene, sprites, foliage cards and towers that draw as impostors far away (see
// docs/rendering/gpu-scene.md#billboards).
BILLBOARDS_SCENE_META :: #load("../content/scenes/billboards.scene.meta", string)
// The animation scene, two skinned foxes that play their clips (see docs/content/kinds/skins-and-animations.md#playback).
ANIMATION_SCENE_META :: #load("../content/scenes/animation.scene.meta", string)
// The cube map scene, a sphere under a Texture sky whose texture is a cube map (see docs/rendering/sky.md#texture).
CUBE_SKY_SCENE_META :: #load("../content/scenes/cube_sky.scene.meta", string)
// The audio scene, a hum that moves behind a wall, over a long sound that streams (see docs/audio/design.md#the-sample).
AUDIO_SCENE_META :: #load("../content/scenes/audio.scene.meta", string)
// The 2D scene, sprites under an orthographic camera (see docs/rendering/2d.md#sprite-renderers).
SPRITES_SCENE_META :: #load("../content/scenes/sprites.scene.meta", string)
// The playground, a character to walk around with a follow camera (see docs/physics/design.md#characters).
PLAYGROUND_SCENE_META :: #load("../content/scenes/playground.scene.meta", string)
// The doorway, twenty agents that cross a room through a doorway and back (see docs/ai/navigation.md#crowds).
DOORWAY_SCENE_META :: #load("../content/scenes/doorway.scene.meta", string)
// The guard scene: a fox guard that patrols, chases and barks at the player that it sees, and searches where it lost
// them, with a behavior tree that H swaps to an HTN, and a wary agent with a utility decision (see
// docs/ai/README.md#the-sample).
GUARD_SCENE_META :: #load("../content/scenes/guard.scene.meta", string)
// The array that tints the large triangles, a layer for each (see docs/content/kinds/textures.md#cube-maps-and-arrays).
TRIANGLE_TINTS_META :: #load("../content/textures/cube/tints.texture_set.meta", string)

// Matches numthreads in content/shaders/post.hlsl.
POST_GROUP_SIZE :: 8
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

CHECKER_SIZE :: 64
CHECKER_CELL :: 8

// A texture of rings streams in on the copy queue after STREAM_FRAME frames, and then replaces the checker on the
// large triangles.
RINGS_SIZE :: 256
RINGS_MIPS :: 9
STREAM_FRAME :: 60

// Matches Vertex in content/shaders/triangle.hlsl.
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
	// The array of tints, and its layers, or 0 until it is resident.
	tints:           u32,
	tint_layers:     u32,
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

// State is the sample's own state, which follows the standard game's (see game.user). The host owns its memory.
State :: struct {
	// F8 cycles the output mode for this run, until the settings' files change.
	output_override:    Maybe(gpu.Output_Request),
	// F7 cycles the main scene, the glass scene, the surfaces scene, the room scene, the billboards scene, the animation
	// scene, the cube map scene, the audio scene and the 2D scene.
	scene_index:        u8,
	next_report:        time.Duration,
	pipelines:          Pipelines,
	vertices:           gpu.Buffer,
	indices:            gpu.Buffer,
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
	// A registration, created again in on_reload.
	triangles:          render.Extractor,
	// content/scripts/hello.luau, which the scheduler runs.
	hello:              script.Main_Script,
}

Pipelines :: struct {
	scene:     render.Shader_Pipeline,
	// A compute pipeline when shadow_mode is Inline, a ray tracing pipeline when it is Pipeline, and not created
	// otherwise.
	shadows:   render.Shader_Pipeline,
	post:      render.Shader_Pipeline,
	lens:      render.Shader_Pipeline,
}

// Frame is what the pass procedures need for one view of the frame. The renderer runs the hooks once for each view, with
// the same data, so the sample makes a Frame in the first hook of a view and keeps it in render.Frame.user. It lives in
// frame memory.
Frame :: struct {
	game:           ^game.Game,
	state:          ^State,
	// The scene's size, at the quality's render scale.
	size:           [2]u32,
	view:           render.View,
	pass_constants: gpu.Upload,
	vertices:       render.Buffer,
	indices:        render.Buffer,
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
}

// hooks are the sample's additions to the standard game.
hooks :: proc() -> game.Hooks {
	return {
		State = State,
		physics_anchor = PHYSICS_ANCHOR,
		register_components = register_components,
		register_world = register_world,
		register_scripts = register_scripts,
		register = register,
		init = init,
		shutdown = shutdown,
		on_reload = on_reload,
		settings_changed = settings_changed,
		begin_frame = begin_frame,
		update = update,
		frame = frame,
		tone_pan = tone_pan,
	}
}

@(export)
cinnabar_game_api :: proc() -> core.Game_API {
	return game.api(hooks)
}

// state_of is the sample's state.
state_of :: proc(g: ^game.Game) -> ^State {
	return game.user(g, State)
}

// frame_of is the sample's data for the view that a hook is drawing.
frame_of :: proc(f: ^render.Frame) -> ^Frame {
	return (^Frame)(f.user)
}

// init makes the sample's GPU resources and pipelines and runs its main script, after the standard game started and
// before it loads the main scene.
init :: proc(g: ^game.Game) {
	s, platform := state_of(g), g.platform
	vertices := [3]Vertex {
		{{0, 0.6}, {0.5, 0}, {1, 0.3, 0.3, 1}},
		{{0.52, -0.3}, {1, 1}, {0.3, 1, 0.3, 1}},
		{{-0.52, -0.3}, {0, 1}, {0.3, 0.3, 1, 1}},
	}
	// Buffer sizes are multiples of 4, so the three u16 indices have one u16 of padding.
	indices := [4]u16{0, 1, 2, 0}
	s.vertices = platform.gpu_create_buffer({size = size_of(vertices), label = "triangle vertices"}, gpu_bytes(&vertices))
	s.indices = platform.gpu_create_buffer({size = size_of(indices), usage = {.Index}, label = "triangle indices"}, gpu_bytes(&indices))

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
		scene   = render.shader_pipeline(TRIANGLE_SHADER),
		shadows = render.shader_pipeline(s.shadow_mode == .Pipeline ? SHADOWS_RT_SHADER : SHADOWS_SHADER),
		post    = render.shader_pipeline(POST_SHADER),
		lens    = render.shader_pipeline(LENS_SHADER),
	}
	sync_pipelines(g)
	if hello, ok := format.meta_guid(HELLO_META); ok {
		s.hello, _ = script.spawn_script(&g.scripts, hello)
	}
	log.infof("mygame: init, shadows %v", s.shadow_mode)
}

// register_components registers the sample's component types, after the engine's.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Spin, SPIN_ID)
	ecs.register_component(r, Triangle, TRIANGLE_ID)
	ecs.register_component(r, Lens, LENS_ID, DEFAULT_LENS)
}

// register adds the sample's lens to the post-processing, before tone mapping, where a volume with a Lens reaches the
// camera, and describes its editor commands. init and on_reload call it after the renderer's and the editor's.
register :: proc(g: ^game.Game) {
	render.register_post_effect(&g.renderer, &g.world, "lens", .Before_Tone_Mapping, Lens, add_lens)
	register_editor_commands(g)
}

// Lens_Pass is the lens's pass, in frame memory.
Lens_Pass :: struct {
	state:  ^State,
	lens:   Lens,
	// The scene's size there, which temporal AA may have upscaled.
	size:   [2]u32,
	input:  render.Texture,
	output: render.Texture,
}

add_lens :: proc(f: ^render.Frame, settings: rawptr) {
	s := state_of((^game.Game)(f.data))
	if !render.pipeline_ready(f.renderer.platform, &s.pipelines.lens) {
		return
	}
	g := f.graph
	pass := new(Lens_Pass, f.renderer.platform.frame_allocator)
	pass^ = {
		state  = s,
		lens   = (^Lens)(settings)^,
		size   = f.scene_size,
		input  = f.scene,
		output = render.create_texture(g, {size = f.scene_size, format = render.SCENE_FORMAT, label = "lens"}),
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
		size       = pass.size,
		aberration = pass.lens.chromatic_aberration.value,
		vignette   = pass.lens.vignette.value,
	}
	groups := (pass.size + POST_GROUP_SIZE - 1) / POST_GROUP_SIZE
	gpu.cmd_set_pipeline(cb, pass.state.pipelines.lens.pipeline)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_dispatch(cb, {groups.x, groups.y, 1})
}

// register_world makes the sample's registrations in the world: its system and its query.
register_world :: proc(g: ^game.Game) {
	w, s := &g.world, state_of(g)
	ecs.register_system(w, {name = "spin", stage = .Fixed, procedure = spin, terms = {ecs.write(w, ecs.Transform), ecs.read(w, Spin)}})
	s.triangles = render.extractor(w, {ecs.read(w, Triangle)})
}

// register_scripts exposes the sample's components and defines its bindings, after the engine's.
register_scripts :: proc(r: ^script.Runtime) {
	script.expose(r, Spin)
	script.expose(r, Triangle)
	script.define(r, "Game.frame", proc(L: ^luau.State) -> c.int {
		luau.pushnumber(L, f64(game.game_of(L).frame_count))
		return 1
	}, "() -> number")
	script.define(r, "Game.greeting", proc(L: ^luau.State) -> c.int {
		luau.pushstring(L, "hello from Luau")
		return 1
	}, "() -> string")
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

// begin_frame takes the F7 and F8 keys, before the world steps.
begin_frame :: proc(g: ^game.Game) {
	update_output(g)
	switch_scene(g)
}

// update reports the frame in the window's title, streams the rings in, updates the pipelines whose shaders changed and
// draws the spinning entities' axes, after the world stepped.
update :: proc(g: ^game.Game, run: bool) {
	s := state_of(g)
	if g.elapsed >= s.next_report {
		s.next_report += time.Second
		title := fmt.aprintf("mygame | frame %d | %.1fs", g.frame_count, time.duration_seconds(g.elapsed), allocator = g.platform.frame_allocator)
		g.platform.set_window_title(title)
	}

	if g.frame_count == STREAM_FRAME {
		stream_rings(g)
	}
	if s.rings_transfer != 0 && !s.rings_ready && g.platform.gpu_transfer_done(s.rings_transfer) {
		s.rings_ready = true
		log.infof("mygame: rings streamed in at frame %d", g.frame_count)
	}
	sync_pipelines(g)
	when DEBUG_AXES {
		draw_spin_axes(g)
	}
}

// tone_pan is the test tone's pan: how far the first spinning entity's presented X axis points along the view's right.
// It is 0 in a scene with nothing spinning.
tone_pan :: proc(g: ^game.Game) -> f32 {
	spinning := make([dynamic]ecs.Entity, g.platform.frame_allocator)
	ecs.collect(&g.world, {SPIN_ID}, &spinning)
	if len(spinning) == 0 {
		return 0
	}
	pose, ok := ecs.presented(&g.world, spinning[0])
	if !ok {
		return 0
	}
	axis := linalg.quaternion128_mul_vector3(pose.rotation, [3]f32{1, 0, 0})
	right := linalg.quaternion128_mul_vector3(game.camera_view(g).rotation, [3]f32{1, 0, 0})
	return linalg.dot(axis, right)
}

// draw_spin_axes draws the axes of each spinning entity into the debug layer.
draw_spin_axes :: proc(g: ^game.Game) {
	spinning := make([dynamic]ecs.Entity, g.platform.frame_allocator)
	ecs.collect(&g.world, {SPIN_ID}, &spinning)
	for e in spinning {
		if pose, ok := ecs.presented(&g.world, e); ok {
			debug.axes(&g.renderer.debug, pose, DEBUG_AXES_SIZE)
		}
	}
}

// stream_rings generates the rings' mip chain and streams it. The backend copies the data before the call returns.
stream_rings :: proc(g: ^game.Game) {
	s := state_of(g)
	desc := gpu.Texture_Desc {
		size      = RINGS_SIZE,
		format    = .RGBA8_Unorm_Srgb,
		mip_count = RINGS_MIPS,
	}
	colors := [3][4]u8{{255, 170, 60, 255}, {60, 190, 255, 255}, {40, 40, 70, 255}}
	data := make([]byte, gpu.mip_chain_size(desc), g.platform.frame_allocator)
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
	s.rings_transfer = g.platform.gpu_stream_texture(s.rings, data)
}

// frame adds the sample's work to the standard game's frame through the renderer's hooks: the triangles in the world
// pass, and the ray-traced shadows and the post pass after it. The render graph places the barriers between the passes
// and the waits between the queues. The editor draws this frame in the views it shows, and the hooks run once for each,
// with their own data.
frame :: proc(g: ^game.Game, desc: ^render.Frame_Desc) {
	desc.hooks.before_world = before_world
	desc.hooks.world_uses = world_uses
	desc.hooks.world_draw = draw_scene
	desc.hooks.after_world = after_world
}

// before_world makes the sample's data for this view of the frame, in Frame.user: the constants of its own passes, its
// triangles relative to the view and its imported resources.
before_world :: proc(f: ^render.Frame) {
	g := (^game.Game)(f.data)
	s := state_of(g)
	frame := new(Frame, g.platform.frame_allocator)
	frame^ = {
		game  = g,
		state = s,
		size  = f.size,
		view  = f.view,
	}
	f.user = frame
	graph := f.graph
	// The sample's own draws cover the same pixels as the renderer's, with its jitter, and pre-expose their colors. Without
	// room for the constants the view draws no triangles.
	if pass, ok := g.platform.gpu_upload(size_of(Pass_Constants), gpu.PASS_CONSTANTS_ALIGN); ok {
		frame.pass_constants = pass
		aspect := f32(f.size.x) / f32(max(f.size.y, 1))
		right, up, forward := render.view_axes(f.view)
		// The sample's traced shadows are for a perspective camera.
		perspective, _ := f.view.projection.(render.Perspective)
		(^Pass_Constants)(raw_data(pass.data))^ = {
			view_projection = render.jittered_view_projection(f),
			right           = {right.x, right.y, right.z, 0},
			up              = {up.x, up.y, up.z, 0},
			forward         = {forward.x, forward.y, forward.z, 0},
			time            = f32(time.duration_seconds(g.elapsed)),
			aspect          = aspect,
			tan_half_fov    = math.tan(perspective.vertical_fov * 0.5),
			near            = render.view_near(f.view),
			exposure        = gpu.read_index(render.gpu_buffer(graph, f.exposure)),
		}
		extract_triangles(frame, f.hidden)
	}
	// The large triangles show the rings once they are streamed in.
	frame.checker = render.import_texture(graph, s.rings_ready ? s.rings : s.checker, .Sampled)
	frame.vertices = render.import_buffer(graph, s.vertices)
	frame.indices = render.import_buffer(graph, s.indices)
}

// world_uses declares what draw_scene reads in the world pass.
world_uses :: proc(f: ^render.Frame, p: render.Pass) {
	frame := frame_of(f)
	g := f.graph
	render.read(g, p, frame.checker)
	render.read(g, p, frame.vertices)
	render.index_buffer(g, p, frame.indices)
}

// after_world traces the triangles' shadows, and multiplies them into a new scene color, before temporal AA.
after_world :: proc(f: ^render.Frame) {
	frame := frame_of(f)
	s := frame.state
	g := f.graph
	frame.scene = f.scene
	// The view that builds the triangle's structure says so when its frame has executed, so the next one does not.
	if s.shadow_mode != .None && add_shadow_passes(g, frame) {
		render.on_executed(g, proc(data: rawptr) {
				(^State)(data).blas_built = true
			}, s)
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

// extract_triangles writes the large triangles' instances for the scene pass and the acceleration structure:
// their poses relative to the camera, interpolated between the last two ticks, their brightness and their IDs. The
// triangles in hidden, the frame's hidden entities, are left out.
extract_triangles :: proc(frame: ^Frame, hidden: []u32) {
	s := frame.state
	w := &frame.game.world
	count := render.extract_count(w, s.triangles)
	triangles, ok := frame.game.platform.gpu_upload(max(count, 1) * size_of(Triangle_Instance), 16)
	if !ok || count == 0 {
		return
	}
	chunks := render.extract(w, s.triangles, frame.view.position, triangles.data, size_of(Triangle_Instance))
	instances := ([^]Triangle_Instance)(raw_data(triangles.data))[:count]
	// The others close up behind the hidden ones.
	kept := 0
	for c in chunks {
		entities := ecs.entities(c.view)
		for t, i in ecs.column(c.view, render.EXTRACT_TERMS, Triangle) {
			if render.is_hidden(hidden, entities[i]) {
				continue
			}
			instance := instances[c.first + i]
			instance.brightness = t.brightness
			instance.id = render.entity_id(entities[i])
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
	instances, ok := frame.game.platform.gpu_upload(MAX_TRIANGLES * size_of(gpu.Accel_Instance), 16)
	if !ok || count == 0 {
		return
	}
	records := ([^]gpu.Accel_Instance)(raw_data(instances.data))[:count]
	triangles := ([^]Triangle_Instance)(raw_data(frame.triangles.data))[:count]
	blas := frame.game.platform.gpu_accel_reference(s.blas)
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

// draw_scene draws the large triangles.
draw_scene :: proc(f: ^render.Frame, ctx: ^render.Pass_Context) {
	frame := frame_of(f)
	if frame.triangle_count == 0 {
		return
	}
	g, cb := ctx.graph, ctx.cb
	constants := Scene_Constants {
		vertices        = gpu.read_index(render.gpu_buffer(g, frame.vertices)),
		texture         = gpu.read_index(render.gpu_texture(g, frame.checker)),
		sampler         = gpu.sampler_index(frame.state.nearest),
		instances       = gpu.read_index(frame.triangles.buffer),
		instance_offset = frame.triangles.offset,
	}
	if guid, guid_ok := format.meta_guid(TRIANGLE_TINTS_META); guid_ok {
		if tints, ready := render.resident_texture(&f.renderer.residency, guid, .D2_Array); ready {
			constants.tints, constants.tint_layers = gpu.read_index(tints.texture), tints.layer_count
		}
	}
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.scene.pipeline)
	gpu.cmd_set_pass_constants(cb, frame.pass_constants)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_set_index_buffer(cb, render.gpu_buffer(g, frame.indices), .U16)
	gpu.cmd_draw_indexed(cb, 3, instance_count = u32(frame.triangle_count))
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

// shutdown destroys the sample's GPU resources, before the standard game shuts down.
shutdown :: proc(g: ^game.Game) {
	s, platform := state_of(g), g.platform
	destroy_pipelines(platform, &s.pipelines)
	platform.gpu_destroy_sampler(s.nearest)
	platform.gpu_destroy_accel(s.tlas)
	platform.gpu_destroy_accel(s.blas)
	platform.gpu_destroy_texture(s.rings)
	platform.gpu_destroy_texture(s.checker)
	platform.gpu_destroy_buffer(s.indices)
	platform.gpu_destroy_buffer(s.vertices)
	log.info("mygame: shutdown")
}

// settings_changed gives Sfx its room, and ends F8's output mode, when the project's settings' files change: the
// standard game then asks for the settings' output mode.
settings_changed :: proc(g: ^game.Game) {
	state_of(g).output_override = nil
	audio.set_bus_effect(&g.audio, "Sfx", 0, {kind = .Reverb, parameters = {1.2, 0.4, 0.15}})
}

// update_output cycles the output mode for this run when F8 is pressed, until the settings' files change.
update_output :: proc(g: ^game.Game) {
	if .F8 not_in g.platform.input().pressed {
		return
	}
	s := state_of(g)
	current := s.output_override.? or_else g.project.settings.output
	next := gpu.Output_Request((int(current) + 1) % len(gpu.Output_Request))
	s.output_override = next
	g.platform.gpu_request_output(next)
	log.infof("mygame: output %v until the project's settings change (F8 cycles it)", next)
}

// switch_scene loads the next scene, the glass scene, the surfaces scene, the room scene, the billboards scene, the
// animation scene, the cube map scene, the audio scene, the 2D scene, the playground, the doorway, the guard, then the
// main scene again, when F7 is pressed. A linked editor owns the scene, so the key does nothing then.
switch_scene :: proc(g: ^game.Game) {
	if .F7 not_in g.platform.input().pressed || editor.active(&g.editor) {
		return
	}
	s := state_of(g)
	metas := [?]string{MAIN_SCENE_META, GLASS_SCENE_META, SURFACES_SCENE_META, ROOM_SCENE_META, BILLBOARDS_SCENE_META, ANIMATION_SCENE_META, CUBE_SKY_SCENE_META, AUDIO_SCENE_META, SPRITES_SCENE_META, PLAYGROUND_SCENE_META, DOORWAY_SCENE_META, GUARD_SCENE_META}
	names := [?]string{"main", "glass", "surfaces", "room", "billboards", "animation", "cube map", "audio", "2D", "playground", "doorway", "guard"}
	s.scene_index = (s.scene_index + 1) % len(metas)
	if guid, ok := format.meta_guid(metas[s.scene_index]); ok {
		scene.load_asset(&g.world, &g.scripts, &g.assets, guid)
		log.infof("mygame: the %s scene (F7 cycles them)", names[s.scene_index])
	}
}

// on_reload updates the pipelines, because the new DLL may describe them differently. The old versions keep drawing
// until the new ones compile.
on_reload :: proc(g: ^game.Game) {
	sync_pipelines(g, force = true)
	log.infof("mygame: reloaded at frame %d", g.frame_count)
}

// sync_pipelines creates the pipelines from their shader assets, and updates each one whose shader the cooker
// compiled again, so a shader change shows in the next frame without a code reload. force updates them all.
sync_pipelines :: proc(g: ^game.Game, force := false) {
	s := state_of(g)
	p, platform, assets := &s.pipelines, g.platform, &g.assets
	render.sync_graphics_pipeline(&p.scene, platform, assets, {.Vertex, .Pixel}, SCENE_PIPELINE, force)
	render.sync_compute_pipeline(&p.post, platform, assets, POST_PIPELINE, force)
	render.sync_compute_pipeline(&p.lens, platform, assets, LENS_PIPELINE, force)
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

destroy_pipelines :: proc(platform: ^core.Platform_API, pipelines: ^Pipelines) {
	render.destroy_shader_pipeline(&pipelines.scene, platform)
	render.destroy_shader_pipeline(&pipelines.shadows, platform)
	render.destroy_shader_pipeline(&pipelines.post, platform)
	render.destroy_shader_pipeline(&pipelines.lens, platform)
}

gpu_bytes :: proc(data: ^$T) -> []byte {
	return ([^]byte)(data)[:size_of(T)]
}

// register_editor_commands describes the game's commands, which the editor shows on its Game tab (see
// docs/editor/shell-and-panels.md#commands). init and on_reload call it.
register_editor_commands :: proc(g: ^game.Game) {
	editor.register_command(&g.editor, {
		id = "mygame.add_triangle",
		label = "Add Triangle",
		description = "Add a spinning triangle 2 m in front of the editor's camera.",
		tab = "Game",
		group = "Triangles",
		icon = "add",
		edits = true,
		procedure = add_triangle,
	})
	editor.register_command(&g.editor, {
		id = "mygame.reverse_spin",
		label = "Reverse Spin",
		description = "Turn the selected triangles the other way.",
		tab = "Game",
		group = "Triangles",
		icon = "rotate",
		edits = true,
		procedure = reverse_spin,
	})
	editor.register_command(&g.editor, {
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
	g := (^game.Game)(ctx.user)
	ctx.message = fmt.aprintf("mygame: %d entities, %d triangles, frame %d", ecs.entity_count(ctx.world), render.extract_count(ctx.world, state_of(g).triangles), g.frame_count, allocator = ctx.allocator)
}
