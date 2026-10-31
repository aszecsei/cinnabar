// The split radiance cascades' gather (see docs/rendering/global-illumination.md#split-cascades): each pixel takes its
// indirect light from the probes around it, at each of its levels of detail. Its diffuse light is the first cascade's:
// at the eight probes around it, the atlas's cosine-weighted mean around its normal. Its specular light is the second
// cascade's along its reflection, blended between the four nearest directions. Each probe counts by its trilinear
// weight, by whether it is in front of the surface, and by its confidence, and the levels blend by the pixel's
// distance. The world probes' light counts too, a little everywhere, so a place that no probe has reached yet fades in
// from it, and fully past the last level. The probes keep their light from frame to frame in world space, so no
// history follows the pixels and nothing smears. The view model's pixels take the light around the camera.
#include "gi_split.hlsli"

// The world probes' light counts this much against a probe's, so it shows only where the split probes have little.
static const float PRIOR_WEIGHT = 0.01;

float probe_confidence(Split_Grid g, uint slot) {
	float confidence = asfloat(cn_buffer(push.slots).Load(slot * SPLIT_SLOT_SIZE + 12));
	return confidence / (confidence + g.confidence_half);
}

// facing is how much a probe at a center counts at a surface: fully in front of it, and little behind it.
float facing(float3 center, float3 p, float3 normal) {
	float3 to_probe = center - p;
	float distance = length(to_probe);
	float f = (dot(distance > 1e-4 ? to_probe / distance : normal, normal) + 1) * 0.5;
	return f * f + 0.05;
}

float2 atlas_uv(Split_Grid g, uint local, float3 n) {
	uint width, height;
	cn_texture(push.atlas).GetDimensions(width, height);
	float2 tile = float2(local % g.atlas_columns, local / g.atlas_columns) * PROBE_TILE;
	return (tile + 1 + (octahedral_encode(n) * 0.5 + 0.5) * PROBE_INTERIOR) / float2(width, height);
}

// gather_level adds a level's probes' light, weighted by the level's share.
void gather_level(Split_Grid g, uint l, float share, float3 p, float3 normal, float3 reflected, inout float4 diffuse, inout float4 specular) {
	Split_Level level = g.levels[l];
	Texture2D<float4> atlas = cn_texture(push.atlas);
	SamplerState s = cn_sampler(constants.sampler_index);
	[unroll] for (uint k = 0; k < 2; k++) {
		Split_Cascade c = g.cascades[k];
		float cell = level.min.w * float(1u << k);
		float3 grid = (p - level.min.xyz) / cell - 0.5;
		int3 base = int3(floor(grid));
		float3 f = grid - float3(base);
		float2 reflected_at = (octahedral_encode(reflected) * 0.5 + 0.5) * c.side - 0.5;
		int2 reflected_base = int2(floor(reflected_at));
		float2 reflected_f = reflected_at - float2(reflected_base);
		for (uint corner = 0; corner < 8; corner++) {
			int3 offset = int3(corner & 1, (corner >> 1) & 1, corner >> 2);
			int3 u = base + offset;
			if (!split_inside(u, k)) {
				continue;
			}
			uint slot = split_find(c, split_key(l, uint3(u)));
			if (slot == SPLIT_NO_SLOT) {
				continue;
			}
			float3 w3 = lerp(1 - f, f, float3(offset));
			float weight = share * w3.x * w3.y * w3.z * facing(split_center(level, u, k), p, normal);
			if (k == 0) {
				float4 e = atlas.SampleLevel(s, atlas_uv(g, slot - c.first_slot, normal), 0);
				diffuse += float4(e.rgb, 1) * weight * e.a;
			} else {
				float3 light = 0;
				[unroll] for (uint r = 0; r < 4; r++) {
					int2 at = int2(r & 1, r >> 1);
					uint2 texel = uint2(clamp(reflected_base + at, 0, int(c.side) - 1));
					float2 wr = lerp(1 - reflected_f, reflected_f, float2(at));
					light += split_load_merged(split_bin(c, slot, texel.y * c.side + texel.x)) * wr.x * wr.y;
				}
				specular += float4(light, 1) * weight * probe_confidence(g, slot);
			}
		}
	}
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	RWTexture2D<float4> out_diffuse = cn_rw_texture(constants.out_diffuse);
	RWTexture2D<float4> out_specular = cn_rw_texture(constants.out_specular);
	float depth = cn_texture(constants.depth).Load(int3(pixel, 0)).r;
	if (depth <= 0) {
		out_diffuse[pixel] = 0;
		out_specular[pixel] = 0;
		return;
	}
	float3 normal = octahedral_normal(pixel);
	float3 position;
	float z;
	if (!surface_at(pixel, position, z)) {
		float3 reflected = reflect(normalize(position), normal);
		out_diffuse[pixel] = float4(surrounding_light(0, normal), 0);
		out_specular[pixel] = float4(beyond_light(0, normal, reflected), 0);
		return;
	}
	float3 reflected = reflect(normalize(position), normal);
	Split_Grid g = split_grid();
	Split_Lod lod = split_lod(g, chebyshev(position));
	float4 diffuse = 0;
	float4 specular = 0;
	// The share of the light that is the world probes', past the last level.
	float beyond = 1;
	if (lod.level < g.level_count) {
		gather_level(g, lod.level, 1 - lod.blend, position, normal, reflected, diffuse, specular);
		beyond = 0;
		if (lod.blend > 0) {
			if (lod.level + 1 < g.level_count) {
				gather_level(g, lod.level + 1, lod.blend, position, normal, reflected, diffuse, specular);
			} else {
				beyond = lod.blend;
			}
		}
	}
	float prior = beyond + PRIOR_WEIGHT;
	// The world probes' light is looked up only where it counts for more than a percent.
	if (prior > 0.01 * (diffuse.a + prior)) {
		diffuse += float4(surrounding_light(position, normal), 1) * prior;
	}
	if (prior > 0.01 * (specular.a + prior)) {
		specular += float4(beyond_light(position, normal, reflected), 1) * prior;
	}
	out_diffuse[pixel] = float4(diffuse.rgb / max(diffuse.a, 1e-5), z);
	out_specular[pixel] = float4(specular.rgb / max(specular.a, 1e-5), 1);
}
