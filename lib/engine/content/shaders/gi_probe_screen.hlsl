// The world probes' screen light (see docs/rendering/global-illumination.md#world-probes): a thread for each ray, after
// the hits' light. A hit of a front face that the screen shows takes its light from last frame's lit scene instead (see
// gi_hit_screen.hlsli), so the probes see what the screen sees.
#include "gi_probe_pass.hlsli"
#include "gi_hit_screen.hlsli"

[numthreads(HIT_GROUP_SIZE, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint ray = id.x;
	if (ray >= push.ray_count || push.lit_valid == 0) {
		return;
	}
	Hit_Record hit = load_hit(push.hits, ray);
	if (hit_missed(hit)) {
		return;
	}
	Hit_Surface s = load_hit_surface(push.surfaces, ray);
	float3 seen;
	if ((hit_flags(s) & HIT_SURFACE_BACK) == 0 && screen_light(s.position - frame.camera_offset.xyz, push.depth, push.lit, frame_probe_grid().sampler_index, seen)) {
		cn_rw_buffer(push.rays).Store<float4>(ray * 16, float4(seen, hit.t));
	}
}
