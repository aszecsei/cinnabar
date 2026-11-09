package editor

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"

import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"

// The viewport tools' game side (see docs/editor/viewport.md#viewport). The editor sends its camera, its selection and its
// gizmo, and the game draws the frame from that camera with add_viewport_passes after its own passes: an outline
// around the selection and the gizmo over the frame. The game's scene pass also writes an entity ID buffer, and a
// pick reads it and the depth, and copies the result to the CPU.
//
// The editor can show more than one viewport (see docs/editor/viewport.md#several-viewports). Viewport 0 is the frame
// itself. Each other one is an extra view of the frame (see extra_viewports), with its own camera, gizmo, settings and
// shared target, and the game calls add_viewport_passes for each.

// The viewports that an editor can show: the frame's, and the extra ones, each with a target from gpu_viewport_target.
MAX_VIEWPORTS :: link.MAX_VIEWPORTS
#assert(MAX_VIEWPORTS == 1 + gpu.MAX_VIEWPORT_TARGETS)

// The entity ID buffer's format, which the renderer draws (see render.ID_FORMAT).
ID_FORMAT :: render.ID_FORMAT
// At most this many picks wait for the GPU. The editor waits for each answer, so it sends one or two at a time.
MAX_PICKS :: 16

// The pick results: the pick's ticket, the ID, depth and stencil at the rectangle's origin, then a bit for each entity
// slot. Matches HEADER_SIZE in shaders/pick.hlsl.
@(private)
PICK_HEADER :: 16
@(private)
PICK_RESULTS_SIZE :: PICK_HEADER + ecs.MAX_ENTITIES / 8

// The tools' shaders are engine content (see docs/content/kinds/shaders.md#shaders).
@(private)
PICK_SHADER :: #load("../content/shaders/pick.hlsl.meta", string)
@(private)
OVERLAY_SHADER :: #load("../content/shaders/overlay.hlsl.meta", string)

// View is the editor's viewports, its selection, and the picks that wait for the GPU. It is part of the session.
View :: struct {
	viewports: [MAX_VIEWPORTS]Viewport,
	selection: [dynamic]ecs.Entity,
	// The entities that the editor hides, with their descendants. The game does not draw them.
	hidden:    [dynamic]ecs.Entity,
	// The picks of every viewport, in the order that they came. One runs at a time, in a frame of its viewport.
	picks:     [dynamic]link.Pick_Request,
	// picks[0] was rendered with Viewport_Tools.ticket, and its results come back through the readback buffer.
	picking:   bool,
}

// Viewport is one of the editor's viewports: its camera, its gizmo and how it draws. Viewport 0 is the frame, which
// is always open. Another one draws from its Open_Viewport to its Close_Viewport.
Viewport :: struct {
	// The camera, once the editor has sent one.
	camera:      Maybe(link.Editor_Camera),
	gizmo:       link.Gizmo_State,
	// A reflection probe's box handles, from Box_Handles, as cubes of handle_size meters.
	handles:     [dynamic]link.Box_Handle,
	handle_size: f32,
	// How the editor wants the viewport drawn, from Set_Viewport_Settings.
	settings:    link.Viewport_Settings,
	// An extra viewport's target, while it is open. The frame's viewport has none.
	target:      Maybe(Viewport_Target),
}

// Viewport_Target is an open extra viewport's shared target: the size that the editor asked for, and what the editor
// knows of the target that the backend made for it.
@(private)
Viewport_Target :: struct {
	size:     [2]u32,
	announce: Target_Announce,
}

// Target_Announce is what the editor knows of an extra viewport's target: nothing before the first frame that takes it,
// then a generation to tell it of, with its size and its name prefix, and then that generation.
@(private)
Target_Announce :: union {
	Target_Pending,
	Target_Told,
}

@(private)
Target_Pending :: struct {
	generation:    u32,
	size:          [2]u32,
	prefix:        [128]u8,
	prefix_length: int,
}

@(private)
Target_Told :: struct {
	generation: u32,
}

// Viewport_Tools is what the tools draw and pick with. It lives in Editor and outlives a session.
Viewport_Tools :: struct {
	// The ticket of the last pick that the GPU ran. A new session keeps it, so a pick of the old one comes back stale.
	ticket:           u32,
	// What the pick needs to read its results: the words of entity bits, and the near planes that the world and the
	// view model were drawn with.
	pick_words:       u32,
	pick_near:        f32,
	pick_view_model_near: f32,
	// The GPU objects, made at the first frame that draws the tools. If they cannot be made, the tools stay off.
	gpu_ready:        bool,
	gpu_failed:       bool,
	pick_pipeline:    render.Shader_Pipeline,
	overlay_pipeline: render.Shader_Pipeline,
	icons_pipeline:   render.Shader_Pipeline,
	results:          gpu.Buffer,
	readback:         gpu.Buffer,
}

// Viewport_Frame is what the game drew of a viewport that the tools draw on and pick from.
Viewport_Frame :: struct {
	// The viewport: 0 for the frame's own view, and an Extra_Viewport's for an extra view.
	viewport:    int,
	view:        render.View,
	// The scene's size, which the debug layer, the IDs and the depth have, and the frame's, which the editor's picks
	// are in. The scene's is smaller at a render scale below 1 (see docs/rendering/anti-aliasing.md#upscaling).
	size:        [2]u32,
	output_size: [2]u32,
	// The debug layer, which the tools draw into, over the debug lines (see docs/rendering/layers-and-output.md#debug).
	// 0 when the frame has no debug layer, outside Edit, where only the pick runs.
	target: render.Texture,
	// The ID buffer, in ID_FORMAT, and the depth that the scene pass wrote with render.view_projection.
	ids:    render.Texture,
	depth:  render.Texture,
}

// active is true while an editor is linked: the game then draws from view, writes the ID buffer, keeps its depth and
// calls add_viewport_passes.
active :: proc(e: ^Editor) -> bool {
	return e.session.connection != 0
}

// view is the camera of the frame's viewport, once a linked editor has sent one, in edit mode or with the free camera.
view :: proc(e: ^Editor) -> (render.View, bool) {
	c, has_camera := e.session.view.viewports[0].camera.?
	// In play mode the game's own camera draws, unless the editor flies its free camera.
	if !active(e) || !has_camera || (e.session.mode != .Edit && !e.session.free_camera) {
		return {}, false
	}
	return camera_view(c), true
}

@(private)
camera_view :: proc(c: link.Editor_Camera) -> render.View {
	return {
		position = {c.position},
		rotation = quaternion(x = c.rotation.x, y = c.rotation.y, z = c.rotation.z, w = c.rotation.w),
		vertical_fov = c.vertical_fov,
		near = c.near,
	}
}

// Extra_Viewport is a viewport other than the frame's that this frame draws: its number, its camera, and its target
// with its size.
Extra_Viewport :: struct {
	viewport: int,
	view:     render.View,
	size:     [2]u32,
	target:   gpu.Texture,
}

// extra_viewports gives the viewports that this frame draws beside its own, in frame memory: each open one that has a
// camera and whose target the editor is not still reading. The game draws each as an extra view of its frame (see
// extra_view), and calls add_viewport_passes for it. They draw from the editor's cameras in every mode, so in Play they
// show the game from outside. Call it once per frame: it takes the targets for the frame.
extra_viewports :: proc(e: ^Editor) -> []Extra_Viewport {
	if !active(e) {
		return nil
	}
	extras := make([dynamic]Extra_Viewport, e.platform.frame_allocator)
	for &v, i in e.session.view.viewports {
		camera, has_camera := v.camera.?
		target, open := &v.target.?
		if i == 0 || !open || !has_camera {
			continue
		}
		shared, ok := e.platform.gpu_viewport_target(i - 1, target.size)
		if !ok {
			continue
		}
		known: Maybe(u32)
		switch a in target.announce {
		case Target_Pending:
			known = a.generation
		case Target_Told:
			known = a.generation
		}
		if known != shared.generation {
			pending := Target_Pending{generation = shared.generation, size = shared.size}
			pending.prefix_length = copy(pending.prefix[:], shared.prefix)
			target.announce = pending
		}
		append(&extras, Extra_Viewport{viewport = i, view = camera_view(camera), size = shared.size, target = shared.texture})
	}
	return extras[:]
}

// extra_view is an extra viewport as an extra view of the frame, with the game's hooks for it: it keeps its IDs for the
// picks, has the debug layer while the frame has, and takes the viewport's view and the features that it turns off.
extra_view :: proc(e: ^Editor, v: Extra_Viewport, hooks: render.Frame_Hooks) -> render.Extra_View {
	overrides := render_overrides(e, v.viewport)
	return {
		view = v.view,
		size = v.size,
		target = v.target,
		keep_ids = true,
		no_debug = !debug_shown(e),
		debug_view = overrides.debug_view,
		disable = overrides.disable,
		hooks = hooks,
	}
}

// Render_Overrides are what the editor's viewport changes in the frame, for render.Frame_Desc.
Render_Overrides :: struct {
	debug_view:      render.Debug_View,
	disable:         render.Features,
	exposure_offset: f32,
	// Count the forward pass's quads for render.shading_stats.
	shading_stats:   bool,
}

// render_overrides gives a viewport's debug view, the features that it turns off and its exposure offset while an
// editor is linked, and none otherwise.
render_overrides :: proc(e: ^Editor, viewport := 0) -> (o: Render_Overrides) {
	if !active(e) {
		return
	}
	s := e.session.view.viewports[viewport].settings
	o.debug_view = render.Debug_View(s.debug_view)
	o.exposure_offset = s.exposure_offset
	o.shading_stats = s.shading_stats
	flags := [render.Feature]bool {
		.Temporal_Aa       = s.no_temporal_aa,
		.Bloom             = s.no_bloom,
		.Tone_Mapping      = s.no_tone_mapping,
		.Fog               = s.no_fog,
		.Ambient_Occlusion = s.no_ambient_occlusion,
		.Gi                = s.no_gi,
		.Shadows           = s.no_shadows,
		.Post_Effects      = s.no_post_effects,
		.Occlusion_Culling = s.no_occlusion_culling,
		.Meshlet_Hierarchy = s.no_meshlet_hierarchy,
		.Clouds            = s.no_clouds,
	}
	for off, feature in flags {
		if off {
			o.disable += {feature}
		}
	}
	return
}

// viewport_quality is the quality that the frame's viewport draws at while an editor is linked: the renderer's, with the
// viewport's preset, anti-aliasing, global illumination and render scale in place of its own where the viewport chooses
// them. A preset sets the global illumination's technique with every feature, and a choice of technique replaces it,
// at the preset's level or the game's. ok is false when the viewport keeps the renderer's, or no editor is linked. The
// extra viewports draw at the frame's quality, as far as an extra view does (see docs/rendering/frame.md#extra-views).
viewport_quality :: proc(e: ^Editor, r: ^render.Renderer) -> (q: render.Quality, ok: bool) {
	if !active(e) {
		return
	}
	s := e.session.view.viewports[0].settings
	q = r.quality
	if s.quality_preset != .Game {
		q = render.preset_quality(render.Quality_Preset(int(s.quality_preset) - 1), r.caps)
		// The preset sets the features; the anti-aliasing and the render scale stay the game's.
		q.aa, q.render_scale = r.quality.aa, r.quality.render_scale
		ok = true
	}
	if s.anti_aliasing != .Game {
		q.aa = render.Aa_Technique(int(s.anti_aliasing) - 1)
		ok = true
	}
	if s.global_illumination != .Game {
		q.gi.technique = render.Gi_Technique(int(s.global_illumination) - 1)
		ok = true
	}
	if s.reflections != .Game {
		q.reflections.technique = render.Reflection_Technique(int(s.reflections) - 1)
		ok = true
	}
	if s.reflections_level != .Game {
		q.reflections.level = render.Quality_Level(int(s.reflections_level) - 1)
		ok = true
	}
	if s.render_scale > 0 {
		q.render_scale = s.render_scale
		ok = true
	}
	return render.clamp_quality(q, r.caps), ok
}

#assert(int(max(link.Viewport_Preset)) == int(render.Quality_Preset.Ultra) + 1)
#assert(int(max(link.Viewport_Aa)) == int(max(render.Aa_Technique)) + 1)
#assert(int(max(link.Viewport_Gi)) == int(max(render.Gi_Technique)) + 1)
#assert(int(max(link.Viewport_Reflections)) == int(max(render.Reflection_Technique)) + 1)
#assert(int(max(link.Viewport_Level)) == int(max(render.Quality_Level)) + 1)

// entity_id is an entity's value in the ID buffer: its index + 1, so 0 is no entity. A pick finds the entity that
// is in that slot when the answer arrives.
entity_id :: proc "contextless" (entity: ecs.Entity) -> u32 {
	return render.entity_id(entity)
}

// add_viewport_passes adds the pick, the icons and the overlay to the frame's graph. Add them after the passes that
// write the target, the ID buffer and the depth. The pick runs in every mode, so a click in Play still selects; the
// icons and the overlay draw only while editing, so the viewport in Play shows what the game shows.
add_viewport_passes :: proc(e: ^Editor, g: ^render.Graph, w: ^ecs.World, frame: Viewport_Frame) {
	v := &e.tools
	tools := &e.session.view
	if !active(e) || frame.viewport < 0 || frame.viewport >= MAX_VIEWPORTS || !create_viewport_gpu(e) {
		return
	}
	viewport := &tools.viewports[frame.viewport]
	sync_viewport_pipelines(e)
	overlays := editing(e)
	// The icons first, so the pick and the outline find them.
	if overlays {
		add_icons_pass(e, g, w, frame)
	}
	platform := e.platform
	slots := ecs.slot_count(w)
	words := (slots + 31) / 32

	if len(tools.picks) > 0 && !tools.picking && int(tools.picks[0].viewport) == frame.viewport {
		request := scale_pick(tools.picks[0], frame)
		size := u32(PICK_HEADER) + words * 4
		zeros, ok := platform.gpu_upload(int(size), 4)
		if ok {
			v.ticket += 1
			tools.picking = true
			v.pick_words = words
			v.pick_near = frame.view.near
			v.pick_view_model_near = render.view_model_view(frame.view).near
			mem.zero_slice(zeros.data)
			pick := new(Pick_Pass, platform.frame_allocator)
			pick^ = {
				pipeline = v.pick_pipeline.pipeline,
				ids      = frame.ids,
				depth    = frame.depth,
				results  = render.import_buffer(g, v.results),
				readback = render.import_buffer(g, v.readback),
				zeros    = zeros,
				size     = size,
				constants = {
					request = v.ticket,
					origin = {request.x, request.y},
					size = {u32(max(request.width, 1)), u32(max(request.height, 1))},
					target_size = frame.size,
					slots = slots,
				},
			}
			p := render.add_compute_pass(g, "editor pick clear", clear_pick, pick)
			render.copy_dest(g, p, pick.results)
			p = render.add_compute_pass(g, "editor pick", run_pick, pick)
			render.read(g, p, frame.ids)
			render.read(g, p, frame.depth)
			render.write(g, p, pick.results)
			p = render.add_compute_pass(g, "editor pick readback", copy_pick, pick)
			render.copy_source(g, p, pick.results)
			render.copy_dest(g, p, pick.readback)
		}
	}

	if !overlays {
		return
	}
	overlay := new(Overlay_Pass, platform.frame_allocator)
	overlay^ = {
		pipeline = v.overlay_pipeline.pipeline,
		ids = frame.ids,
		depth = frame.depth,
		slots = slots,
		view_projection = render.view_projection(frame.view, f32(frame.size.x) / f32(max(frame.size.y, 1))),
	}
	if len(tools.selection) > 0 {
		if upload, ok := platform.gpu_upload(int(max(words, 1)) * 4, 4); ok {
			with_descendants(w, tools.selection[:], ([^]u32)(raw_data(upload.data))[:max(words, 1)])
			overlay.selection = upload
			overlay.outline = true
		}
	}
	if viewport.gizmo.kind != .None || len(viewport.handles) > 0 {
		vertices := make([dynamic]Gizmo_Vertex, platform.frame_allocator)
		box_handle_vertices(viewport.handles[:], viewport.handle_size, frame.view, &vertices)
		gizmo_vertices(viewport.gizmo, frame.view, &vertices)
		if upload, ok := platform.gpu_upload(max(len(vertices), 1) * size_of(Gizmo_Vertex), 16); ok && len(vertices) > 0 {
			copy(upload.data, ([^]byte)(raw_data(vertices))[:len(vertices) * size_of(Gizmo_Vertex)])
			overlay.vertices = upload
			overlay.vertex_count = u32(len(vertices))
		}
	}
	if e.session.mesh_overlay.active {
		vertices := make([dynamic]Gizmo_Vertex, platform.frame_allocator)
		mesh_overlay_vertices(e, w, frame.view, frame.size.y, &vertices)
		if upload, ok := platform.gpu_upload(max(len(vertices), 1) * size_of(Gizmo_Vertex), 16); ok && len(vertices) > 0 {
			copy(upload.data, ([^]byte)(raw_data(vertices))[:len(vertices) * size_of(Gizmo_Vertex)])
			overlay.mesh_vertices = upload
			overlay.mesh_vertex_count = u32(len(vertices))
		}
	}
	if overlay.outline || overlay.vertex_count > 0 || overlay.mesh_vertex_count > 0 {
		p := render.add_render_pass(g, "editor overlay", draw_overlay, overlay)
		render.color(g, p, frame.target, .Load)
		render.read(g, p, frame.ids)
		render.read(g, p, frame.depth)
	}
}

// scale_pick is a pick in the frame's pixels in the scene's, which are larger at a render scale below 1: the scene's
// pixels that the request's cover, at least one.
@(private)
scale_pick :: proc(request: link.Pick_Request, frame: Viewport_Frame) -> link.Pick_Request {
	if frame.output_size == frame.size || frame.output_size.x == 0 || frame.output_size.y == 0 {
		return request
	}
	scale := [2]f32{f32(frame.size.x) / f32(frame.output_size.x), f32(frame.size.y) / f32(frame.output_size.y)}
	r := request
	r.x = i32(f32(request.x) * scale.x)
	r.y = i32(f32(request.y) * scale.y)
	r.width = max(i32(math.ceil(f32(request.x + max(request.width, 1)) * scale.x)) - r.x, 1)
	r.height = max(i32(math.ceil(f32(request.y + max(request.height, 1)) * scale.y)) - r.y, 1)
	return r
}

// Matches Push in shaders/pick.hlsl.
@(private)
Pick_Constants :: struct {
	ids:         u32,
	depth:       u32,
	results:     u32,
	request:     u32,
	origin:      [2]i32,
	size:        [2]u32,
	target_size: [2]u32,
	slots:       u32,
	stencil:     u32,
}

@(private)
Pick_Pass :: struct {
	pipeline:  gpu.Pipeline,
	ids:       render.Texture,
	depth:     render.Texture,
	results:   render.Buffer,
	readback:  render.Buffer,
	zeros:     gpu.Upload,
	// The bytes of results that the pick uses.
	size:      u32,
	constants: Pick_Constants,
}

@(private)
clear_pick :: proc(ctx: ^render.Pass_Context) {
	pick := (^Pick_Pass)(ctx.data)
	gpu.cmd_copy_buffer(ctx.cb, pick.zeros.buffer, pick.zeros.offset, render.gpu_buffer(ctx.graph, pick.results), 0, pick.size)
}

@(private)
run_pick :: proc(ctx: ^render.Pass_Context) {
	pick := (^Pick_Pass)(ctx.data)
	g := ctx.graph
	constants := pick.constants
	constants.ids = gpu.read_index(render.gpu_texture(g, pick.ids))
	constants.depth = gpu.read_index(render.gpu_texture(g, pick.depth))
	constants.stencil = gpu.stencil_index(render.gpu_texture(g, pick.depth))
	constants.results = gpu.write_index(render.gpu_buffer(g, pick.results))
	gpu.cmd_set_pipeline(ctx.cb, pick.pipeline)
	gpu.cmd_push_constants(ctx.cb, &constants)
	groups := (constants.size + 7) / 8
	gpu.cmd_dispatch(ctx.cb, {groups.x, groups.y, 1})
}

@(private)
copy_pick :: proc(ctx: ^render.Pass_Context) {
	pick := (^Pick_Pass)(ctx.data)
	g := ctx.graph
	gpu.cmd_copy_buffer(ctx.cb, render.gpu_buffer(g, pick.results), 0, render.gpu_buffer(g, pick.readback), 0, pick.size)
}

// Matches Push in shaders/overlay.hlsl.
@(private)
Overlay_Constants :: struct {
	view_projection:  matrix[4, 4]f32,
	ids:              u32,
	selection:        u32,
	selection_offset: u32,
	slots:            u32,
	vertices:         u32,
	vertex_offset:    u32,
	mode:             u32,
	depth:            u32,
	stencil:          u32,
}

@(private)
Overlay_Pass :: struct {
	pipeline:        gpu.Pipeline,
	ids:             render.Texture,
	depth:           render.Texture,
	slots:           u32,
	view_projection: matrix[4, 4]f32,
	outline:         bool,
	selection:       gpu.Upload,
	vertices:        gpu.Upload,
	vertex_count:    u32,
	// Mesh mode's overlay, which draws before the gizmo, faded where the scene hides it (see mesh_overlay.odin).
	mesh_vertices:     gpu.Upload,
	mesh_vertex_count: u32,
}

@(private)
draw_overlay :: proc(ctx: ^render.Pass_Context) {
	o := (^Overlay_Pass)(ctx.data)
	constants := Overlay_Constants {
		view_projection = o.view_projection,
		ids             = gpu.read_index(render.gpu_texture(ctx.graph, o.ids)),
		depth           = gpu.read_index(render.gpu_texture(ctx.graph, o.depth)),
		stencil         = gpu.stencil_index(render.gpu_texture(ctx.graph, o.depth)),
		slots           = o.slots,
	}
	gpu.cmd_set_pipeline(ctx.cb, o.pipeline)
	if o.outline {
		constants.selection = gpu.read_index(o.selection.buffer)
		constants.selection_offset = o.selection.offset
		gpu.cmd_push_constants(ctx.cb, &constants)
		gpu.cmd_draw(ctx.cb, 3)
	}
	if o.mesh_vertex_count > 0 {
		constants.vertices = gpu.read_index(o.mesh_vertices.buffer)
		constants.vertex_offset = o.mesh_vertices.offset
		constants.mode = 2
		gpu.cmd_push_constants(ctx.cb, &constants)
		gpu.cmd_draw(ctx.cb, o.mesh_vertex_count)
	}
	if o.vertex_count > 0 {
		constants.vertices = gpu.read_index(o.vertices.buffer)
		constants.vertex_offset = o.vertices.offset
		constants.mode = 1
		gpu.cmd_push_constants(ctx.cb, &constants)
		gpu.cmd_draw(ctx.cb, o.vertex_count)
	}
}

// Visibility is the entities that the editor hides, with their descendants, as a bit for each entity slot. It is in
// frame memory, for one frame.
Visibility :: struct {
	hidden: []u32,
}

// visibility is what the editor hides this frame. A game that draws entities skips those that is_visible rejects, so
// they are neither drawn nor picked. Without an editor, or with nothing hidden, it hides nothing.
visibility :: proc(e: ^Editor, w: ^ecs.World) -> Visibility {
	if !active(e) || len(e.session.view.hidden) == 0 {
		return {}
	}
	bits := make([]u32, (ecs.slot_count(w) + 31) / 32, e.platform.frame_allocator)
	with_descendants(w, e.session.view.hidden[:], bits)
	return {bits}
}

is_visible :: proc "contextless" (v: Visibility, entity: ecs.Entity) -> bool {
	index := ecs.entity_index(entity)
	return int(index / 32) >= len(v.hidden) || v.hidden[index / 32] & (1 << (index % 32)) == 0
}

// with_descendants sets a bit for each slot whose entity is in the list or has an ancestor in it: the outline's
// selection, and the hidden entities.
@(private)
with_descendants :: proc(w: ^ecs.World, selection: []ecs.Entity, bits: []u32) {
	for &b in bits {
		b = 0
	}
	mark :: proc(bits: []u32, entity: ecs.Entity) {
		index := ecs.entity_index(entity)
		if int(index / 32) < len(bits) {
			bits[index / 32] |= 1 << (index % 32)
		}
	}
	for entity in selection {
		if ecs.is_alive(w, entity) {
			mark(bits, entity)
		}
	}
	children := make([dynamic]ecs.Entity, w.platform.frame_allocator)
	ecs.collect(w, {ecs.PARENT_ID}, &children)
	// A child is outlined when any ancestor is selected. The walk stops at a depth that no real hierarchy reaches, in
	// case of a cycle.
	outer: for child in children {
		parent := parent_of(w, child)
		for depth := 0; parent != 0 && depth < 64; depth += 1 {
			for entity in selection {
				if entity == parent {
					mark(bits, child)
					continue outer
				}
			}
			parent = parent_of(w, parent)
		}
	}
}

@(private)
parent_of :: proc(w: ^ecs.World, entity: ecs.Entity) -> ecs.Entity {
	if p := (^ecs.Parent)(ecs.get_raw(w, entity, ecs.PARENT_ID)); p != nil {
		return p.entity
	}
	return 0
}

// create_viewport_gpu makes the tools' pipelines and buffers once. It reports false if they cannot be made.
@(private)
create_viewport_gpu :: proc(e: ^Editor) -> bool {
	v := &e.tools
	if v.gpu_ready || v.gpu_failed {
		return v.gpu_ready
	}
	platform := e.platform
	v.pick_pipeline = render.shader_pipeline(PICK_SHADER)
	v.overlay_pipeline = render.shader_pipeline(OVERLAY_SHADER)
	v.icons_pipeline = render.shader_pipeline(ICONS_SHADER)
	v.results = platform.gpu_create_buffer({size = PICK_RESULTS_SIZE, usage = {.Storage}, label = "editor pick results"}, nil)
	v.readback = platform.gpu_create_buffer({size = PICK_RESULTS_SIZE, usage = {.Readback}, label = "editor pick readback"}, nil)
	v.gpu_ready = e.assets != nil && v.results != {} && v.readback != {}
	if !v.gpu_ready {
		log.error("editor: cannot create the viewport tools' GPU objects")
		destroy_viewport_gpu(e)
		v.gpu_failed = true
	}
	return v.gpu_ready
}

@(private)
destroy_viewport_gpu :: proc(e: ^Editor) {
	v := &e.tools
	platform := e.platform
	render.destroy_shader_pipeline(&v.pick_pipeline, platform)
	render.destroy_shader_pipeline(&v.overlay_pipeline, platform)
	render.destroy_shader_pipeline(&v.icons_pipeline, platform)
	platform.gpu_destroy_buffer(v.results)
	platform.gpu_destroy_buffer(v.readback)
	v.pick_pipeline, v.overlay_pipeline, v.icons_pipeline, v.results, v.readback = {}, {}, {}, {}, {}
	v.gpu_ready = false
}

// sync_viewport_pipelines creates the pipelines from their shaders, and updates them when the cooker compiles the
// shaders again, or when force is set after a code reload, which may bring new descriptions. Until a pipeline is
// ready, the passes that use it record nothing.
@(private)
sync_viewport_pipelines :: proc(e: ^Editor, force := false) {
	v := &e.tools
	if !v.gpu_ready {
		return
	}
	render.sync_compute_pipeline(&v.pick_pipeline, e.platform, e.assets, PICK_PIPELINE, force)
	render.sync_graphics_pipeline(&v.overlay_pipeline, e.platform, e.assets, {.Vertex, .Pixel}, OVERLAY_PIPELINE, force)
	render.sync_graphics_pipeline(&v.icons_pipeline, e.platform, e.assets, {.Vertex, .Pixel}, ICONS_PIPELINE, force)
}

@(private)
PICK_PIPELINE :: gpu.Compute_Pipeline_Desc {
	label = "editor pick",
}

@(private)
OVERLAY_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors = {{format = render.DEBUG_FORMAT, blend = .Alpha}},
	label  = "editor overlay",
}

// handle_viewport_message handles the tools' messages. It reports false for any other message.
@(private)
handle_viewport_message :: proc(e: ^Editor, message: link.Message) -> bool {
	v := &e.session.view
	// A message for a viewport that the game does not have is dropped.
	viewport :: proc(v: ^View, index: u32) -> ^Viewport {
		if index >= MAX_VIEWPORTS {
			log.warnf("editor: the editor names viewport %d, and there are %d", index, MAX_VIEWPORTS)
			return nil
		}
		return &v.viewports[index]
	}
	#partial switch m in message {
	case link.Editor_Camera:
		if p := viewport(v, m.viewport); p != nil {
			p.camera = m
		}
	case link.Open_Viewport:
		// Viewport 0 is the frame, whose size is the host's.
		if p := viewport(v, m.viewport); p != nil && m.viewport > 0 {
			size := [2]u32{u32(clamp(m.width, 1, gpu.MAX_VIEWPORT_SIZE)), u32(clamp(m.height, 1, gpu.MAX_VIEWPORT_SIZE))}
			if target, open := &p.target.?; open {
				target.size = size
			} else {
				p.target = Viewport_Target{size = size}
			}
		}
	case link.Close_Viewport:
		if m.viewport > 0 && m.viewport < MAX_VIEWPORTS {
			close_viewport(e, int(m.viewport))
		}
	case link.Set_Selection:
		clear(&v.selection)
		for entity in m.entities {
			append(&v.selection, ecs.Entity(entity))
		}
	case link.Set_Hidden:
		clear(&v.hidden)
		for entity in m.entities {
			append(&v.hidden, ecs.Entity(entity))
		}
	case link.Gizmo_State:
		if p := viewport(v, m.viewport); p != nil {
			p.gizmo = m
		}
	case link.Box_Handles:
		if p := viewport(v, m.viewport); p != nil {
			clear(&p.handles)
			append(&p.handles, ..m.handles)
			p.handle_size = m.size
		}
	case link.Set_Viewport_Settings:
		if p := viewport(v, m.viewport); p != nil {
			p.settings = m.settings
		}
	case link.Pick_Request:
		if len(v.picks) == MAX_PICKS {
			log.warnf("editor: more than %d picks wait for the GPU, so pick %d is dropped", MAX_PICKS, m.id)
			return true
		}
		append(&v.picks, m)
	case:
		return false
	}
	return true
}

// close_viewport closes an extra viewport: it draws no more, and its shared target goes. Its camera, gizmo and settings
// stay, as the editor sends them whether the viewport is open or not.
@(private)
close_viewport :: proc(e: ^Editor, index: int) {
	v := &e.session.view.viewports[index]
	if _, open := v.target.?; open {
		v.target = nil
		e.platform.gpu_release_viewport_target(index - 1)
	}
}

// viewport_open is whether a viewport draws: the frame's always, and another one while it is open.
@(private)
viewport_open :: proc(e: ^Editor, index: u32) -> bool {
	if index >= MAX_VIEWPORTS {
		return false
	}
	_, open := e.session.view.viewports[index].target.?
	return index == 0 || open
}

// send_viewport_targets tells the editor of each extra viewport's target that is new, or of a new generation.
@(private)
send_viewport_targets :: proc(e: ^Editor, out: ^[dynamic]byte) {
	for &v, i in e.session.view.viewports {
		target, open := &v.target.?
		if !open {
			continue
		}
		if pending, is_pending := &target.announce.(Target_Pending); is_pending {
			link.write_message(
				out,
				link.Viewport_Target {
					viewport = u32(i),
					prefix = string(pending.prefix[:pending.prefix_length]),
					generation = pending.generation,
					width = i32(pending.size.x),
					height = i32(pending.size.y),
				},
			)
			target.announce = Target_Told{pending.generation}
		}
	}
}

// finish_pick sends the answer to the pick that the GPU ran, once its results are on the CPU. A pick at the head of the
// line whose viewport is not open would never run, so it is answered with no hits.
@(private)
finish_pick :: proc(e: ^Editor, w: ^ecs.World, out: ^[dynamic]byte, allocator: runtime.Allocator) {
	v := &e.tools
	tools := &e.session.view
	for !tools.picking && len(tools.picks) > 0 && !viewport_open(e, tools.picks[0].viewport) {
		link.write_message(out, link.Pick_Result{id = tools.picks[0].id, submesh = -1})
		ordered_remove(&tools.picks, 0)
	}
	if !tools.picking || !v.gpu_ready {
		return
	}
	data, ok := e.platform.gpu_read_buffer(v.readback)
	if !ok {
		return
	}
	tools.picking = false
	words := ([^]u32)(raw_data(data))
	// A frame that did not run the pick, such as one that the GPU dropped, leaves an old ticket, and the pick runs again.
	if words[0] != v.ticket || len(tools.picks) == 0 {
		return
	}
	request := tools.picks[0]
	ordered_remove(&tools.picks, 0)
	link.write_message(out, pick_result(w, request, words[:PICK_HEADER / 4 + v.pick_words], v.pick_near, v.pick_view_model_near, allocator))
}

// pick_result reads a pick's results: the header and the bits of entity slots.
@(private)
pick_result :: proc(w: ^ecs.World, request: link.Pick_Request, words: []u32, near, view_model_near: f32, allocator: runtime.Allocator) -> link.Pick_Result {
	hits := make([dynamic]link.Pick_Hit, allocator)
	for word, i in words[PICK_HEADER / 4:] {
		for bit in 0 ..< u32(32) {
			if word & (1 << bit) == 0 {
				continue
			}
			if entity, alive := ecs.slot_entity(w, u32(i) * 32 + bit); alive {
				append(&hits, link.Pick_Hit{entity = u64(entity), scene_id = scene_id_of(w, entity)})
			}
		}
	}
	depth: f32
	submesh: i32 = -1
	if request.width <= 1 && request.height <= 1 && render.id_entity(words[1]) != 0 {
		// The view model's pixels have the view model's near plane (see docs/rendering/layers-and-output.md#view-model).
		depth = render.view_depth(transmute(f32)words[2], words[3] & render.VIEW_MODEL_STENCIL != 0 ? view_model_near : near)
		submesh = i32(render.id_submesh(words[1]))
	}
	return {id = request.id, hits = hits[:], depth = depth, submesh = submesh}
}

// The gizmo's shape, as fractions of Gizmo_State.size. The editor's hit test uses the same numbers (see
// Gizmo.cs in Cinnabar.Editor.Tools).
@(private)
GIZMO_WIDTH :: 0.03
@(private)
GIZMO_SHAFT :: 0.82
@(private)
GIZMO_CONE :: 0.07
@(private)
GIZMO_PLANE_NEAR :: 0.25
@(private)
GIZMO_PLANE_FAR :: 0.5
@(private)
GIZMO_CENTER :: 0.08
@(private)
GIZMO_VIEW_RING :: 1.2
@(private)
GIZMO_CUBE :: 0.06
@(private)
GIZMO_RING_SEGMENTS :: 64

// Matches Vertex in shaders/overlay.hlsl.
@(private)
Gizmo_Vertex :: struct {
	position: [3]f32,
	// RGBA8, linear.
	color:    u32,
}

@(private)
Gizmo_Builder :: struct {
	out:   ^[dynamic]Gizmo_Vertex,
	right: [3]f32,
	up:    [3]f32,
}

@(private)
GIZMO_COLORS := [link.Gizmo_Part][4]f32 {
	.None = {0, 0, 0, 0},
	.X    = {0.80, 0.07, 0.05, 1},
	.Y    = {0.20, 0.65, 0.04, 1},
	.Z    = {0.06, 0.22, 0.90, 1},
	// A plane has the color of the axis it does not move along.
	.XY   = {0.06, 0.22, 0.90, 0.4},
	.YZ   = {0.80, 0.07, 0.05, 0.4},
	.ZX   = {0.20, 0.65, 0.04, 0.4},
	.View = {0.80, 0.80, 0.80, 0.8},
}

@(private)
GIZMO_HOT :: [4]f32{1, 0.65, 0.02, 1}

// gizmo_vertices builds the gizmo's triangles, relative to the view. Translate has arrows, planes and a square in the
// middle; Rotate has a ring about each axis and one about the view's axis; Scale has axes with cubes and a cube in the
// middle. The hot part is drawn in the highlight color.
@(private)
gizmo_vertices :: proc(gizmo: link.Gizmo_State, view: render.View, out: ^[dynamic]Gizmo_Vertex) {
	center := ecs.position_sub({gizmo.position}, view.position)
	r := gizmo.rotation
	rotation := quaternion(x = r.x, y = r.y, z = r.z, w = r.w)
	if abs(linalg.length(r)) < 1e-6 {
		rotation = 1
	}
	axes := [3][3]f32 {
		linalg.quaternion128_mul_vector3(rotation, [3]f32{1, 0, 0}),
		linalg.quaternion128_mul_vector3(rotation, [3]f32{0, 1, 0}),
		linalg.quaternion128_mul_vector3(rotation, [3]f32{0, 0, 1}),
	}
	s := gizmo.size
	right, up, _ := render.view_axes(view)
	b := Gizmo_Builder{out, right, up}
	color :: proc(gizmo: link.Gizmo_State, part: link.Gizmo_Part) -> u32 {
		c := GIZMO_COLORS[part]
		if gizmo.hot == part {
			c = {GIZMO_HOT.r, GIZMO_HOT.g, GIZMO_HOT.b, max(c.a, 0.6)}
		}
		return pack_color(c)
	}
	AXIS_PARTS :: [3]link.Gizmo_Part{.X, .Y, .Z}
	PLANE_PARTS :: [3]link.Gizmo_Part{.XY, .YZ, .ZX}

	switch gizmo.kind {
	case .None:
	case .Translate:
		for part, i in PLANE_PARTS {
			u, w := axes[i], axes[(i + 1) % 3]
			c := color(gizmo, part)
			near, far := GIZMO_PLANE_NEAR * s, GIZMO_PLANE_FAR * s
			quad(&b, center + u * near + w * near, center + u * far + w * near, center + u * far + w * far, center + u * near + w * far, c)
		}
		for part, i in AXIS_PARTS {
			c := color(gizmo, part)
			ribbon(&b, center, center + axes[i] * (GIZMO_SHAFT * s), GIZMO_WIDTH * s, c)
			cone(&b, center + axes[i] * (GIZMO_SHAFT * s), axes[i], (1 - GIZMO_SHAFT) * s, GIZMO_CONE * s, c)
		}
		h := GIZMO_CENTER * s
		quad(&b, center - right * h - up * h, center + right * h - up * h, center + right * h + up * h, center - right * h + up * h, color(gizmo, .View))
	case .Rotate:
		for part, i in AXIS_PARTS {
			ring(&b, center, axes[(i + 1) % 3], axes[(i + 2) % 3], s, GIZMO_WIDTH * s, color(gizmo, part))
		}
		ring(&b, center, right, up, GIZMO_VIEW_RING * s, GIZMO_WIDTH * s, color(gizmo, .View))
	case .Scale:
		for part, i in AXIS_PARTS {
			c := color(gizmo, part)
			end := center + axes[i] * ((1 - GIZMO_CUBE) * s)
			ribbon(&b, center, end, GIZMO_WIDTH * s, c)
			cube(&b, end, axes, GIZMO_CUBE * s, c)
		}
		cube(&b, center, axes, GIZMO_CENTER * s, color(gizmo, .View))
	}
}

// box_handle_vertices builds the box handles' triangles, relative to the view: a cube of size meters on each handle, in
// its box's color, and the hot one in the highlight color. They go before the gizmo, which draws over them.
@(private)
box_handle_vertices :: proc(handles: []link.Box_Handle, size: f32, view: render.View, out: ^[dynamic]Gizmo_Vertex) {
	right, up, forward := render.view_axes(view)
	b := Gizmo_Builder{out, right, up}
	for h in handles {
		c := PROBE_COLORS[h.kind]
		if h.hot {
			c = {GIZMO_HOT.r, GIZMO_HOT.g, GIZMO_HOT.b, 1}
		}
		center := ecs.position_sub({h.position}, view.position)
		cube(&b, center, {right, up, forward}, size * 0.5, pack_color(c))
	}
}

@(private)
pack_color :: proc(c: [4]f32) -> u32 {
	b := linalg.clamp(c, 0, 1) * 255 + 0.5
	return u32(b.r) | u32(b.g) << 8 | u32(b.b) << 16 | u32(b.a) << 24
}

@(private)
triangle :: proc(b: ^Gizmo_Builder, p0, p1, p2: [3]f32, color: u32) {
	append(b.out, Gizmo_Vertex{p0, color}, Gizmo_Vertex{p1, color}, Gizmo_Vertex{p2, color})
}

@(private)
quad :: proc(b: ^Gizmo_Builder, p0, p1, p2, p3: [3]f32, color: u32) {
	triangle(b, p0, p1, p2, color)
	triangle(b, p0, p2, p3, color)
}

// ribbon is a segment of a width, turned to face the view, which is at the origin.
@(private)
ribbon :: proc(b: ^Gizmo_Builder, from, to: [3]f32, width: f32, color: u32) {
	side := linalg.cross(to - from, (from + to) * 0.5)
	if linalg.length(side) < 1e-9 {
		side = b.right
	}
	side = linalg.normalize(side) * (width * 0.5)
	quad(b, from - side, to - side, to + side, from + side, color)
}

@(private)
ring :: proc(b: ^Gizmo_Builder, center, u, w: [3]f32, radius, width: f32, color: u32) {
	point :: proc(center, u, w: [3]f32, radius: f32, k: int) -> [3]f32 {
		angle := f32(k) * (2 * math.PI / GIZMO_RING_SEGMENTS)
		return center + (u * math.cos(angle) + w * math.sin(angle)) * radius
	}
	for k in 0 ..< GIZMO_RING_SEGMENTS {
		ribbon(b, point(center, u, w, radius, k), point(center, u, w, radius, k + 1), width, color)
	}
}

@(private)
cone :: proc(b: ^Gizmo_Builder, base, axis: [3]f32, length, radius: f32, color: u32) {
	SEGMENTS :: 12
	u := linalg.normalize(linalg.cross(axis, abs(axis.y) < 0.9 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}))
	w := linalg.cross(axis, u)
	tip := base + axis * length
	for k in 0 ..< SEGMENTS {
		a0 := f32(k) * (2 * math.PI / SEGMENTS)
		a1 := f32(k + 1) * (2 * math.PI / SEGMENTS)
		p0 := base + (u * math.cos(a0) + w * math.sin(a0)) * radius
		p1 := base + (u * math.cos(a1) + w * math.sin(a1)) * radius
		triangle(b, tip, p0, p1, color)
		triangle(b, base, p1, p0, color)
	}
}

@(private)
cube :: proc(b: ^Gizmo_Builder, center: [3]f32, axes: [3][3]f32, half: f32, color: u32) {
	corner :: proc(center: [3]f32, axes: [3][3]f32, half: f32, i: int) -> [3]f32 {
		sx: f32 = i & 1 != 0 ? 1 : -1
		sy: f32 = i & 2 != 0 ? 1 : -1
		sz: f32 = i & 4 != 0 ? 1 : -1
		return center + (axes[0] * sx + axes[1] * sy + axes[2] * sz) * half
	}
	FACES :: [6][4]int{{0, 1, 3, 2}, {4, 6, 7, 5}, {0, 4, 5, 1}, {2, 3, 7, 6}, {0, 2, 6, 4}, {1, 5, 7, 3}}
	for f in FACES {
		quad(b, corner(center, axes, half, f[0]), corner(center, axes, half, f[1]), corner(center, axes, half, f[2]), corner(center, axes, half, f[3]), color)
	}
}

#assert(size_of(Gizmo_Vertex) == 16)
