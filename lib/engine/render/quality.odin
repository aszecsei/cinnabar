package render

import "cinnabar:core"
import "cinnabar:core/gpu"

// Quality (see docs/rendering/quality.md#quality) is what the frame may cost: each feature's technique and its level,
// which a game's settings menu chooses and the hardware limits. The volumes' settings are the look, and stay the same
// at every level: a room's ambient occlusion radius is the art's, how many slices find it is the quality's. In
// draw_frame the volumes resolve first, then apply_quality, then the editor's apply_debug, and each can only turn a
// feature off.

// Quality_Level is a feature's level. Each feature's parameters for it are in a table beside the feature, such as
// SHADOW_PARAMS.
Quality_Level :: enum u8 {
	Low,
	Medium,
	High,
	Ultra,
}

// Quality_Preset is every feature at one level, or Custom when they differ from every preset.
Quality_Preset :: enum u8 {
	Low,
	Medium,
	High,
	Ultra,
	Custom,
}

// The ambient occlusion's techniques (see docs/rendering/ambient-occlusion.md#techniques), in the order that they were added, so a
// code reload keeps a quality's choice: GTAO after XeGTAO, the most faithful; SSAO, the cheapest; and HBAO between.
Ao_Technique :: enum u8 {
	Off,
	Gtao,
	Ssao,
	Hbao,
}

Gi_Technique :: enum u8 {
	Off,
	// Screen-space radiance cascades (see docs/rendering/global-illumination.md#global-illumination).
	Screen_Cascades,
}

// The anti-aliasing's techniques (see docs/rendering/anti-aliasing.md#anti-aliasing), in the order that they were
// added: temporal AA, the sharpest on still images and the softest in motion, then FXAA and SMAA 1x, which see one
// frame and do not blur in motion.
Aa_Technique :: enum u8 {
	Off,
	Taa,
	Fxaa,
	Smaa,
}

Shadow_Quality :: struct {
	level:      Quality_Level,
	// Traced shadows for the first MAX_MASK_LIGHTS lights, which needs Ray_Query. The shadow maps still take the rest,
	// at level.
	ray_traced: bool,
}

Ao_Quality :: struct {
	technique: Ao_Technique,
	level:     Quality_Level,
}

Gi_Quality :: struct {
	technique: Gi_Technique,
	level:     Quality_Level,
}

// Quality is plain data, so it lives in Game_State and a code reload keeps it. Its zero value is the cheapest frame
// at full resolution, with every feature that can be off off; preset_quality and default_quality give the others.
Quality :: struct {
	shadows:      Shadow_Quality,
	ao:           Ao_Quality,
	gi:           Gi_Quality,
	fog:          Quality_Level,
	aa:           Aa_Technique,
	// The share of the frame's width and height that the scene renders at, from MIN_RENDER_SCALE to 1, 0 giving 1.
	// Temporal AA upscales the scene to the frame's size (see docs/rendering/anti-aliasing.md#upscaling); with the
	// other techniques, the output pass stretches it.
	render_scale: f32,
}

// Caps are what the device can do that quality depends on, from Platform_API.gpu_features and gpu_adapter.
Caps :: struct {
	ray_query:    bool,
	vendor:       gpu.Vendor,
	// The adapter's own memory in bytes, 0 when unknown.
	video_memory: u64,
}

// The smallest render scale: below half, temporal AA has too few samples a pixel to upscale from.
MIN_RENDER_SCALE :: 0.5

// The video memory below which default_quality picks each preset. Unknown memory picks High.
QUALITY_LOW_MEMORY :: 4 << 30
QUALITY_MEDIUM_MEMORY :: 6 << 30
QUALITY_HIGH_MEMORY :: 10 << 30

// device_caps are the caps of the platform's device. A platform without a GPU, as in the tests, has none.
device_caps :: proc(platform: ^core.Platform_API) -> (caps: Caps) {
	if platform.gpu_features != nil {
		caps.ray_query = .Ray_Query in platform.gpu_features()
	}
	if platform.gpu_adapter != nil {
		adapter := platform.gpu_adapter()
		caps.vendor, caps.video_memory = adapter.vendor, adapter.video_memory
	}
	return
}

// preset_quality is every feature at a preset's level, with traced shadows from High up where the device has them.
// Custom gives High's.
preset_quality :: proc(preset: Quality_Preset, caps: Caps) -> Quality {
	level := preset == .Custom ? Quality_Level.High : Quality_Level(u8(preset))
	return {
		shadows = {level = level, ray_traced = caps.ray_query && level >= .High},
		ao = {technique = .Gtao, level = level},
		gi = {technique = .Screen_Cascades, level = level},
		fog = level,
		aa = .Taa,
		render_scale = 1,
	}
}

// quality_preset is the preset that a quality is, or Custom.
quality_preset :: proc(q: Quality, caps: Caps) -> Quality_Preset {
	for preset in Quality_Preset.Low ..= Quality_Preset.Ultra {
		if q == preset_quality(preset, caps) {
			return preset
		}
	}
	return .Custom
}

// default_quality is the preset for a device: by its video memory, the less memory the lower.
default_quality :: proc(caps: Caps) -> Quality {
	preset := Quality_Preset.High
	switch {
	case caps.video_memory == 0:
	case caps.video_memory < QUALITY_LOW_MEMORY:
		preset = .Low
	case caps.video_memory < QUALITY_MEDIUM_MEMORY:
		preset = .Medium
	case caps.video_memory >= QUALITY_HIGH_MEMORY:
		preset = .Ultra
	}
	return preset_quality(preset, caps)
}

// clamp_quality turns off what the device cannot do, and puts each enum back in its range, since a settings file or a
// script may give any number.
clamp_quality :: proc(q: Quality, caps: Caps) -> Quality {
	q := q
	clamp_enum :: proc(value: $T, fallback: T) -> T {
		return value >= min(T) && value <= max(T) ? value : fallback
	}
	q.shadows.level = clamp_enum(q.shadows.level, .High)
	q.shadows.ray_traced &&= caps.ray_query
	q.ao.technique = clamp_enum(q.ao.technique, .Off)
	q.ao.level = clamp_enum(q.ao.level, .High)
	q.gi.technique = clamp_enum(q.gi.technique, .Off)
	q.gi.level = clamp_enum(q.gi.level, .High)
	q.fog = clamp_enum(q.fog, .High)
	q.aa = clamp_enum(q.aa, .Off)
	// Not a number, or 0, is full resolution.
	q.render_scale = q.render_scale > 0 ? clamp(q.render_scale, MIN_RENDER_SCALE, 1) : 1
	return q
}

// render_size is the scene's size for a frame's size at a render scale, at least a pixel on each side.
render_size :: proc(size: [2]u32, scale: f32) -> [2]u32 {
	if scale >= 1 {
		return size
	}
	return {max(u32(f32(size.x) * scale + 0.5), 1), max(u32(f32(size.y) * scale + 0.5), 1)}
}

// set_quality makes a quality the renderer's from the next frame on, as far as the device can do it.
set_quality :: proc(r: ^Renderer, q: Quality) {
	r.quality = clamp_quality(q, r.caps)
}

// apply_quality gives a frame's settings the quality's techniques and levels. It only turns features off: a volume that
// turned one off keeps it off.
apply_quality :: proc(settings: ^Frame_Settings, q: Quality) {
	settings.shadows.level = q.shadows.level
	settings.shadows.ray_traced = q.shadows.ray_traced
	settings.ambient_occlusion.technique = q.ao.technique
	settings.ambient_occlusion.level = q.ao.level
	settings.ambient_occlusion.off ||= q.ao.technique == .Off
	settings.gi.level = q.gi.level
	settings.gi.off ||= q.gi.technique == .Off
	settings.fog.level = q.fog
	settings.post.aa = q.aa
	settings.post.no_aa ||= q.aa == .Off
}
