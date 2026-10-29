// The sky's transmittance table (see sky_common.hlsli): the share of light that reaches each height along each mu
// from the top of the atmosphere, as the optical depth along the ray.
#include "sky_common.hlsli"

static const uint STEPS = 40;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= TRANSMITTANCE_SIZE)) {
		return;
	}
	float h, mu;
	transmittance_params(float2(id.xy) / float2(TRANSMITTANCE_SIZE - 1), h, mu);
	float dt = distance_to_top(h, mu) / STEPS;
	float3 depth = 0;
	for (uint i = 0; i < STEPS; i++) {
		depth += medium_at(height_along(h, mu, (i + 0.5) * dt)).extinction * dt;
	}
	cn_rw_texture(push.output)[id.xy] = float4(exp(-depth), 1);
}
