// The ambient light (see docs/rendering/sky.md#ambient-light): a linear function of the direction, per channel, which
// the frame's and the global illumination's constants hold as four float4s.
#ifndef AMBIENT_HLSLI
#define AMBIENT_HLSLI

// Matches ambient_at in lib/engine/render/lights.odin: constant + x * d.x + y * d.y + z * d.z.
float3 ambient_light(float4 ambient[4], float3 d) {
	return max(ambient[0].rgb + ambient[1].rgb * d.x + ambient[2].rgb * d.y + ambient[3].rgb * d.z, 0);
}

// The ambient light averaged over every direction, which scatters into fog and sprites whatever their phase.
float3 ambient_average(float4 ambient[4]) {
	return ambient[0].rgb;
}

#endif
