// The radiance cascades' merge (see docs/rendering/global-illumination.md#global-illumination): one pass for each cascade, from the last
// to the first. Each texel adds what gets through its interval from beyond: the next cascade's light in its direction,
// the four finer directions that it splits into, at the four probes of the next cascade around it, weighted by how
// near they are and whether they are on the same surface (see probe_weight). The last cascade takes the light from
// beyond its probe's surface: the world probes', or the ambient sky's. The merge writes the cascades in place.
#include "gi_common.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint k = constants.cascade;
	uint directions = cascade_directions(k);
	uint2 probe = id.xy / directions;
	uint2 direction_texel = id.xy % directions;
	if (any(probe >= cascade_probes(k))) {
		return;
	}
	RWTexture2D<float4> cascades = cn_rw_texture(constants.cascades);
	uint2 texel = cascade_texel(k, probe, direction_texel);
	float4 here = cascades[texel];
	if (here.a <= 0) {
		return;
	}
	float3 beyond = 0;
	float3 position;
	float z;
	int2 pixel = probe_pixel(k, probe);
	surface_at(pixel, position, z);
	float3 normal = octahedral_normal(pixel);
	float3 direction = direction_of(direction_texel, directions, 0.5);
	if (k + 1 >= constants.cascade_count) {
		beyond = beyond_light(position, normal, direction);
	} else {
		uint next = k + 1;
		uint next_spacing = cascade_spacing(next);
		uint2 next_probes = cascade_probes(next);
		float2 grid = (float2(pixel) + 0.5) / next_spacing - 0.5;
		int2 base = int2(floor(grid));
		float2 f = grid - base;
		float total = 0;
		[unroll] for (uint n = 0; n < 4; n++) {
			int2 offset = int2(n & 1, n >> 1);
			int2 neighbor = clamp(base + offset, 0, int2(next_probes) - 1);
			float2 w2 = lerp(1 - f, f, float2(offset));
			float weight = w2.x * w2.y * probe_weight(position, normal, z, probe_pixel(next, uint2(neighbor)));
			if (weight <= 0) {
				continue;
			}
			float3 light = 0;
			[unroll] for (uint c = 0; c < 4; c++) {
				uint2 child = direction_texel * 2 + uint2(c & 1, c >> 1);
				light += cascades[cascade_texel(next, uint2(neighbor), child)].rgb;
			}
			beyond += light * 0.25 * weight;
			total += weight;
		}
		beyond = total > 0 ? beyond / total : beyond_light(position, normal, direction);
	}
	cascades[texel] = float4(here.rgb + here.a * beyond, here.a);
}
