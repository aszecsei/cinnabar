// ReSTIR GI's spatial pass (see docs/rendering/global-illumination.md#restir-gi): a thread for each reservoir merges
// the reservoirs of a few neighbours within the grid's spatial_radius, on a disk that turns each frame, into its own.
// A neighbour counts while its surface is this one's, by its depth and its normal, and its sample is reconnected to
// this surface: its weight is multiplied by the Jacobian of the change in solid angle, as its W is a density in the
// neighbour's solid angle, and a neighbour whose Jacobian is past jacobian_max either way, or whose sample faces away
// from this surface, does not count. With visibility, a shadow ray to each neighbour's sample keeps the light
// from leaking through a thin wall between them. The neighbours count as at most spatial_max_m samples together, and
// the weights are the plain share of their samples, which is biased a little darker at the edges of surfaces. The
// result does not feed the next frame's temporal pass, so the reservoirs do not grow alike from frame to frame.
#include "gi_restir.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Restir_Grid g = restir_grid();
	if (any(id.xy >= g.reservoirs)) {
		return;
	}
	int2 texel = int2(id.xy);
	float3 p;
	float3 normal;
	float z;
	Restir_Reservoir center = restir_load(push.sample_in, push.light_in, push.normal_in, texel);
	if (!restir_surface(g, texel, p, normal, z)) {
		restir_store(push.sample_out, push.light_out, push.normal_out, texel, restir_empty());
		return;
	}
	uint state = restir_seed(g, texel, 2);
	Restir_Reservoir r = restir_empty();
	r.depth = z;
	restir_merge(r, center, restir_target(center, p, normal) * center.W * center.M, center.M, state);
	float share = g.spatial_max_m / max(float(g.spatial_samples), 1);
	for (uint i = 0; i < g.spatial_samples; i++) {
		float angle = 2 * RESTIR_PI * random_unit(state);
		float radius = g.spatial_radius * sqrt(random_unit(state));
		int2 q = texel + int2(round(float2(cos(angle), sin(angle)) * radius));
		if (all(q == texel)) {
			continue;
		}
		float3 pq;
		float3 nq;
		float zq;
		if (!restir_surface(g, q, pq, nq, zq)) {
			continue;
		}
		if (abs(zq - z) > g.depth_tolerance * z || dot(nq, normal) < g.normal_cos) {
			continue;
		}
		Restir_Reservoir s = restir_load(push.sample_in, push.light_in, push.normal_in, q);
		if (s.M <= 0) {
			continue;
		}
		if (!s.infinite && dot(s.normal, p - s.position) <= 0) {
			continue;
		}
		float jacobian = restir_jacobian(p, pq, s);
		if (!(jacobian <= g.jacobian_max && jacobian >= 1 / g.jacobian_max)) {
			continue;
		}
		float target = restir_target(s, p, normal);
		if (target > 0 && g.visibility != 0 && !restir_visible(g, p, normal, z, s)) {
			continue;
		}
		float M = min(s.M, share);
		restir_merge(r, s, target * s.W * M * jacobian, M, state);
	}
	restir_finish(r, p, normal);
	restir_store(push.sample_out, push.light_out, push.normal_out, texel, r);
}
