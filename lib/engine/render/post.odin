package render

import "core:math"
import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"

// Post-processing (see docs/rendering/post-processing.md#post-processing): temporal AA into a history texture, the exposure from a
// luminance histogram, which pre-exposes the next frame, and bloom, all in linear HDR at the scene's resolution. The
// output pass then tone maps through a lookup table, which a compute pass bakes when the settings change.

// The engine's post-processing shaders, by their .meta files.
TEMPORAL_AA_SHADER :: #load("../content/shaders/temporal_aa.hlsl.meta", string)
BLOOM_SHADER :: #load("../content/shaders/bloom.hlsl.meta", string)
HISTOGRAM_SHADER :: #load("../content/shaders/exposure_histogram.hlsl.meta", string)
EXPOSURE_SHADER :: #load("../content/shaders/exposure_adapt.hlsl.meta", string)
TONE_LUT_SHADER :: #load("../content/shaders/tone_lut.hlsl.meta", string)

// The thread groups of the passes over pixels, and of the histogram.
POST_GROUP_SIZE :: 8
HISTOGRAM_GROUP_SIZE :: 16
// The camera's jitter cycles through this many points of the Halton (2, 3) sequence.
JITTER_SAMPLES :: 8
// This frame's share of temporal AA's result. The history holds the rest.
TEMPORAL_BLEND :: 0.1
// The prepass clears the velocity to this where it draws nothing, the sky and a game's own draws, which temporal AA
// then moves with the camera. Matches VELOCITY_NONE in temporal_aa.hlsl.
VELOCITY_NONE :: 10000
// Bloom's chain halves the scene at most this many times, and stops before a side is shorter than BLOOM_MIN_SIZE.
BLOOM_LEVELS :: 6
BLOOM_MIN_SIZE :: 8
BLOOM_FORMAT :: gpu.Format.RGBA16_Float
DEFAULT_BLOOM_INTENSITY :: 0.04
// The luminance histogram's bins, and the range of log2 luminance that bins 1 and up cover. Bin 0 holds black pixels.
HISTOGRAM_BINS :: 256
HISTOGRAM_MIN_LOG :: -12
HISTOGRAM_MAX_LOG :: 8
// The auto exposure's limits on the scene's average luminance, as log2, and its speed: the share of the way to its
// target that it goes in a second is 1 - e^-speed.
DEFAULT_EXPOSURE_RANGE :: [2]f32{-8, 4}
DEFAULT_ADAPTATION_SPEED :: 1.5
// The tone mapping lookup table has LUT_SIZE^3 entries, its blue slices side by side in one 2D texture. Matches
// tone_lut.hlsli.
LUT_SIZE :: 32
LUT_FORMAT :: gpu.Format.RGBA16_Float
// In HDR output, SDR's white, which the UI has, is the display's SDR white, as Windows shows SDR content, or
// DEFAULT_PAPER_WHITE nits when that is unknown. The brightest colors reach the display's peak, or DEFAULT_PEAK nits
// (see docs/rendering/layers-and-output.md#hdr-output).
DEFAULT_PAPER_WHITE :: 200
DEFAULT_PEAK :: 1000

Tone_Mapper :: enum u8 {
	// AgX: a smooth roll-off to white that desaturates bright colors.
	AgX,
	// Khronos PBR Neutral: colors up to 0.76 stay as they are, so base colors show true.
	Pbr_Neutral,
	// Stephen Hill's fit of ACES's reference and output transforms.
	Aces,
}

Exposure_Mode :: enum u8 {
	// The exposure adapts to the scene's average luminance.
	Auto,
	// The exposure is Post_Settings.exposure.
	Manual,
}

// Post_Settings are a frame's post-processing, in Frame_Settings, from the Anti_Aliasing, Exposure, Tone_Mapping and Bloom settings. Where 0 would mean nothing, it gives the default.
Post_Settings :: struct {
	no_temporal_aa:        bool,
	no_bloom:              bool,
	// Bloom's share of the final color.
	bloom_intensity:       f32,
	exposure_mode:         Exposure_Mode,
	// With Manual, the scale of the scene's colors. 0 means 1.
	exposure:              f32,
	// Stops added to the exposure, in either mode.
	exposure_compensation: f32,
	// With Auto, the range of the scene's average luminance, as log2, that the exposure adapts to. Zero gives
	// DEFAULT_EXPOSURE_RANGE.
	exposure_range:        [2]f32,
	// With Auto, how fast the exposure adapts. 0 gives DEFAULT_ADAPTATION_SPEED.
	adaptation_speed:      f32,
	tone_mapper:           Tone_Mapper,
	// Color grading, which the lookup table bakes with the tone mapper: contrast in stops around middle grey,
	// saturation, and a tint that multiplies the scene. 1 and white leave the scene as it is.
	contrast:              f32,
	saturation:            f32,
	tint:                  [3]f32,
	// For HDR output, in nits: the brightness of SDR's white, which the UI has, 0 giving the display's SDR white, and
	// the brightest color, 0 giving the display's peak. Paper white is at most the peak.
	paper_white:           f32,
	peak:                  f32,
}

// Post is the post-processing's state between frames, in the Renderer.
Post :: struct {
	temporal_aa:    Shader_Pipeline,
	bloom:          Shader_Pipeline,
	histogram:      Shader_Pipeline,
	adapt:          Shader_Pipeline,
	tone_lut:       Shader_Pipeline,
	// Bilinear and clamped: the history, bloom's chain and the lookup table read with it.
	sampler:        gpu.Sampler,
	// Two floats: the exposure that pre-exposes this frame's scene, then last frame's. The exposure pass writes the
	// next frame's.
	exposure:       gpu.Buffer,
	// Holds 1: the previews are not pre-exposed.
	unit_exposure:  gpu.Buffer,
	histogram_bins: gpu.Buffer,
	lut:            gpu.Texture,
	// What the lookup table was last baked from, and the shader's version then.
	lut_grading:    Grading,
	lut_version:    u32,
	lut_baked:      bool,
	// Counts the frames with temporal AA, for the jitter.
	jitter_index:   u32,
	last_time:      f64,
	// The exposure has adapted once. The first frame takes its target at once.
	adapted:        bool,
}

// Grading is what the lookup table bakes: the tone mapper and the color grading, with the defaults resolved.
@(private)
Grading :: struct {
	tone_mapper: Tone_Mapper,
	contrast:    f32,
	saturation:  f32,
	tint:        [3]f32,
	// For HDR output, with its paper white and peak in nits, which are zero for SDR.
	hdr:         bool,
	paper_white: f32,
	peak:        f32,
}

// Post_Frame is what one frame's post passes need, in frame memory.
@(private)
Post_Frame :: struct {
	settings:         Post_Settings,
	temporal:         bool,
	// The exposure pass runs, and with exposure_auto, the histogram before it.
	exposure:         bool,
	exposure_auto:    bool,
	history:          History,
	reproject:        matrix[4, 4]f32,
	// The scenes that temporal AA and bloom read.
	temporal_in:      Texture,
	bloom_in:         Texture,
	reset:            bool,
	delta:            f32,
	histogram:        Buffer,
	bloom_levels:     int,
	bloom_down:       [BLOOM_LEVELS]Texture,
	bloom_up:         [BLOOM_LEVELS]Texture,
	bloom_sizes:      [BLOOM_LEVELS][2]u32,
	grading:          Grading,
	// In HDR output, the UI's white in nits, which the output pass scales it to.
	paper_white:      f32,
	// A debug view that is not shaded is in the scene, which the output pass only encodes, and the tone mapping is off.
	raw:              bool,
	no_tone_mapping:  bool,
	// The game's post effects run, with their settings, by their index in Renderer.effects.
	effects:          bool,
	effect_settings:  []Effect_Settings,
	// The bloom composite's scene, bloom and their scales, and its result.
	composite_in:     Texture,
	composite_bloom:  Texture,
	composite_out:    Texture,
	composite_scales: [2]f32,
}

// Bloom_Step is one pass of bloom's chain: a level's downsample, or its upsample.
@(private = "file")
Bloom_Step :: struct {
	frame: ^Frame,
	level: int,
	up:    bool,
}

// Temporal_Constants matches Temporal_Constants in temporal_aa.hlsl.
@(private = "file")
Temporal_Constants :: struct {
	reproject:     matrix[4, 4]f32,
	jitter:        [2]f32,
	inverse_size:  [2]f32,
	size:          [2]u32,
	scene:         u32,
	velocity:      u32,
	depth:         u32,
	history:       u32,
	output:        u32,
	exposure:      u32,
	sampler_index: u32,
	valid:         u32,
	blend:         f32,
	padding:       u32,
}

// The modes of bloom.hlsl: the first downsample, which weighs down bright pixels so they do not flicker, the others,
// the upsamples, and the composite into the scene before a game's effects (see add_post_effects).
@(private)
BLOOM_FIRST :: 0
@(private)
BLOOM_DOWN :: 1
@(private)
BLOOM_UP :: 2
@(private)
BLOOM_COMPOSITE :: 3

// Bloom_Push matches Push in bloom.hlsl.
@(private)
Bloom_Push :: struct {
	source:        u32,
	base:          u32,
	output:        u32,
	sampler_index: u32,
	source_texel:  [2]f32,
	size:          [2]u32,
	mode:          u32,
	scene_scale:   f32,
	bloom_scale:   f32,
	padding:       u32,
}

// Histogram_Push matches Push in exposure_histogram.hlsl.
@(private = "file")
Histogram_Push :: struct {
	scene:         u32,
	depth:         u32,
	exposure:      u32,
	histogram:     u32,
	size:          [2]u32,
	min_log:       f32,
	inverse_range: f32,
}

// Exposure_Push matches Push in exposure_adapt.hlsl.
@(private = "file")
Exposure_Push :: struct {
	histogram:    u32,
	exposure:     u32,
	manual:       u32,
	reset:        u32,
	min_log:      f32,
	range:        f32,
	low_log:      f32,
	high_log:     f32,
	compensation: f32,
	scale:        f32,
	adapt:        f32,
	padding:      u32,
}

// Lut_Push matches Push in tone_lut.hlsl.
@(private = "file")
Lut_Push :: struct {
	output:      u32,
	tone_mapper: u32,
	contrast:    f32,
	saturation:  f32,
	tint:        [3]f32,
	hdr:         u32,
	paper_white: f32,
	peak:        f32,
	padding:     [2]u32,
}

#assert(size_of(Temporal_Constants) == 128 && size_of(Bloom_Push) <= 128 && size_of(Exposure_Push) <= 128)

post_init :: proc(p: ^Post, platform: ^core.Platform_API) {
	p.temporal_aa = shader_pipeline(TEMPORAL_AA_SHADER)
	p.bloom = shader_pipeline(BLOOM_SHADER)
	p.histogram = shader_pipeline(HISTOGRAM_SHADER)
	p.adapt = shader_pipeline(EXPOSURE_SHADER)
	p.tone_lut = shader_pipeline(TONE_LUT_SHADER)
	p.sampler = platform.gpu_create_sampler({filter = .Linear, mip_filter = .Linear, address = .Clamp, label = "post sampler"})
	ones := [4]f32{1, 1, 0, 0}
	p.exposure = platform.gpu_create_buffer({size = size_of(ones), usage = {.Storage}, label = "exposure"}, transmute([]byte)ones[:])
	p.unit_exposure = platform.gpu_create_buffer({size = size_of(ones), label = "unit exposure"}, transmute([]byte)ones[:])
	zeros: [HISTOGRAM_BINS]u32
	p.histogram_bins = platform.gpu_create_buffer({size = size_of(zeros), usage = {.Storage}, label = "luminance histogram"}, transmute([]byte)zeros[:])
	p.lut = platform.gpu_create_texture({size = {LUT_SIZE * LUT_SIZE, LUT_SIZE}, format = LUT_FORMAT, usage = {.Sampled, .Storage}, label = "tone mapping lut"}, nil)
}

post_destroy :: proc(p: ^Post, platform: ^core.Platform_API) {
	for pipeline in ([]^Shader_Pipeline{&p.temporal_aa, &p.bloom, &p.histogram, &p.adapt, &p.tone_lut}) {
		destroy_shader_pipeline(pipeline, platform)
	}
	platform.gpu_destroy_sampler(p.sampler)
	for b in ([]gpu.Buffer{p.exposure, p.unit_exposure, p.histogram_bins}) {
		platform.gpu_destroy_buffer(b)
	}
	platform.gpu_destroy_texture(p.lut)
	p.lut, p.lut_baked = {}, false
}

@(private)
sync_post_pipelines :: proc(r: ^Renderer, force: bool) {
	p := &r.post
	assets := r.residency.assets
	sync_compute_pipeline(&p.temporal_aa, r.platform, assets, {label = "temporal aa"}, force)
	sync_compute_pipeline(&p.bloom, r.platform, assets, {label = "bloom"}, force)
	sync_compute_pipeline(&p.histogram, r.platform, assets, {label = "exposure histogram"}, force)
	sync_compute_pipeline(&p.adapt, r.platform, assets, {label = "exposure"}, force)
	sync_compute_pipeline(&p.tone_lut, r.platform, assets, {label = "tone mapping lut"}, force)
}

// pipeline_ready is whether a pipeline is compiled, so a pass that it records does its work. A post pass whose
// pipeline is not ready is left out, and the frame goes on without it, as a game's post effect should be.
pipeline_ready :: proc(platform: ^core.Platform_API, p: ^Shader_Pipeline) -> bool {
	return p.pipeline != {} && (platform.gpu_pipeline_ready == nil || platform.gpu_pipeline_ready(p.pipeline))
}

// halton is the index-th point of the Halton sequence of a base, in [0, 1).
@(private)
halton :: proc(index, base: u32) -> f32 {
	scale: f32 = 1
	result: f32 = 0
	for i := index; i > 0; i /= base {
		scale /= f32(base)
		result += scale * f32(i % base)
	}
	return result
}

// jitter_projection moves what a view_projection gives by a jitter in normalized device coordinates.
jitter_projection :: proc(m: matrix[4, 4]f32, jitter: [2]f32) -> matrix[4, 4]f32 {
	shift := matrix[4, 4]f32{
		1, 0, 0, jitter.x,
		0, 1, 0, jitter.y,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
	return shift * m
}

// jittered_view_projection is the frame's view_projection with the camera's jitter, which a game's own draws in the
// world pass use, so they cover the same pixels as the renderer's draws do.
jittered_view_projection :: proc(f: ^Frame) -> matrix[4, 4]f32 {
	return jitter_projection(f.view_projection, f.jitter)
}

// begin_post decides the frame's jitter, before the scene's constants are written, and which post passes run, so the
// world pass keeps the depth for them. It imports the exposure buffer and the lookup table, which the passes before
// post read.
@(private)
begin_post :: proc(f: ^Frame, settings: Post_Settings) {
	r := f.renderer
	p := &r.post
	platform := r.platform
	pf := new(Post_Frame, platform.frame_allocator)
	f.post = pf
	pf.settings = settings
	pf.temporal = !settings.no_temporal_aa && pipeline_ready(platform, &p.temporal_aa)
	pf.exposure = pipeline_ready(platform, &p.adapt)
	pf.exposure_auto = pf.exposure && settings.exposure_mode == .Auto && pipeline_ready(platform, &p.histogram)
	if pf.temporal {
		p.jitter_index += 1
		n := p.jitter_index % JITTER_SAMPLES + 1
		pixel := [2]f32{halton(n, 2) - 0.5, halton(n, 3) - 0.5}
		f.jitter = {2 * pixel.x / f32(f.size.x), -2 * pixel.y / f32(f.size.y)}
	}
	now := platform.time_seconds != nil ? platform.time_seconds() : 0
	pf.delta = p.last_time > 0 ? f32(clamp(now - p.last_time, 0, 0.25)) : 0
	p.last_time = now
	f.exposure = import_buffer(f.graph, p.exposure)
	f.lut = import_texture(f.graph, p.lut, .Storage)
}

// add_post_passes adds the post passes after the world and the before_post hook: temporal AA, whose history becomes
// Frame.scene, the exposure for the next frame, bloom into Frame.bloom, and the lookup table's bake when the settings
// or its shader changed.
@(private)
add_post_passes :: proc(f: ^Frame) {
	r := f.renderer
	p := &r.post
	pf := f.post
	g := f.graph
	platform := r.platform
	s := pf.settings

	add_post_effects(f, .Before_Temporal_Aa)
	if pf.temporal {
		pf.history = history_texture(g, {size = f.size, format = SCENE_FORMAT, label = "temporal aa history"})
		if pf.history.current != 0 {
			pf.temporal_in = f.scene
			pf.reproject = f.previous_view_projection * linalg.matrix4_translate_f32(f.camera_motion) * linalg.inverse(f.view_projection)
			pass := add_compute_pass(g, "temporal aa", run_temporal_aa, f)
			read(g, pass, f.scene)
			read(g, pass, f.velocity)
			read(g, pass, f.depth)
			read(g, pass, f.exposure)
			read(g, pass, pf.history.previous)
			write(g, pass, pf.history.current)
			f.scene = pf.history.current
		}
	}
	add_post_effects(f, .After_Temporal_Aa)

	if pf.exposure {
		pf.reset = !p.adapted
		p.adapted = true
		pf.histogram = import_buffer(g, p.histogram_bins)
		if pf.exposure_auto {
			pass := add_compute_pass(g, "exposure histogram", run_histogram, f)
			read(g, pass, f.scene)
			read(g, pass, f.depth)
			read(g, pass, f.exposure)
			write(g, pass, pf.histogram)
		}
		pass := add_compute_pass(g, "exposure", run_exposure, f)
		write(g, pass, f.exposure)
		if pf.exposure_auto {
			write(g, pass, pf.histogram)
		}
	}

	if !s.no_bloom && pipeline_ready(platform, &p.bloom) {
		size := f.size
		for level in 0 ..< BLOOM_LEVELS {
			size = {max(size.x / 2, 1), max(size.y / 2, 1)}
			if level > 0 && min(size.x, size.y) < BLOOM_MIN_SIZE {
				break
			}
			pf.bloom_sizes[level] = size
			pf.bloom_down[level] = create_texture(g, {size = size, format = BLOOM_FORMAT, label = "bloom down"})
			pf.bloom_levels += 1
		}
		pf.bloom_in = f.scene
		source := f.scene
		for level in 0 ..< pf.bloom_levels {
			pass := add_compute_pass(g, "bloom down", run_bloom, new_clone(Bloom_Step{f, level, false}, platform.frame_allocator))
			read(g, pass, source)
			write(g, pass, pf.bloom_down[level])
			source = pf.bloom_down[level]
		}
		// From the smallest level up, each level adds the blurred level below it.
		for level := pf.bloom_levels - 2; level >= 0; level -= 1 {
			pf.bloom_up[level] = create_texture(g, {size = pf.bloom_sizes[level], format = BLOOM_FORMAT, label = "bloom up"})
			pass := add_compute_pass(g, "bloom up", run_bloom, new_clone(Bloom_Step{f, level, true}, platform.frame_allocator))
			read(g, pass, pf.bloom_down[level])
			read(g, pass, source)
			write(g, pass, pf.bloom_up[level])
			source = pf.bloom_up[level]
		}
		// Each level adds its share, so the chain's sum is about levels times the scene.
		intensity := s.bloom_intensity
		f.bloom = source
		f.bloom_scale = intensity / f32(pf.bloom_levels)
		f.scene_scale = 1 - intensity
	}
	add_post_effects(f, .Before_Tone_Mapping)

	pf.grading = {
		tone_mapper = s.tone_mapper,
		contrast    = s.contrast,
		saturation  = s.saturation,
		tint        = s.tint,
	}
	if f.output.mode != .Sdr {
		display := f.output.display
		peak := s.peak > 0 ? s.peak : display.max_luminance > 0 ? display.max_luminance : DEFAULT_PEAK
		paper_white := s.paper_white > 0 ? s.paper_white : display.sdr_white > 0 ? display.sdr_white : DEFAULT_PAPER_WHITE
		pf.grading.hdr, pf.grading.peak, pf.grading.paper_white = true, peak, min(paper_white, peak)
		pf.paper_white = pf.grading.paper_white
	}
	stale := !p.lut_baked || pf.grading != p.lut_grading || p.tone_lut.version != p.lut_version
	if stale && pipeline_ready(platform, &p.tone_lut) {
		pass := add_compute_pass(g, "tone mapping lut", run_tone_lut, f)
		write(g, pass, f.lut)
		p.lut_baked, p.lut_grading, p.lut_version = true, pf.grading, p.tone_lut.version
	}
}

// groups is the thread groups of a dispatch over a size.
@(private)
groups :: proc(size: [2]u32, group: u32) -> [3]u32 {
	return {(size.x + group - 1) / group, (size.y + group - 1) / group, 1}
}

@(private = "file")
run_temporal_aa :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	pf := f.post
	g := ctx.graph
	platform := f.renderer.platform
	constants := Temporal_Constants {
		reproject     = pf.reproject,
		jitter        = f.jitter,
		inverse_size  = {1 / f32(f.size.x), 1 / f32(f.size.y)},
		size          = f.size,
		scene         = gpu.read_index(gpu_texture(g, pf.temporal_in)),
		velocity      = gpu.read_index(gpu_texture(g, f.velocity)),
		depth         = gpu.read_index(gpu_texture(g, f.depth)),
		history       = gpu.read_index(gpu_texture(g, pf.history.previous)),
		output        = gpu.write_index(gpu_texture(g, pf.history.current)),
		exposure      = gpu.read_index(gpu_buffer(g, f.exposure)),
		sampler_index = gpu.sampler_index(f.renderer.post.sampler),
		valid         = u32(pf.history.valid),
		blend         = TEMPORAL_BLEND,
	}
	upload, ok := platform.gpu_upload(size_of(Temporal_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Temporal_Constants)(raw_data(upload.data))^ = constants
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.post.temporal_aa.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
}

@(private = "file")
run_histogram :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	push := Histogram_Push {
		scene         = gpu.read_index(gpu_texture(g, f.scene)),
		depth         = gpu.read_index(gpu_texture(g, f.depth)),
		exposure      = gpu.read_index(gpu_buffer(g, f.exposure)),
		histogram     = gpu.write_index(gpu_buffer(g, f.post.histogram)),
		size          = f.size,
		min_log       = HISTOGRAM_MIN_LOG,
		inverse_range = 1.0 / (HISTOGRAM_MAX_LOG - HISTOGRAM_MIN_LOG),
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.post.histogram.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, HISTOGRAM_GROUP_SIZE))
}

@(private = "file")
run_exposure :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	pf := f.post
	g := ctx.graph
	s := pf.settings
	limits := s.exposure_range != {} ? s.exposure_range : DEFAULT_EXPOSURE_RANGE
	speed := s.adaptation_speed > 0 ? s.adaptation_speed : DEFAULT_ADAPTATION_SPEED
	push := Exposure_Push {
		histogram    = gpu.write_index(gpu_buffer(g, pf.histogram)),
		exposure     = gpu.write_index(gpu_buffer(g, f.exposure)),
		manual       = u32(!pf.exposure_auto),
		reset        = u32(pf.reset),
		min_log      = HISTOGRAM_MIN_LOG,
		range        = HISTOGRAM_MAX_LOG - HISTOGRAM_MIN_LOG,
		low_log      = limits[0],
		high_log     = limits[1],
		compensation = s.exposure_compensation,
		scale        = s.exposure > 0 ? s.exposure : 1,
		adapt        = 1 - math.exp(-pf.delta * speed),
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.post.adapt.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, {1, 1, 1})
}

@(private = "file")
run_bloom :: proc(ctx: ^Pass_Context) {
	step := (^Bloom_Step)(ctx.data)
	f := step.frame
	pf := f.post
	g := ctx.graph
	level := step.level
	push := Bloom_Push {
		sampler_index = gpu.sampler_index(f.renderer.post.sampler),
		size          = pf.bloom_sizes[level],
	}
	source: Texture
	source_size: [2]u32
	if step.up {
		below := level + 1
		source = below == pf.bloom_levels - 1 ? pf.bloom_down[below] : pf.bloom_up[below]
		source_size = pf.bloom_sizes[below]
		push.base = gpu.read_index(gpu_texture(g, pf.bloom_down[level]))
		push.output = gpu.write_index(gpu_texture(g, pf.bloom_up[level]))
		push.mode = BLOOM_UP
	} else {
		source = level == 0 ? pf.bloom_in : pf.bloom_down[level - 1]
		source_size = level == 0 ? f.size : pf.bloom_sizes[level - 1]
		push.output = gpu.write_index(gpu_texture(g, pf.bloom_down[level]))
		push.mode = level == 0 ? BLOOM_FIRST : BLOOM_DOWN
	}
	push.source = gpu.read_index(gpu_texture(g, source))
	push.source_texel = {1 / f32(source_size.x), 1 / f32(source_size.y)}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.post.bloom.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(push.size, POST_GROUP_SIZE))
}

@(private = "file")
run_tone_lut :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	grading := f.post.grading
	push := Lut_Push {
		output      = gpu.write_index(gpu_texture(ctx.graph, f.lut)),
		tone_mapper = u32(grading.tone_mapper),
		contrast    = grading.contrast,
		saturation  = grading.saturation,
		tint        = grading.tint,
		hdr         = u32(grading.hdr),
		paper_white = grading.paper_white,
		peak        = grading.peak,
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.post.tone_lut.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups({LUT_SIZE * LUT_SIZE, LUT_SIZE}, POST_GROUP_SIZE))
}

// reads_depth is whether a post pass reads the scene's depth after the world pass.
@(private)
reads_depth :: proc(f: ^Frame) -> bool {
	return f.post.temporal || f.post.exposure_auto
}
