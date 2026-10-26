// Ambient occlusion (see docs/rendering/ambient-occlusion.md#ambient-occlusion): ground-truth ambient occlusion (GTAO, after Jimenez et
// al.) from gtao_depth.hlsl's depth levels and the prepass's normals. Each pixel searches a few slices around the view
// direction for the highest horizon on each side, and integrates the cosine-weighted visible arc between them. After
// XeGTAO's XeGTAO_MainPass (Copyright (C) 2016-2021, Intel Corporation; SPDX-License-Identifier: MIT).
#include "ao_common.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Ao_Pixel p;
	if (!ao_begin(id, p)) {
		return;
	}
	float min_step = MIN_PIXELS / p.pixels;
	// The noise gives the slices' angle and the steps' offset.
	float slice_noise = p.noise.x;
	float step_noise = p.noise.y;

	float visibility = 0;
	// The slices turn evenly around the view direction, not around the screen's axis, which off the screen's center
	// would weigh some directions more and make an open plane look occluded or brighter than open.
	float3 across = normalize(cross(float3(0, 1, 0), p.view));
	float3 along = cross(p.view, across);
	float2 projection_scale = p.view_model ? constants.view_model.xy : constants.projection.xy;
	uint slices = constants.samples;
	uint steps = constants.steps;
	[loop] for (uint slice = 0; slice < slices; slice++) {
		float phi = (slice + slice_noise) / slices * PI;
		float3 ortho = cos(phi) * across + sin(phi) * along;
		// The slice's direction on the screen: how its direction moves the point's projection. The screen's y goes
		// down, view space's up.
		float2 moved = projection_scale * (ortho.xy * p.position.z - p.position.xy * ortho.z);
		float2 omega = normalize(float2(moved.x * constants.size.x, -moved.y * constants.size.y)) * p.pixels;
		float3 axis = normalize(cross(ortho, p.view));
		float3 projected = p.normal - axis * dot(p.normal, axis);
		float projected_length = length(projected);
		float sign_n = dot(ortho, projected) >= 0 ? 1 : -1;
		float cos_n = saturate(dot(projected, p.view) / max(projected_length, 1e-5));
		float n = sign_n * acos(cos_n);
		float low0 = cos(n + HALF_PI);
		float low1 = cos(n - HALF_PI);
		float horizon0 = low0;
		float horizon1 = low1;
		[loop] for (uint step = 0; step < steps; step++) {
			float s = (step + frac(step_noise + (slice + step * steps) * 0.618034)) / steps;
			s = s * s + min_step;
			int2 offset = int2(round(omega * s));
			uint level = level_at(length(float2(offset)));
			float3 sample_position;
			if (ao_sample(p, p.pixel + offset, level, sample_position)) {
				float3 delta = sample_position - p.position;
				float distance = length(delta);
				horizon0 = max(horizon0, lerp(low0, dot(delta / distance, p.view), ao_falloff(p, distance)));
			}
			if (ao_sample(p, p.pixel - offset, level, sample_position)) {
				float3 delta = sample_position - p.position;
				float distance = length(delta);
				horizon1 = max(horizon1, lerp(low1, dot(delta / distance, p.view), ao_falloff(p, distance)));
			}
		}
		// The visible arc between the two horizons, each at most a quarter turn from the normal, cosine-weighted.
		projected_length = lerp(projected_length, 1, 0.05);
		float h0 = -acos(clamp(horizon1, -1, 1));
		float h1 = acos(clamp(horizon0, -1, 1));
		h0 = n + clamp(h0 - n, -HALF_PI, HALF_PI);
		h1 = n + clamp(h1 - n, -HALF_PI, HALF_PI);
		float arc0 = (cos_n + 2 * h0 * sin(n) - cos(2 * h0 - n)) / 4;
		float arc1 = (cos_n + 2 * h1 * sin(n) - cos(2 * h1 - n)) / 4;
		visibility += projected_length * (arc0 + arc1);
	}
	ao_end(p, visibility / slices);
}
