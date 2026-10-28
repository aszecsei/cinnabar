package render

import "core:math"
import "core:mem"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/profile"
import "cinnabar:engine/asset"
import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"
import "cinnabar:engine/volume"

// The frame's targets (see docs/rendering/layers-and-output.md#layers). The world draws into linear HDR colors, the editor's entity IDs
// and reversed depth, which the prepass writes with the normals and the velocities (see PREPASS_COLORS). The UI is premultiplied and sRGB-encoded, and blends as encoded values. The debug layer has an
// sRGB view, so it blends in linear light, and the output pass encodes it.
SCENE_FORMAT :: gpu.Format.RGBA16_Float
// Each pixel holds entity_id of the entity drawn there, or 0, with the submesh drawn there in its high bits (see
// id_submesh). The editor picks from it.
ID_FORMAT :: gpu.Format.R32_Uint
// An ID buffer value's low ID_ENTITY_BITS are its entity_id, which ecs.MAX_ENTITIES fits, and the bits above them its
// submesh, clamped to ID_MAX_SUBMESH. ID_ENTITY_MASK and ID_ENTITY_BITS match the shaders that read the buffer.
ID_ENTITY_BITS :: 25
ID_ENTITY_MASK :: 1 << ID_ENTITY_BITS - 1
ID_MAX_SUBMESH :: 1 << (32 - ID_ENTITY_BITS) - 1
#assert(ecs.MAX_ENTITIES <= ID_ENTITY_MASK)
// The scene's depth has a stencil, whose bit VIEW_MODEL_STENCIL marks the view model's pixels.
DEPTH_FORMAT :: gpu.Format.D32_Float_S8_Uint
VIEW_MODEL_STENCIL :: 1
UI_FORMAT :: gpu.Format.RGBA8_Unorm
DEBUG_FORMAT :: gpu.Format.RGBA8_Unorm_Srgb
// The world pass's color targets, which a game's pipelines that draw in it use.
WORLD_COLORS :: []gpu.Color_Target{{format = SCENE_FORMAT}, {format = ID_FORMAT}}
// The stencil test of a game's pipelines that draw in the world pass, so they never cover the view model, as the
// renderer's draws never do (see docs/rendering/layers-and-output.md#view-model).
WORLD_STENCIL :: gpu.Stencil_State {
	compare   = .Equal,
	read_mask = VIEW_MODEL_STENCIL,
}

// Debug lines are this many pixels wide, and the part that the scene hides draws with this alpha.
DEBUG_LINE_WIDTH :: 2
DEBUG_HIDDEN_ALPHA :: 0.3

// The engine's shaders for the debug layer and the output pass, by their .meta files.
DEBUG_SHADER :: #load("../content/shaders/debug.hlsl.meta", string)
OUTPUT_SHADER :: #load("../content/shaders/output.hlsl.meta", string)

// entity_id is an entity's value in the ID buffer: its slot + 1, so 0 is no entity.
entity_id :: proc "contextless" (entity: ecs.Entity) -> u32 {
	return ecs.entity_index(entity) + 1
}

// id_entity is an ID buffer value's entity_id, without its submesh.
id_entity :: proc "contextless" (id: u32) -> u32 {
	return id & ID_ENTITY_MASK
}

// id_submesh is the submesh of an ID buffer value: the index of the mesh's submesh drawn there, clamped to
// ID_MAX_SUBMESH, or 0 for what is not a submesh of a mesh.
id_submesh :: proc "contextless" (id: u32) -> int {
	return int(id >> ID_ENTITY_BITS)
}

// Renderer is the built-in renderer (see docs/rendering/frame.md#frame). It lives in Game_State and holds handles only, so
// a code reload keeps it.
Renderer :: struct {
	platform:        ^core.Platform_API,
	residency:       Residency,
	textures:        Texture_Cache,
	// The lines that debug draws, which the debug layer draws each frame.
	debug:           debug.Draw,
	// Registrations, created again in renderer_reload.
	meshes:          Extractor,
	surfaces:        Extractor,
	volumes:         volume.Volumes,
	materials:       Materials,
	scene:           Gpu_Scene,
	lights:          Lights,
	shadows:         Shadow_Passes,
	previews:        Previews,
	ao:              Ao_Passes,
	gi:              Gi_Passes,
	fog:             Volumetric_Fog,
	post:            Post,
	// The game's post effects, in the order that they run at each point. renderer_reload clears them.
	effects:         [MAX_POST_EFFECTS]Post_Effect,
	effect_count:    int,
	// The output pass's pipeline for each output mode's frame target format. Only the frame's mode's is made.
	output_pipelines: [gpu.Output_Mode]Shader_Pipeline,
	debug_tested:    Shader_Pipeline,
	debug_hidden:    Shader_Pipeline,
	// Tested lines where the view model is, whose depth they cannot compare with.
	debug_behind:    Shader_Pipeline,
	debug_overlay:   Shader_Pipeline,
	// The debug views from the frame's textures (see Debug_View).
	debug_view:      Shader_Pipeline,
	// Moment-based transparency's composite over the scene (see docs/rendering/transparency.md#transparency).
	transparency_composite: Shader_Pipeline,
	// The compute sprites' pipelines and buffers (see docs/rendering/transparency.md#sprites).
	sprites:         Sprites,
	// The particle systems' pool and state (see docs/rendering/particles.md#particles).
	particles:       Particles,
	// What the device can do, and the quality that the frames have unless Frame_Desc.quality replaces it (see
	// set_quality).
	caps:            Caps,
	quality:         Quality,
	// A code reload may bring new descriptions, so the next frame updates every pipeline.
	reloaded:        bool,
}

// Frame_Desc is what a game gives draw_frame each frame. It lives in frame memory, and so do its hooks' data.
Frame_Desc :: struct {
	view:              View,
	size:              [2]u32,
	// Keeps the IDs and the depth after the frame's passes need them, for the editor's picking and outline.
	keep_ids:          bool,
	// No debug layer this frame: the debug lines are not drawn, though those with a duration still expire, and the
	// output pass composites no debug layer. The debug hook still runs, with Frame.debug 0, so passes that read the IDs
	// and the depth after post-processing, such as the editor's picks, still run; nothing may draw into Frame.debug
	// then. The editor sets it outside Edit (see docs/rendering/layers-and-output.md#debug).
	no_debug:          bool,
	// The entity slots not to draw, a bit each, as the editor hides them. nil hides nothing.
	hidden:            []u32,
	// The frame's settings (see docs/rendering/frame.md#settings). nil takes them from the volumes at the view, as
	// resolve_settings does.
	settings:          ^Frame_Settings,
	// The frame's quality, as far as the device can do it (see docs/rendering/quality.md#quality). nil takes
	// Renderer.quality.
	quality:           ^Quality,
	// The editor's debug view, the features that it turns off, and the stops that it adds to the exposure (see
	// docs/rendering/post-processing.md#debug-views).
	debug_view:        Debug_View,
	disable:           Features,
	exposure_offset:   f32,
	hooks:             Frame_Hooks,
	// The editor's material previews that the frame also draws, each into its own target (see
	// docs/rendering/materials.md#material-previews). draw_frame sets each one's complete.
	previews:          []Preview_Desc,
	// The sprites that the frame draws with the moment-based transparent surfaces, at most MAX_SPRITES (see
	// docs/rendering/transparency.md#sprites).
	sprites:           []Sprite,
	// The time that the particles step this frame, in seconds: the game's simulation time, which is 0 while the editor
	// is in Edit or paused (see docs/rendering/particles.md#time).
	delta:             f32,
	// The Particle_Systems that step by the host's time while delta is 0: those that the editor plays, its selection.
	playing:           []ecs.Entity,
}

// Frame_Hooks add a game's passes and draws to the frame. Each is optional. They are procedures in the game, so a
// Frame_Desc never outlives its frame.
Frame_Hooks :: struct {
	// Given to every hook as Frame.data.
	data:         rawptr,
	// Adds passes before the prepass, such as culling.
	before_world:  proc(f: ^Frame),
	// Adds passes after the prepass, which can read Frame.depth, Frame.normals and Frame.velocity.
	after_prepass: proc(f: ^Frame),
	// Declares the world pass's other uses, such as the buffers that world_draw reads.
	world_uses:   proc(f: ^Frame, pass: Pass),
	// Records draws into the world pass, after the Mesh_Renderers in piece 0. The pass has world_pieces pieces.
	world_draw:   proc(f: ^Frame, ctx: ^Pass_Context),
	world_pieces: int,
	// Adds passes after the world pass. A pass that makes a new scene color sets Frame.scene to it.
	after_world:  proc(f: ^Frame),
	// Adds passes just before post-processing, such as a game's own layer that it composites into Frame.scene in
	// linear HDR. Post-processing then reads Frame.scene.
	before_post:  proc(f: ^Frame),
	// Adds the passes that draw the UI into Frame.ui, after a pass that clears it. They load it.
	ui:           proc(f: ^Frame),
	// Adds passes that draw into Frame.debug after the debug lines, such as the editor's tools. They load it. With
	// Frame_Desc.no_debug the hook still runs, but Frame.debug is 0 and nothing may draw into it.
	debug:        proc(f: ^Frame),
}

// Frame is one frame's targets and data, in frame memory, which the hooks and the passes share.
Frame :: struct {
	renderer:                 ^Renderer,
	graph:                    ^Graph,
	data:                     rawptr,
	view:                     View,
	// The scene's size, which the world's targets, the debug layer and every pass before temporal AA have: the frame's
	// size at the quality's render scale (see docs/rendering/anti-aliasing.md#upscaling).
	size:                     [2]u32,
	// The frame's size, which the frame target and the UI have.
	output_size:              [2]u32,
	// The size of Frame.scene: size, until temporal AA upscales it to output_size. The post passes after temporal AA,
	// and a game's post effects there, take it.
	scene_size:               [2]u32,
	debug_view:               Debug_View,
	// The quality's level of detail error, in pixels.
	lod_error:                f32,
	// The directional lights' cascades (see Shadows).
	shadow_settings:          Shadow_Settings,
	// How the frame target reaches the display (see docs/rendering/layers-and-output.md#hdr-output).
	output:                   gpu.Output,
	view_projection:          matrix[4, 4]f32,
	// The camera's subpixel jitter for temporal AA, in normalized device coordinates, which the renderer's draws add
	// (see jittered_view_projection). Zero without temporal AA.
	jitter:                   [2]f32,
	// Last frame's view_projection, and how far the camera moved since then.
	previous_view_projection: matrix[4, 4]f32,
	camera_motion:            [3]f32,
	// The scene's colors, pre-exposed: a game's own draws in the world pass scale theirs by the float at 0 of exposure,
	// which the exposure pass writes after the world pass.
	scene:                    Texture,
	ids:                      Texture,
	depth:                    Texture,
	normals:                  Texture,
	velocity:                 Texture,
	// The ambient occlusion in r, which the forward pass reads, and the integrated fog volume: zero without them.
	ambient_occlusion:        Texture,
	fog_volume:               Texture,
	// The global illumination's diffuse and specular light, zero without it.
	gi_diffuse:               Texture,
	gi_specular:              Texture,
	// Moment-based transparency's optical depth and moments, zero without it (see docs/rendering/transparency.md#transparency).
	moments_zeroth:           Texture,
	moments:                  Texture,
	// nil without sprites.
	sprites:                  ^Sprite_Frame,
	// nil without particles to step.
	particles:                ^Particle_Frame,
	// Zero without a UI hook, and without debug lines or a debug hook.
	ui:                       Texture,
	debug:                    Texture,
	hooks:                    Frame_Hooks,
	exposure:                 Buffer,
	// Bloom's result, zero without bloom, which the output pass adds to the scene with these scales.
	bloom:                    Texture,
	bloom_scale:              f32,
	scene_scale:              f32,
	// The tone mapping lookup table (see LUT_SIZE).
	lut:                      Texture,
	// The scene tone mapped and anti-aliased by FXAA or SMAA, which the output pass only encodes: zero when the output
	// pass tone maps the scene itself.
	display:                  Texture,
	post:                     ^Post_Frame,
	ao:                       ^Ao_Frame,
	// nil without global illumination.
	gi:                       ^Gi_Frame,
	// nil without fog.
	fog:                      ^Fog_Frame,
	scene_frame:              ^Scene_Frame,
	lights:                   ^Light_Frame,
	shadows:                  ^Shadow_Frame,
	debug_lines:              gpu.Upload,
	tested_lines:             int,
	overlay_lines:            int,
}

// Debug_Vertex_Line matches Line in debug.hlsl.
Debug_Vertex_Line :: struct {
	a:       [3]f32,
	color:   u32,
	b:       [3]f32,
	padding: u32,
}

// Debug_Push matches Push in debug.hlsl.
Debug_Push :: struct {
	view_projection: matrix[4, 4]f32,
	lines:           u32,
	lines_offset:    u32,
	first_line:      u32,
	alpha:           f32,
	viewport:        [2]f32,
	width:           f32,
}

// Output_Push matches Push in output.hlsl.
Output_Push :: struct {
	scene:         u32,
	ui:            u32,
	debug:         u32,
	has_ui:        u32,
	has_debug:     u32,
	bloom:         u32,
	has_bloom:     u32,
	lut:           u32,
	has_lut:       u32,
	sampler_index: u32,
	scene_scale:   f32,
	bloom_scale:   f32,
	// The lookup table holds HDR colors. mode is the gpu.Output_Mode, and paper_white the UI's white in nits in HDR.
	lut_hdr:       u32,
	mode:          u32,
	paper_white:   f32,
	// The scene holds a debug view's colors as they are, which the pass only encodes.
	raw:           u32,
	// The scene is Frame.display, tone mapped already.
	tone_mapped:   u32,
	// The tone map pass's target. size is the pass's target's size, which the scene and the debug layer are stretched
	// to when theirs is smaller.
	output:        u32,
	size:          [2]u32,
}

#assert(size_of(Debug_Push) <= 128 && size_of(Output_Push) <= 128)

renderer_init :: proc(r: ^Renderer, platform: ^core.Platform_API, assets: ^asset.Assets, w: ^ecs.World) {
	// The Renderer is too large for a temporary on the stack, so it is zeroed in place.
	mem.zero_item(r)
	r.platform = platform
	r.caps = device_caps(platform)
	r.quality = default_quality(r.caps)
	r.meshes = mesh_extractor(w)
	r.surfaces = surface_extractor(w)
	volume.register(&r.volumes, w)
	for &p in r.output_pipelines {
		p = shader_pipeline(OUTPUT_SHADER)
	}
	r.debug_tested = shader_pipeline(DEBUG_SHADER)
	r.debug_hidden = shader_pipeline(DEBUG_SHADER)
	r.debug_behind = shader_pipeline(DEBUG_SHADER)
	r.debug_overlay = shader_pipeline(DEBUG_SHADER)
	r.debug_view = shader_pipeline(DEBUG_VIEW_SHADER)
	r.transparency_composite = shader_pipeline(TRANSPARENCY_COMPOSITE_SHADER)
	residency_init(&r.residency, platform, assets)
	debug.init(&r.debug, platform.heap_allocator)
	materials_init(&r.materials, platform)
	scene_init(&r.scene, platform)
	lights_init(&r.lights, platform, w)
	shadows_init(&r.shadows, platform)
	previews_init(&r.previews, r)
	ao_init(&r.ao)
	gi_init(&r.gi)
	fog_init(&r.fog)
	sprites_init(&r.sprites)
	particles_init(&r.particles, w)
	post_init(&r.post, platform)
}

// mesh_extractor selects the entities with a Mesh_Renderer.
@(private = "file")
mesh_extractor :: proc(w: ^ecs.World) -> Extractor {
	return extractor(w, {ecs.read(w, Mesh_Renderer), ecs.optional(ecs.read(w, View_Model))})
}

// renderer_reload keeps the renderer after a code reload, and makes its registrations again.
renderer_reload :: proc(r: ^Renderer, platform: ^core.Platform_API, w: ^ecs.World) {
	r.platform = platform
	r.meshes = mesh_extractor(w)
	r.surfaces = surface_extractor(w)
	volume.register(&r.volumes, w)
	lights_register(&r.lights, w)
	particles_register(&r.particles, w)
	// The effects' procedures were in the old code, so the game registers them again.
	r.effect_count = 0
	r.reloaded = true
	residency_reload(&r.residency, platform)
	materials_reload(&r.materials)
}

renderer_destroy :: proc(r: ^Renderer) {
	residency_destroy(&r.residency)
	cache_destroy(&r.textures, r.platform)
	debug.destroy(&r.debug)
	materials_destroy(&r.materials, r.platform)
	scene_destroy(&r.scene, r.platform)
	lights_destroy(&r.lights, r.platform)
	shadows_destroy(&r.shadows, r.platform)
	previews_destroy(&r.previews, r)
	ao_destroy(&r.ao, r.platform)
	gi_destroy(&r.gi, r.platform)
	fog_destroy(&r.fog, r.platform)
	sprites_destroy(&r.sprites, r.platform)
	particles_destroy(&r.particles, r.platform)
	post_destroy(&r.post, r.platform)
	for &p in r.output_pipelines {
		destroy_shader_pipeline(&p, r.platform)
	}
	for p in ([]^Shader_Pipeline{&r.debug_tested, &r.debug_hidden, &r.debug_behind, &r.debug_overlay, &r.debug_view, &r.transparency_composite}) {
		destroy_shader_pipeline(p, r.platform)
	}
}

// draw_frame draws a frame into the frame target: the world, the UI and the debug layer, combined by the output pass
// (see docs/rendering/frame.md#frame). The world draws in a prepass, then in the forward pass with the lights' clusters and
// the shadows, then post-processing runs on it. It returns false if the graph could not execute.
draw_frame :: proc(r: ^Renderer, w: ^ecs.World, desc: Frame_Desc) -> bool {
	profile.scope_text(&r.platform.profile, "Build frame", .Render)
	residency_update(&r.residency)
	output := r.platform.gpu_output != nil ? r.platform.gpu_output() : gpu.Output{format = gpu.FRAME_TARGET_FORMAT}
	sync_frame_pipelines(r, output.mode, len(desc.previews) > 0)
	g := begin(r.platform, &r.textures)
	quality := desc.quality != nil ? clamp_quality(desc.quality^, r.caps) : r.quality
	size := render_size(desc.size, quality.render_scale)
	f := new(Frame, r.platform.frame_allocator)
	f^ = {
		renderer        = r,
		graph           = &g,
		data            = desc.hooks.data,
		view            = desc.view,
		size            = size,
		output_size     = desc.size,
		scene_size      = size,
		output          = output,
		view_projection = view_projection(desc.view, f32(size.x) / f32(max(size.y, 1))),
		hooks           = desc.hooks,
		scene_scale     = 1,
		debug_view      = desc.debug_view,
		lod_error       = quality.lod_error,
	}
	target := import_texture(&g, r.platform.gpu_frame_target(), .Color)
	f.scene = create_texture(&g, {size = size, format = SCENE_FORMAT, label = "scene"})
	f.ids = create_texture(&g, {size = size, format = ID_FORMAT, label = "entity ids"})
	f.depth = create_texture(&g, {size = size, format = DEPTH_FORMAT, label = "scene depth"})
	f.normals = create_texture(&g, {size = size, format = NORMAL_FORMAT, label = "scene normals"})
	f.velocity = create_texture(&g, {size = size, format = VELOCITY_FORMAT, label = "scene velocity"})
	settings := desc.settings != nil ? desc.settings^ : resolve_settings(r, w, desc.view.position, desc.hidden)
	apply_quality(&settings, quality)
	apply_debug(&settings, desc.debug_view, desc.disable, desc.exposure_offset)
	begin_post(f, settings.post)
	f.post.effects = .Post_Effects not_in desc.disable && desc.debug_view == .Lit
	f.post.effect_settings = settings.effects
	f.post.no_tone_mapping = .Tone_Mapping in desc.disable
	// A view that is not shaded keeps the exposure where it was, so the lit scene comes back as it was.
	if !debug_view_shaded(desc.debug_view) {
		f.post.raw, f.post.exposure, f.post.exposure_auto = true, false, false
	}
	f.shadow_settings = settings.shadows
	build_scene(f, w, desc.hidden)
	f.lights = extract_lights(f, w, desc.hidden)
	if .Shadows in desc.disable {
		for &casts in f.lights.casts {
			casts = false
		}
	}
	assign_shadows(f)
	upload_lights(f)
	begin_fog(f, settings.fog)
	begin_gi(f, settings.gi, settings.ambient)
	add_scene_passes(f, settings.ambient)
	begin_sprites(f, desc.sprites, &r.sprites.main)
	begin_particles(f, w, desc.delta, desc.hidden, desc.playing)
	lines := debug.frame_lines(&r.debug)
	has_debug := !desc.no_debug && (len(lines) > 0 || desc.hooks.debug != nil)

	add_particle_passes(f)
	add_ribbon_pass(f)
	if desc.hooks.before_world != nil {
		desc.hooks.before_world(f)
	}
	// The view model first, which sets its stencil bit, then the world, which draws only where the bit is clear.
	p := add_render_pass(&g, "prepass", proc(ctx: ^Pass_Context) {
		draw_scene_view((^Frame)(ctx.data), ctx.cb, VIEW_VIEW_MODEL, .Prepass)
		draw_scene_view((^Frame)(ctx.data), ctx.cb, VIEW_CAMERA, .Prepass)
	}, f)
	color(&g, p, f.normals, .Clear)
	color(&g, p, f.velocity, .Clear, {VELOCITY_NONE, VELOCITY_NONE, 0, 0})
	depth(&g, p, f.depth, .Clear)
	declare_scene_draws(f, p)
	add_particle_history_pass(f)
	if desc.hooks.after_prepass != nil {
		desc.hooks.after_prepass(f)
	}
	add_ao_passes(f, settings.ambient_occlusion)
	add_gi_passes(f)
	add_cluster_passes(f)
	add_shadow_passes(f)
	add_fog_passes(f)

	p = add_render_pass(&g, "world", draw_world, f, pieces = max(desc.hooks.world_pieces, 1))
	color(&g, p, f.scene, .Clear, {settings.background.r, settings.background.g, settings.background.b, 1})
	color(&g, p, f.ids, .Clear, store = desc.keep_ids || desc.debug_view == .Entity_Ids ? .Store : .Discard)
	// The debug layer tests against the depth, the editor reads it, and so do the fog over the background, the
	// transparent surfaces, the sprites, temporal AA, the exposure and the depth's debug view.
	keep_depth := desc.keep_ids || has_debug || f.fog != nil || has_transparency(f) || has_sprites(f) || reads_depth(f) || desc.debug_view == .Depth
	depth(&g, p, f.depth, .Load, store = keep_depth ? .Store : .Discard)
	declare_scene_draws(f, p)
	declare_lighting(f, p, opaque = true)
	if desc.hooks.world_uses != nil {
		desc.hooks.world_uses(f, p)
	}
	// The background's fog first, so it does not dim the transparent surfaces in front of it, and the global
	// illumination's lit scene, which keeps only the opaque surfaces.
	add_fog_background(f)
	add_gi_lit(f)
	add_transparency_passes(f)
	if desc.hooks.after_world != nil {
		desc.hooks.after_world(f)
	}
	if desc.hooks.before_post != nil {
		desc.hooks.before_post(f)
	}
	add_debug_view_pass(f)
	add_post_passes(f)
	add_transparent_id_pass(f, desc.keep_ids)

	if desc.hooks.ui != nil {
		f.ui = create_texture(&g, {size = desc.size, format = UI_FORMAT, label = "ui"})
		p = add_render_pass(&g, "clear ui", proc(_: ^Pass_Context) {}, f)
		color(&g, p, f.ui, .Clear)
		desc.hooks.ui(f)
	}

	if has_debug {
		f.debug = create_texture(&g, {size = size, format = DEBUG_FORMAT, label = "debug"})
		upload_debug_lines(f, lines)
		p = add_render_pass(&g, "debug", draw_debug_lines, f)
		color(&g, p, f.debug, .Clear)
		depth(&g, p, f.depth, .Load, store = desc.keep_ids ? .Store : .Discard)
	}
	// Without the layer, the hook still adds the passes that need no target, such as the editor's picks.
	if desc.hooks.debug != nil {
		desc.hooks.debug(f)
	}

	p = add_render_pass(&g, "output", draw_output, f)
	if f.display != 0 {
		read(&g, p, f.display)
	} else {
		read(&g, p, f.scene)
		read(&g, p, f.lut)
		if f.bloom != 0 {
			read(&g, p, f.bloom)
		}
	}
	if f.ui != 0 {
		read(&g, p, f.ui)
	}
	if f.debug != 0 {
		read(&g, p, f.debug)
	}
	color(&g, p, target, .Discard)

	for &preview in desc.previews {
		add_preview_passes(f, &preview)
	}
	ok := execute(&g)
	debug.end_frame(&r.debug)
	return ok
}

// frame_time is the time that materials read, in seconds since the host started. It wraps every hour, so a float
// keeps its precision.
frame_time :: proc(r: ^Renderer) -> f32 {
	if r.platform.time_seconds == nil {
		return 0
	}
	return f32(math.mod(r.platform.time_seconds(), 3600))
}

// sync_frame_pipelines creates the renderer's pipelines from their shaders, and updates those whose shaders changed,
// or all of them after a code reload.
@(private = "file")
sync_frame_pipelines :: proc(r: ^Renderer, mode: gpu.Output_Mode, previews: bool) {
	force := r.reloaded
	r.reloaded = false
	assets := r.residency.assets
	sync_output_pipeline(r, mode, force)
	// The previews' targets are always in FRAME_TARGET_FORMAT.
	if mode != .Sdr && previews {
		sync_output_pipeline(r, .Sdr, force)
	}
	sync_post_pipelines(r, force)
	sync_ao_pipelines(r, force)
	sync_gi_pipelines(r, force)
	sync_fog_pipelines(r, force)
	sync_sprite_pipelines(r, force)
	sync_particle_pipelines(r, force)
	sync_compute_pipeline(&r.debug_view, r.platform, assets, {label = "debug view"}, force)
	sync_compute_pipeline(&r.transparency_composite, r.platform, assets, {label = "transparency composite"}, force)
	debug_desc := gpu.Graphics_Pipeline_Desc {
		colors       = {{format = DEBUG_FORMAT, blend = .Alpha}},
		depth_format = DEPTH_FORMAT,
	}
	// Tested lines compare depth only with the world's pixels. The view model always hides them, as it hides the world.
	debug_desc.stencil = WORLD_STENCIL
	debug_desc.depth_compare, debug_desc.label = .Greater_Equal, "debug lines"
	sync_graphics_pipeline(&r.debug_tested, r.platform, assets, {.Vertex, .Pixel}, debug_desc, force)
	debug_desc.depth_compare, debug_desc.label = .Less, "debug lines (hidden)"
	sync_graphics_pipeline(&r.debug_hidden, r.platform, assets, {.Vertex, .Pixel}, debug_desc, force)
	debug_desc.stencil.compare = .Not_Equal
	debug_desc.depth_compare, debug_desc.label = .Always, "debug lines (behind the view model)"
	sync_graphics_pipeline(&r.debug_behind, r.platform, assets, {.Vertex, .Pixel}, debug_desc, force)
	debug_desc.stencil = {}
	debug_desc.depth_compare, debug_desc.label = .Always, "debug lines (overlay)"
	sync_graphics_pipeline(&r.debug_overlay, r.platform, assets, {.Vertex, .Pixel}, debug_desc, force)
}

@(private = "file")
sync_output_pipeline :: proc(r: ^Renderer, mode: gpu.Output_Mode, force: bool) {
	desc := gpu.Graphics_Pipeline_Desc {
		colors = {{format = gpu.output_format(mode)}},
		label  = "output",
	}
	sync_graphics_pipeline(&r.output_pipelines[mode], r.platform, r.residency.assets, {.Vertex, .Pixel}, desc, force)
}

@(private = "file")
draw_world :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	if ctx.piece == 0 {
		draw_scene_view(f, ctx.cb, VIEW_VIEW_MODEL, .Forward)
		draw_scene_view(f, ctx.cb, VIEW_CAMERA, .Forward)
	}
	if f.hooks.world_draw != nil {
		f.hooks.world_draw(f, ctx)
	}
}

// upload_debug_lines writes the lines relative to the camera, the tested ones first, then the overlay ones.
@(private = "file")
upload_debug_lines :: proc(f: ^Frame, lines: []debug.Line) {
	upload, ok := f.renderer.platform.gpu_upload(max(len(lines), 1) * size_of(Debug_Vertex_Line), 16)
	if !ok {
		return
	}
	records := ([^]Debug_Vertex_Line)(raw_data(upload.data))[:len(lines)]
	pack :: proc(c: [4]f32) -> u32 {
		packed: u32
		for ch, i in c {
			packed |= u32(clamp(ch, 0, 1) * 255 + 0.5) << (u32(i) * 8)
		}
		return packed
	}
	next := 0
	for mode in debug.Mode {
		for l in lines {
			if l.mode == mode {
				records[next] = {a = ecs.position_sub(l.a, f.view.position), b = ecs.position_sub(l.b, f.view.position), color = pack(l.color)}
				next += 1
			}
		}
		if mode == .Tested {
			f.tested_lines = next
		}
	}
	f.overlay_lines = next - f.tested_lines
	f.debug_lines = upload
}

@(private = "file")
draw_debug_lines :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	r := f.renderer
	if f.tested_lines + f.overlay_lines == 0 {
		return
	}
	push := Debug_Push {
		view_projection = f.view_projection,
		lines           = gpu.read_index(f.debug_lines.buffer),
		lines_offset    = f.debug_lines.offset,
		viewport        = {f32(f.size.x), f32(f.size.y)},
		width           = DEBUG_LINE_WIDTH,
	}
	draw :: proc(cb: ^gpu.Command_Buffer, pipeline: gpu.Pipeline, push: ^Debug_Push, first, count: int, alpha: f32) {
		// A pipeline that does not exist yet, because its shader is not cooked, draws nothing.
		if count == 0 || pipeline == {} {
			return
		}
		push.first_line, push.alpha = u32(first), alpha
		gpu.cmd_set_pipeline(cb, pipeline)
		gpu.cmd_push_constants(cb, push)
		gpu.cmd_draw(cb, u32(count * 6))
	}
	draw(ctx.cb, r.debug_hidden.pipeline, &push, 0, f.tested_lines, DEBUG_HIDDEN_ALPHA)
	draw(ctx.cb, r.debug_behind.pipeline, &push, 0, f.tested_lines, DEBUG_HIDDEN_ALPHA)
	draw(ctx.cb, r.debug_tested.pipeline, &push, 0, f.tested_lines, 1)
	draw(ctx.cb, r.debug_overlay.pipeline, &push, f.tested_lines, f.overlay_lines, 1)
}

@(private = "file")
draw_output :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	pipeline := f.renderer.output_pipelines[f.output.mode].pipeline
	if pipeline == {} {
		return
	}
	push := output_push(f, gpu_texture(g, f.scene), f.output.mode)
	if f.display != 0 {
		push.scene, push.tone_mapped = gpu.read_index(gpu_texture(g, f.display)), 1
	} else {
		tone_map_inputs(f, g, &push)
	}
	if f.ui != 0 {
		push.ui, push.has_ui = gpu.read_index(gpu_texture(g, f.ui)), 1
	}
	if f.debug != 0 {
		push.debug, push.has_debug = gpu.read_index(gpu_texture(g, f.debug)), 1
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_draw(ctx.cb, 3)
}

// tone_map_inputs gives the output pass's constants, or the tone map pass's, what the frame's tone mapping reads
// besides the scene: bloom, and the lookup table unless the tone mapping is off or the scene is raw.
@(private)
tone_map_inputs :: proc(f: ^Frame, g: ^Graph, push: ^Output_Push) {
	if f.bloom != 0 {
		push.bloom, push.has_bloom = gpu.read_index(gpu_texture(g, f.bloom)), 1
		push.scene_scale, push.bloom_scale = f.scene_scale, f.bloom_scale
	}
	if f.post.no_tone_mapping {
		push.has_lut = 0
	}
	push.raw = u32(f.post.raw)
}

// output_push is the output pass's constants for a scene, which it tone maps through the lookup table once that is
// baked, and encodes for an output mode.
@(private)
output_push :: proc(f: ^Frame, scene: gpu.Texture, mode: gpu.Output_Mode) -> Output_Push {
	r := f.renderer
	return {
		size          = f.output_size,
		scene         = gpu.read_index(scene),
		lut           = gpu.read_index(r.post.lut),
		has_lut       = u32(r.post.lut_baked),
		sampler_index = gpu.sampler_index(r.post.sampler),
		scene_scale   = 1,
		lut_hdr       = u32(r.post.lut_grading.hdr),
		mode          = u32(mode),
		// An SDR frame whose table is still HDR, until it is baked again, reads it with the paper white it was baked with.
		paper_white   = f.post.paper_white > 0 ? f.post.paper_white : max(r.post.lut_grading.paper_white, 1),
	}
}
