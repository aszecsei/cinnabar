// The ambient light (see docs/rendering/sky.md#ambient-light): a linear function of the direction, per channel, which
// the frame's and the global illumination's constants hold as four float4s.
#ifndef AMBIENT_HLSLI
#define AMBIENT_HLSLI

// Matches ambient_at in lib/engine/render/lights.odin: constant + x * d.x + y * d.y + z * d.z.
float3 ambient_light(float4 ambient[4], float3 d) {
	return max(ambient[0].rgb + ambient[1].rgb * d.x + ambient[2].rgb * d.y + ambient[3].rgb * d.z, 0);
}

// The ambient light averaged over every direction, which the sprites and the clouds take whatever their phase.
float3 ambient_average(float4 ambient[4]) {
	return ambient[0].rgb;
}

// Matches ambient_scattered in lib/engine/render/lights.odin: the ambient light that a medium with Henyey-Greenstein's
// g scatters along toward, per unit of scattering. The ambient's gradient is its light's first harmonics convolved with
// the cosine, which scales them by 2/3, so the light is constant + 1.5 * gradient . d from a direction d. The phase
// scales the first harmonics by g, and the light that leaves along toward came from -toward's side.
float3 ambient_scattered(float4 ambient[4], float g, float3 toward) {
	float3 gradient = ambient[1].rgb * toward.x + ambient[2].rgb * toward.y + ambient[3].rgb * toward.z;
	return max(ambient[0].rgb - 1.5 * g * gradient, 0);
}

#endif
