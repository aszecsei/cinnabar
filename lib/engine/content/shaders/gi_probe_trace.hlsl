// The world probes' rays (see docs/rendering/global-illumination.md#world-probes): a thread for each ray of each probe
// that the frame updates. Each traces the ray scene's surfaces from its probe, and stores its hit for hit shading.
#include "gi_probe_pass.hlsli"

static const float PI_4 = 12.5663706;

[numthreads(HIT_GROUP_SIZE, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint ray = id.x;
	if (ray >= push.ray_count) {
		return;
	}
	Probe_Grid grid = frame_probe_grid();
	Probe probe = job_probe(grid, ray / grid.rays);
	RayDesc desc;
	desc.Origin = probe.position + frame.camera_offset.xyz;
	desc.Direction = probe_ray_direction(grid, ray % grid.rays);
	desc.TMin = 0;
	desc.TMax = probe.distance;
	// Each ray stands for its share of the sphere, which its cone covers.
	store_hit(push.hits, ray, trace_hit(cn_accel(push.accel), desc, RAY_MASK_SURFACES, sqrt(PI_4 / grid.rays)));
}
