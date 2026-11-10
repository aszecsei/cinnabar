package render

import "core:log"
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
// and reversed depth, which the prepass writes with the normals, the velocities and the roughness (see PREPASS_COLORS). The UI is premultiplied and sRGB-encoded, and blends as encoded values. The debug layer has an
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
	instanced:       Extractor,
	surfaces:        Extractor,
	volumes:         volume.Volumes,
	materials:       Materials,
	scene:           Gpu_Scene,
	lights:          Lights,
	shadows:         Shadow_Passes,
	// The GPU scene's acceleration structure and hit shading (see docs/rendering/ray-scene.md#ray-scene).
	ray_scene:       Ray_Scene,
	previews:        Previews,
	// The spatiotemporal blue noise that the ambient occlusion and the screen-space and traced reflections sample.
	blue_noise:      Blue_Noise,
	ao:              Ao_Passes,
	gi:              Gi_Passes,
	// The screen-space reflections (see screen_reflections.odin).
	ssr:             Screen_Reflections,
	// The traced reflections (see traced_reflections.odin).
	rtr:             Traced_Reflections,
	fog:             Volumetric_Fog,
	sky:             Sky,
	// The volumetric clouds (see clouds.odin).
	clouds:          Volumetric_Clouds,
	// The last frame's sky, which sky_texture_sun answers for.
	last_sky_mode:   Sky_Mode,
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
	// The sprite renderers (see sheet_sprites.odin).
	sheet_sprites:   Sheet_Sprites,
	// The frame's own view's state (see View_State) unless Frame_Desc.state names another, which a game with one camera has
	// no other of.
	view:            View_State,
	// The state of the last frame's own view when it was not view, which the stats getters read, or nil. view_state_destroy
	// clears it, so it never dangles.
	stats_view:      ^View_State,
	// The particle systems' pool and state (see docs/rendering/particles.md#particles).
	particles:       Particles,
	// The reflection probes' cubes, slots and capture (see reflection_probes.odin).
	reflection_probes: Reflection_Probes,
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
	// The frame's own view draws into this texture, in gpu.FRAME_TARGET_FORMAT (always SDR) and the render target layout,
	// which the view leaves it in, as an Extra_View does, and not into the frame target. 0 draws into the frame target,
	// in the frame's output mode. size is the texture's size.
	target:            gpu.Texture,
	// What the renderer keeps for the frame's own view from frame to frame (see View_State): the caller's, made with
	// view_state_init and freed with view_state_destroy, or nil for Renderer.view. A game whose own view changes between
	// frames, as the editor's does when viewports open and close, gives each camera a state of its own, so none loses its
	// histories (see docs/rendering/frame.md#views). It must not be an extra view's.
	state:             ^View_State,
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
	// Count the forward pass's quads and their pixels for shading_stats, which costs the forward pass a little (see
	// docs/rendering/lighting-and-shadows.md#quad-overdraw).
	shading_stats:     bool,
	hooks:             Frame_Hooks,
	// A second hook, for a caller that adds passes to the frame without owning hooks.data (see Frame_Overlay).
	overlay:           Frame_Overlay,
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
	// The pose of each skinned entity this frame, by entity (see Skin_Pose and docs/rendering/gpu-scene.md#skinned-meshes).
	// A Mesh_Renderer with no pose here, or whose mesh has no skin stream, draws at rest.
	skins:             []Skin_Pose,
	// Other views of the same world that the frame also draws, each into a target of its own, after its own view (see
	// docs/rendering/frame.md#views). At most MAX_EXTRA_VIEWS draw.
	extra_views:       []Extra_View,
}

// The most extra views that a frame draws. The texture cache holds the transient textures of this many and the frame's own.
MAX_EXTRA_VIEWS :: 4

// Extra_View is another camera on the frame's world, drawn after the frame's own view into its own target (see
// docs/rendering/frame.md#views). It draws exactly what the frame's own view would from its camera, with the state in its
// View_State, and its own quality, settings, debug view and hooks. The frame's world is shared: the GPU scene's render
// origin and the view model are the frame's own view's, its particles step once a frame, and its reflection probes rank by
// the nearest of the views.
Extra_View :: struct {
	view:            View,
	size:            [2]u32,
	// The output pass's target, in gpu.FRAME_TARGET_FORMAT (always SDR), in the render target layout, which the view
	// leaves it in. A view with no target or no size is not drawn.
	target:          gpu.Texture,
	// What the renderer keeps for the view from frame to frame. Required: a view without it is a mistake, and asserts. The
	// caller makes it with view_state_init and frees it with view_state_destroy, and gives each view its own.
	state:           ^View_State,
	// As Frame_Desc's, for this view. nil takes the frame's quality, and resolves the settings at the view's position.
	quality:         ^Quality,
	settings:        ^Frame_Settings,
	keep_ids:        bool,
	no_debug:        bool,
	debug_view:      Debug_View,
	disable:         Features,
	exposure_offset: f32,
	hooks:           Frame_Hooks,
	overlay:         Frame_Overlay,
}

// use_view makes an Extra_View the frame's own view: its camera, size, target, state, quality, settings, debug view, hooks,
// overlay and the rest. A caller that draws several cameras of one frame describes each as an Extra_View, gives the first
// to the frame with this, and the rest to Frame_Desc.extra_views, as the editor package does (see
// docs/rendering/frame.md#views).
use_view :: proc(desc: ^Frame_Desc, v: Extra_View) {
	desc.view, desc.size, desc.target, desc.state = v.view, v.size, v.target, v.state
	desc.quality, desc.settings, desc.keep_ids, desc.no_debug = v.quality, v.settings, v.keep_ids, v.no_debug
	desc.debug_view, desc.disable, desc.exposure_offset, desc.hooks = v.debug_view, v.disable, v.exposure_offset, v.hooks
	desc.overlay = v.overlay
}

// Frame_Overlay is a second hook beside Frame_Hooks, with a data pointer of its own: it runs in every view after the
// debug hook, with the frame's debug layer, and runs also when the frame has none (Frame_Desc.no_debug), as the debug
// hook does, in which case Frame.debug is 0 and nothing may draw into it. It exists for a caller that adds passes to a
// view without owning Frame_Hooks.data, which the game's: the editor's tools draw this way into the views of the game's
// frame (see docs/rendering/frame.md#views). A frame with an overlay has a debug layer whenever it has no no_debug.
Frame_Overlay :: struct {
	data: rawptr,
	draw: proc(f: ^Frame, data: rawptr),
}

// Frame_Hooks add a game's passes and draws to the frame. Each is optional. They are procedures in the game, so a
// Frame_Desc never outlives its frame.
Frame_Hooks :: struct {
	// Given to every hook as Frame.data.
	data:         rawptr,
	// Adds passes before the prepass, such as culling.
	before_world:  proc(f: ^Frame),
	// Adds passes after the prepass, which can read Frame.depth, Frame.normals, Frame.velocity and Frame.roughness.
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
	// Adds passes that draw into Frame.debug after the debug lines. They load it. With Frame_Desc.no_debug the hook still
	// runs, but Frame.debug is 0 and nothing may draw into it.
	debug:        proc(f: ^Frame),
}

// Frame is one frame's targets and data, in frame memory, which the hooks and the passes share.
Frame :: struct {
	renderer:                 ^Renderer,
	graph:                    ^Graph,
	data:                     rawptr,
	// A pointer for the hooks to keep this view's data in: nil when the view begins, and not touched by the renderer. The
	// hooks of one frame run once for each view with the same Frame_Hooks.data, so a game that keeps data for each view,
	// such as the constants of its own passes, makes it in its first hook of the view and sets user to it (see
	// docs/rendering/frame.md#views). Its memory is frame memory.
	user:                     rawptr,
	// The entity slots not to draw, as Frame_Desc.hidden has them (see is_hidden), for a game that draws its own geometry.
	hidden:                   []u32,
	// The view's state between frames, and what the frame's views share while it is drawn (see World_Frame).
	state:                    ^View_State,
	world:                    ^World_Frame,
	// This frame is an extra view's (see Extra_View), not the frame's own view: the work that the world needs once a frame
	// is the frame's own view's.
	extra:                    bool,
	// The pool of mesh pages' buffers in the frame's graph, 0 before any paged mesh is resident.
	mesh_pool:                Mesh_Pool_Frame,
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
	// The view's projection as the shaders take it, and the view model's.
	projection:               View_Projection,
	view_model_projection:    View_Projection,
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
	// Each pixel's roughness from the prepass, ROUGHNESS_NONE where it drew nothing.
	roughness:                Texture,
	// The ambient occlusion in r, which the forward pass reads, and the integrated fog volume: zero without them.
	ambient_occlusion:        Texture,
	fog_volume:               Texture,
	// The global illumination's diffuse and specular light, zero without it.
	gi_diffuse:               Texture,
	gi_specular:              Texture,
	// The screen-space or traced reflections: the specular light along each pixel's reflection, filtered for its
	// roughness and pre-exposed, in rgb, and its weight in a, which the forward pass reads. Zero without them.
	reflections:              Texture,
	// Moment-based transparency's optical depth and moments, zero without it (see docs/rendering/transparency.md#transparency).
	moments_zeroth:           Texture,
	moments:                  Texture,
	// nil without sprites.
	sprites:                  ^Sprite_Frame,
	// The view's sprite renderers, nil without any (see sheet_sprites.odin), and whether the world has any, which
	// add_scene_passes writes the camera's constants for.
	sheet_sprites:            ^Sheet_Sprite_Frame,
	wants_sheet_sprites:      bool,
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
	// nil without the screen-space or traced reflections, whose Ssr_Frame.traced is set.
	ssr:                      ^Ssr_Frame,
	// nil without fog.
	fog:                      ^Fog_Frame,
	// nil without an Atmosphere sky.
	sky:                      ^Sky_Frame,
	// nil without a Texture sky whose texture is resident.
	sky_texture:              ^Sky_Texture_Frame,
	// nil when the sky's cubemap has no textures (see sky_cube.odin).
	sky_cube:                 ^Sky_Cube_Frame,
	// nil without clouds (see clouds.odin); its shadow map, which the light loop reads, is zero without a sun that casts it.
	clouds:                   ^Cloud_Frame,
	// nil without the reflection probes (see reflection_probes.odin).
	reflection_probes:        ^Reflection_Probe_Frame,
	// Frame_Desc.disable has occlusion culling, or the hierarchy over meshlets.
	no_occlusion:             bool,
	no_meshlet_hierarchy:     bool,
	scene_frame:              ^Scene_Frame,
	lights:                   ^Light_Frame,
	shadows:                  ^Shadow_Frame,
	// The ray scene, when a feature requested it this frame (see request_ray_scene).
	ray_scene:                ^Ray_Scene_Frame,
	// nil when the frame measures nothing (see Shading_Frame).
	shading:                  ^Shading_Frame,
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

// World_Frame is what the views of a frame share while it is drawn, in the memory of draw_frame: where each view looks
// from, which the reflection probes rank by, and the particles that the frame's own view stepped, which the others draw.
@(private)
World_Frame :: struct {
	cameras:   []ecs.World_Position,
	particles: Particle_Share,
}

#assert(size_of(Debug_Push) <= 128 && size_of(Output_Push) <= 128)

renderer_init :: proc(r: ^Renderer, platform: ^core.Platform_API, assets: ^asset.Assets, w: ^ecs.World) {
	// The Renderer is too large for a temporary on the stack, so it is zeroed in place.
	mem.zero_item(r)
	r.platform = platform
	r.caps = device_caps(platform)
	r.quality = default_quality(r.caps)
	r.meshes = mesh_extractor(w)
	r.instanced = instanced_extractor(w)
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
	ray_scene_init(&r.ray_scene)
	previews_init(&r.previews, r)
	blue_noise_init(&r.blue_noise)
	ao_init(&r.ao)
	gi_init(&r.gi)
	screen_reflections_init(&r.ssr)
	traced_reflections_init(&r.rtr)
	fog_init(&r.fog)
	sky_init(&r.sky)
	clouds_init(&r.clouds)
	sprites_init(&r.sprites)
	sheet_sprites_init(&r.sheet_sprites, platform, w)
	particles_init(&r.particles, w)
	reflection_probes_init(&r.reflection_probes, r, w)
	post_init(&r.post, platform)
	view_state_init(&r.view, r)
}

// mesh_extractor selects the entities with a Mesh_Renderer.
@(private = "file")
mesh_extractor :: proc(w: ^ecs.World) -> Extractor {
	return extractor(w, {ecs.read(w, Mesh_Renderer), ecs.optional(ecs.read(w, View_Model))})
}

// instanced_extractor selects the entities with an Instanced_Mesh_Renderer.
@(private = "file")
instanced_extractor :: proc(w: ^ecs.World) -> Extractor {
	return extractor(w, {ecs.read(w, Instanced_Mesh_Renderer)})
}

// renderer_reload keeps the renderer after a code reload, and makes its registrations again.
renderer_reload :: proc(r: ^Renderer, platform: ^core.Platform_API, w: ^ecs.World) {
	r.platform = platform
	r.meshes = mesh_extractor(w)
	r.instanced = instanced_extractor(w)
	r.surfaces = surface_extractor(w)
	volume.register(&r.volumes, w)
	lights_register(&r.lights, w)
	particles_register(&r.particles, w)
	sheet_sprites_register(&r.sheet_sprites, w)
	reflection_probes_register(&r.reflection_probes, w)
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
	ray_scene_destroy(&r.ray_scene, r.platform)
	previews_destroy(&r.previews, r)
	ao_destroy(&r.ao, r.platform)
	gi_destroy(&r.gi, r.platform)
	screen_reflections_destroy(&r.ssr, r.platform)
	traced_reflections_destroy(&r.rtr, r.platform)
	fog_destroy(&r.fog, r.platform)
	sky_destroy(&r.sky, r)
	clouds_destroy(&r.clouds, r.platform)
	sprites_destroy(&r.sprites, r.platform)
	sheet_sprites_destroy(&r.sheet_sprites, r.platform, r.residency.assets)
	view_state_destroy(&r.view, r)
	particles_destroy(&r.particles, r.platform)
	reflection_probes_destroy(&r.reflection_probes, r)
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
// the shadows, then post-processing runs on it. Then each of the extra views draws into its own target (see
// docs/rendering/frame.md#views). It returns false if the frame's own graph could not execute.
draw_frame :: proc(r: ^Renderer, w: ^ecs.World, desc: Frame_Desc) -> bool {
	profile.scope_text(&r.platform.profile, "Build frame", .Render)
	residency_set_mesh_pool(&r.residency, r.quality.mesh_pool)
	residency_update(&r.residency)
	output := r.platform.gpu_output != nil ? r.platform.gpu_output() : gpu.Output{format = gpu.FRAME_TARGET_FORMAT}
	// A target of its own is always SDR, whatever the frame's output is.
	if desc.target != {} {
		output = {format = gpu.FRAME_TARGET_FORMAT}
	}
	own := desc.state != nil ? desc.state : &r.view
	sync_frame_pipelines(r, output.mode, len(desc.previews) > 0 || len(desc.extra_views) > 0)
	quality := desc.quality != nil ? clamp_quality(desc.quality^, r.caps) : r.quality

	// The extra views that draw, and where every view looks from.
	if len(desc.extra_views) > MAX_EXTRA_VIEWS {
		log.warnf("render: %d extra views, of which only the first %d draw", len(desc.extra_views), MAX_EXTRA_VIEWS)
	}
	extras: [MAX_EXTRA_VIEWS]Extra_View
	count := 0
	cameras: [1 + MAX_EXTRA_VIEWS]ecs.World_Position
	cameras[0] = desc.view.position
	for ev in desc.extra_views[:min(len(desc.extra_views), MAX_EXTRA_VIEWS)] {
		if ev.target == {} || ev.size.x == 0 || ev.size.y == 0 {
			continue
		}
		assert(ev.state != nil && ev.state != own, "render: an extra view needs a View_State of its own")
		for other in extras[:count] {
			assert(other.state != ev.state, "render: two extra views share a View_State")
		}
		extras[count] = ev
		count += 1
		cameras[count] = ev.view.position
	}
	world := new(World_Frame, r.platform.frame_allocator)
	world.cameras = cameras[1:1 + count]

	frame_target := desc.target != {} ? desc.target : r.platform.gpu_frame_target()
	ok := draw_view(r, w, desc, world, own, output, limit_quality(desc.view, quality), frame_target, false)
	if !ok {
		mesh_pool_not_sent(&r.residency.pool)
	}
	// The stats are the frame's own view's, whichever state that is this frame.
	r.stats_view = own != &r.view ? own : nil
	// The extra views come after the frame's own, which committed what it did, so they read the world as it left it. A view
	// that fails does not fail the others.
	for ev in extras[:count] {
		view := desc
		view.view, view.size, view.keep_ids, view.no_debug, view.debug_view = ev.view, ev.size, ev.keep_ids, ev.no_debug, ev.debug_view
		view.disable, view.hooks, view.exposure_offset, view.settings = ev.disable, ev.hooks, ev.exposure_offset, ev.settings
		view.overlay = ev.overlay
		view.extra_views, view.previews, view.playing, view.delta, view.shading_stats = nil, nil, nil, 0, false
		view_quality := ev.quality != nil ? clamp_quality(ev.quality^, r.caps) : quality
		// The target is always SDR, whatever the frame's output is.
		draw_view(r, w, view, world, ev.state, {format = gpu.FRAME_TARGET_FORMAT}, limit_quality(view.view, view_quality), ev.target, true)
	}
	// After the last view, so the lines of this frame reach them all.
	debug.end_frame(&r.debug)
	return ok
}

// draw_view draws one view of the frame in a graph of its own: the frame's own view, or an extra view, which keeps its own
// state (see View_State). The work that the world needs once a frame is the frame's own view's (see Frame.extra). desc is
// the view's: for an extra view, the frame's with the view's own fields. It returns false if the graph could not execute.
@(private = "file")
draw_view :: proc(
	r: ^Renderer,
	w: ^ecs.World,
	desc: Frame_Desc,
	world: ^World_Frame,
	state: ^View_State,
	output: gpu.Output,
	quality: Quality,
	frame_target: gpu.Texture,
	extra: bool,
) -> bool {
	// The stats take what came back once the frame has executed, or failed: a frame that did not copy them, or did not
	// execute, shows none.
	defer read_view_stats(r, state)
	state.frames += 1
	g := extra ? begin_extra(r.platform, &r.textures, &state.histories) : begin(r.platform, &r.textures, &state.histories)
	size := render_size(desc.size, quality.render_scale)
	aspect := f32(size.x) / f32(max(size.y, 1))
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
		view_projection = view_projection(desc.view, aspect),
		projection      = projection_constants(desc.view, aspect),
		view_model_projection = projection_constants(view_model_view(desc.view), aspect),
		hooks           = desc.hooks,
		hidden          = desc.hidden,
		scene_scale     = 1,
		debug_view      = desc.debug_view,
		lod_error       = quality.lod_error,
		state           = state,
		world           = world,
		extra           = extra,
	}
	target := import_texture(&g, frame_target, .Color)
	f.scene = create_texture(&g, {size = size, format = SCENE_FORMAT, label = "scene"})
	f.ids = create_texture(&g, {size = size, format = ID_FORMAT, label = "entity ids"})
	f.depth = create_texture(&g, {size = size, format = DEPTH_FORMAT, label = "scene depth"})
	f.normals = create_texture(&g, {size = size, format = NORMAL_FORMAT, label = "scene normals"})
	f.velocity = create_texture(&g, {size = size, format = VELOCITY_FORMAT, label = "scene velocity"})
	f.roughness = create_texture(&g, {size = size, format = ROUGHNESS_FORMAT, label = "scene roughness"})
	settings := desc.settings != nil ? desc.settings^ : resolve_settings(r, w, desc.view.position, desc.hidden)
	apply_quality(&settings, quality)
	apply_debug(&settings, desc.debug_view, desc.disable, desc.exposure_offset)
	apply_view_limits(&settings, desc.view)
	begin_post(f, settings.post)
	f.post.effects = .Post_Effects not_in desc.disable && desc.debug_view == .Lit
	f.post.effect_settings = settings.effects
	f.post.no_tone_mapping = .Tone_Mapping in desc.disable
	// A view that is not shaded keeps the exposure where it was, so the lit scene comes back as it was.
	if !debug_view_shaded(desc.debug_view) {
		f.post.raw, f.post.exposure, f.post.exposure_auto = true, false, false
	}
	f.shadow_settings = settings.shadows
	f.no_occlusion = .Occlusion_Culling in desc.disable
	f.no_meshlet_hierarchy = .Meshlet_Hierarchy in desc.disable
	if !extra {
		r.last_sky_mode = settings.sky.mode
	}
	// The frame's own view brings the pool of mesh pages up to date before anything draws from it, whether or not anything
	// draws yet: a mesh's roots come in this way. An extra view draws from the pool as that left it.
	if !extra {
		f.mesh_pool = add_stream_pages_pass(&g, &r.residency.pool, r.platform, r.residency.assets)
	}
	if f.mesh_pool.pool == 0 {
		f.mesh_pool = mesh_pool_buffers(&g, &r.residency.pool)
	}
	build_scene(f, w, desc.hidden, desc.skins)
	f.lights = extract_lights(f, w, desc.hidden)
	if .Shadows in desc.disable {
		for &casts in f.lights.casts {
			casts = false
		}
	}
	// The sky tints its sun's light before the shadows and the upload take the lights, and the clouds flag the light that
	// casts their shadow.
	ambient := begin_sky(f, settings.sky)
	begin_clouds(f, settings.clouds, settings.sky, ambient)
	begin_sky_cube(f, settings.sky, settings.reflections.level, ambient)
	begin_reflection_probes(f, w, desc.hidden, settings.reflections, ambient)
	assign_shadows(f)
	upload_lights(f)
	upload_reflection_probe_lights(f)
	begin_fog(f, settings.fog)
	begin_gi(f, settings.gi, ambient)
	begin_screen_reflections(f, settings.reflections)
	f.wants_sheet_sprites = any_sprite_renderers(r, w)
	add_scene_passes(f, ambient)
	// Every request for the ray scene came before, so its build is before every pass that traces it.
	add_ray_scene_passes(f)
	begin_sprites(f, desc.sprites, &r.sprites.main)
	begin_sheet_sprites(f, w, desc.hidden, desc.playing, desc.delta)
	if extra {
		begin_particles_draw(f)
	} else {
		begin_particles(f, w, desc.delta, desc.hidden, desc.playing)
	}
	lines := debug.frame_lines(&r.debug)
	has_debug := !desc.no_debug && (len(lines) > 0 || desc.hooks.debug != nil || desc.overlay.draw != nil)

	add_particle_passes(f)
	add_ribbon_pass(f)
	add_particle_mesh_pass(f)
	if desc.hooks.before_world != nil {
		desc.hooks.before_world(f)
	}
	begin_shading(f, desc.shading_stats)
	// The view model first, which sets its stencil bit, then the world, which draws only where the bit is clear.
	p := add_render_pass(&g, "prepass", proc(ctx: ^Pass_Context) {
		draw_scene_view((^Frame)(ctx.data), ctx.cb, VIEW_VIEW_MODEL, .Prepass)
		draw_scene_view((^Frame)(ctx.data), ctx.cb, VIEW_CAMERA, .Prepass, filter = .No_Particles)
	}, f)
	color(&g, p, f.normals, .Clear)
	color(&g, p, f.velocity, .Clear, {VELOCITY_NONE, VELOCITY_NONE, 0, 0})
	color(&g, p, f.roughness, .Clear, {ROUGHNESS_NONE, 0, 0, 0})
	depth(&g, p, f.depth, .Clear)
	declare_scene_draws(f, p)
	// With occlusion culling, that was the early view: the depth pyramid, the late view's culling and its prepass.
	add_occlusion_passes(f)
	add_cull_stats_copy(f)
	add_particle_history_pass(f)
	add_particle_prepass(f)
	if desc.hooks.after_prepass != nil {
		desc.hooks.after_prepass(f)
	}
	// The cloud shadow map first: the passes that light the world from here on read it.
	add_cloud_shadow_passes(f)
	add_ao_passes(f, settings.ambient_occlusion)
	add_gi_world_probes(f)
	add_gi_passes(f)
	add_screen_reflection_passes(f)
	add_cluster_passes(f)
	add_shadow_passes(f)
	add_cloud_passes(f)
	add_fog_passes(f)
	add_sky_passes(f)
	add_sky_texture_passes(f)
	add_sky_cube_passes(f)
	add_reflection_probe_passes(f)

	// The sky draws over the background after the world pass, so the clear is black under it.
	draws_sky := sky_draws(f)
	background := draws_sky ? {} : settings.sky.background
	p = add_render_pass(&g, "world", draw_world, f, pieces = max(desc.hooks.world_pieces, 1))
	color(&g, p, f.scene, .Clear, {background.r, background.g, background.b, 1})
	color(&g, p, f.ids, .Clear, store = desc.keep_ids || desc.debug_view == .Entity_Ids ? .Store : .Discard)
	// The debug layer tests against the depth, the editor reads it, and so do the sky, the fog over the background, the
	// transparent surfaces, the sprites, temporal AA, the exposure and the depth's debug view.
	keep_depth := desc.keep_ids || has_debug || f.fog != nil || draws_sky || has_transparency(f) || has_sprites(f) || has_sheet_sprites(f) || reads_depth(f) || desc.debug_view == .Depth
	depth(&g, p, f.depth, .Load, store = keep_depth ? .Store : .Discard)
	declare_scene_draws(f, p)
	declare_lighting(f, p, opaque = true)
	declare_shading(f, p)
	if desc.hooks.world_uses != nil {
		desc.hooks.world_uses(f, p)
	}
	add_shading_stats_copy(f)
	// The sky, the clouds over it, then the background's fog, so it does not dim the transparent surfaces in front of
	// it, and the global illumination's and the reflections' lit scenes, which keep only the opaque surfaces.
	add_sky_background(f)
	add_sky_texture_background(f)
	add_cloud_composite(f)
	add_fog_background(f)
	add_gi_lit(f)
	add_screen_reflection_lit(f)
	add_transparency_passes(f)
	add_sheet_sprite_pass(f)
	if desc.hooks.after_world != nil {
		desc.hooks.after_world(f)
	}
	if desc.hooks.before_post != nil {
		desc.hooks.before_post(f)
	}
	add_debug_view_pass(f)
	add_post_passes(f)
	add_transparent_id_pass(f, desc.keep_ids)
	add_sheet_sprite_id_pass(f, desc.keep_ids)

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
	if desc.overlay.draw != nil {
		desc.overlay.draw(f, desc.overlay.data)
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
	if ok {
		for &preview in desc.previews {
			if preview.capture != 0 && preview.complete != nil && preview.complete^ && preview.captured != nil && r.platform.gpu_capture_texture != nil {
				preview.captured^ = r.platform.gpu_capture_texture(preview.target, preview.capture)
			}
		}
	}
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
sync_frame_pipelines :: proc(r: ^Renderer, mode: gpu.Output_Mode, sdr: bool) {
	force := r.reloaded
	r.reloaded = false
	assets := r.residency.assets
	sync_output_pipeline(r, mode, force)
	// The previews' and the extra views' targets are always in FRAME_TARGET_FORMAT.
	if mode != .Sdr && sdr {
		sync_output_pipeline(r, .Sdr, force)
	}
	sync_post_pipelines(r, force)
	sync_ao_pipelines(r, force)
	sync_gi_pipelines(r, force)
	sync_screen_reflections(r, force)
	sync_traced_reflections(r, force)
	sync_ray_scene_pipelines(r, force)
	sync_fog_pipelines(r, force)
	sync_sky_pipelines(r, force)
	sync_cloud_pipelines(r, force)
	sync_sprite_pipelines(r, force)
	sync_sheet_sprite_pipelines(r, force)
	sync_particle_pipelines(r, force)
	sync_reflection_probe_pipelines(r, force)
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
		if sf := f.scene_frame; sf != nil && sf.occluding {
			draw_scene_view(f, ctx.cb, sf.late_view, .Forward)
		}
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
	// The table as this frame's passes see it: baked this frame, or by a frame before.
	bake, has_lut := f.post.lut.?
	return {
		size          = f.output_size,
		scene         = gpu.read_index(scene),
		lut           = gpu.read_index(r.post.lut),
		has_lut       = u32(has_lut),
		sampler_index = gpu.sampler_index(r.post.sampler),
		scene_scale   = 1,
		lut_hdr       = u32(bake.grading.hdr),
		mode          = u32(mode),
		// An SDR frame whose table is still HDR, until it is baked again, reads it with the paper white it was baked with.
		paper_white   = f.post.paper_white > 0 ? f.post.paper_white : max(bake.grading.paper_white, 1),
	}
}
