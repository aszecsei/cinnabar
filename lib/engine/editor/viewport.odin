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

// The viewport tools' game side (see docs/editor.md#viewport). The editor sends its camera, its selection and its
// gizmo, and the game draws the frame from that camera with add_viewport_passes after its own passes: an outline
// around the selection and the gizmo over the frame. The game's scene pass also writes an entity ID buffer, and a
// pick reads it and the depth, and copies the result to the CPU.

// The entity ID buffer's format. Each pixel holds entity_id of the entity drawn there, or 0.
ID_FORMAT :: gpu.Format.R32_Uint
// At most this many picks wait for the GPU. The editor waits for each answer, so it sends one or two at a time.
MAX_PICKS :: 16

// The pick results: the pick's ticket, the ID and depth at the rectangle's origin, and padding, then a bit for each
// entity slot. Matches HEADER_SIZE in shaders/pick.hlsl.
@(private)
PICK_HEADER :: 16
@(private)
PICK_RESULTS_SIZE :: PICK_HEADER + ecs.MAX_ENTITIES / 8

// The tools' shaders are engine content (see docs/content-pipeline.md#shaders).
@(private)
PICK_SHADER :: #load("../content/shaders/pick.hlsl.meta", string)
@(private)
OVERLAY_SHADER :: #load("../content/shaders/overlay.hlsl.meta", string)

// Viewport is the editor's camera, selection and gizmo, and the picks that wait for the GPU. It lives in Editor.
Viewport :: struct {
	camera:           link.Editor_Camera,
	has_camera:       bool,
	selection:        [dynamic]ecs.Entity,
	// The entities that the editor hides, with their descendants. The game does not draw them.
	hidden:           [dynamic]ecs.Entity,
	gizmo:            link.Gizmo_State,
	picks:            [dynamic]link.Pick_Request,
	// picks[0] was rendered with this ticket, and its results come back through the readback buffer.
	picking:          bool,
	ticket:           u32,
	// What the pick needs to read its results: the words of entity bits and the near plane that it was drawn with.
	pick_words:       u32,
	pick_near:        f32,
	// The GPU objects, made at the first frame that draws the tools. If they cannot be made, the tools stay off.
	gpu_ready:        bool,
	gpu_failed:       bool,
	pick_pipeline:    render.Shader_Pipeline,
	overlay_pipeline: render.Shader_Pipeline,
	results:          gpu.Buffer,
	readback:         gpu.Buffer,
}

// Viewport_Frame is what the game drew that the tools draw on and pick from.
Viewport_Frame :: struct {
	view:   render.View,
	size:   [2]u32,
	// The frame target, which the tools draw over.
	target: render.Texture,
	// The ID buffer, in ID_FORMAT, and the depth that the scene pass wrote with render.view_projection.
	ids:    render.Texture,
	depth:  render.Texture,
}

// active is true while an editor is linked: the game then draws from view, writes the ID buffer, keeps its depth and
// calls add_viewport_passes.
active :: proc(e: ^Editor) -> bool {
	return e.connection != 0
}

// view is the editor's camera, once a linked editor has sent one, in edit mode or with the free camera.
view :: proc(e: ^Editor) -> (render.View, bool) {
	c := e.viewport.camera
	// In play mode the game's own camera draws, unless the editor flies its free camera.
	if !active(e) || !e.viewport.has_camera || (e.mode != .Edit && !e.free_camera) {
		return {}, false
	}
	return {
			position = {c.position},
			rotation = quaternion(x = c.rotation.x, y = c.rotation.y, z = c.rotation.z, w = c.rotation.w),
			vertical_fov = c.vertical_fov,
			near = c.near,
		},
		true
}

// entity_id is an entity's value in the ID buffer: its index + 1, so 0 is no entity. A pick finds the entity that
// is in that slot when the answer arrives.
entity_id :: proc "contextless" (entity: ecs.Entity) -> u32 {
	return ecs.entity_index(entity) + 1
}

// add_viewport_passes adds the pick and the overlay to the frame's graph. Add them after the passes that write the
// target, the ID buffer and the depth.
add_viewport_passes :: proc(e: ^Editor, g: ^render.Graph, w: ^ecs.World, frame: Viewport_Frame) {
	v := &e.viewport
	if !active(e) || !create_viewport_gpu(e) {
		return
	}
	sync_viewport_pipelines(e)
	platform := e.platform
	slots := ecs.slot_count(w)
	words := (slots + 31) / 32

	if len(v.picks) > 0 && !v.picking {
		request := v.picks[0]
		size := u32(PICK_HEADER) + words * 4
		zeros, ok := platform.gpu_upload(int(size), 4)
		if ok {
			v.ticket += 1
			v.picking = true
			v.pick_words = words
			v.pick_near = frame.view.near
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

	overlay := new(Overlay_Pass, platform.frame_allocator)
	overlay^ = {
		pipeline = v.overlay_pipeline.pipeline,
		ids = frame.ids,
		depth = frame.depth,
		slots = slots,
		view_projection = render.view_projection(frame.view, f32(frame.size.x) / f32(max(frame.size.y, 1))),
	}
	if len(v.selection) > 0 {
		if upload, ok := platform.gpu_upload(int(max(words, 1)) * 4, 4); ok {
			with_descendants(w, v.selection[:], ([^]u32)(raw_data(upload.data))[:max(words, 1)])
			overlay.selection = upload
			overlay.outline = true
		}
	}
	if v.gizmo.kind != .None {
		vertices := make([dynamic]Gizmo_Vertex, platform.frame_allocator)
		gizmo_vertices(v.gizmo, frame.view, &vertices)
		if upload, ok := platform.gpu_upload(max(len(vertices), 1) * size_of(Gizmo_Vertex), 16); ok && len(vertices) > 0 {
			copy(upload.data, ([^]byte)(raw_data(vertices))[:len(vertices) * size_of(Gizmo_Vertex)])
			overlay.vertices = upload
			overlay.vertex_count = u32(len(vertices))
		}
	}
	if overlay.outline || overlay.vertex_count > 0 {
		p := render.add_render_pass(g, "editor overlay", draw_overlay, overlay)
		render.color(g, p, frame.target, .Load)
		render.read(g, p, frame.ids)
		render.read(g, p, frame.depth)
	}
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
}

@(private)
draw_overlay :: proc(ctx: ^render.Pass_Context) {
	o := (^Overlay_Pass)(ctx.data)
	constants := Overlay_Constants {
		view_projection = o.view_projection,
		ids             = gpu.read_index(render.gpu_texture(ctx.graph, o.ids)),
		depth           = gpu.read_index(render.gpu_texture(ctx.graph, o.depth)),
		slots           = o.slots,
	}
	gpu.cmd_set_pipeline(ctx.cb, o.pipeline)
	if o.outline {
		constants.selection = gpu.read_index(o.selection.buffer)
		constants.selection_offset = o.selection.offset
		gpu.cmd_push_constants(ctx.cb, &constants)
		gpu.cmd_draw(ctx.cb, 3)
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
	if !active(e) || len(e.viewport.hidden) == 0 {
		return {}
	}
	bits := make([]u32, (ecs.slot_count(w) + 31) / 32, e.platform.frame_allocator)
	with_descendants(w, e.viewport.hidden[:], bits)
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
	v := &e.viewport
	if v.gpu_ready || v.gpu_failed {
		return v.gpu_ready
	}
	platform := e.platform
	v.pick_pipeline = render.shader_pipeline(PICK_SHADER)
	v.overlay_pipeline = render.shader_pipeline(OVERLAY_SHADER)
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
	v := &e.viewport
	platform := e.platform
	render.destroy_shader_pipeline(&v.pick_pipeline, platform)
	render.destroy_shader_pipeline(&v.overlay_pipeline, platform)
	platform.gpu_destroy_buffer(v.results)
	platform.gpu_destroy_buffer(v.readback)
	v.pick_pipeline, v.overlay_pipeline, v.results, v.readback = {}, {}, {}, {}
	v.gpu_ready = false
}

// sync_viewport_pipelines creates the pipelines from their shaders, and updates them when the cooker compiles the
// shaders again, or when force is set after a code reload, which may bring new descriptions. Until a pipeline is
// ready, the passes that use it record nothing.
@(private)
sync_viewport_pipelines :: proc(e: ^Editor, force := false) {
	v := &e.viewport
	if !v.gpu_ready {
		return
	}
	render.sync_compute_pipeline(&v.pick_pipeline, e.platform, e.assets, PICK_PIPELINE, force)
	render.sync_graphics_pipeline(&v.overlay_pipeline, e.platform, e.assets, {.Vertex, .Pixel}, OVERLAY_PIPELINE, force)
}

@(private)
PICK_PIPELINE :: gpu.Compute_Pipeline_Desc {
	label = "editor pick",
}

@(private)
OVERLAY_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors = {{format = gpu.FRAME_TARGET_FORMAT, blend = .Alpha}},
	label  = "editor overlay",
}

// handle_viewport_message handles the tools' messages. It reports false for any other message.
@(private)
handle_viewport_message :: proc(e: ^Editor, message: link.Message) -> bool {
	v := &e.viewport
	#partial switch m in message {
	case link.Editor_Camera:
		v.camera = m
		v.has_camera = true
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
		v.gizmo = m
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

// reset_viewport forgets what an editor sent, for a new editor. A pick that the GPU still runs finishes with an old
// ticket, so nothing reads it.
@(private)
reset_viewport :: proc(e: ^Editor) {
	v := &e.viewport
	v.camera, v.has_camera, v.gizmo, v.picking = {}, false, {}, false
	clear(&v.selection)
	clear(&v.hidden)
	clear(&v.picks)
}

// finish_pick sends the answer to the pick that the GPU ran, once its results are on the CPU.
@(private)
finish_pick :: proc(e: ^Editor, w: ^ecs.World, out: ^[dynamic]byte, allocator: runtime.Allocator) {
	v := &e.viewport
	if !v.picking || !v.gpu_ready {
		return
	}
	data, ok := e.platform.gpu_read_buffer(v.readback)
	if !ok {
		return
	}
	v.picking = false
	words := ([^]u32)(raw_data(data))
	// A frame that did not run the pick, such as one that the GPU dropped, leaves an old ticket, and the pick runs again.
	if words[0] != v.ticket || len(v.picks) == 0 {
		return
	}
	request := v.picks[0]
	ordered_remove(&v.picks, 0)
	link.write_message(out, pick_result(w, request, words[:PICK_HEADER / 4 + v.pick_words], v.pick_near, allocator))
}

// pick_result reads a pick's results: the header and the bits of entity slots.
@(private)
pick_result :: proc(w: ^ecs.World, request: link.Pick_Request, words: []u32, near: f32, allocator: runtime.Allocator) -> link.Pick_Result {
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
	if request.width <= 1 && request.height <= 1 && words[1] != 0 {
		depth = render.view_depth(transmute(f32)words[2], near)
	}
	return {id = request.id, hits = hits[:], depth = depth}
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
