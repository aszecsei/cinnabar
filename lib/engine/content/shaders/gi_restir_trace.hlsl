// ReSTIR GI's rays (see docs/rendering/global-illumination.md#restir-gi): a thread for each tile of the screen, which
// traces one ray from its pixel this frame through the ray scene, at most the grid's reach. The ray starts at the
// pixel's surface, a little off it, and its direction is cosine-weighted around the surface's normal, new each frame.
// It passes through glass, and stores the glass's transmittance beside its hit (see gi_translucency.hlsli). A pixel
// without a surface stores a miss of no length, which the temporal pass skips.
#include "gi_restir.hlsli"

// The rays' cone, in radians.
static const float RESTIR_SPREAD = 0.25;

[numthreads(RESTIR_GROUP, 1, 1)]
void cs_main(uint3 group : SV_GroupID, uint thread : SV_GroupIndex) {
	Restir_Grid g = restir_grid();
	uint ray = (group.y * 65535 + group.x) * RESTIR_GROUP + thread;
	if (ray >= g.ray_count) {
		return;
	}
	int2 texel = int2(ray % g.reservoirs.x, ray / g.reservoirs.x);
	float3 p;
	float3 normal;
	float z;
	if (!restir_surface(g, texel, p, normal, z)) {
		Hit_Record miss;
		miss.instance = HIT_MISS;
		miss.primitive = 0;
		miss.barycentrics = 0;
		miss.direction = hit_pack_unit(float3(0, 0, 1));
		miss.t = 0;
		miss.cone_width = 0;
		miss.bin = 0;
		miss.entry = 0;
		store_hit(push.hits, ray, miss);
		store_transmittance(push.transmit, ray, 1);
		return;
	}
	uint state = restir_seed(g, texel, 0);
	float2 u = float2(random_unit(state), random_unit(state));
	RayDesc desc;
	desc.Origin = p + normal * g.bias * pixel_meters(z) + g.camera_offset.xyz;
	desc.Direction = restir_cosine_direction(normal, u);
	desc.TMin = 0;
	desc.TMax = g.reach;
	// A diffuse ray's hit needs little of its texture's detail, so its cone is wide: the materials sample coarse mips.
	float spread = RESTIR_SPREAD;
	float3 transmittance;
	store_hit(push.hits, ray, trace_hit_through(cn_accel(push.accel), desc, RAY_MASK_SURFACES, spread, push.translucency, transmittance));
	store_transmittance(push.transmit, ray, transmittance);
}
