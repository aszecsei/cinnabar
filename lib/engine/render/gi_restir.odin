package render

import "core:log"
import "core:math"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// ReSTIR GI (see docs/rendering/global-illumination.md#restir-gi), after Ouyang et al.'s "ReSTIR GI: Path Resampling
// for Real-Time Path Tracing": with the world probes, one ray a pixel of each tile from the prepass's surface, cosine
// sampled, which traces the ray scene. Hit shading and the world probes' hit light give the light that its hit sends
// back, and the probes' light at the hit is the bounces past the first. Each tile keeps a reservoir: the sample point
// that it chose, its light and its weight. The temporal pass merges this frame's sample into last frame's reservoir,
// found by the velocity, and the spatial pass merges in a few neighbours' reservoirs, each reconnected to the pixel's
// surface through the Jacobian of the change in solid angle. The resolve gives each pixel the diffuse light of the
// reservoirs around it, blended into its history as the screen cascades' gather blends, with the world probes' light
// along its reflection for the specular light, and an a-trous filter smooths what is left of the noise. The
// reservoirs are history textures of the graph, so a resize, a camera cut or a frame that did not run them starts
// them over.

// The engine's ReSTIR GI shaders, by their .meta files.
GI_RESTIR_TRACE_SHADER :: #load("../content/shaders/gi_restir_trace.hlsl.meta", string)
GI_RESTIR_TEMPORAL_SHADER :: #load("../content/shaders/gi_restir_temporal.hlsl.meta", string)
GI_RESTIR_SPATIAL_SHADER :: #load("../content/shaders/gi_restir_spatial.hlsl.meta", string)
GI_RESTIR_RESOLVE_SHADER :: #load("../content/shaders/gi_restir_resolve.hlsl.meta", string)
GI_RESTIR_FILTER_SHADER :: #load("../content/shaders/gi_restir_filter.hlsl.meta", string)

// Match gi_restir.hlsli.
RESTIR_GROUP :: 64
// A ray starts this many pixels off its surface.
RESTIR_BIAS :: 2
// A reused reservoir counts while its receiver's depth is within this share of the pixel's, and its normal within
// this cosine of the pixel's.
RESTIR_DEPTH_TOLERANCE :: 0.1
RESTIR_NORMAL_COS :: 0.9
// A neighbour's sample is reused only while the change in solid angle from its surface to the pixel's is within this
// factor either way: past it, the sample is nearly grazing one of the two.
RESTIR_JACOBIAN_MAX :: 8
// The sample point, with its weight; its light, with its count; and its normal, the receiver's depth and its age.
RESTIR_SAMPLE_FORMAT :: gpu.Format.RGBA32_Float
RESTIR_LIGHT_FORMAT :: gpu.Format.RGBA16_Float
RESTIR_NORMAL_FORMAT :: gpu.Format.RGBA16_Float
// A sample's light is at most this luminance, pre-exposed: a quarter of the world probes' limit, as a reservoir keeps a
// rare bright sample for many frames, and at the probes' limit the light was strewn with sparks.
RESTIR_RADIANCE_MAX :: 4
// A reservoir's bytes in each texture: the sample's, the light's and the normal's.
RESTIR_RESERVOIR_SIZE :: 16 + 8 + 8

// Gi_Restir_Params are ReSTIR GI at a level. A ray is traced from one pixel of each tile a frame, at most reach
// meters; past it, the world probes' light along the ray counts. Last frame's reservoir counts as at most
// temporal_max_m samples, and a sample is kept for at most max_age frames, so the light follows a change. The spatial
// pass merges spatial_samples neighbours within spatial_radius reservoirs, to at most spatial_max_m samples, and with
// visibility traces a shadow ray to each neighbour's sample. The resolve blends into a history of at most
// history_frames frames, and the filter runs filter_passes a-trous steps.
Gi_Restir_Params :: struct {
	tile:            [2]u32,
	reach:           f32,
	temporal_max_m:  f32,
	max_age:         u32,
	spatial_samples: u32,
	spatial_radius:  f32,
	spatial_max_m:   f32,
	visibility:      bool,
	filter_passes:   u32,
	history_frames:  f32,
}

// Low and Medium run only when a quality picks ReSTIR GI by hand: no preset does below Ultra.
@(rodata)
GI_RESTIR_PARAMS := [Quality_Level]Gi_Restir_Params {
	.Low = {
		tile = {2, 2},
		reach = 32,
		temporal_max_m = 10,
		max_age = 30,
		spatial_samples = 3,
		spatial_radius = 12,
		spatial_max_m = 30,
		filter_passes = 3,
		history_frames = 16,
	},
	.Medium = {
		tile = {2, 2},
		reach = 48,
		temporal_max_m = 15,
		max_age = 30,
		spatial_samples = 4,
		spatial_radius = 16,
		spatial_max_m = 40,
		filter_passes = 2,
		history_frames = 12,
	},
	.High = {
		tile = {2, 2},
		reach = 64,
		temporal_max_m = 20,
		max_age = 40,
		spatial_samples = 5,
		spatial_radius = 24,
		spatial_max_m = 60,
		filter_passes = 2,
		history_frames = 12,
	},
	.Ultra = {
		tile = {1, 1},
		reach = 128,
		temporal_max_m = 20,
		max_age = 50,
		spatial_samples = 6,
		spatial_radius = 30,
		spatial_max_m = 80,
		visibility = true,
		filter_passes = 2,
		history_frames = 10,
	},
}

// Restir_Grid matches Restir_Grid in gi_restir.hlsli: a frame's ReSTIR GI, in the upload ring.
Restir_Grid :: struct {
	// How far the camera moved since last frame, which a last frame's sample point moves back by.
	camera_motion:   [4]f32,
	// The camera relative to the render origin, which the ray scene is relative to.
	camera_offset:   [4]f32,
	reservoirs:      [2]u32,
	tile:            [2]u32,
	rotation:        [2]u32,
	ray_count:       u32,
	frame:           u32,
	reach:           f32,
	bias:            f32,
	temporal_max_m:  f32,
	max_age:         f32,
	spatial_samples: u32,
	spatial_radius:  f32,
	spatial_max_m:   f32,
	visibility:      u32,
	jacobian_max:    f32,
	depth_tolerance: f32,
	normal_cos:      f32,
	radiance_max:    f32,
	// Whether last frame's reservoirs are this view's, at this size.
	history_valid:   u32,
	padding:         [3]u32,
}

#assert(size_of(Restir_Grid) == 128)

// Restir_Push matches Restir_Push in gi_restir.hlsli. Each pass binds the textures that it writes for writing.
@(private = "file")
Restir_Push :: struct {
	grid:         u32,
	grid_offset:  u32,
	pass:         u32,
	// The filter's step, in pixels.
	step:         u32,
	hits:         u32,
	surfaces:     u32,
	rays:         u32,
	accel:        u32,
	// What the rays pass through glass by.
	translucency: Translucency,
	transmit:     u32,
	exposure:     u32,
	sample_in:    u32,
	light_in:     u32,
	normal_in:    u32,
	sample_out:   u32,
	light_out:    u32,
	normal_out:   u32,
	filter_in:    u32,
	filter_out:   u32,
	padding:      [2]u32,
}

#assert(size_of(Restir_Push) <= 128)
// HLSL starts a nested struct of a constant buffer on 16 bytes.
#assert(offset_of(Restir_Push, translucency) % 16 == 0)

// Gi_Restir is ReSTIR GI's pipelines and the rays' buffers, which every view shares, in Gi_Passes.
Gi_Restir :: struct {
	trace:        Shader_Pipeline,
	temporal:     Shader_Pipeline,
	spatial:      Shader_Pipeline,
	resolve:      Shader_Pipeline,
	filter:       Shader_Pipeline,
	hits:         gpu.Buffer,
	surfaces:     gpu.Buffer,
	rays:         gpu.Buffer,
	transmit:     gpu.Buffer,
	ray_capacity: int,
}

// Gi_Restir_State is one view's ReSTIR GI between frames, in Gi_State. Its reservoirs are the graph's history
// textures, which the cache keeps.
Gi_Restir_State :: struct {
	// Counts the frames that ran it, for the rays' directions and the lights' choices.
	frame:   u32,
	// Whether the last frame that wanted ReSTIR GI had it, for note_restir_fallback.
	running: bool,
}

// Restir_Reservoirs are one set of reservoirs' textures.
@(private)
Restir_Reservoirs :: struct {
	sample: Texture,
	light:  Texture,
	normal: Texture,
}

// Gi_Restir_Frame is one frame's ReSTIR GI, in frame memory.
@(private)
Gi_Restir_Frame :: struct {
	frame:    ^Frame,
	params:   Gi_Restir_Params,
	grid:     Restir_Grid,
	upload:   gpu.Upload,
	hits:     Buffer,
	surfaces: Buffer,
	rays:     Buffer,
	transmit: Buffer,
	// Last frame's reservoirs, this frame's after the temporal pass, and after the spatial pass.
	previous: Restir_Reservoirs,
	temporal: Restir_Reservoirs,
	spatial:  Restir_Reservoirs,
	// The filter's two textures, which its steps write in turn.
	filtered: [2]Texture,
}

@(private = "file")
Restir_Pass :: enum u32 {
	Trace,
	Temporal,
	Spatial,
	Resolve,
	Filter,
}

// Restir_Step is one ReSTIR GI pass's data, in frame memory.
@(private = "file")
Restir_Step :: struct {
	restir: ^Gi_Restir_Frame,
	pass:   Restir_Pass,
	// The filter's step, and the textures that it reads and writes.
	step:   u32,
	input:  Texture,
	output: Texture,
}

gi_restir_init :: proc(s: ^Gi_Restir) {
	s.trace = shader_pipeline(GI_RESTIR_TRACE_SHADER)
	s.temporal = shader_pipeline(GI_RESTIR_TEMPORAL_SHADER)
	s.spatial = shader_pipeline(GI_RESTIR_SPATIAL_SHADER)
	s.resolve = shader_pipeline(GI_RESTIR_RESOLVE_SHADER)
	s.filter = shader_pipeline(GI_RESTIR_FILTER_SHADER)
}

gi_restir_destroy :: proc(s: ^Gi_Restir, platform: ^core.Platform_API) {
	for p in ([]^Shader_Pipeline{&s.trace, &s.temporal, &s.spatial, &s.resolve, &s.filter}) {
		destroy_shader_pipeline(p, platform)
	}
	for b in ([]gpu.Buffer{s.hits, s.surfaces, s.rays, s.transmit}) {
		platform.gpu_destroy_buffer(b)
	}
	s.hits, s.surfaces, s.rays, s.transmit, s.ray_capacity = {}, {}, {}, {}, 0
}

// sync_gi_restir_pipelines makes ReSTIR GI's pipelines, with Ray_Query only.
@(private)
sync_gi_restir_pipelines :: proc(r: ^Renderer, force: bool) {
	if !r.caps.ray_query {
		return
	}
	s := &r.gi.restir
	assets := r.residency.assets
	sync_compute_pipeline(&s.trace, r.platform, assets, {label = "gi restir trace"}, force)
	sync_compute_pipeline(&s.temporal, r.platform, assets, {label = "gi restir temporal"}, force)
	sync_compute_pipeline(&s.spatial, r.platform, assets, {label = "gi restir spatial"}, force)
	sync_compute_pipeline(&s.resolve, r.platform, assets, {label = "gi restir resolve"}, force)
	sync_compute_pipeline(&s.filter, r.platform, assets, {label = "gi restir filter"}, force)
}

// gi_restir_ready is whether ReSTIR GI's pipelines have compiled.
@(private)
gi_restir_ready :: proc(r: ^Renderer) -> bool {
	s := &r.gi.restir
	for p in ([]^Shader_Pipeline{&s.trace, &s.temporal, &s.spatial, &s.resolve, &s.filter}) {
		if !pipeline_ready(r.platform, p) {
			return false
		}
	}
	return true
}

// restir_fit is the tiles that a frame traces, a ray and a reservoir for each: the level's tile, widened while the rays
// are more than hit shading takes, as split_tile widens the split cascades'.
restir_fit :: proc(size: [2]u32, params: Gi_Restir_Params) -> (tile, reservoirs: [2]u32) {
	tile = params.tile
	for {
		reservoirs = (size + tile - 1) / tile
		if reservoirs.x * reservoirs.y <= MAX_HIT_RAYS {
			return
		}
		if tile.x <= tile.y {
			tile.x *= 2
		} else {
			tile.y *= 2
		}
	}
}

// restir_bytes is ReSTIR GI's memory for a view at a level, without the rays' buffers, which the split cascades'
// size: both halves of the reservoirs' histories, and the spatial pass's reservoirs.
restir_bytes :: proc(size: [2]u32, params: Gi_Restir_Params) -> int {
	_, reservoirs := restir_fit(size, params)
	return int(reservoirs.x) * int(reservoirs.y) * RESTIR_RESERVOIR_SIZE * 3
}

// restir_jacobian is how much the solid angle of a sample point changes when a neighbour's sample is reused at a
// receiver: the cosine at the sample toward the receiver over the one toward the neighbour, times the neighbour's
// squared distance over the receiver's. A sample at infinity, a ray that hit nothing, keeps its solid angle. Matches
// restir_jacobian in gi_restir.hlsli.
restir_jacobian :: proc(
	receiver, neighbour, sample, sample_normal: [3]f32,
	infinite: bool,
) -> f32 {
	if infinite {
		return 1
	}
	to_receiver := receiver - sample
	to_neighbour := neighbour - sample
	d_r := math.max(dot3(to_receiver, to_receiver), 1e-8)
	d_q := math.max(dot3(to_neighbour, to_neighbour), 1e-8)
	cos_r := abs(dot3(sample_normal, to_receiver)) / math.sqrt(d_r)
	cos_q := math.max(abs(dot3(sample_normal, to_neighbour)) / math.sqrt(d_q), 1e-6)
	return cos_r / cos_q * (d_q / d_r)
}

@(private = "file")
dot3 :: proc(a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

// ensure_restir_rays grows the rays' buffers to hold count rays.
@(private = "file")
ensure_restir_rays :: proc(r: ^Renderer, count: int) {
	s := &r.gi.restir
	if count <= s.ray_capacity {
		return
	}
	platform := r.platform
	for b in ([]gpu.Buffer{s.hits, s.surfaces, s.rays, s.transmit}) {
		platform.gpu_destroy_buffer(b)
	}
	s.ray_capacity = max(count, s.ray_capacity * 2)
	capacity := u32(s.ray_capacity)
	s.hits = platform.gpu_create_buffer(
		{size = capacity * size_of(Hit_Record), usage = {.Storage}, label = "gi restir hits"},
		nil,
	)
	s.surfaces = platform.gpu_create_buffer(
		{size = capacity * size_of(Hit_Surface), usage = {.Storage}, label = "gi restir surfaces"},
		nil,
	)
	s.rays = platform.gpu_create_buffer(
		{size = capacity * 16, usage = {.Storage}, label = "gi restir rays"},
		nil,
	)
	s.transmit = platform.gpu_create_buffer(
		{size = capacity * 4, usage = {.Storage}, label = "gi restir transmittance"},
		nil,
	)
}

// restir_histories are a view's reservoirs between frames, at their size: the zero value when the cache has no room.
@(private = "file")
restir_histories :: proc(g: ^Graph, size: [2]u32) -> (sample, light, normal: History, ok: bool) {
	sample = history_texture(
		g,
		{size = size, format = RESTIR_SAMPLE_FORMAT, label = "gi restir sample"},
	)
	light = history_texture(
		g,
		{size = size, format = RESTIR_LIGHT_FORMAT, label = "gi restir light"},
	)
	normal = history_texture(
		g,
		{size = size, format = RESTIR_NORMAL_FORMAT, label = "gi restir normal"},
	)
	ok = sample.current != 0 && light.current != 0 && normal.current != 0
	return
}

// add_gi_restir_passes adds ReSTIR GI after the world probes, on the compute queue, and sets Frame.gi_diffuse and
// Frame.gi_specular. It is false, and adds nothing, without the world probes this frame, ReSTIR GI's pipelines, room
// for a batch of hit shading, or room in the upload ring or the history cache; the frame then takes the screen
// cascades.
@(private)
add_gi_restir_passes :: proc(f: ^Frame) -> bool {
	r := f.renderer
	platform := r.platform
	gf := f.gi
	pf := gf.probes
	if pf == nil || !gi_restir_ready(r) || !hit_shading_ready(f) {
		return false
	}
	params := GI_RESTIR_PARAMS[gf.settings.level]
	tile, reservoirs := restir_fit(f.size, params)
	ray_count := reservoirs.x * reservoirs.y
	upload, ok := platform.gpu_upload(size_of(Restir_Grid), 16)
	if !ok {
		return false
	}
	g := f.graph
	// Hit shading's turn comes before the histories: a history that a frame takes counts as written once the frame
	// executes, so the histories are taken only when the passes that write them run. A cache with no room, which logs
	// an error, wastes the turn.
	reservation, reserved := reserve_hit_shading(f, ray_count).?
	if !reserved {
		return false
	}
	sample, light, normal, histories := restir_histories(g, reservoirs)
	if !histories {
		return false
	}
	ensure_restir_rays(r, int(ray_count))
	s := &f.state.gi.restir
	s.frame += 1
	shared := &r.gi.restir
	rf := new(Gi_Restir_Frame, platform.frame_allocator)
	rf.frame, rf.params, rf.upload = f, params, upload
	rf.hits = import_buffer(g, shared.hits)
	rf.surfaces = import_buffer(g, shared.surfaces)
	rf.rays = import_buffer(g, shared.rays)
	rf.transmit = import_buffer(g, shared.transmit)
	rf.previous = {sample.previous, light.previous, normal.previous}
	rf.temporal = {sample.current, light.current, normal.current}
	rf.spatial = restir_transient_reservoirs(g, reservoirs)

	offset := ecs.position_sub(f.view.position, r.scene.origin)
	motion := f.camera_motion
	rf.grid = {
		camera_motion   = {motion.x, motion.y, motion.z, 0},
		camera_offset   = {offset.x, offset.y, offset.z, 0},
		reservoirs      = reservoirs,
		tile            = tile,
		rotation        = split_rotation(s.frame, tile),
		ray_count       = ray_count,
		frame           = s.frame,
		reach           = params.reach,
		bias            = RESTIR_BIAS,
		temporal_max_m  = params.temporal_max_m,
		max_age         = f32(params.max_age),
		spatial_samples = params.spatial_samples,
		spatial_radius  = params.spatial_radius,
		spatial_max_m   = params.spatial_max_m,
		visibility      = u32(params.visibility),
		jacobian_max    = RESTIR_JACOBIAN_MAX,
		depth_tolerance = RESTIR_DEPTH_TOLERANCE,
		normal_cos      = RESTIR_NORMAL_COS,
		radiance_max    = RESTIR_RADIANCE_MAX,
		history_valid   = u32(sample.valid && light.valid && normal.valid),
	}
	(^Restir_Grid)(raw_data(upload.data))^ = rf.grid

	add_restir_trace(rf)
	shaded := add_hit_shading(
		f,
		reservation,
		{hits = rf.hits, surfaces = rf.surfaces, count = ray_count, transmit = rf.transmit},
		.Compute,
		"gi restir",
	)
	// Each frame's choices of lights are new, so the reservoirs gather many of them.
	inputs := new_clone(pf.hit_light, platform.frame_allocator)
	inputs.seed = s.frame
	add_hit_light_passes(f, inputs, "gi restir", shaded, rf.rays)

	p := add_compute_pass(
		g,
		"gi restir temporal",
		run_restir_pass,
		restir_step(rf, .Temporal),
		queue = .Compute,
	)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read(g, p, f.velocity)
	read(g, p, f.exposure)
	read(g, p, rf.hits)
	read(g, p, rf.surfaces)
	read(g, p, rf.rays)
	read(g, p, rf.transmit)
	read_reservoirs(g, p, rf.previous)
	write_reservoirs(g, p, rf.temporal)
	declare_probe_reads(f, p)
	declare_sky_cube_reads(f, p)

	p = add_compute_pass(
		g,
		"gi restir spatial",
		run_restir_pass,
		restir_step(rf, .Spatial),
		queue = .Compute,
	)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read_accel(g, p, ray_scene_accel(f))
	declare_translucency_reads(f, p)
	read_reservoirs(g, p, rf.temporal)
	write_reservoirs(g, p, rf.spatial)

	add_restir_denoise(rf)
	gf.restir = rf
	return true
}

// restir_transient_reservoirs are a frame's spatial reservoirs, which no later frame reads, at a size.
@(private = "file")
restir_transient_reservoirs :: proc(g: ^Graph, size: [2]u32) -> Restir_Reservoirs {
	transient :: proc(g: ^Graph, size: [2]u32, format: gpu.Format, label: string) -> Texture {
		return create_texture(g, {size = size, format = format, label = label})
	}
	return {
		transient(g, size, RESTIR_SAMPLE_FORMAT, "gi restir spatial sample"),
		transient(g, size, RESTIR_LIGHT_FORMAT, "gi restir spatial light"),
		transient(g, size, RESTIR_NORMAL_FORMAT, "gi restir spatial normal"),
	}
}

@(private = "file")
restir_step :: proc(rf: ^Gi_Restir_Frame, pass: Restir_Pass) -> ^Restir_Step {
	return new_clone(
		Restir_Step{restir = rf, pass = pass},
		rf.frame.renderer.platform.frame_allocator,
	)
}

// add_restir_trace adds the rays' trace from the tiles' pixels, into the frame's hits and their transmittance, which
// hit shading takes next.
@(private = "file")
add_restir_trace :: proc(rf: ^Gi_Restir_Frame) {
	f := rf.frame
	g := f.graph
	p := add_compute_pass(
		g,
		"gi restir trace",
		run_restir_pass,
		restir_step(rf, .Trace),
		queue = .Compute,
	)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read_accel(g, p, ray_scene_accel(f))
	declare_translucency_reads(f, p)
	write(g, p, rf.hits)
	write(g, p, rf.transmit)
}

// add_restir_denoise adds the resolve of the frame's spatial reservoirs into the diffuse and specular histories and
// the filter's steps, and sets Frame.gi_diffuse and Frame.gi_specular.
@(private = "file")
add_restir_denoise :: proc(rf: ^Gi_Restir_Frame) {
	f := rf.frame
	g := f.graph
	gf := f.gi
	params := rf.params
	platform := f.renderer.platform
	p := add_compute_pass(
		g,
		"gi restir resolve",
		run_restir_pass,
		restir_step(rf, .Resolve),
		queue = .Compute,
	)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read(g, p, f.velocity)
	read(g, p, f.exposure)
	read_reservoirs(g, p, rf.spatial)
	read(g, p, gf.diffuse.previous)
	read(g, p, gf.specular.previous)
	write(g, p, gf.diffuse.current)
	write(g, p, gf.specular.current)
	declare_probe_reads(f, p)
	declare_gather_specular(f, p)

	f.gi_diffuse, f.gi_specular = gf.diffuse.current, gf.specular.current
	if params.filter_passes > 0 {
		rf.filtered = {
			create_texture(g, {size = f.size, format = GI_FORMAT, label = "gi restir filtered"}),
			create_texture(g, {size = f.size, format = GI_FORMAT, label = "gi restir filtered 2"}),
		}
	}
	input := gf.diffuse.current
	for i in 0 ..< params.filter_passes {
		output := rf.filtered[i % 2]
		filter := new_clone(
			Restir_Step {
				restir = rf,
				pass = .Filter,
				step = 1 << i,
				input = input,
				output = output,
			},
			platform.frame_allocator,
		)
		p = add_compute_pass(g, "gi restir filter", run_restir_pass, filter, queue = .Compute)
		read(g, p, f.depth)
		read(g, p, f.normals)
		read(g, p, input)
		write(g, p, output)
		input = output
	}
	f.gi_diffuse = input
}

@(private = "file")
read_reservoirs :: proc(g: ^Graph, p: Pass, reservoirs: Restir_Reservoirs) {
	read(g, p, reservoirs.sample)
	read(g, p, reservoirs.light)
	read(g, p, reservoirs.normal)
}

@(private = "file")
write_reservoirs :: proc(g: ^Graph, p: Pass, reservoirs: Restir_Reservoirs) {
	write(g, p, reservoirs.sample)
	write(g, p, reservoirs.light)
	write(g, p, reservoirs.normal)
}

// note_restir_fallback warns when a frame that wants ReSTIR GI takes the screen cascades after a frame that had it,
// which changes the whole frame's indirect light with nothing moving. It warns once, until ReSTIR GI runs again.
@(private)
note_restir_fallback :: proc(f: ^Frame, ran: bool) {
	r := f.renderer
	s := &f.state.gi.restir
	if ran || f.gi.settings.technique != .Restir {
		s.running = ran
		return
	}
	if !s.running {
		return
	}
	s.running = false
	reason := "the upload ring or the history cache has no room"
	switch {
	case f.gi.probes == nil:
		reason = "the world probes did not run"
	case !gi_restir_ready(r):
		reason = "its pipelines are not ready"
	case !hit_shading_ready(f):
		reason = "hit shading has no room"
	}
	log.warnf("gi: ReSTIR GI gave way to the screen cascades: %s", reason)
}

// run_restir_pass dispatches a ReSTIR GI pass. Its pass constants are the global illumination's, for the pixels'
// surfaces, the world probes and the sky's cubemap.
@(private = "file")
run_restir_pass :: proc(ctx: ^Pass_Context) {
	step := (^Restir_Step)(ctx.data)
	rf := step.restir
	f := rf.frame
	s := &f.renderer.gi.restir
	gf := f.gi
	g := ctx.graph
	read_index :: proc(g: ^Graph, t: Texture) -> u32 {
		return gpu.read_index(gpu_texture(g, t))
	}
	write_index :: proc(g: ^Graph, t: Texture) -> u32 {
		return gpu.write_index(gpu_texture(g, t))
	}
	push := Restir_Push {
		grid        = gpu.read_index(rf.upload.buffer),
		grid_offset = rf.upload.offset,
		pass        = u32(step.pass),
		step        = step.step,
		exposure    = gpu.read_index(gpu_buffer(g, f.exposure)),
	}
	c := gi_constants(ctx, f)
	pipeline: gpu.Pipeline
	dispatch: [3]u32
	switch step.pass {
	case .Trace:
		pipeline, dispatch = s.trace.pipeline, restir_groups(rf.grid.ray_count)
		push.hits = gpu.write_index(gpu_buffer(g, rf.hits))
		push.transmit = gpu.write_index(gpu_buffer(g, rf.transmit))
		push.accel = gpu.read_index(gpu_accel(g, ray_scene_accel(f)))
		push.translucency = translucency_constants(f, g)
	case .Temporal:
		pipeline, dispatch = s.temporal.pipeline, groups(rf.grid.reservoirs, POST_GROUP_SIZE)
		push.hits = gpu.read_index(gpu_buffer(g, rf.hits))
		push.surfaces = gpu.read_index(gpu_buffer(g, rf.surfaces))
		push.rays = gpu.read_index(gpu_buffer(g, rf.rays))
		push.transmit = gpu.read_index(gpu_buffer(g, rf.transmit))
		push.sample_in, push.light_in, push.normal_in =
			read_index(g, rf.previous.sample),
			read_index(g, rf.previous.light),
			read_index(g, rf.previous.normal)
		push.sample_out, push.light_out, push.normal_out =
			write_index(g, rf.temporal.sample),
			write_index(g, rf.temporal.light),
			write_index(g, rf.temporal.normal)
		c.velocity = read_index(g, f.velocity)
	case .Spatial:
		pipeline, dispatch = s.spatial.pipeline, groups(rf.grid.reservoirs, POST_GROUP_SIZE)
		push.accel = gpu.read_index(gpu_accel(g, ray_scene_accel(f)))
		push.translucency = translucency_constants(f, g)
		push.sample_in, push.light_in, push.normal_in =
			read_index(g, rf.temporal.sample),
			read_index(g, rf.temporal.light),
			read_index(g, rf.temporal.normal)
		push.sample_out, push.light_out, push.normal_out =
			write_index(g, rf.spatial.sample),
			write_index(g, rf.spatial.light),
			write_index(g, rf.spatial.normal)
	case .Resolve:
		pipeline, dispatch = s.resolve.pipeline, groups(f.size, POST_GROUP_SIZE)
		push.sample_in, push.light_in, push.normal_in =
			read_index(g, rf.spatial.sample),
			read_index(g, rf.spatial.light),
			read_index(g, rf.spatial.normal)
		c = gather_constants(ctx, f)
		c.velocity = read_index(g, f.velocity)
		c.history_diffuse = read_index(g, gf.diffuse.previous)
		c.history_specular = read_index(g, gf.specular.previous)
		c.out_diffuse = write_index(g, gf.diffuse.current)
		c.out_specular = write_index(g, gf.specular.current)
		c.max_frames = rf.params.history_frames
	case .Filter:
		pipeline, dispatch = s.filter.pipeline, groups(f.size, POST_GROUP_SIZE)
		push.filter_in, push.filter_out = read_index(g, step.input), write_index(g, step.output)
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	if !upload_gi_constants(ctx, f, c) {
		return
	}
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, dispatch)
}

// restir_groups is a dispatch of a thread for each of count, in groups of RESTIR_GROUP, in rows of at most 65535
// groups.
@(private = "file")
restir_groups :: proc(count: u32) -> [3]u32 {
	n := (count + RESTIR_GROUP - 1) / RESTIR_GROUP
	return {min(n, 65535), (n + 65534) / 65535, 1}
}
