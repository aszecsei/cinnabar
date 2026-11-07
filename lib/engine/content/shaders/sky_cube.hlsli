// The sky's specular light (see docs/rendering/sky.md#specular-light): its cubemap, prefiltered by roughness, from mip 0,
// a mirror, to the last, roughness 1. A new cubemap blends in over the last one, so a changing sky does not pop.
// Without a cubemap yet, the specular light is the ambient light's.
#ifndef SKY_CUBE_HLSLI
#define SKY_CUBE_HLSLI

#include "ambient.hlsli"
#include "cinnabar.hlsli"

// The frame's cubemaps: the current one and the one that it blends in over, by blend, their mips, 0 without a
// cubemap, and their sampler.
struct Sky_Cube {
	uint current;
	uint previous;
	float blend;
	float mips;
	uint sampler_index;
};

// sky_specular is the sky's light along a direction, blurred by a roughness.
float3 sky_specular(Sky_Cube c, float4 ambient[4], float3 d, float roughness) {
	if (c.mips <= 0) {
		return ambient_light(ambient, d);
	}
	float lod = saturate(roughness) * (c.mips - 1);
	SamplerState s = cn_sampler(c.sampler_index);
	float3 light = cn_texture_cube(c.current).SampleLevel(s, d, lod).rgb;
	if (c.blend < 1) {
		light = lerp(cn_texture_cube(c.previous).SampleLevel(s, d, lod).rgb, light, c.blend);
	}
	return light;
}

#endif
