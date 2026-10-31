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
	lights.lights = push.lights;
	lights.lights_offset = push.lights_offset;
	lights.light_count = push.light_count;
	float4 result = hit_light(load_hit(push.hits, ray), push.surfaces, ray, lights, frame_probe_grid());
	cn_rw_buffer(push.rays).Store<float4>(ray * 16, result);
}
