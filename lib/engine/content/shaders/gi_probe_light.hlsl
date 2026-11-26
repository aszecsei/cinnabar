// The world probes' hit lighting (see docs/rendering/global-illumination.md#world-probes): a thread for each ray, which
// takes its hit's light (see gi_hit_light.hlsli). gi_probe_screen.hlsl then gives the hits that the screen shows their
// light there.
#include "gi_probe_pass.hlsli"
#include "gi_hit_light.hlsli"

[numthreads(HIT_GROUP_SIZE, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint ray = id.x;
	if (ray >= push.ray_count) {
		return;
	}
	Hit_Lights lights;
	lights.accel = push.accel;
	lights.hit_instances = push.hit_instances;
	lights.hit_instances_offset = push.hit_instances_offset;
	lights.hit_submeshes = push.hit_submeshes;
	lights.hit_submeshes_offset = push.hit_submeshes_offset;
	lights.light_grid = push.light_grid;
	lights.light_grid_offset = push.light_grid_offset;
	lights.candidates = push.candidates;
	lights.seed = push.seed;
	float4 result = hit_light(load_hit(push.hits, ray), push.surfaces, ray, lights, frame_probe_grid());
	cn_rw_buffer(push.rays).Store<float4>(ray * 16, result);
}
