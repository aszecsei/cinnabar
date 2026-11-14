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
// pass. With a virtual shadow map in the quality, its levels take the place of the cascades (see virtual_shadows.odin).
// A frame that does not trace gives the directional light with the shadow map contact shadows: a compute pass marches a
// short way toward it on the screen, through the ambient occlusion's depth levels.

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
// and point lights' faces take slots of slot pixels, several to a cell. A level with virtual_levels has a virtual shadow
// map, whose pool is pool_pages of VIRTUAL_PAGE_TEXELS on a side. virtual_bias moves its levels: above 0 is coarser.
// A level with soft has percentage-closer soft shadows for the atlas's lights that have a size (see Soft_Params), and a
// level with smrt rays shadow map ray tracing for the virtual shadow map's light (see Smrt_Params).
Shadow_Params :: struct {
	atlas:          int,
	cell:           int,
	slot:           int,
	cascades:       int,
	filter:         Shadow_Filter,
	virtual_levels: int,
	pool_pages:     [2]u32,
	virtual_bias:   f32,
	soft:           Soft_Params,
	smrt:           Smrt_Params,
}

// Smrt_Params are the virtual shadow map's soft shadows at a level, shadow map ray tracing (see
// docs/rendering/lighting-and-shadows.md#the-virtual-shadow-map): each pixel's rays toward the light's disk, each ray's
// steps through the map's depth, and how far a ray reaches, in meters. A level with no rays keeps the comparison taps.
// Match virtual_soft_shadow in material_lighting.hlsli.
Smrt_Params :: struct {
	rays:   u32,
	steps:  u32,
	length: f32,
}

// Soft_Params are the percentage-closer soft shadows of the atlas's spot, point and area lights at a level (see
// docs/rendering/lighting-and-shadows.md#soft-shadows): the blocker search's gathers, each of 2x2 texels, the filter's
// bilinear comparisons, and the widest the filter reaches from its middle, in texels. A level with no taps keeps the
// comparison taps of Shadow_Params.filter. Match soft_shadow_map in material_lighting.hlsli.
Soft_Params :: struct {
	search: u32,
	taps:   u32,
	radius: f32,
}

@(rodata)
SHADOW_PARAMS := [Quality_Level]Shadow_Params {
	.Low    = {atlas = 2048, cell = 1024, slot = 512, cascades = 2, filter = .Taps_1},
	.Medium = {atlas = 4096, cell = 1024, slot = 512, cascades = 3, filter = .Taps_4, virtual_levels = 12, pool_pages = {32, 32}, virtual_bias = 1, soft = {search = 4, taps = 8, radius = 16}},
	.High   = {atlas = 4096, cell = 1024, slot = 512, cascades = 4, filter = .Taps_4, virtual_levels = 12, pool_pages = {64, 32}, soft = {search = 8, taps = 16, radius = 16}, smrt = {rays = 4, steps = 6, length = SMRT_LENGTH}},
	.Ultra  = {atlas = 8192, cell = 2048, slot = 1024, cascades = 4, filter = .Taps_9, virtual_levels = 13, pool_pages = {64, 64}, soft = {search = 8, taps = 24, radius = 32}, smrt = {rays = 8, steps = 8, length = SMRT_LENGTH}},
}
// How far the virtual shadow map's rays reach toward the light, in meters. A caster farther than this casts a penumbra
// as wide as one this far.
SMRT_LENGTH :: 20
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
// The contact shadows hold one light's visibility: a frame that has them traces no mask.
CONTACT_SHADOWS_FORMAT :: gpu.Format.R8_Unorm

// soft_guard is the band of texels around a soft light's view, inside its slot, that its filter may read past the
// view's edge: the filter's reach, and a texel each for a gather's and a comparison's 2x2. A cube face's or a spot
// light's view is that much wider than its own field of view, so a wide filter at its edge reads what lies beyond the
// edge, and never a neighbouring view, nor a seam where its taps would clamp. 0 without soft shadows.
soft_guard :: proc(p: Shadow_Params) -> int {
	return p.soft.taps > 0 ? int(math.ceil(p.soft.radius)) + 2 : 0
}

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
// The traced mask's denoiser's shaders (lib/engine/content/shaders/shadow_denoise_temporal.hlsl and
// shadow_denoise_spatial.hlsl).
MASK_TEMPORAL_SHADER :: #load("../content/shaders/shadow_denoise_temporal.hlsl.meta", string)
MASK_SPATIAL_SHADER :: #load("../content/shaders/shadow_denoise_spatial.hlsl.meta", string)
// The traced mask's history averages a soft channel over at most this many frames. Matches MAX_FRAMES in
// shadow_denoise_temporal.hlsl.
MASK_HISTORY_FRAMES :: 16
// The soft channels' raw visibility, their history's average and its frames, and their penumbrae's radii in meters.
MASK_HISTORY_FORMAT :: gpu.Format.RGBA16_Float
MASK_FRAMES_FORMAT :: gpu.Format.RGBA8_Unorm
MASK_PENUMBRA_FORMAT :: gpu.Format.RGBA16_Float
// The spatial pass's widest disk, in pixels.
MASK_MAX_BLUR :: 24
// CONTACT_SHADOWS_SHADER is the engine's contact shadows shader (lib/engine/content/shaders/contact_shadows.hlsl).
CONTACT_SHADOWS_SHADER :: #load("../content/shaders/contact_shadows.hlsl.meta", string)

// Shadow_View matches Shadow_View in material_common.hlsli: a shadow map's projection of positions relative to the
// camera, as its matrix's rows, its rectangle of the atlas in UV, and the size of a texel. A virtual shadow map's level
// has its valid rectangle in UV (low, high) as rect, and page_origin, its first page in the level's absolute grid.
Shadow_View :: struct {
	rows:            [4][4]f32,
	rect:            [4]f32,
	// In meters for an orthographic view, at 1 m for a perspective one.
	texel:           f32,
	perspective:     u32,
	page_origin:     [2]i32,
}

#assert(size_of(Shadow_View) == 96)
// virtual_origin in virtual_shadow.hlsli loads a level's page_origin alone, at this offset.
#assert(offset_of(Shadow_View, page_origin) == 88)
#assert(VIRTUAL_MAX_LEVELS <= MAX_PASS_PIECES)

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
	// The channels whose lights have a size, a bit each, which trace toward a point on the light's shape that the blue
	// noise picks, and write their penumbrae's radii, a write index.
	soft:          u32,
	penumbra:      u32,
	noise:         u32,
	noise_slice:   u32,
	padding:       u32,
}

// Denoise_Temporal_Constants matches Denoise_Temporal_Constants in shadow_denoise_temporal.hlsl.
Denoise_Temporal_Constants :: struct {
	// For each channel, last frame's channel that held its light, or max(u32) to start again.
	history_channel: [4]u32,
	size:            [2]u32,
	inverse_size:    [2]f32,
	raw:             u32,
	velocity:        u32,
	previous:        u32,
	previous_frames: u32,
	current:         u32,
	current_frames:  u32,
	sampler_index:   u32,
	soft:            u32,
	valid:           u32,
	padding:         [3]u32,
}

// Denoise_Spatial_Constants matches Denoise_Spatial_Constants in shadow_denoise_spatial.hlsl.
Denoise_Spatial_Constants :: struct {
	right:       [4]f32,
	up:          [4]f32,
	forward:     [4]f32,
	projection:  [4]f32,
	view_model:  [4]f32,
	size:        [2]u32,
	accumulated: u32,
	raw:         u32,
	penumbra:    u32,
	depth:       u32,
	normals:     u32,
	stencil:     u32,
	output:      u32,
	noise:       u32,
	noise_slice: u32,
	soft:        u32,
	max_radius:  f32,
	jitter:      [2]f32,
	padding:     u32,
}

// Mask_History is what the traced mask's history holds in a view's state: the light entity of each channel that it
// averaged, so that a channel whose light was another's last frame starts again, as assign_shadows ranks the lights
// anew each frame. A frame sets it when it executes (see commit_mask_history).
Mask_History :: struct {
	lights: [MAX_MASK_LIGHTS]ecs.Entity,
}

#assert(size_of(Mask_Constants) == 176)
#assert(size_of(Denoise_Temporal_Constants) == 80)
#assert(size_of(Denoise_Spatial_Constants) == 144)

// Contact_Constants matches Contact_Constants in contact_shadows.hlsl.
Contact_Constants :: struct {
	projection:  [4]f32,
	// The direction toward the light, in view space.
	to_light:    [4]f32,
	levels:      [4]u32,
	level4:      u32,
	output:      u32,
	noise:       u32,
	noise_slice: u32,
	size:        [2]u32,
	// The camera's jitter, which the prepass drew with (see Frame.jitter).
	jitter:      [2]f32,
}

// Shadow_Passes is the shadows' state between frames, in the Renderer.
Shadow_Passes :: struct {
	mask_pipeline:     Shader_Pipeline,
	contact_pipeline:  Shader_Pipeline,
	// The traced mask's denoiser.
	temporal_pipeline: Shader_Pipeline,
	spatial_pipeline:  Shader_Pipeline,
	sampler:       gpu.Sampler,
	virtual:       Virtual_Shadows,
}

// Shadow_Frame is one frame's shadows, in frame memory: the shadow maps' views, the lights of the mask's channels, and
// the light that takes the contact shadows, or -1.
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
	// The virtual shadow map's light's size, where the level traces its soft shadows (see Smrt_Params), or 0.
	virtual_size:   f32,
	// The soft channels, a bit each, and the denoiser's textures, which a frame with soft channels has.
	mask_soft:      u32,
	mask_raw:       Texture,
	mask_penumbra:  Texture,
	mask_history:   History,
	mask_frames:    History,
	contact_light:  i32,
	atlas:          Texture,
	mask:           Texture,
	contact:        Texture,
	virtual:        Virtual_Frame,
	views_upload:   gpu.Upload,
	mask_constants: gpu.Upload,
}

shadows_init :: proc(s: ^Shadow_Passes, platform: ^core.Platform_API) {
	s.mask_pipeline = shader_pipeline(SHADOW_MASK_SHADER)
	s.contact_pipeline = shader_pipeline(CONTACT_SHADOWS_SHADER)
	s.temporal_pipeline = shader_pipeline(MASK_TEMPORAL_SHADER)
	s.spatial_pipeline = shader_pipeline(MASK_SPATIAL_SHADER)
	s.sampler = platform.gpu_create_sampler({filter = .Linear, address = .Clamp, compare = .Greater_Equal, label = "shadow comparison"})
	virtual_shadows_init(&s.virtual)
}

shadows_destroy :: proc(s: ^Shadow_Passes, platform: ^core.Platform_API) {
	virtual_shadows_destroy(&s.virtual, platform)
	platform.gpu_destroy_sampler(s.sampler)
	destroy_shader_pipeline(&s.mask_pipeline, platform)
	destroy_shader_pipeline(&s.contact_pipeline, platform)
	destroy_shader_pipeline(&s.temporal_pipeline, platform)
	destroy_shader_pipeline(&s.spatial_pipeline, platform)
}

// cascade_splits are the view depths at which count cascades end: between even and exponential splits of the range
// from the near plane to distance, lambda of the way to exponential. The splits past count repeat the last, so no
// depth reaches a cascade past it. A lambda of 0 gives even splits, which an orthographic view takes: a near plane of
// 0 has no exponential splits.
cascade_splits :: proc(near: f32, distance: f32 = SHADOW_DISTANCE, lambda: f32 = SHADOW_SPLIT_LAMBDA, count := SHADOW_CASCADES) -> (splits: [SHADOW_CASCADES]f32) {
	far := max(distance, near * 2)
	n := clamp(count, 1, SHADOW_CASCADES)
	for &split, i in splits {
		t := f32(min(i + 1, n)) / f32(n)
		exponential := lambda > 0 ? near * math.pow(far / near, t) : 0
		even := near + (far - near) * t
		split = lambda * exponential + (1 - lambda) * even
	}
	return
}

// assign_shadows gives the lights that cast shadows their shadows, in order: the directional lights, then the
// punctual lights by how much light they bring to the view. With traced shadows, the first MAX_MASK_LIGHTS take
// channels of the mask. The others take shadow maps while the atlas has room: the cascades only for one directional
// light, which takes the contact shadows in a frame that does not trace.
@(private)
assign_shadows :: proc(f: ^Frame) {
	r := f.renderer
	if r.caps.ray_query {
		// Synced whether or not this frame traces, so turning tracing on does not wait for it to compile.
		sync_compute_pipeline(&r.shadows.mask_pipeline, r.platform, r.residency.assets, {label = "shadow mask"}, r.reloaded)
		sync_compute_pipeline(&r.shadows.temporal_pipeline, r.platform, r.residency.assets, {label = "shadow mask temporal"}, r.reloaded)
		sync_compute_pipeline(&r.shadows.spatial_pipeline, r.platform, r.residency.assets, {label = "shadow mask spatial"}, r.reloaded)
	}
	sync_compute_pipeline(&r.shadows.contact_pipeline, r.platform, r.residency.assets, {label = "contact shadows"}, r.reloaded)
	trace := f.shadow_settings.ray_traced && r.shadows.mask_pipeline.pipeline != {} && request_ray_scene(f)
	params := SHADOW_PARAMS[f.shadow_settings.level]
	virtual := f.shadow_settings.virtual && params.virtual_levels > 0 && ensure_virtual_shadows(r, &f.state.virtual_shadows, params)
	contact := !trace && pipeline_ready(r.platform, &r.shadows.contact_pipeline)
	assign_shadow_views(f, trace, virtual, contact)
}

// assign_shadow_views gives the lights their shadows, with the mask's channels first if trace, and with a virtual shadow
// map in place of the cascades if virtual. If contact, the directional light with the cascades or the virtual shadow
// map also takes the contact shadows.
@(private)
assign_shadow_views :: proc(f: ^Frame, trace: bool, virtual := false, contact := false) {
	r := f.renderer
	lf := f.lights
	sf := new(Shadow_Frame, r.platform.frame_allocator)
	f.shadows = sf
	sf.contact_light = -1
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
		// A light with a size takes soft shadows, whose views have a guard band.
		guard := light_size(record^) > 0 ? soft_guard(sf.params) : 0
		if trace && sf.mask_count < MAX_MASK_LIGHTS {
			record.mask = i32(sf.mask_count)
			sf.mask_lights[sf.mask_count] = u32(i)
			if light_size(record^) > 0 {
				sf.mask_soft |= 1 << u32(sf.mask_count)
			}
			sf.mask_count += 1
			continue
		}
		switch record.type {
		case .Directional:
			// The cascades take the first cells, so the slots start after them. A virtual shadow map's levels take none.
			// A second directional light without a mask channel has no shadow.
			if cascades_taken || next_slot > 0 {
				continue
			}
			cascades_taken = true
			record.shadow = i32(len(sf.views))
			if contact {
				record.flags += {.Contact_Shadow}
				sf.contact_light = i32(i)
			}
			if virtual {
				record.flags += {.Virtual_Shadow}
				if sf.params.smrt.rays > 0 {
					sf.virtual_size = light_size(record^)
				}
				add_virtual_levels(f, sf, record.direction)
			} else {
				first_slot = sf.params.cascades * slots_per_cell(sf.params)
				add_cascades(f, sf, record.direction)
			}
		case .Spot:
			if first_slot + next_slot + 1 > max_views {
				continue
			}
			record.shadow = i32(len(sf.views))
			cone := math.acos(clamp(-record.spot_offset / record.spot_scale, -1, 1))
			// The cone's half angle is where the falloff reaches 0: cos = -offset / scale.
			add_perspective_view(f, sf, record.position, record.direction, min(cone * 2, math.to_radians(f32(170))), record.range, first_slot + next_slot, guard)
			next_slot += 1
		case .Point, .Quad, .Disk, .Line:
			// An area light casts its shadows from its middle, as a point light does, as soft as its size.
			if first_slot + next_slot + 6 > max_views {
				continue
			}
			record.shadow = i32(len(sf.views))
			for axis in CUBE_FACES {
				add_perspective_view(f, sf, record.position, axis, math.PI / 2, record.range, first_slot + next_slot, guard)
				next_slot += 1
			}
		}
	}
	if !cascades_taken {
		// Every view depth is beyond the last split, so no pixel looks for a cascade.
		sf.cascade_splits = {}
	}
	// A reflection probe's capture takes a slot after the others for its own view of the directional light.
	add_reflection_probe_shadow(f, sf, first_slot + next_slot, max_views)
	if len(sf.views) > 0 {
		ok: bool
		sf.views_upload, ok = upload_bytes(r.platform, ([^]byte)(raw_data(sf.views))[:len(sf.views) * size_of(Shadow_View)])
		if !ok {
			// Without their views, the lights have no shadow maps.
			for &record in lf.records {
				record.shadow = -1
				record.flags -= {.Virtual_Shadow, .Contact_Shadow}
			}
			sf.contact_light = -1
			clear(&sf.views)
			sf.virtual.count = 0
		}
	}
}

// soft_shadow_constants fills the frame's constants for the soft shadows of the atlas and of the virtual shadow map, at a
// level that has them. The blue noise turns the taps and the rays of each pixel, and each frame takes its next slice
// when temporal AA or an upscaler averages them over time; without either, the noise stays where it is, and before it
// is resident, every pixel takes the same turn.
@(private)
soft_shadow_constants :: proc(constants: ^Frame_Constants, f: ^Frame) {
	r := f.renderer
	sf := f.shadows
	soft, smrt := sf.params.soft, sf.params.smrt
	traces := sf.virtual_size > 0 && sf.virtual.count > 0 && smrt.rays > 0
	if soft.taps == 0 && !traces {
		return
	}
	if soft.taps > 0 {
		constants.shadow_soft_search = soft.search
		constants.shadow_soft_taps = soft.taps
		constants.shadow_soft_radius = soft.radius
		constants.shadow_depth_sampler = gpu.sampler_index(r.post.sampler)
	}
	if traces {
		constants.virtual_soft_size = sf.virtual_size
		constants.virtual_rays = smrt.rays
		constants.virtual_steps = smrt.steps
		constants.virtual_ray_length = smrt.length
	}
	if noise := blue_noise(r); noise != {} {
		temporal := f.post != nil && (f.post.temporal || f.post.upscaler != {})
		constants.shadow_noise = gpu.read_index(noise)
		constants.shadow_noise_slice = temporal ? u32(f.state.frames % BLUE_NOISE_SLICES) : 0
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
@(private)
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
	start := view_near(f.view)
	distance := s.distance > 0 ? s.distance : SHADOW_DISTANCE
	lambda := s.split_lambda
	// An orthographic view's cascades split evenly what it shows, up to the shadows' distance past its near plane.
	if o, orthographic := f.view.projection.(Orthographic); orthographic {
		distance, lambda = min(start + distance, o.far), 0
	}
	splits := cascade_splits(start, distance, lambda, sf.params.cascades)
	sf.cascade_splits = splits
	right, up, forward := view_axes(f.view)
	light_right, light_up := light_basis(direction)
	camera_offset := ecs.position_sub(f.view.position, f.renderer.scene.origin)
	for split, c in splits[:sf.params.cascades] {
		// The slice's corners, relative to the camera, and the sphere around them.
		corners: [8][3]f32
		for &corner, k in corners {
			z := k < 4 ? start : split
			v := view_corner(f.projection, {k & 1 != 0 ? 1 : -1, k & 2 != 0 ? 1 : -1}, z)
			corner = right * v.x + up * v.y + forward * v.z
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

// add_orthographic_shadow_view adds an orthographic view along a directional light's direction of a sphere relative to
// the camera, in a slot of the atlas, as a cascade's is but for its snapping. Depth is clamped, not clipped.
@(private)
add_orthographic_shadow_view :: proc(sf: ^Shadow_Frame, direction, center: [3]f32, radius: f32, slot: int) {
	light_right, light_up := light_basis(direction)
	depth_range := 2 * radius
	d := linalg.dot(direction, center)
	m := matrix[4, 4]f32{
		light_right.x / radius, light_right.y / radius, light_right.z / radius, -linalg.dot(light_right, center) / radius,
		light_up.x / radius, light_up.y / radius, light_up.z / radius, -linalg.dot(light_up, center) / radius,
		-direction.x / depth_range, -direction.y / depth_range, -direction.z / depth_range, (radius + d) / depth_range,
		0, 0, 0, 1,
	}
	pixels, rect := slot_viewport(sf.params, slot, sf.params.slot)
	planes := frustum_planes_6(m)
	planes[4] = {0, 0, 0, 1}
	append(&sf.matrices, m)
	append(&sf.views, Shadow_View{rows = matrix_rows(m), rect = rect, texel = 2 * radius / f32(sf.params.slot)})
	append(&sf.planes, planes)
	append(&sf.eyes, [4]f32{direction.x, direction.y, direction.z, 0})
	append(&sf.viewports, pixels)
}

// add_perspective_view adds a perspective view from a light's position, relative to the camera, along a direction,
// with reversed depth from SHADOW_NEAR, and culling to the light's range. With a guard of texels, its field of view
// widens so that fov fills the slot but for guard texels on each side (see soft_guard).
@(private = "file")
add_perspective_view :: proc(f: ^Frame, sf: ^Shadow_Frame, position, direction: [3]f32, fov, range: f32, slot: int, guard := 0) {
	right, up := light_basis(direction)
	slot_size := sf.params.slot
	s := 1 / math.tan(fov * 0.5) * f32(slot_size - 2 * guard) / f32(slot_size)
	// The rows take a position relative to the camera: its offset from the light along the light's axes, projected.
	m := matrix[4, 4]f32{
		right.x * s, right.y * s, right.z * s, -linalg.dot(right, position) * s,
		up.x * s, up.y * s, up.z * s, -linalg.dot(up, position) * s,
		0, 0, 0, SHADOW_NEAR,
		direction.x, direction.y, direction.z, -linalg.dot(direction, position),
	}
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

@(private)
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
// (see docs/rendering/ray-scene.md#ray-scene), or without them, the contact shadows' pass, which reads the ambient
// occlusion's depth levels, so it runs after add_ao_passes. The maps draw the bins of each shadow view, which the
// culling filled.
@(private)
add_shadow_passes :: proc(f: ^Frame) {
	sf := f.shadows
	g := f.graph
	if sf.virtual.count > 0 {
		add_virtual_shadow_passes(f)
	} else {
		forget_virtual_cache(f)
	}
	if atlas_views := len(sf.views) - sf.virtual.count; atlas_views > 0 {
		atlas := u32(sf.params.atlas)
		sf.atlas = create_texture(g, {size = {atlas, atlas}, format = SHADOW_FORMAT, label = "shadow atlas"})
		p := add_render_pass(g, "shadow maps", draw_shadow_maps, f, pieces = atlas_views)
		depth(g, p, sf.atlas, .Clear)
		declare_scene_draws(f, p)
	}
	if sf.mask_count == 0 {
		add_contact_shadows_pass(f)
		return
	}
	sf.mask = create_texture(g, {size = f.size, format = SHADOW_MASK_FORMAT, label = "shadow mask"})
	r := f.renderer
	if sf.mask_soft != 0 &&
	   (!pipeline_ready(r.platform, &r.shadows.temporal_pipeline) || !pipeline_ready(r.platform, &r.shadows.spatial_pipeline)) {
		// Until the denoiser compiles, every channel traces toward its light's middle.
		sf.mask_soft = 0
	}
	if sf.mask_soft != 0 {
		sf.mask_history = history_texture(g, {size = f.size, format = MASK_HISTORY_FORMAT, label = "shadow mask history"})
		sf.mask_frames = history_texture(g, {size = f.size, format = MASK_FRAMES_FORMAT, label = "shadow mask frames"})
		if sf.mask_history.current == 0 || sf.mask_frames.current == 0 {
			sf.mask_soft = 0
		}
	}
	p := add_compute_pass(g, "shadow mask", trace_shadow_mask, f)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read_accel(g, p, ray_scene_accel(f))
	if sf.mask_soft == 0 {
		write(g, p, sf.mask)
		return
	}
	sf.mask_raw = create_texture(g, {size = f.size, format = SHADOW_MASK_FORMAT, label = "shadow mask raw"})
	sf.mask_penumbra = create_texture(g, {size = f.size, format = MASK_PENUMBRA_FORMAT, label = "shadow mask penumbra"})
	write(g, p, sf.mask_raw)
	write(g, p, sf.mask_penumbra)

	temporal := add_compute_pass(g, "shadow mask temporal", run_mask_temporal, f)
	read(g, temporal, sf.mask_raw)
	read(g, temporal, f.velocity)
	read(g, temporal, sf.mask_history.previous)
	read(g, temporal, sf.mask_frames.previous)
	write(g, temporal, sf.mask_history.current)
	write(g, temporal, sf.mask_frames.current)

	spatial := add_compute_pass(g, "shadow mask spatial", run_mask_spatial, f)
	read(g, spatial, sf.mask_history.current)
	read(g, spatial, sf.mask_raw)
	read(g, spatial, sf.mask_penumbra)
	read(g, spatial, f.depth)
	read(g, spatial, f.normals)
	write(g, spatial, sf.mask)
	on_executed(g, commit_mask_history, f)
}

// commit_mask_history keeps the lights of the channels whose history the frame wrote, once it has executed.
@(private = "file")
commit_mask_history :: proc(data: rawptr) {
	f := (^Frame)(data)
	f.state.mask_history = mask_history_of(f)
}

// mask_history_of is the Mask_History that a frame's traced mask leaves: its soft channels' lights.
@(private = "file")
mask_history_of :: proc(f: ^Frame) -> (h: Mask_History) {
	sf := f.shadows
	for c in 0 ..< sf.mask_count {
		if sf.mask_soft & (1 << u32(c)) != 0 {
			h.lights[c] = f.lights.entities[sf.mask_lights[c]]
		}
	}
	return
}

// mask_history_channels is, for each of a frame's channels, the channel of the last frame's history that held its
// light, or max(u32) when none did, so the channel starts again.
mask_history_channels :: proc(previous: Mask_History, current: Mask_History) -> (channels: [4]u32) {
	for light, c in current.lights {
		channels[c] = max(u32)
		if light == {} {
			continue
		}
		for old, p in previous.lights {
			if old == light {
				channels[c] = u32(p)
			}
		}
	}
	return
}

@(private = "file")
run_mask_temporal :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.shadows
	g := ctx.graph
	pipeline := f.renderer.shadows.temporal_pipeline.pipeline
	if pipeline == {} {
		return
	}
	constants := Denoise_Temporal_Constants {
		history_channel = mask_history_channels(f.state.mask_history, mask_history_of(f)),
		size            = f.size,
		inverse_size    = {1 / f32(f.size.x), 1 / f32(f.size.y)},
		raw             = gpu.read_index(gpu_texture(g, sf.mask_raw)),
		velocity        = gpu.read_index(gpu_texture(g, f.velocity)),
		previous        = gpu.read_index(gpu_texture(g, sf.mask_history.previous)),
		previous_frames = gpu.read_index(gpu_texture(g, sf.mask_frames.previous)),
		current         = gpu.write_index(gpu_texture(g, sf.mask_history.current)),
		current_frames  = gpu.write_index(gpu_texture(g, sf.mask_frames.current)),
		sampler_index   = gpu.sampler_index(f.renderer.post.sampler),
		soft            = sf.mask_soft,
		valid           = u32(sf.mask_history.valid && sf.mask_frames.valid),
	}
	dispatch_mask_pass(ctx, f, pipeline, constants)
}

@(private = "file")
run_mask_spatial :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.shadows
	g := ctx.graph
	pipeline := f.renderer.shadows.spatial_pipeline.pipeline
	if pipeline == {} {
		return
	}
	right, up, forward := view_axes(f.view)
	noise, slice := mask_noise(f)
	constants := Denoise_Spatial_Constants {
		right       = {right.x, right.y, right.z, 0},
		up          = {up.x, up.y, up.z, 0},
		forward     = {forward.x, forward.y, forward.z, 0},
		projection  = f.projection,
		view_model  = f.view_model_projection,
		size        = f.size,
		accumulated = gpu.read_index(gpu_texture(g, sf.mask_history.current)),
		raw         = gpu.read_index(gpu_texture(g, sf.mask_raw)),
		penumbra    = gpu.read_index(gpu_texture(g, sf.mask_penumbra)),
		depth       = gpu.read_index(gpu_texture(g, f.depth)),
		normals     = gpu.read_index(gpu_texture(g, f.normals)),
		stencil     = gpu.stencil_index(gpu_texture(g, f.depth)),
		output      = gpu.write_index(gpu_texture(g, sf.mask)),
		noise       = noise,
		noise_slice = slice,
		soft        = sf.mask_soft,
		max_radius  = MASK_MAX_BLUR,
		jitter      = f.jitter,
	}
	dispatch_mask_pass(ctx, f, pipeline, constants)
}

// mask_noise is the blue noise's read index, 0 until it is resident, and the slice that the frame takes: a new one each
// frame, since the mask's own history averages them, whether or not temporal AA runs.
@(private = "file")
mask_noise :: proc(f: ^Frame) -> (noise, slice: u32) {
	if t := blue_noise(f.renderer); t != {} {
		return gpu.read_index(t), u32(f.state.frames % BLUE_NOISE_SLICES)
	}
	return
}

@(private = "file")
dispatch_mask_pass :: proc(ctx: ^Pass_Context, f: ^Frame, pipeline: gpu.Pipeline, constants: $T) {
	upload, ok := f.renderer.platform.gpu_upload(size_of(T), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^T)(raw_data(upload.data))^ = constants
	groups := (f.size + MASK_GROUP_SIZE - 1) / MASK_GROUP_SIZE
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, {groups.x, groups.y, 1})
}

// add_contact_shadows_pass adds the contact shadows' pass, on the compute queue beside the ambient occlusion, whose
// depth levels and blue noise it reads. Without the ambient occlusion, or a light that takes them, it adds nothing.
// The march finds each pixel's plane from the depths, not the prepass's normals, which a normal map tilts.
@(private = "file")
add_contact_shadows_pass :: proc(f: ^Frame) {
	sf := f.shadows
	g := f.graph
	if sf.contact_light < 0 || f.ao == nil {
		return
	}
	sf.contact = create_texture(g, {size = f.size, format = CONTACT_SHADOWS_FORMAT, label = "contact shadows"})
	p := add_compute_pass(g, "contact shadows", run_contact_shadows, f, queue = .Compute)
	for level in f.ao.levels {
		read(g, p, level)
	}
	write(g, p, sf.contact)
}

@(private = "file")
run_contact_shadows :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.shadows
	g := ctx.graph
	pipeline := f.renderer.shadows.contact_pipeline.pipeline
	if pipeline == {} {
		return
	}
	right, up, forward := view_axes(f.view)
	to_light := -f.lights.records[sf.contact_light].direction
	constants := Contact_Constants {
		projection  = f.projection,
		to_light    = {linalg.dot(to_light, right), linalg.dot(to_light, up), linalg.dot(to_light, forward), 0},
		output      = gpu.write_index(gpu_texture(g, sf.contact)),
		noise       = f.ao.constants.noise,
		size        = f.size,
		jitter      = f.jitter,
		noise_slice = f.ao.constants.noise_slice,
	}
	for level, i in f.ao.levels {
		index := gpu.read_index(gpu_texture(g, level))
		if i < 4 {
			constants.levels[i] = index
		} else {
			constants.level4 = index
		}
	}
	upload, ok := f.renderer.platform.gpu_upload(size_of(Contact_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Contact_Constants)(raw_data(upload.data))^ = constants
	groups := (f.size + MASK_GROUP_SIZE - 1) / MASK_GROUP_SIZE
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, {groups.x, groups.y, 1})
}

@(private = "file")
draw_shadow_maps :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	// A virtual shadow map's levels are the first views.
	view := f.shadows.virtual.count + ctx.piece
	viewport := f.shadows.viewports[view]
	gpu.cmd_set_viewport(ctx.cb, {f32(viewport.x), f32(viewport.y)}, {f32(viewport.z), f32(viewport.w)})
	gpu.cmd_set_scissor(ctx.cb, {i32(viewport.x), i32(viewport.y)}, {i32(viewport.z), i32(viewport.w)})
	draw_scene_view(f, ctx.cb, FIRST_SHADOW_VIEW + view, .Depth)
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
	offset := ecs.position_sub(f.view.position, f.renderer.scene.origin)
	constants := Mask_Constants {
		right         = {right.x, right.y, right.z, 0},
		up            = {up.x, up.y, up.z, 0},
		forward       = {forward.x, forward.y, forward.z, 0},
		projection    = f.projection,
		view_model    = f.view_model_projection,
		camera_offset = {offset.x, offset.y, offset.z, 0},
		light_index   = {max(u32), max(u32), max(u32), max(u32)},
		depth         = gpu.read_index(gpu_texture(g, f.depth)),
		normals       = gpu.read_index(gpu_texture(g, f.normals)),
		output        = gpu.write_index(gpu_texture(g, sf.mask_soft != 0 ? sf.mask_raw : sf.mask)),
		accel         = gpu.read_index(gpu_accel(g, ray_scene_accel(f))),
		lights        = gpu.read_index(f.lights.upload.buffer),
		lights_offset = f.lights.upload.offset,
		size          = f.size,
		stencil       = gpu.stencil_index(gpu_texture(g, f.depth)),
		jitter        = f.jitter,
		soft          = sf.mask_soft,
	}
	for c in 0 ..< sf.mask_count {
		constants.light_index[c] = sf.mask_lights[c]
	}
	if sf.mask_soft != 0 {
		constants.penumbra = gpu.write_index(gpu_texture(g, sf.mask_penumbra))
		constants.noise, constants.noise_slice = mask_noise(f)
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
