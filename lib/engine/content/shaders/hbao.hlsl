// Ambient occlusion (see docs/rendering/ambient-occlusion.md#techniques): horizon-based ambient occlusion (HBAO, after Bavoil, Sainz
// and Dimitrov 2008) from gtao_depth.hlsl's depth levels and the prepass's normals. Each pixel marches a few directions
// on the screen. Along each, it keeps the highest elevation above the surface's tangent plane that it has seen, and
// each step that rises above it occludes by how much it rises, faded by its distance. The engine's own search, not
// NVIDIA's HBAO+ library: it runs on every vendor, and shares GTAO's levels, noise, edges and denoiser.
#include "ao_common.hlsli"

// The tangent plane is raised by this much, as a sine, so a flat surface's own depth steps do not occlude it.
static const float TANGENT_BIAS = 0.1;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Ao_Pixel p;
	if (!ao_begin(id, p)) {
		return;
	}
	uint directions = constants.samples;
	uint steps = constants.steps;
	// The steps are evenly spaced from MIN_PIXELS to the search's reach, each moved by the noise within its gap.
	float stride = (p.pixels - MIN_PIXELS) / steps;
	float occlusion = 0;
	[loop] for (uint d = 0; d < directions; d++) {
		float angle = (d + p.noise.x) / directions * 2 * PI;
		float2 direction = float2(cos(angle), sin(angle));
		float horizon = TANGENT_BIAS;
		[loop] for (uint step = 0; step < steps; step++) {
			float distance_pixels = MIN_PIXELS + (step + p.noise.y) * stride;
			int2 offset = int2(round(direction * distance_pixels));
			float3 sample_position;
			if (!ao_sample(p, p.pixel + offset, level_at(length(float2(offset))), sample_position)) {
				continue;
			}
			float3 delta = sample_position - p.position;
			float distance = length(delta);
			float elevation = dot(p.normal, delta / max(distance, 1e-5));
			if (elevation > horizon) {
				occlusion += (elevation - horizon) * ao_falloff(p, distance);
				horizon = elevation;
			}
		}
	}
	// A direction occludes at most 1 - TANGENT_BIAS, from the raised tangent plane to straight up.
	ao_end(p, 1 - occlusion / (directions * (1 - TANGENT_BIAS)));
}
