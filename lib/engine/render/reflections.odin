package render

import "cinnabar:core/gpu"

// Reflections: their quality's techniques and levels (see docs/rendering/quality.md#quality). Off has no reflections
// of the frame's own: the specular light is the global illumination's, or the sky's cubemap's. Probes looks up the
// reflection probes in the forward pass (see reflection_probes.odin), in front of the sky's cubemap, and over the
// global illumination's specular light on smooth surfaces. Screen adds the screen-space reflections (see
// screen_reflections.odin) in front of the probes, which keep the probes' parameters at its level.

// Reflection_Params are a technique's parameters at a level. Each technique adds the fields that it reads.
//
// Probes: the probes' faces' size and format, the probes that hold a cube at once, the faces that a frame captures, the
// prefilter's samples per texel, and the roughnesses between which the probes fade out over the global illumination's
// specular light, which keeps its dynamic occlusion on rough surfaces.
//
// Screen: whether the rays start from one pixel of each 2x2 block, the rays from each, the march's steps, and the
// roughness above which a surface takes none, which its weight fades out to over the 0.1 below.
Reflection_Params :: struct {
	face:        u32,
	format:      gpu.Format,
	probes:      u32,
	faces:       u32,
	samples:     u32,
	rough_start: f32,
	rough_end:   f32,
	half:        bool,
	rays:        u32,
	steps:       u32,
	cutoff:      f32,
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
		.Low = {half = true, rays = 1, steps = 16, cutoff = 0.3},
		.Medium = {half = true, rays = 1, steps = 32, cutoff = 0.4},
		.High = {half = false, rays = 1, steps = 48, cutoff = 0.5},
		.Ultra = {half = false, rays = 2, steps = 64, cutoff = 0.6},
	},
}

// Reflection_Settings are a frame's reflections, in Frame_Settings. No volume sets them yet: apply_quality gives them
// the quality's technique and level, and turns them off for Off.
Reflection_Settings :: struct {
	off:       bool,
	// The technique, and its REFLECTION_PARAMS.
	technique: Reflection_Technique,
	level:     Quality_Level,
}
