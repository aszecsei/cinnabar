// The global illumination's gather (see docs/rendering/global-illumination.md#global-illumination): each pixel takes its indirect light
// from the merged cascades. Its diffuse light is the cosine-weighted mean of the first cascade's directions around its
// normal (see direction_weight), and its specular light the second cascade's along its reflection, blended between directions, each at the four probes around it, weighted
// by how near they are, whether they are on the same surface (see probe_weight) and how alike their normals are. Then both blend into their histories, found by the velocity,
// and a history whose depth is not where this frame's point was last frame starts over. The view model's pixels take
// the light around the camera: the world probes', or the ambient light.
#include "gi_common.hlsli"

// A history counts while its depth is within this share of the pixel's.
static const float HISTORY_TOLERANCE = 0.05;

// gather_probes gives a cascade's four probes around a pixel and how much each counts: by how near it is, whether it is
// on the same surface (see probe_weight) and how alike its normal is.
void gather_probes(uint k, int2 pixel, float3 position, float3 normal, float z, out int2 probes[4], out float weights[4]) {
	uint spacing = cascade_spacing(k);
	uint2 count = cascade_probes(k);
	float2 grid = (float2(pixel) + 0.5) / spacing - 0.5;
	int2 base = int2(floor(grid));
	float2 f = grid - base;
	[unroll] for (uint n = 0; n < 4; n++) {
		int2 offset = int2(n & 1, n >> 1);
		probes[n] = clamp(base + offset, 0, int2(count) - 1);
		float2 w2 = lerp(1 - f, f, float2(offset));
		int2 probe_at = probe_pixel(k, uint2(probes[n]));
		float alike = pow(saturate(dot(octahedral_normal(probe_at), normal)), 4) + 1e-3;
		weights[n] = w2.x * w2.y * alike * probe_weight(position, normal, z, probe_at);
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
	Texture2D<float4> cascades = cn_texture(constants.cascades);

	int2 probes[4];
	float weights[4];

	// The diffuse light: each direction's weight depends only on the normal, so the four probes share it.
	gather_probes(0, pixel, position, normal, z, probes, weights);
	uint directions = cascade_directions(0);
	float3 sums[4] = {(float3)0, (float3)0, (float3)0, (float3)0};
	float cosines = 0;
	for (uint d = 0; d < directions * directions; d++) {
		uint2 texel = uint2(d % directions, d / directions);
		float w = direction_weight(texel, directions, normal);
		if (w <= 0) {
			continue;
		}
		cosines += w;
		[unroll] for (uint n = 0; n < 4; n++) {
			if (weights[n] > 0) {
				sums[n] += cascades.Load(int3(cascade_texel(0, uint2(probes[n]), texel), 0)).rgb * w;
			}
		}
	}
	float3 diffuse = 0;
	float diffuse_total = 0;
	[unroll] for (uint n = 0; n < 4; n++) {
		diffuse += sums[n] * weights[n];
		diffuse_total += weights[n];
	}
	diffuse /= max(cosines, 1e-5);

	// The specular light: the reflection falls between four direction texels, which blend, so a reflection does not
	// show their steps.
	gather_probes(1, pixel, position, normal, z, probes, weights);
	directions = cascade_directions(1);
	float2 reflected_at = (octahedral_encode(reflected) * 0.5 + 0.5) * directions - 0.5;
	int2 reflected_base = int2(floor(reflected_at));
	float2 reflected_f = reflected_at - reflected_base;
	float3 specular = 0;
	float specular_total = 0;
	[unroll] for (uint n = 0; n < 4; n++) {
		if (weights[n] <= 0) {
			continue;
		}
		float3 light = 0;
		[unroll] for (uint r = 0; r < 4; r++) {
			int2 corner = int2(r & 1, r >> 1);
			uint2 texel = uint2(clamp(reflected_base + corner, 0, int(directions) - 1));
			float2 wr = lerp(1 - reflected_f, reflected_f, float2(corner));
			light += cascades.Load(int3(cascade_texel(1, uint2(probes[n]), texel), 0)).rgb * wr.x * wr.y;
		}
		specular += light * weights[n];
		specular_total += weights[n];
	}
	diffuse = diffuse_total > 0 ? diffuse / diffuse_total : surrounding_light(position, normal);
	specular = specular_total > 0 ? specular / specular_total : beyond_light(position, normal, reflected);

	float4 diffuse_result = float4(diffuse, z);
	float4 specular_result = float4(specular, 1);
	if (constants.valid != 0) {
		float2 uv = (float2(pixel) + 0.5) / float2(constants.size);
		float2 previous_uv = uv - cn_texture(constants.velocity).Load(int3(pixel, 0)).rg;
		float expected = mul(constants.previous, float4(position, 1)).w;
		if (all(previous_uv == saturate(previous_uv))) {
			int2 previous_pixel = min(int2(previous_uv * float2(constants.size)), int2(constants.size) - 1);
			float4 history_diffuse = cn_texture(constants.history_diffuse).Load(int3(previous_pixel, 0));
			float4 history_specular = cn_texture(constants.history_specular).Load(int3(previous_pixel, 0));
			if (abs(history_diffuse.a - expected) <= HISTORY_TOLERANCE * expected) {
				float frames = min(history_specular.a + 1, constants.max_frames);
				diffuse_result.rgb = lerp(history_diffuse.rgb, diffuse, 1 / frames);
				specular_result = float4(lerp(history_specular.rgb, specular, 1 / frames), frames);
			}
		}
	}
	out_diffuse[pixel] = diffuse_result;
	out_specular[pixel] = specular_result;
}
