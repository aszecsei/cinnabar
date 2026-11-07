package render

import "cinnabar:core/gpu"

// Reflections: their quality's techniques and levels (see docs/rendering/quality.md#quality). Off has no reflections
// of the frame's own: the specular light is the global illumination's, or the sky's cubemap's. Probes looks up the
// reflection probes in the forward pass (see reflection_probes.odin), in front of the sky's cubemap, and over the
// global illumination's specular light on smooth surfaces. Screen adds the screen-space reflections (see
// screen_reflections.odin) in front of the probes, which keep the probes' parameters at its level. Ray_Traced traces
// the ray scene in their place (see traced_reflections.odin), through the screen-space reflections' resolve and temporal
// pass, in front of the probes too.

// Reflection_Params are a technique's parameters at a level. Each technique adds the fields that it reads.
//
// Probes: the probes' faces' size and format, the probes that hold a cube at once, the faces that a frame captures, the
// prefilter's samples per texel, and the roughnesses between which the probes fade out over the global illumination's
// specular light, which keeps its dynamic occlusion on rough surfaces.
//
// Screen: the block of pixels that one pixel's rays start from, in turn, 1x1 for every pixel, the rays from each, the
// march's steps, and the roughness above which a surface takes none, which its weight fades out to over the 0.1 below.
//
// Ray_Traced: the block, one ray from each, the steps of the march on the screen before a ray traces, none for 0, the
// cutoff, and the distance in meters past which a hit has no weight, and the probes fill in.
Reflection_Params :: struct {
	face:        u32,
	format:      gpu.Format,
	probes:      u32,
	faces:       u32,
	samples:     u32,
	rough_start: f32,
	rough_end:   f32,
	stride:      [2]u32,
	rays:        u32,
	steps:       u32,
	cutoff:      f32,
	distance:    f32,
}

// The probes hold prefiltered light, with no alpha, which RG11B10_Float's range fits at every level.
@(rodata)
REFLECTION_PARAMS := [Reflection_Technique][Quality_Level]Reflection_Params {
	.Off = {},
	.Probes = {
		.Low = {
			face = 64,
			format = .RG11B10_Float,
			probes = 16,
			faces = 1,
			samples = 32,
			rough_start = 0.2,
			rough_end = 0.45,
		},
		.Medium = {
			face = 128,
			format = .RG11B10_Float,
			probes = 32,
			faces = 2,
			samples = 64,
			rough_start = 0.2,
			rough_end = 0.45,
		},
		.High = {
			face = 128,
			format = .RG11B10_Float,
			probes = 64,
			faces = 3,
			samples = 64,
			rough_start = 0.2,
			rough_end = 0.45,
		},
		.Ultra = {
			face = 256,
			format = .RG11B10_Float,
			probes = 64,
			faces = 6,
			samples = 128,
			rough_start = 0.2,
			rough_end = 0.45,
		},
	},
	.Screen = {
		.Low = {stride = {2, 2}, rays = 1, steps = 16, cutoff = 0.3},
		.Medium = {stride = {2, 2}, rays = 1, steps = 32, cutoff = 0.4},
		.High = {stride = {1, 1}, rays = 1, steps = 48, cutoff = 0.5},
		.Ultra = {stride = {1, 1}, rays = 2, steps = 64, cutoff = 0.6},
	},
	.Ray_Traced = {
		.Low = {stride = {2, 2}, rays = 1, steps = 16, cutoff = 0.3, distance = 50},
		.Medium = {stride = {2, 2}, rays = 1, steps = 16, cutoff = 0.4, distance = 100},
		.High = {stride = {2, 1}, rays = 1, steps = 16, cutoff = 0.5, distance = 200},
		.Ultra = {stride = {1, 1}, rays = 1, steps = 16, cutoff = 0.6, distance = 500},
	},
}

// reflection_stride is a level's block, doubled along x, then y, until the rays of a frame of a size fit one hit
// shading batch, MAX_HIT_RAYS.
reflection_stride :: proc(size: [2]u32, stride: [2]u32) -> [2]u32 {
	s := [2]u32{max(stride.x, 1), max(stride.y, 1)}
	for {
		trace := (size + s - 1) / s
		if u64(trace.x) * u64(trace.y) <= MAX_HIT_RAYS {
			return s
		}
		if s.x <= s.y {
			s.x *= 2
		} else {
			s.y *= 2
		}
	}
}

// Reflection_Settings are a frame's reflections, in Frame_Settings. No volume sets them yet: apply_quality gives them
// the quality's technique and level, and turns them off for Off.
Reflection_Settings :: struct {
	off:       bool,
	// The technique, and its REFLECTION_PARAMS.
	technique: Reflection_Technique,
	level:     Quality_Level,
}
