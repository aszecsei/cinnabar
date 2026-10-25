package render

import "core:math"
import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// Shadows (see docs/rendering.md#shadows). With Ray_Query, a compute pass traces up to four lights' shadows into a
// screen-space mask, from the prepass's depth, against an acceleration structure of the GPU scene. The other lights
// that cast shadows get shadow maps in one atlas: four cascades for the first directional light, one view for a spot
// light, and six for a point light. The maps draw each material's depth pass.

// The atlas is square. Cascades take cells of SHADOW_CELL pixels; spot lights and point lights' faces take slots of
// SHADOW_SLOT, four to a cell.
SHADOW_ATLAS_SIZE :: 4096
SHADOW_FORMAT :: gpu.Format.D32_Float
SHADOW_CELL :: 1024
SHADOW_SLOT :: 512
SHADOW_CASCADES :: 4
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

@(private = "file")
CELLS_PER_SIDE :: SHADOW_ATLAS_SIZE / SHADOW_CELL
@(private = "file")
SLOTS_PER_CELL :: (SHADOW_CELL / SHADOW_SLOT) * (SHADOW_CELL / SHADOW_SLOT)
MAX_SHADOW_VIEWS :: CELLS_PER_SIDE * CELLS_PER_SIDE * SLOTS_PER_CELL

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
	padding:       [3]u32,
}

// Shadow_Passes is the shadows' state between frames, in the Renderer.
Shadow_Passes :: struct {
	// Whether the device traces rays in shaders, and the GPU scene's top-level acceleration structure then.
	ray_query:     bool,
	accel:         gpu.Accel_Struct,
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
	viewports:      [dynamic][4]u32,
	cascade_splits: [4]f32,
	mask_lights:    [MAX_MASK_LIGHTS]u32,
	mask_count:     int,
	atlas:          Texture,
	mask:           Texture,
	views_upload:   gpu.Upload,
	// The meshes whose acceleration structures this frame builds.
	builds:         []^Resident_Mesh,
	accel:          Accel,
	mask_constants: gpu.Upload,
}

shadows_init :: proc(s: ^Shadow_Passes, platform: ^core.Platform_API) {
	s.ray_query = .Ray_Query in platform.gpu_features()
	if s.ray_query {
		s.accel = platform.gpu_create_accel({kind = .Top, max_instances = MAX_INSTANCES, label = "gpu scene"})
	}
	s.mask_pipeline = shader_pipeline(SHADOW_MASK_SHADER)
	s.sampler = platform.gpu_create_sampler({filter = .Linear, address = .Clamp, compare = .Greater_Equal, label = "shadow comparison"})
}

shadows_destroy :: proc(s: ^Shadow_Passes, platform: ^core.Platform_API) {
	platform.gpu_destroy_accel(s.accel)
	platform.gpu_destroy_sampler(s.sampler)
	destroy_shader_pipeline(&s.mask_pipeline, platform)
}

// cascade_splits are the view depths at which each cascade ends: between even and exponential splits of the range
// from the near plane to distance, lambda of the way to exponential.
cascade_splits :: proc(near: f32, distance: f32 = SHADOW_DISTANCE, lambda: f32 = SHADOW_SPLIT_LAMBDA) -> (splits: [SHADOW_CASCADES]f32) {
	far := max(distance, near * 2)
	for &split, i in splits {
		t := f32(i + 1) / SHADOW_CASCADES
		exponential := near * math.pow(far / near, t)
		even := near + (far - near) * t
		split = lambda * exponential + (1 - lambda) * even
	}
	return
}

// assign_shadows gives the lights that cast shadows their shadows, in order: the directional lights, then the
// punctual lights by how much light they bring to the view. With Ray_Query, the first MAX_MASK_LIGHTS take channels of
// the mask. The others take shadow maps while the atlas has room: the cascades only for one directional light.
@(private)
assign_shadows :: proc(f: ^Frame) {
	r := f.renderer
	if r.shadows.ray_query {
		sync_compute_pipeline(&r.shadows.mask_pipeline, r.platform, r.residency.assets, {label = "shadow mask"}, r.reloaded)
	}
	assign_shadow_views(f, r.shadows.ray_query && r.shadows.mask_pipeline.pipeline != {})
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
	sf.viewports = make([dynamic][4]u32, r.platform.frame_allocator)

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
			first_slot = SHADOW_CASCADES * SLOTS_PER_CELL
			record.shadow = i32(len(sf.views))
			add_cascades(f, sf, record.direction)
		case .Spot:
			if first_slot + next_slot + 1 > MAX_SHADOW_VIEWS {
				continue
			}
			record.shadow = i32(len(sf.views))
			cone := math.acos(clamp(-record.spot_offset / record.spot_scale, -1, 1))
			// The cone's half angle is where the falloff reaches 0: cos = -offset / scale.
			add_perspective_view(f, sf, record.position, record.direction, min(cone * 2, math.to_radians(f32(170))), record.range, first_slot + next_slot)
			next_slot += 1
		case .Point, .Quad, .Disk, .Line:
			// An area light casts its shadows from its middle, as a point light does.
			if first_slot + next_slot + 6 > MAX_SHADOW_VIEWS {
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

// slot_viewport is a slot's rectangle of the atlas in pixels, and in UV.
@(private = "file")
slot_viewport :: proc(slot: int, size: int) -> (pixels: [4]u32, rect: [4]f32) {
	per_side := SHADOW_CELL / size
	cell := size == SHADOW_CELL ? slot : slot / SLOTS_PER_CELL
	sub := size == SHADOW_CELL ? 0 : slot % SLOTS_PER_CELL
	x := (cell % CELLS_PER_SIDE) * SHADOW_CELL + (sub % per_side) * size
	y := (cell / CELLS_PER_SIDE) * SHADOW_CELL + (sub / per_side) * size
	pixels = {u32(x), u32(y), u32(size), u32(size)}
	rect = {f32(x) / SHADOW_ATLAS_SIZE, f32(y) / SHADOW_ATLAS_SIZE, f32(size) / SHADOW_ATLAS_SIZE, f32(size) / SHADOW_ATLAS_SIZE}
	return
}

// add_cascades adds the views of a directional light's cascades. Each is an orthographic view of the bounding sphere
// of its slice of the view's frustum, whose center snaps to its texels in the render origin's space, so the shadow's
// edges stay still as the camera moves. Depth is clamped, not clipped, so casters between the light and the view
// still write depth.
@(private = "file")
add_cascades :: proc(f: ^Frame, sf: ^Shadow_Frame, direction: [3]f32) {
	s := f.shadow_settings
	splits := cascade_splits(f.view.near, s.distance > 0 ? s.distance : SHADOW_DISTANCE, s.split_lambda)
	sf.cascade_splits = splits
	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	light_right, light_up := light_basis(direction)
	camera_offset := ecs.position_sub(f.view.position, f.renderer.scene.origin)
	start := f.view.near
	for split, c in splits {
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
		texel := 2 * radius / SHADOW_CELL
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
		pixels, rect := slot_viewport(c, SHADOW_CELL)
		planes := frustum_planes_6(m)
		// The near plane culls nothing: casters toward the light still cast, with their depth clamped.
		planes[4] = {0, 0, 0, 1}
		append(&sf.matrices, m)
		append(&sf.views, Shadow_View{rows = matrix_rows(m), rect = rect, texel = texel})
		append(&sf.planes, planes)
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
	pixels, rect := slot_viewport(slot, SHADOW_SLOT)
	planes := frustum_planes_6(m)
	// The far plane is at the light's range.
	planes[5] = {-direction.x, -direction.y, -direction.z, linalg.dot(direction, position) + range}
	append(&sf.matrices, m)
	append(&sf.views, Shadow_View{rows = matrix_rows(m), rect = rect, texel = 2 / (s * SHADOW_SLOT), perspective = 1})
	append(&sf.planes, planes)
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

// add_shadow_passes adds the shadow maps' pass, and with traced lights, the acceleration structures' builds and the
// mask's pass. The maps draw the bins of each shadow view, which the culling filled.
@(private)
add_shadow_passes :: proc(f: ^Frame) {
	sf := f.shadows
	g := f.graph
	if len(sf.views) > 0 {
		sf.atlas = create_texture(g, {size = SHADOW_ATLAS_SIZE, format = SHADOW_FORMAT, label = "shadow atlas"})
		p := add_render_pass(g, "shadow maps", draw_shadow_maps, f, pieces = len(sf.views))
		depth(g, p, sf.atlas, .Clear)
		declare_scene_draws(f, p)
	}
	if sf.mask_count == 0 {
		return
	}
	add_accel_passes(f)
	sf.mask = create_texture(g, {size = f.size, format = SHADOW_MASK_FORMAT, label = "shadow mask"})
	p := add_compute_pass(g, "shadow mask", trace_shadow_mask, f)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read_accel(g, p, sf.accel)
	write(g, p, sf.mask)
}

// add_accel_passes builds the acceleration structures of the meshes that became ready, then the GPU scene's top-level
// structure from this frame's instances.
@(private = "file")
add_accel_passes :: proc(f: ^Frame) {
	r := f.renderer
	sf := f.shadows
	g := f.graph
	sf.accel = import_accel(g, r.shadows.accel)
	sf.builds = unbuilt_accels(&r.residency)
	blases := make([]Accel, len(sf.builds), r.platform.frame_allocator)
	if len(sf.builds) > 0 {
		p := add_compute_pass(g, "build mesh accels", proc(ctx: ^Pass_Context) {
			for m in (^Frame)(ctx.data).shadows.builds {
				gpu.cmd_build_accel(ctx.cb, m.accel)
			}
		}, f)
		for m, i in sf.builds {
			build_input(g, p, import_buffer(g, m.positions))
			build_input(g, p, import_buffer(g, m.indices))
			blases[i] = import_accel(g, m.accel)
			build_accel(g, p, blases[i])
			m.accel_built = true
		}
	}
	p := add_compute_pass(g, "build scene accel", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		instances := f.scene_frame.accel_instances
		gpu.cmd_build_top_accel(ctx.cb, gpu_accel(ctx.graph, f.shadows.accel), instances.buffer, instances.offset, u32(f.scene_frame.accel_count))
	}, f)
	for blas in blases {
		build_input(g, p, blas)
	}
	build_accel(g, p, sf.accel)
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
		accel         = gpu.read_index(gpu_accel(g, sf.accel)),
		lights        = gpu.read_index(f.lights.upload.buffer),
		lights_offset = f.lights.upload.offset,
		size          = f.size,
		stencil       = gpu.stencil_index(gpu_texture(g, f.depth)),
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
