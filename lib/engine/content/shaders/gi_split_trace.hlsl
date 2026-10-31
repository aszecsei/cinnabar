// The split radiance cascades' rays (see docs/rendering/global-illumination.md#split-cascades): a thread for each tile
// of the screen, which traces one ray from its pixel this frame through the ray scene, as far as the last cascade of
// its coarser level reaches. The ray starts at the pixel's surface, a little off it, not at a probe's center, so no
// probe inside a wall darkens what it sees. Its direction is uniform over the sphere: the R2 sequence by the frame,
// offset for each tile. A pixel without a surface stores a miss of no length, which the deposit skips.
#include "gi_split.hlsli"

// split_ray_direction is a tile's ray this frame.
float3 split_ray_direction(Split_Grid g, uint ray) {
	uint h = split_hash(ray * 0x9e3779b9u + 1);
	float2 offset = float2(h & 0xffff, h >> 16) / 65536.0;
	// R2's steps, 0.7548776662 and 0.5698402910, in 32-bit fixed point, so the frame's multiple wraps exactly.
	uint2 step = uint2(g.frame * 3242174889u, g.frame * 2447445413u);
	float2 u = frac(offset + float2(step >> 8) / 16777216.0);
	float z = 1 - 2 * u.x;
	float r = sqrt(saturate(1 - z * z));
	float phi = SPLIT_TAU * u.y;
	return float3(r * cos(phi), r * sin(phi), z);
}

[numthreads(SPLIT_GROUP, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Split_Grid g = split_grid();
	uint ray = id.x;
	if (ray >= g.ray_count) {
		return;
	}
	int2 pixel;
	float3 p;
	float z;
	Split_Lod lod;
	lod.level = g.level_count;
	if (split_pixel(g, ray, pixel, p, z)) {
		lod = split_lod(g, chebyshev(p));
	}
	if (lod.level >= g.level_count) {
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
		return;
	}
	uint coarse = min(lod.level + (lod.blend > 0 ? 1 : 0), g.level_count - 1);
	float3 normal = octahedral_normal(pixel);
	RayDesc desc;
	desc.Origin = p + normal * g.bias * pixel_meters(z) + g.camera_offset.xyz;
	desc.Direction = split_ray_direction(g, ray);
	desc.TMin = 0;
	desc.TMax = split_reach(g, g.levels[coarse].min.w);
	// A ray's cone widens as a probe's direction texel does.
	float spread = SPLIT_SQRT_SPHERE / g.directions;
	store_hit(push.hits, ray, trace_hit(cn_accel(push.accel), desc, RAY_MASK_SURFACES, spread));
}
