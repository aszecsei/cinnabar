// Ambient occlusion (see docs/rendering/ambient-occlusion.md#techniques): screen-space ambient occlusion (SSAO) with a hemisphere
// around the normal, after Crytek's (Mittring 2007) as normal-oriented versions build it, from gtao_depth.hlsl's depth
// levels and the prepass's normals. Each pixel places a few points in the hemisphere over its surface, cosine-weighted,
// and a point that the depth buffer has a surface in front of is occluded, faded by that surface's distance from the
// pixel. The cheapest of the three, and the coarsest: it counts occluded points, not how far the horizon rises.
#include "ao_common.hlsli"

// A point is occluded by a surface at least this share of its depth in front of it, so a surface does not occlude
// itself by its depth's precision.
static const float DEPTH_BIAS = 0.003;
// The golden angle, which spreads the points around the normal.
static const float GOLDEN_ANGLE = 2.3999632;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Ao_Pixel p;
	if (!ao_begin(id, p)) {
		return;
	}
	// A basis around the normal.
	float3 helper = abs(p.normal.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0);
	float3 tangent = normalize(cross(helper, p.normal));
	float3 bitangent = cross(p.normal, tangent);

	uint samples = constants.samples;
	float occlusion = 0;
	[loop] for (uint i = 0; i < samples; i++) {
		// A cosine-weighted point of a Fibonacci spiral over the hemisphere, turned by the noise, so the points count
		// as the ambient light weighs them.
		float u = (i + 0.5) / samples;
		float sin_theta = sqrt(u);
		float cos_theta = sqrt(1 - u);
		float phi = i * GOLDEN_ANGLE + p.noise.x * 2 * PI;
		float3 direction = (cos(phi) * tangent + sin(phi) * bitangent) * sin_theta + p.normal * cos_theta;
		// More points near the pixel, where the occluders that matter most are.
		float s = (i + p.noise.y) / samples;
		float3 target = p.position + direction * p.radius * lerp(0.1, 1, s * s);
		if (target.z <= 0) {
			continue;
		}
		float2 target_pixels = screen_pixels(target, p.view_model);
		float pixels = length(target_pixels - (float2(p.pixel) + 0.5));
		float3 surface;
		if (!ao_sample(p, int2(target_pixels), level_at(max(pixels, 1)), surface)) {
			continue;
		}
		if (surface.z < target.z * (1 - DEPTH_BIAS)) {
			occlusion += ao_falloff(p, length(surface - p.position));
		}
	}
	ao_end(p, 1 - occlusion / samples);
}
