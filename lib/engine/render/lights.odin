package render

import "core:log"
import "core:math"
import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// The lights and their clusters (see docs/rendering.md#lights-and-clusters). Each frame writes the lights relative to
// the camera, the directional ones first. A compute pass then gives each cluster, a tile of the screen and a depth
// slice, the punctual lights that reach it, and the forward pass loops over the lights of its pixel's cluster.

// Clusters are tiles of this many pixels, in this many depth slices from the near plane to CLUSTER_FAR, which slice
// exponentially; the last slice reaches on to infinity.
CLUSTER_TILE :: 64
CLUSTER_SLICES :: 32
CLUSTER_FAR :: 500
// The index list has room for this many lights per cluster on average. A cluster that finds it full gets fewer.
CLUSTER_AVERAGE_LIGHTS :: 32
CLUSTER_GROUP_SIZE :: 64
// At most this many lights in a frame, of which this many directional ones. Later ones are left out.
MAX_LIGHTS :: 1024
MAX_DIRECTIONAL_LIGHTS :: 4

// CLUSTER_SHADER is the engine's light clustering shader (lib/engine/content/shaders/cluster_lights.hlsl).
CLUSTER_SHADER :: #load("../content/shaders/cluster_lights.hlsl.meta", string)

// The area lights' lookup tables (see docs/rendering.md#area-lights), which tools/ltc_fit fits: two LTC_SIZE x LTC_SIZE
// RGBA32_Float textures, one after the other. Matches LTC_SIZE in ltc.hlsli.
LTC_SIZE :: 64
@(private = "file", rodata)
ltc_tables := #load("ltc_ggx.bin")

Light_Type :: enum u32 {
	Directional,
	Point,
	Spot,
	Quad,
	Disk,
	Line,
}

Light_Flag :: enum u32 {
	// An area light that shines from both of its faces.
	Two_Sided,
}

// Light_Record matches Light_Record in material_common.hlsli: a light relative to the camera. direction is where the
// light travels. A spot light's cone falls off as saturate(cos * spot_scale + spot_offset), squared. shadow is the
// light's first shadow view and mask its channel of the shadow mask, each -1 for none.
//
// An area light's position is its middle, and its range reaches past its shape by the component's range. extent is its
// half size along its +x in the world: a quad's half width, a disk's radius, a line's half length. extent_y is a quad's
// half height or a disk's radius along its +y, which is cross(direction, extent), or a line's radius. Its color is a
// point light's that is as bright, which the shaders spread over its area.
Light_Record :: struct {
	position:    [3]f32,
	range:       f32,
	color:       [3]f32,
	type:        Light_Type,
	direction:   [3]f32,
	spot_scale:  f32,
	spot_offset: f32,
	shadow:      i32,
	mask:        i32,
	flags:       bit_set[Light_Flag;u32],
	extent:      [3]f32,
	extent_y:    f32,
}

#assert(size_of(Light_Record) == 80)

// Ambient is the light from everything else until global illumination: the sky's from above and the ground's from
// below.
Ambient :: struct {
	sky:    [3]f32,
	ground: [3]f32,
}

DEFAULT_AMBIENT :: Ambient {
	sky    = {0.3, 0.36, 0.45},
	ground = {0.14, 0.12, 0.1},
}

// Cluster_Constants matches Cluster_Constants in cluster_lights.hlsl.
Cluster_Constants :: struct {
	right:         [4]f32,
	up:            [4]f32,
	forward:       [4]f32,
	// The projection's x and y scales, the near plane, and the slices' scale.
	projection:    [4]f32,
	size:          [2]f32,
	columns:       u32,
	rows:          u32,
	lights:        u32,
	lights_offset: u32,
	first_light:   u32,
	light_count:   u32,
	clusters:      u32,
	indices:       u32,
	counter:       u32,
	capacity:      u32,
}

// Lights is the lights' state between frames, in the Renderer: the extractors of the light components, and the
// clusters' buffers, which grow with the frame's size.
Lights :: struct {
	// Registrations, created again in renderer_reload.
	directional:      Extractor,
	point:            Extractor,
	spot:             Extractor,
	quad:             Extractor,
	disk:             Extractor,
	line:             Extractor,
	clusters:         gpu.Buffer,
	indices:          gpu.Buffer,
	counter:          gpu.Buffer,
	cluster_capacity: int,
	index_capacity:   int,
	pipeline:         Shader_Pipeline,
	// The area lights' lookup tables, and their bilinear sampler.
	ltc_matrix:       gpu.Texture,
	ltc_amplitude:    gpu.Texture,
	ltc_sampler:      gpu.Sampler,
}

// Light_Frame is one frame's lights, in frame memory. casts says which lights want a shadow, as the shadows assign
// them (see assign_shadows).
@(private)
Light_Frame :: struct {
	records:           [dynamic]Light_Record,
	casts:             [dynamic]bool,
	directional_count: int,
	upload:            gpu.Upload,
	columns:           u32,
	rows:              u32,
	slice_scale:       f32,
	slice_bias:        f32,
	// Whether the clusters are made this frame. Without them the forward pass skips the punctual lights.
	clustered:         bool,
	constants:         gpu.Upload,
	zero:              gpu.Upload,
	clusters:          Buffer,
	indices:           Buffer,
	counter:           Buffer,
}

lights_init :: proc(l: ^Lights, platform: ^core.Platform_API, w: ^ecs.World) {
	lights_register(l, w)
	l.counter = platform.gpu_create_buffer({size = 4, usage = {.Storage}, label = "light cluster counter"}, nil)
	l.pipeline = shader_pipeline(CLUSTER_SHADER)
	table_size := LTC_SIZE * LTC_SIZE * 16
	assert(len(ltc_tables) == 2 * table_size, "render: ltc_ggx.bin is not two tables of LTC_SIZE; run just ltc-fit")
	desc := gpu.Texture_Desc {
		size   = {LTC_SIZE, LTC_SIZE},
		format = .RGBA32_Float,
		usage  = {.Sampled},
		label  = "ltc matrix",
	}
	l.ltc_matrix = platform.gpu_create_texture(desc, ltc_tables[:table_size])
	desc.label = "ltc amplitude"
	l.ltc_amplitude = platform.gpu_create_texture(desc, ltc_tables[table_size:])
	l.ltc_sampler = platform.gpu_create_sampler({filter = .Linear, address = .Clamp, label = "ltc sampler"})
}

// lights_register makes the light extractors, in init and after a code reload.
lights_register :: proc(l: ^Lights, w: ^ecs.World) {
	l.directional = extractor(w, {ecs.read(w, Directional_Light)})
	l.point = extractor(w, {ecs.read(w, Point_Light)})
	l.spot = extractor(w, {ecs.read(w, Spot_Light)})
	l.quad = extractor(w, {ecs.read(w, Quad_Light)})
	l.disk = extractor(w, {ecs.read(w, Disk_Light)})
	l.line = extractor(w, {ecs.read(w, Line_Light)})
}

lights_destroy :: proc(l: ^Lights, platform: ^core.Platform_API) {
	for b in ([]gpu.Buffer{l.clusters, l.indices, l.counter}) {
		platform.gpu_destroy_buffer(b)
	}
	destroy_shader_pipeline(&l.pipeline, platform)
	platform.gpu_destroy_texture(l.ltc_matrix)
	platform.gpu_destroy_texture(l.ltc_amplitude)
	platform.gpu_destroy_sampler(l.ltc_sampler)
}

// cluster_grid is the clusters' columns and rows for a frame's size.
cluster_grid :: proc(size: [2]u32) -> (columns, rows: u32) {
	return max((size.x + CLUSTER_TILE - 1) / CLUSTER_TILE, 1), max((size.y + CLUSTER_TILE - 1) / CLUSTER_TILE, 1)
}

// cluster_slice is the depth slice of a view depth, as cluster_of in material_lighting.hlsli finds it: slices are
// exponential from the near plane to CLUSTER_FAR.
cluster_slice :: proc(depth, near: f32) -> int {
	scale, bias := slice_constants(near)
	return int(clamp(math.log2(depth) * scale + bias, 0, CLUSTER_SLICES - 1))
}

@(private)
slice_constants :: proc(near: f32) -> (scale, bias: f32) {
	scale = CLUSTER_SLICES / math.log2(CLUSTER_FAR / near)
	return scale, -math.log2(near) * scale
}

// extract_lights writes the frame's lights relative to the camera, the directional ones first, and leaves out those
// of hidden entities. A field at 0 takes its default (see the components).
@(private)
extract_lights :: proc(f: ^Frame, w: ^ecs.World, hidden: []u32) -> ^Light_Frame {
	r := f.renderer
	lf := new(Light_Frame, r.platform.frame_allocator)
	lf.records = make([dynamic]Light_Record, r.platform.frame_allocator)
	lf.casts = make([dynamic]bool, r.platform.frame_allocator)
	l := &r.lights

	add :: proc(lf: ^Light_Frame, record: Light_Record, casts: bool) {
		if len(lf.records) == MAX_LIGHTS {
			return
		}
		append(&lf.records, record)
		append(&lf.casts, casts)
	}
	color_of :: proc(color: [3]f32, intensity: f32) -> [3]f32 {
		return (color == {} ? 1 : color) * intensity
	}
	size_or_default :: proc(size: f32) -> f32 {
		return size > 0 ? size : DEFAULT_AREA_SIZE
	}
	// area is an area light's record, its range grown by the radius of its shape's bounding sphere.
	area :: proc(f: ^Frame, pose: ecs.Transform, type: Light_Type, color: [3]f32, range, half_x, half_y, bounds: f32, two_sided: bool) -> Light_Record {
		return {
			type = type,
			position = ecs.position_sub(pose.position, f.view.position),
			range = (range > 0 ? range : DEFAULT_LIGHT_RANGE) + bounds,
			color = color,
			direction = forward_of(pose),
			shadow = -1,
			mask = -1,
			flags = two_sided ? {.Two_Sided} : {},
			extent = right_of(pose) * half_x,
			extent_y = half_y,
		}
	}

	it := ecs.query_iter(w, l.directional.query)
	for view in ecs.query_next(&it) {
		for e, i in ecs.entities(view) {
			pose, ok := light_pose(w, view, i, hidden, e)
			light := ecs.column(view, EXTRACT_TERMS, Directional_Light)[i]
			if !ok || lf.directional_count == MAX_DIRECTIONAL_LIGHTS {
				continue
			}
			add(lf, {type = .Directional, color = color_of(light.color, light.intensity), direction = forward_of(pose), shadow = -1, mask = -1}, light.cast_shadows)
			lf.directional_count += 1
		}
	}
	it = ecs.query_iter(w, l.point.query)
	for view in ecs.query_next(&it) {
		for e, i in ecs.entities(view) {
			pose, ok := light_pose(w, view, i, hidden, e)
			light := ecs.column(view, EXTRACT_TERMS, Point_Light)[i]
			if !ok {
				continue
			}
			add(
				lf,
				{
					type = .Point,
					position = ecs.position_sub(pose.position, f.view.position),
					range = light.range > 0 ? light.range : DEFAULT_LIGHT_RANGE,
					color = color_of(light.color, light.intensity),
					shadow = -1,
					mask = -1,
				},
				light.cast_shadows,
			)
		}
	}
	it = ecs.query_iter(w, l.spot.query)
	for view in ecs.query_next(&it) {
		for e, i in ecs.entities(view) {
			pose, ok := light_pose(w, view, i, hidden, e)
			light := ecs.column(view, EXTRACT_TERMS, Spot_Light)[i]
			if !ok {
				continue
			}
			outer := light.outer_angle > 0 ? light.outer_angle : DEFAULT_SPOT_OUTER
			inner := light.inner_angle > 0 ? min(light.inner_angle, outer) : outer
			cos_outer, cos_inner := math.cos(outer), math.cos(inner)
			scale := 1 / max(cos_inner - cos_outer, 1e-4)
			add(
				lf,
				{
					type = .Spot,
					position = ecs.position_sub(pose.position, f.view.position),
					range = light.range > 0 ? light.range : DEFAULT_LIGHT_RANGE,
					color = color_of(light.color, light.intensity),
					direction = forward_of(pose),
					spot_scale = scale,
					spot_offset = -cos_outer * scale,
					shadow = -1,
					mask = -1,
				},
				light.cast_shadows,
			)
		}
	}
	it = ecs.query_iter(w, l.quad.query)
	for view in ecs.query_next(&it) {
		for e, i in ecs.entities(view) {
			pose, ok := light_pose(w, view, i, hidden, e)
			light := ecs.column(view, EXTRACT_TERMS, Quad_Light)[i]
			if !ok {
				continue
			}
			half_x, half_y := size_or_default(light.width) / 2, size_or_default(light.height) / 2
			bounds := math.sqrt(half_x * half_x + half_y * half_y)
			add(lf, area(f, pose, .Quad, color_of(light.color, light.intensity), light.range, half_x, half_y, bounds, light.two_sided), light.cast_shadows)
		}
	}
	it = ecs.query_iter(w, l.disk.query)
	for view in ecs.query_next(&it) {
		for e, i in ecs.entities(view) {
			pose, ok := light_pose(w, view, i, hidden, e)
			light := ecs.column(view, EXTRACT_TERMS, Disk_Light)[i]
			if !ok {
				continue
			}
			half_x, half_y := size_or_default(light.width) / 2, size_or_default(light.height) / 2
			add(lf, area(f, pose, .Disk, color_of(light.color, light.intensity), light.range, half_x, half_y, max(half_x, half_y), light.two_sided), light.cast_shadows)
		}
	}
	it = ecs.query_iter(w, l.line.query)
	for view in ecs.query_next(&it) {
		for e, i in ecs.entities(view) {
			pose, ok := light_pose(w, view, i, hidden, e)
			light := ecs.column(view, EXTRACT_TERMS, Line_Light)[i]
			if !ok {
				continue
			}
			half, radius := size_or_default(light.length) / 2, max(light.radius, 0)
			add(lf, area(f, pose, .Line, color_of(light.color, light.intensity), light.range, half, radius, half + radius, false), light.cast_shadows)
		}
	}
	if len(lf.records) == MAX_LIGHTS {
		log.warnf("render: more than %d lights; the rest are left out", MAX_LIGHTS)
	}
	lf.columns, lf.rows = cluster_grid(f.size)
	lf.slice_scale, lf.slice_bias = slice_constants(f.view.near)
	return lf
}

// light_pose is a light's presented pose, unless its entity is hidden.
@(private)
light_pose :: proc(w: ^ecs.World, view: ecs.Chunk_View, i: int, hidden: []u32, e: ecs.Entity) -> (pose: ecs.Transform, ok: bool) {
	if is_hidden(hidden, e) {
		return
	}
	pose = ecs.column(view, 0, ecs.Transform)[i]
	if previous := ecs.column(view, 1, ecs.Previous_Transform); previous != nil {
		pose = ecs.interpolate(ecs.Transform(previous[i]), pose, w.clock.alpha)
	}
	return pose, true
}

// forward_of is a pose's +z in the world, where a light shines.
@(private)
forward_of :: proc(pose: ecs.Transform) -> [3]f32 {
	return linalg.normalize(linalg.quaternion128_mul_vector3(pose.rotation, [3]f32{0, 0, 1}))
}

// right_of is a pose's +x in the world, along an area light's width or length.
@(private)
right_of :: proc(pose: ecs.Transform) -> [3]f32 {
	return linalg.normalize(linalg.quaternion128_mul_vector3(pose.rotation, [3]f32{1, 0, 0}))
}

// upload_lights writes the light records into the upload ring, after the shadows set their views and channels, and
// readies the clusters: their pipeline, their buffers for the frame's size, and their pass's constants.
@(private)
upload_lights :: proc(f: ^Frame) {
	r := f.renderer
	lf := f.lights
	l := &r.lights
	platform := r.platform
	ok: bool
	lf.upload, ok = platform.gpu_upload(max(len(lf.records), 1) * size_of(Light_Record), 16)
	if !ok {
		clear(&lf.records)
		lf.directional_count = 0
		return
	}
	copy(lf.upload.data, ([^]byte)(raw_data(lf.records))[:len(lf.records) * size_of(Light_Record)])

	sync_compute_pipeline(&l.pipeline, platform, r.residency.assets, {label = "cluster lights"}, r.reloaded)
	if l.pipeline.pipeline == {} || len(lf.records) == lf.directional_count {
		return
	}
	cluster_count := int(lf.columns * lf.rows) * CLUSTER_SLICES
	if cluster_count > l.cluster_capacity {
		platform.gpu_destroy_buffer(l.clusters)
		platform.gpu_destroy_buffer(l.indices)
		l.cluster_capacity = cluster_count
		l.index_capacity = cluster_count * CLUSTER_AVERAGE_LIGHTS
		l.clusters = platform.gpu_create_buffer({size = u32(cluster_count * 8), usage = {.Storage}, label = "light clusters"}, nil)
		l.indices = platform.gpu_create_buffer({size = u32(l.index_capacity * 4), usage = {.Storage}, label = "light cluster indices"}, nil)
	}
	lf.zero, ok = platform.gpu_upload(4, 4)
	if !ok {
		return
	}
	(^u32)(raw_data(lf.zero.data))^ = 0
	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	constants := Cluster_Constants {
		right         = {right.x, right.y, right.z, 0},
		up            = {up.x, up.y, up.z, 0},
		forward       = {forward.x, forward.y, forward.z, 0},
		projection    = {scale.x, scale.y, f.view.near, lf.slice_scale},
		size          = {f32(f.size.x), f32(f.size.y)},
		columns       = lf.columns,
		rows          = lf.rows,
		lights        = gpu.read_index(lf.upload.buffer),
		lights_offset = lf.upload.offset,
		first_light   = u32(lf.directional_count),
		light_count   = u32(len(lf.records) - lf.directional_count),
		clusters      = gpu.write_index(l.clusters),
		indices       = gpu.write_index(l.indices),
		counter       = gpu.write_index(l.counter),
		capacity      = u32(l.index_capacity),
	}
	lf.constants, ok = platform.gpu_upload(size_of(Cluster_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Cluster_Constants)(raw_data(lf.constants.data))^ = constants
	lf.clustered = true
}

// add_cluster_passes adds the passes that assign the punctual lights to the clusters: one that zeroes the index list's
// counter, and one that fills the clusters.
@(private)
add_cluster_passes :: proc(f: ^Frame) {
	lf := f.lights
	if !lf.clustered {
		return
	}
	l := &f.renderer.lights
	g := f.graph
	lf.clusters = import_buffer(g, l.clusters)
	lf.indices = import_buffer(g, l.indices)
	lf.counter = import_buffer(g, l.counter)
	p := add_compute_pass(g, "clear light counter", proc(ctx: ^Pass_Context) {
		lf := (^Frame)(ctx.data).lights
		gpu.cmd_copy_buffer(ctx.cb, lf.zero.buffer, lf.zero.offset, gpu_buffer(ctx.graph, lf.counter), 0, 4)
	}, f)
	copy_dest(g, p, lf.counter)
	p = add_compute_pass(g, "cluster lights", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		count := f.lights.columns * f.lights.rows * CLUSTER_SLICES
		gpu.cmd_set_pipeline(ctx.cb, f.renderer.lights.pipeline.pipeline)
		gpu.cmd_set_pass_constants(ctx.cb, f.lights.constants)
		gpu.cmd_dispatch(ctx.cb, {(count + CLUSTER_GROUP_SIZE - 1) / CLUSTER_GROUP_SIZE, 1, 1})
	}, f)
	write(g, p, lf.counter)
	write(g, p, lf.clusters)
	write(g, p, lf.indices)
}

// projection_scale is a projection's x and y scales: a view-space x maps to x * scale.x / z in normalized device
// coordinates.
@(private)
projection_scale :: proc(view_projection: matrix[4, 4]f32) -> [2]f32 {
	// The rotation keeps each row's length, so the rows' lengths are the scales.
	return {linalg.length([3]f32{view_projection[0, 0], view_projection[0, 1], view_projection[0, 2]}), linalg.length([3]f32{view_projection[1, 0], view_projection[1, 1], view_projection[1, 2]})}
}
