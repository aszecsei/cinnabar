// What the traced reflections' shaders share (see docs/rendering/lighting-and-shadows.md#ray-traced-reflections): the
// trace's push constants and how it tells the light pass what became of each ray.
#ifndef RTR_COMMON_HLSLI
#define RTR_COMMON_HLSLI

#include "gi_translucency.hlsli"

// Matches Rtr_Trace_Push in lib/engine/render/traced_reflections.odin. hits holds a Hit_Record for each trace texel,
// row by row, and transmit each ray's transmittance, the glass that it crossed. camera_offset is the camera's position
// relative to the render origin, which the ray scene is placed by. translucency is what the rays pass glass by.
struct Rtr_Trace_Push {
	float4 camera_offset;
	uint accel;
	uint hits;
	uint ray_count;
	uint transmit;
	Translucency translucency;
};

// How far a ray traces, in meters: past the level's reach, so a ray that finds nothing at all sees the sky, and one that
// hits something past the reach has no weight. A ray that sees the sky keeps this as its distance, so the temporal pass
// reprojects a point far away.
static const float RTR_FAR = 10000;
// A trace texel's radiance has this weight while its ray waits for the light pass.
static const float RTR_PENDING = -1;
// A waiting ray's distance is this when it hit past the reach, and was not shaded.
static const float RTR_PAST_REACH = -1;

#endif
