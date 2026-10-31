// The split radiance cascades' deposit (see docs/rendering/global-illumination.md#split-cascades): a thread for each
// traced pixel splits its ray by its hit's distance, at each of the pixel's levels. The cascade whose interval holds
// the hit counts the ray and adds the hit's light, in its bin of the ray's direction at the probe of the pixel's cell;
// each cascade before it counts the ray as passing through, and a ray past the last cascade passes through them all.
// The light is pre-exposed and in fixed point, so the bins add it with integer atomics, with a dither that keeps dim
// light's mean. A back face this near the pixel means that the ray started inside geometry, and the ray counts for
// nothing.
#include "gi_split.hlsli"

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
	if (!split_pixel(g, ray, pixel, p, z)) {
		return;
	}
	Split_Lod lod = split_lod(g, chebyshev(p));
	if (lod.level >= g.level_count) {
		return;
	}
	Hit_Record hit = load_hit(push.hits, ray);
	float4 light = cn_buffer(push.rays).Load<float4>(ray * 16);
	bool missed = hit_missed(hit);
	bool back = !missed && light.a < 0;
	float t = missed ? 1e30 : abs(light.a);
	if (back && t < 4 * g.bias * pixel_meters(z)) {
		return;
	}
	float3 d = hit_unpack_unit(hit.direction);
	float exposure = cn_buffer(push.exposure).Load<float>(0);
	float3 radiance = back ? 0 : min(light.rgb * exposure, g.radiance_max) * g.radiance_scale;
	uint h = split_hash(ray ^ (g.frame * 0x9e3779b9u));
	float3 dither = float3(h & 0x3ff, (h >> 10) & 0x3ff, (h >> 20) & 0x3ff) / 1024.0;
	uint3 units = uint3(radiance + dither);

	RWByteAddressBuffer accum = cn_rw_buffer(push.accum);
	RWByteAddressBuffer slots = cn_rw_buffer(push.slots);
	RWByteAddressBuffer deposits = cn_rw_buffer(push.deposits);
	for (uint n = 0; n < 2; n++) {
		uint l = lod.level + n;
		if (l >= g.level_count || (n == 1 && lod.blend <= 0)) {
			break;
		}
		Split_Level level = g.levels[l];
		int3 u = split_cell(level, p);
		uint hit_cascade = split_hit_cascade(t, g.interval * level.min.w);
		for (uint k = 0; k < g.cascade_count && k <= hit_cascade; k++) {
			int3 uk = u >> k;
			if (!split_inside(uk, k)) {
				continue;
			}
			Split_Cascade c = g.cascades[k];
			uint slot = split_find(c, split_key(l, uint3(uk)));
			if (slot == SPLIT_NO_SLOT) {
				continue;
			}
			uint address = split_bin(c, slot, split_direction_bin(d, c.side)) * SPLIT_ACCUM_SIZE;
			accum.InterlockedAdd(address, 1);
			if (k == hit_cascade) {
				accum.InterlockedAdd(address + 4, 1);
				accum.InterlockedAdd(address + 8, units.r);
				accum.InterlockedAdd(address + 12, units.g);
				accum.InterlockedAdd(address + 16, units.b);
			}
			slots.Store(slot * SPLIT_SLOT_SIZE + 4, g.frame);
			deposits.InterlockedAdd(slot * 4, 1);
		}
	}
}
