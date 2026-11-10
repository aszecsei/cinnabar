// The aerial perspective volume's layout (see docs/rendering/sky.md#aerial-perspective), which sky_aerial.hlsl writes
// and fog_at.hlsli and clouds_composite.hlsl read. The volume is the camera's screen across and down, and the distance
// along each pixel's ray in depth, squared as Hillaire's is, so most of its slices are in the first kilometers, where
// the world is: texel k holds the air up to AERIAL_DISTANCE * ((k + 0.5) / AERIAL_SLICES)^2. rgb is the light that the
// air scatters toward the camera, not pre-exposed, and a the mean share of light that it lets through.
#ifndef AERIAL_HLSLI
#define AERIAL_HLSLI

// Match SKY_AERIAL_SIZE and SKY_AERIAL_DISTANCE in lib/engine/render/sky.odin. The distance is in meters.
static const float AERIAL_SLICES = 32;
static const float AERIAL_DISTANCE = 32000;

// aerial_slice_distance is the distance, in meters, up to which a slice's texels hold the air.
float aerial_slice_distance(float slice) {
	float w = (slice + 0.5) / AERIAL_SLICES;
	return AERIAL_DISTANCE * w * w;
}

// aerial_sample is the air between the camera and a point at a distance in meters along the ray through a place on
// the screen, uv, from 0 to 1. A point nearer than the first slice takes its share of that slice's air, so the air
// fades in from none at the camera, as Hillaire's does. Past AERIAL_DISTANCE, the clamping sampler gives the last
// slice.
float4 aerial_sample(Texture3D<float4> volume, SamplerState clamping, float2 uv, float distance) {
	float first = 0.5 / AERIAL_SLICES;
	float w = sqrt(max(distance, 0) / AERIAL_DISTANCE);
	float weight = saturate((w * w) / (first * first));
	float4 air = volume.SampleLevel(clamping, float3(uv, max(w, first)), 0);
	return float4(air.rgb * weight, lerp(1, air.a, weight));
}

#endif
