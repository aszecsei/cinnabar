// ReSTIR GI's rays (see docs/rendering/global-illumination.md#restir-gi): a thread for each tile of the screen, which
// traces one ray from its pixel this frame through the ray scene, at most the grid's reach. The ray starts at the
// pixel's surface, a little off it. Its direction is new each frame: where the pixel's cell has a ray guide, a share of
// the guide's mix of the rays take it from the guide, and the rest are cosine-weighted around the surface's normal
// (see docs/rendering/global-illumination.md#ray-guiding). The pdf of that mixture at the ray's direction is stored
// beside it, for the temporal pass's weight. It passes through glass, and stores the glass's transmittance beside its
// hit (see gi_translucency.hlsli). A pixel without a surface stores a miss of no length, which the temporal pass skips.
#include "gi_restir_guide.hlsli"

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
		cn_rw_buffer(push.pdfs).Store(ray * 4, asuint(0.0));
		return;
	}
	uint state = restir_seed(g, texel, 0);
	Restir_Guide gd = restir_guide();
	uint cell = 0;
	bool guided = false;
	if (gd.level_count > 0 && constants.probes != 0) {
		guided = guide_cell(gd, load_probe_grid(constants.probe_grid, constants.probe_grid_offset), p, cell);
	}
	bool from_guide = false;
	if (guided) {
		from_guide = random_unit(state) < gd.mix;
	}
	float3 direction;
	if (from_guide) {
		direction = guide_sample(gd.guide, cell, normal, state);
	} else {
		float2 u = float2(random_unit(state), random_unit(state));
		direction = restir_cosine_direction(normal, u);
	}
	cn_rw_buffer(push.pdfs).Store(ray * 4, asuint(guide_mixture_pdf(gd.guide, cell, guided, gd.mix, normal, direction)));
	RayDesc desc;
	desc.Origin = p + normal * g.bias * pixel_meters(z) + g.camera_offset.xyz;
	desc.Direction = direction;
	desc.TMin = 0;
	desc.TMax = g.reach;
	// A diffuse ray's hit needs little of its texture's detail, so its cone is wide: the materials sample coarse mips.
	float spread = RESTIR_SPREAD;
	float3 transmittance;
	store_hit(push.hits, ray, trace_hit_through(cn_accel(push.accel), desc, RAY_MASK_SURFACES, spread, push.translucency, transmittance));
	store_transmittance(push.transmit, ray, transmittance);
}
