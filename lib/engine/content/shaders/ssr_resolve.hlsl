// The screen-space reflections' resolve (see docs/rendering/lighting-and-shadows.md#screen-space-reflections): each pixel
// reuses the rays of its own trace texel and three of its neighbors', in a ring that the blue noise turns each frame.
// Each ray's direction from this pixel's surface, to its hit or along it for a miss, counts by this pixel's GGX
// specular times the cosine over the ray's own pdf: Stachowiak's ratio estimator ("Stochastic Screen-Space
// Reflections", SIGGRAPH 2015), whose sum of weighted light over the sum of weights is the light filtered by this
// pixel's own lobe. A ray's weight from the trace scales its light and its weight alike, so the result's weight is the
// share of the lobe that the screen found, and the probes fill in the rest. The weight fades to 0 over CUTOFF_FADE
// below the cutoff. The resolve also keeps the mean distance to the hits, which the temporal pass reprojects by.
#include "ssr_common.hlsli"

static const int2 RING[8] = {
	int2(1, 0), int2(1, 1), int2(0, 1), int2(-1, 1), int2(-1, 0), int2(-1, -1), int2(0, -1), int2(1, -1),
};

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	RWTexture2D<float4> resolved = cn_rw_texture(constants.resolved);
	RWTexture2D<float4> distances = cn_rw_texture(constants.distance);
	float3 position;
	float roughness = roughness_at(pixel);
	if (!surface_at(pixel, position) || roughness > constants.cutoff) {
		resolved[id.xy] = 0;
		distances[id.xy] = 0;
		return;
	}
	float3 normal = normal_at(pixel);
	float3 view = -normalize(position);
	float n_v = dot(normal, view);
	float alpha = ggx_alpha(roughness);
	bool half_size = any(constants.trace_size != constants.size);
	int2 own = half_size ? pixel / 2 : pixel;
	int2 last = int2(constants.trace_size) - 1;
	uint turn = uint(noise(pixel, 3).x * 8);
	float sum_weight = 0;
	float sum_found = 0;
	float3 sum_light = 0;
	float sum_distance = 0;
	[unroll] for (uint n = 0; n < 4; n++) {
		int2 texel = clamp(own + (n == 0 ? int2(0, 0) : RING[(turn + n * 3) % 8]), 0, last);
		int2 source = min(half_size ? texel * 2 + int2(constants.offset) : texel, int2(constants.size) - 1);
		float3 origin;
		if (!surface_at(source, origin)) {
			continue;
		}
		for (uint r = 0; r < constants.ray_count; r++) {
			float4 ray = cn_texture(constants.rays[r]).Load(int3(texel, 0));
			if (ray.w <= 0) {
				continue;
			}
			float3 direction = octahedral_decode(ray.xy);
			float3 l = ray.z > 0 ? normalize(origin + direction * ray.z - position) : direction;
			float3 h = normalize(view + l);
			float weight = specular_weight(n_v, dot(normal, l), saturate(dot(normal, h)), alpha) / ray.w;
			float4 light = cn_texture(constants.rays[2 + r]).Load(int3(texel, 0));
			sum_weight += weight;
			sum_found += weight * light.a;
			sum_light += weight * light.a * light.rgb;
			sum_distance += weight * light.a * ray.z;
		}
	}
	float found = sum_weight > 0 ? sum_found / sum_weight : 0;
	float4 result = 0;
	float mean_distance = 0;
	if (sum_found > 0) {
		result.rgb = sum_light / sum_found;
		mean_distance = sum_distance / sum_found;
	}
	result.a = found * saturate((constants.cutoff - roughness) / CUTOFF_FADE);
	resolved[id.xy] = result;
	distances[id.xy] = mean_distance;
}
