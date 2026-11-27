// The world probes' rays (see docs/rendering/global-illumination.md#world-probes): a thread for each ray of each probe
// that the frame updates. Each traces the ray scene's surfaces from its probe, through glass, and stores its hit for hit
// shading and the glass's transmittance (see gi_translucency.hlsli). Where the probe's cell of the ray guide is valid,
// some of its rays come from the guide (probe_rays).
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
	desc.Direction = probe_ray(grid, probe, probe_rays(grid, probe), ray % grid.rays);
	desc.TMin = 0;
	desc.TMax = probe.distance;
	// Each ray stands for its share of the sphere, which its cone covers.
	float3 transmittance;
	store_hit(push.hits, ray, trace_hit_through(cn_accel(push.accel), desc, RAY_MASK_SURFACES, sqrt(PI_4 / grid.rays), push.translucency, transmittance));
	store_transmittance(push.transmit, ray, transmittance);
}
