package render

import "core:math"
import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// Shadows (see docs/rendering/lighting-and-shadows.md#shadows). With Ray_Query and traced shadows in the quality, a compute pass
// traces up to four lights' shadows into a screen-space mask, from the prepass's depth, against an acceleration
// structure of the GPU scene. The other lights that cast shadows get shadow maps in one atlas: the cascades for the
// first directional light, one view for a spot light, and six for a point light. The maps draw each material's depth
// pass.

SHADOW_FORMAT :: gpu.Format.D32_Float
// The most cascades that a level has. Frame_Constants.cascade_splits holds this many.
SHADOW_CASCADES :: 4

// Shadow_Filter is how many bilinear comparisons a shadow map's lookup takes: 1 is the hardware's 2x2, 4 a 3x3
// neighbourhood, 9 a 4x4. Matches shadow_map in material_lighting.hlsli.
Shadow_Filter :: enum u32 {
	Taps_1 = 1,
	Taps_4 = 4,
	Taps_9 = 9,
}

// Shadow_Params are the shadow maps at a level. The atlas is square. Cascades take cells of cell pixels; spot lights
// and point lights' faces take slots of slot pixels, several to a cell.
Shadow_Params :: struct {
	atlas:    int,
	cell:     int,
	slot:     int,
	cascades: int,
	filter:   Shadow_Filter,
}

@(rodata)
SHADOW_PARAMS := [Quality_Level]Shadow_Params {
	.Low    = {atlas = 2048, cell = 1024, slot = 512, cascades = 2, filter = .Taps_1},
	.Medium = {atlas = 4096, cell = 1024, slot = 512, cascades = 3, filter = .Taps_4},
	.High   = {atlas = 4096, cell = 1024, slot = 512, cascades = 4, filter = .Taps_4},
	.Ultra  = {atlas = 8192, cell = 2048, slot = 1024, cascades = 4, filter = .Taps_9},
}
// By default, the cascades cover the view to this depth, in meters, split between even and exponential by this much
// (see Shadows).
SHADOW_DISTANCE :: 100
SHADOW_SPLIT_LAMBDA :: 0.75
// The depth bias of the shadow maps' pipelines (see gpu.Graphics_Pipeline_Desc). Depth is reversed, so it is negative.
SHADOW_DEPTH_BIAS :: -64
SHADOW_SLOPE_BIAS :: -2
// A spot light's and a point light's shadow views start this close to the light.
SHADOW_NEAR :: 0.05
// The mask has a channel for each traced light.
MAX_MASK_LIGHTS :: 4
SHADOW_MASK_FORMAT :: gpu.Format.RGBA8_Unorm
MASK_GROUP_SIZE :: 8

// slots_per_cell is how many slots a cell holds.
slots_per_cell :: proc(p: Shadow_Params) -> int {
	return (p.cell / p.slot) * (p.cell / p.slot)
}

// max_shadow_views is how many slots the atlas holds.
max_shadow_views :: proc(p: Shadow_Params) -> int {
	cells := p.atlas / p.cell
	return cells * cells * slots_per_cell(p)
}

// SHADOW_MASK_SHADER is the engine's shadow mask shader (lib/engine/content/shaders/shadow_mask.hlsl).
SHADOW_MASK_SHADER :: #load("../content/shaders/shadow_mask.hlsl.meta", string)

// Shadow_View matches Shadow_View in material_common.hlsli: a shadow map's projection of positions relative to the
// camera, as its matrix's rows, its rectangle of the atlas in UV, and the size of a texel.
Shadow_View :: struct {
	rows:            [4][4]f32,
	rect:            [4]f32,
	// In meters for an orthographic view, at 1 m for a perspective one.
	texel:           f32,
	perspective:     u32,
	padding:         [2]f32,
}

#assert(size_of(Shadow_View) == 96)

// Mask_Constants matches Mask_Constants in shadow_mask.hlsl.
Mask_Constants :: struct {
	right:         [4]f32,
	up:            [4]f32,
	forward:       [4]f32,
	projection:    [4]f32,
	view_model:    [4]f32,
	camera_offset: [4]f32,
	light_index:   [4]u32,
	depth:         u32,
	normals:       u32,
	output:        u32,
	accel:         u32,
	lights:        u32,
	lights_offset: u32,
	size:          [2]u32,
	stencil:       u32,
	// The camera's jitter, which the prepass drew with (see Frame.jitter).
	jitter:        [2]f32,
	padding:       u32,
}

// Shadow_Passes is the shadows' state between frames, in the Renderer.
Shadow_Passes :: struct {
	mask_pipeline: Shader_Pipeline,
	sampler:       gpu.Sampler,
}

// Shadow_Frame is one frame's shadows, in frame memory: the shadow maps' views, and the lights of the mask's channels.
@(private)
Shadow_Frame :: struct {
	views:          [dynamic]Shadow_View,
	// Each view's projection, as the depth pass's Frame_Constants hold it, and its culling planes, relative to the camera, and its rectangle of the atlas in pixels.
	matrices:       [dynamic]matrix[4, 4]f32,
	planes:         [dynamic][6][4]f32,
	// Where each view looks from, as Frame_Constants.cull_eye has it: the light's position relative to the camera in
	// w = 1, or the direction that its light travels in w = 0.
	eyes:           [dynamic][4]f32,
	viewports:      [dynamic][4]u32,
	cascade_splits: [4]f32,
	params:         Shadow_Params,
	mask_lights:    [MAX_MASK_LIGHTS]u32,
	mask_count:     int,
	atlas:          Texture,
	mask:           Texture,
	views_upload:   gpu.Upload,
	mask_constants: gpu.Upload,
}

shadows_init :: proc(s: ^Shadow_Passes, platform: ^core.Platform_API) {
	s.mask_pipeline = shader_pipeline(SHADOW_MASK_SHADER)
	s.sampler = platform.gpu_create_sampler({filter = .Linear, address = .Clamp, compare = .Greater_Equal, label = "shadow comparison"})
}

shadows_destroy :: proc(s: ^Shadow_Passes, platform: ^core.Platform_API) {
	platform.gpu_destroy_sampler(s.sampler)
	destroy_shader_pipeline(&s.mask_pipeline, platform)
}

// cascade_splits are the view depths at which count cascades end: between even and exponential splits of the range
// from the near plane to distance, lambda of the way to exponential. The splits past count repeat the last, so no
// depth reaches a cascade past it.
cascade_splits :: proc(near: f32, distance: f32 = SHADOW_DISTANCE, lambda: f32 = SHADOW_SPLIT_LAMBDA, count := SHADOW_CASCADES) -> (splits: [SHADOW_CASCADES]f32) {
	far := max(distance, near * 2)
	n := clamp(count, 1, SHADOW_CASCADES)
	for &split, i in splits {
		t := f32(min(i + 1, n)) / f32(n)
		exponential := near * math.pow(far / near, t)
		even := near + (far - near) * t
		split = lambda * exponential + (1 - lambda) * even
	}
	return
}

// assign_shadows gives the lights that cast shadows their shadows, in order: the directional lights, then the
// punctual lights by how much light they bring to the view. With traced shadows, the first MAX_MASK_LIGHTS take
// channels of the mask. The others take shadow maps while the atlas has room: the cascades only for one directional
// light.
@(private)
assign_shadows :: proc(f: ^Frame) {
	r := f.renderer
	if r.caps.ray_query {
		// Synced whether or not this frame traces, so turning tracing on does not wait for it to compile.
		sync_compute_pipeline(&r.shadows.mask_pipeline, r.platform, r.residency.assets, {label = "shadow mask"}, r.reloaded)
	}
	trace := f.shadow_settings.ray_traced && r.shadows.mask_pipeline.pipeline != {} && request_ray_scene(f)
	assign_shadow_views(f, trace)
}

// assign_shadow_views gives the lights their shadows, with the mask's channels first if trace.
@(private)
assign_shadow_views :: proc(f: ^Frame, trace: bool) {
	r := f.renderer
	lf := f.lights
	sf := new(Shadow_Frame, r.platform.frame_allocator)
	f.shadows = sf
	sf.views = make([dynamic]Shadow_View, r.platform.frame_allocator)
	sf.matrices = make([dynamic]matrix[4, 4]f32, r.platform.frame_allocator)
	sf.planes = make([dynamic][6][4]f32, r.platform.frame_allocator)
	sf.eyes = make([dynamic][4]f32, r.platform.frame_allocator)
	sf.viewports = make([dynamic][4]u32, r.platform.frame_allocator)
	sf.params = SHADOW_PARAMS[f.shadow_settings.level]
	max_views := max_shadow_views(sf.params)

	// The directional lights first, in their order, then the punctual ones by their light in view.
	order := make([dynamic]int, r.platform.frame_allocator)
	importance := make([]f32, len(lf.records), r.platform.frame_allocator)
	camera_planes := frustum_planes(f.view_projection)
	for record, i in lf.records {
		if !lf.casts[i] {
			continue
		}
		if record.type != .Directional {
			if !sphere_inside(camera_planes[:], record.position, record.range) {
				continue
			}
			importance[i] = max(record.color.r, record.color.g, record.color.b) / max(linalg.length2(record.position), 1)
		}
		append(&order, i)
	}
	punctual_start := 0
	for i in order {
		if lf.records[i].type == .Directional {
			punctual_start += 1
		}
	}
	sort_by_importance(order[punctual_start:], importance)

	cascades_taken := false
	next_slot := 0
	first_slot := 0
	for i in order {
		record := &lf.records[i]
		if trace && sf.mask_count < MAX_MASK_LIGHTS {
			record.mask = i32(sf.mask_count)
			sf.mask_lights[sf.mask_count] = u32(i)
			sf.mask_count += 1
			continue
		}
		switch record.type {
		case .Directional:
			// The cascades take the first cells, so the slots start after them. A second directional light without a
			// mask channel has no shadow.
			if cascades_taken || next_slot > 0 {
				continue
			}
			cascades_taken = true
			first_slot = sf.params.cascades * slots_per_cell(sf.params)
			record.shadow = i32(len(sf.views))
			add_cascades(f, sf, record.direction)
		case .Spot:
			if first_slot + next_slot + 1 > max_views {
				continue
			}
			record.shadow = i32(len(sf.views))
			cone := math.acos(clamp(-record.spot_offset / record.spot_scale, -1, 1))
			// The cone's half angle is where the falloff reaches 0: cos = -offset / scale.
			add_perspective_view(f, sf, record.position, record.direction, min(cone * 2, math.to_radians(f32(170))), record.range, first_slot + next_slot)
			next_slot += 1
		case .Point, .Quad, .Disk, .Line:
			// An area light casts its shadows from its middle, as a point light does.
			if first_slot + next_slot + 6 > max_views {
				continue
			}
			record.shadow = i32(len(sf.views))
			for axis in CUBE_FACES {
				add_perspective_view(f, sf, record.position, axis, math.PI / 2, record.range, first_slot + next_slot)
				next_slot += 1
			}
		}
	}
	if !cascades_taken {
		// Every view depth is beyond the last split, so no pixel looks for a cascade.
		sf.cascade_splits = {}
	}
	if len(sf.views) > 0 {
		ok: bool
		sf.views_upload, ok = upload_bytes(r.platform, ([^]byte)(raw_data(sf.views))[:len(sf.views) * size_of(Shadow_View)])
		if !ok {
			// Without their views, the lights have no shadow maps.
			for &record in lf.records {
				record.shadow = -1
			}
			clear(&sf.views)
		}
	}
}

// The cube faces' directions, in the order that light_shadow in material_lighting.hlsli picks them.
@(private = "file")
CUBE_FACES :: [6][3]f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}

@(private = "file")
sort_by_importance :: proc(order: []int, importance: []f32) {
	// Insertion sort: few lights cast shadows.
	for i in 1 ..< len(order) {
		for j := i; j > 0 && importance[order[j]] > importance[order[j - 1]]; j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
}

@(private = "file")
sphere_inside :: proc(planes: [][4]f32, center: [3]f32, radius: f32) -> bool {
	for p in planes {
		if linalg.dot(p.xyz, center) + p.w < -radius {
			return false
		}
	}
	return true
}

// light_basis is a right, up and forward with forward along a direction, as a view's axes are, with right × up =
// forward.
@(private = "file")
light_basis :: proc(forward: [3]f32) -> (right, up: [3]f32) {
	hint := abs(forward.y) < 0.99 ? [3]f32{0, 1, 0} : [3]f32{0, 0, 1}
	right = linalg.normalize(linalg.cross(hint, forward))
	up = linalg.cross(forward, right)
	return
}

// slot_viewport is a slot's rectangle of the atlas in pixels, and in UV: a whole cell when size is the cell's, and
// otherwise one of its slots.
slot_viewport :: proc(p: Shadow_Params, slot: int, size: int) -> (pixels: [4]u32, rect: [4]f32) {
	per_side := p.cell / size
	cells_per_side := p.atlas / p.cell
	cell := size == p.cell ? slot : slot / slots_per_cell(p)
	sub := size == p.cell ? 0 : slot % slots_per_cell(p)
	x := (cell % cells_per_side) * p.cell + (sub % per_side) * size
	y := (cell / cells_per_side) * p.cell + (sub / per_side) * size
	pixels = {u32(x), u32(y), u32(size), u32(size)}
	atlas := f32(p.atlas)
	rect = {f32(x) / atlas, f32(y) / atlas, f32(size) / atlas, f32(size) / atlas}
	return
}

// add_cascades adds the views of a directional light's cascades. Each is an orthographic view of the bounding sphere
// of its slice of the view's frustum, whose center snaps to its texels in the render origin's space, so the shadow's
// edges stay still as the camera moves. Depth is clamped, not clipped, so casters between the light and the view
// still write depth.
@(private = "file")
add_cascades :: proc(f: ^Frame, sf: ^Shadow_Frame, direction: [3]f32) {
	s := f.shadow_settings
	splits := cascade_splits(f.view.near, s.distance > 0 ? s.distance : SHADOW_DISTANCE, s.split_lambda, sf.params.cascades)
	sf.cascade_splits = splits
	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	light_right, light_up := light_basis(direction)
	camera_offset := ecs.position_sub(f.view.position, f.renderer.scene.origin)
	start := f.view.near
	for split, c in splits[:sf.params.cascades] {
		// The slice's corners, relative to the camera, and the sphere around them.
		corners: [8][3]f32
		for &corner, k in corners {
			z := k < 4 ? start : split
			x := (k & 1 != 0 ? 1 : -1) * z / scale.x
			y := (k & 2 != 0 ? 1 : -1) * z / scale.y
			corner = right * x + up * y + forward * z
		}
		center: [3]f32
		for corner in corners {
			center += corner / 8
		}
		radius: f32
		for corner in corners {
			radius = max(radius, linalg.length(corner - center))
		}
		// A radius in whole sixteenths of a meter keeps the texel size still too.
		radius = math.ceil(radius * 16) / 16
		texel := 2 * radius / f32(sf.params.cell)
		absolute := center + camera_offset
		snap := [2]f32{linalg.dot(absolute, light_right), linalg.dot(absolute, light_up)}
		snapped := [2]f32{math.floor(snap.x / texel) * texel, math.floor(snap.y / texel) * texel}
		center += light_right * (snapped.x - snap.x) + light_up * (snapped.y - snap.y)

		// x and y map the sphere to [-1, 1], and depth is 1 at the sphere's near side, toward the light, and 0 at its far
		// side.
		depth_range := 2 * radius
		d := linalg.dot(direction, center)
		m := matrix[4, 4]f32{
			light_right.x / radius, light_right.y / radius, light_right.z / radius, -linalg.dot(light_right, center) / radius,
			light_up.x / radius, light_up.y / radius, light_up.z / radius, -linalg.dot(light_up, center) / radius,
			-direction.x / depth_range, -direction.y / depth_range, -direction.z / depth_range, (radius + d) / depth_range,
			0, 0, 0, 1,
		}
		pixels, rect := slot_viewport(sf.params, c, sf.params.cell)
		planes := frustum_planes_6(m)
		// The near plane culls nothing: casters toward the light still cast, with their depth clamped.
		planes[4] = {0, 0, 0, 1}
		append(&sf.matrices, m)
		append(&sf.views, Shadow_View{rows = matrix_rows(m), rect = rect, texel = texel})
		append(&sf.planes, planes)
		append(&sf.eyes, [4]f32{direction.x, direction.y, direction.z, 0})
		append(&sf.viewports, pixels)
		start = split
	}
}

// add_perspective_view adds a perspective view from a light's position, relative to the camera, along a direction,
// with reversed depth from SHADOW_NEAR, and culling to the light's range.
@(private = "file")
add_perspective_view :: proc(f: ^Frame, sf: ^Shadow_Frame, position, direction: [3]f32, fov, range: f32, slot: int) {
	right, up := light_basis(direction)
	s := 1 / math.tan(fov * 0.5)
	// The rows take a position relative to the camera: its offset from the light along the light's axes, projected.
	m := matrix[4, 4]f32{
		right.x * s, right.y * s, right.z * s, -linalg.dot(right, position) * s,
		up.x * s, up.y * s, up.z * s, -linalg.dot(up, position) * s,
		0, 0, 0, SHADOW_NEAR,
		direction.x, direction.y, direction.z, -linalg.dot(direction, position),
	}
	slot_size := sf.params.slot
	pixels, rect := slot_viewport(sf.params, slot, slot_size)
	planes := frustum_planes_6(m)
	// The far plane is at the light's range.
	planes[5] = {-direction.x, -direction.y, -direction.z, linalg.dot(direction, position) + range}
	append(&sf.matrices, m)
	append(&sf.views, Shadow_View{rows = matrix_rows(m), rect = rect, texel = 2 / (s * f32(slot_size)), perspective = 1})
	append(&sf.planes, planes)
	append(&sf.eyes, [4]f32{position.x, position.y, position.z, 1})
	append(&sf.viewports, pixels)
}

@(private = "file")
matrix_rows :: proc(m: matrix[4, 4]f32) -> (rows: [4][4]f32) {
	for r in 0 ..< 4 {
		rows[r] = {m[r, 0], m[r, 1], m[r, 2], m[r, 3]}
	}
	return
}

// frustum_planes_6 are the planes of a projection: left, right, bottom, top, near and far, each normalized. A plane
// that the projection does not bound, as an infinite far plane, culls nothing.
@(private)
frustum_planes_6 :: proc(m: matrix[4, 4]f32) -> (planes: [6][4]f32) {
	row :: proc(m: matrix[4, 4]f32, r: int) -> [4]f32 {
		return {m[r, 0], m[r, 1], m[r, 2], m[r, 3]}
	}
	x, y, z, w := row(m, 0), row(m, 1), row(m, 2), row(m, 3)
	// Clip space keeps -w <= x, y <= w and 0 <= z <= w; with reversed depth, z <= w is the near plane.
	planes = {w + x, w - x, w + y, w - y, w - z, z}
	for &p in planes {
		length := linalg.length(p.xyz)
		p = length > 1e-6 ? p / length : {0, 0, 0, 1}
	}
	return
}

// add_shadow_passes adds the shadow maps' pass, and with traced lights, the mask's pass, which traces the ray scene
// (see docs/rendering/ray-scene.md#ray-scene). The maps draw the bins of each shadow view, which the culling filled.
@(private)
add_shadow_passes :: proc(f: ^Frame) {
	sf := f.shadows
	g := f.graph
	if len(sf.views) > 0 {
		atlas := u32(sf.params.atlas)
		sf.atlas = create_texture(g, {size = {atlas, atlas}, format = SHADOW_FORMAT, label = "shadow atlas"})
		p := add_render_pass(g, "shadow maps", draw_shadow_maps, f, pieces = len(sf.views))
		depth(g, p, sf.atlas, .Clear)
		declare_scene_draws(f, p)
	}
	if sf.mask_count == 0 {
		return
	}
	sf.mask = create_texture(g, {size = f.size, format = SHADOW_MASK_FORMAT, label = "shadow mask"})
	p := add_compute_pass(g, "shadow mask", trace_shadow_mask, f)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read_accel(g, p, ray_scene_accel(f))
	write(g, p, sf.mask)
}

@(private = "file")
draw_shadow_maps :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	viewport := f.shadows.viewports[ctx.piece]
	gpu.cmd_set_viewport(ctx.cb, {f32(viewport.x), f32(viewport.y)}, {f32(viewport.z), f32(viewport.w)})
	gpu.cmd_set_scissor(ctx.cb, {i32(viewport.x), i32(viewport.y)}, {i32(viewport.z), i32(viewport.w)})
	draw_scene_view(f, ctx.cb, FIRST_SHADOW_VIEW + ctx.piece, .Depth)
}

@(private = "file")
trace_shadow_mask :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.shadows
	g := ctx.graph
	pipeline := f.renderer.shadows.mask_pipeline.pipeline
	if pipeline == {} {
		return
	}
	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	view_model := view_model_view(f.view)
	view_model_scale := projection_scale(view_projection(view_model, f32(f.size.x) / f32(max(f.size.y, 1))))
	offset := ecs.position_sub(f.view.position, f.renderer.scene.origin)
	constants := Mask_Constants {
		right         = {right.x, right.y, right.z, 0},
		up            = {up.x, up.y, up.z, 0},
		forward       = {forward.x, forward.y, forward.z, 0},
		projection    = {scale.x, scale.y, f.view.near, 0},
		view_model    = {view_model_scale.x, view_model_scale.y, view_model.near, 0},
		camera_offset = {offset.x, offset.y, offset.z, 0},
		light_index   = {max(u32), max(u32), max(u32), max(u32)},
		depth         = gpu.read_index(gpu_texture(g, f.depth)),
		normals       = gpu.read_index(gpu_texture(g, f.normals)),
		output        = gpu.write_index(gpu_texture(g, sf.mask)),
		accel         = gpu.read_index(gpu_accel(g, ray_scene_accel(f))),
		lights        = gpu.read_index(f.lights.upload.buffer),
		lights_offset = f.lights.upload.offset,
		size          = f.size,
		stencil       = gpu.stencil_index(gpu_texture(g, f.depth)),
		jitter        = f.jitter,
	}
	for c in 0 ..< sf.mask_count {
		constants.light_index[c] = sf.mask_lights[c]
	}
	upload, ok := f.renderer.platform.gpu_upload(size_of(Mask_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Mask_Constants)(raw_data(upload.data))^ = constants
	groups := (f.size + MASK_GROUP_SIZE - 1) / MASK_GROUP_SIZE
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, {groups.x, groups.y, 1})
}
