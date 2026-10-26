// FXAA (see docs/rendering/anti-aliasing.md#fxaa), after Lottes's FXAA 3.11 at its quality preset 39: on the tone-mapped
// scene, a pixel whose neighbors' luma differs enough is on an edge. The edge runs along the axis with the larger
// change, and the pixel moves its sample across it, toward the neighbor with the steeper change, by how near the
// edge's nearer end is. Searches step out along the edge in both directions until the luma leaves the edge's average.
// A pixel that differs from all its neighbors, a detail smaller than a pixel, blends toward them as well.
#include "cinnabar.hlsli"

// Matches Fxaa_Push in lib/engine/render/spatial_aa.odin.
struct Push {
	uint input;
	uint output;
	uint sampler_index;
	uint padding;
	uint2 size;
	float2 texel;
};
CN_PUSH_CONSTANTS(Push, push);

// An edge is a range of luma among the pixel and its neighbors above EDGE_THRESHOLD of their brightest, and above
// EDGE_THRESHOLD_MIN, so dark noise is not smoothed. SUBPIXEL is how much a lone detail blends with its neighbors.
static const float EDGE_THRESHOLD = 0.125;
static const float EDGE_THRESHOLD_MIN = 0.0625;
static const float SUBPIXEL = 0.75;
// The searches' steps in pixels along the edge, longer as they go.
static const uint STEPS = 12;
static const float STEP_SIZES[STEPS] = {1, 1, 1, 1, 1, 1.5, 2, 2, 2, 2, 4, 8};

// The colors are sRGB-encoded, so this luma is perceptual, as the thresholds are.
float luma(float3 c) {
	return dot(c, float3(0.299, 0.587, 0.114));
}

float luma_at(Texture2D<float4> input, int2 pixel, int2 offset) {
	return luma(input.Load(int3(clamp(pixel + offset, 0, int2(push.size) - 1), 0)).rgb);
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	Texture2D<float4> input = cn_texture(push.input);
	SamplerState linear_clamp = cn_sampler(push.sampler_index);
	RWTexture2D<float4> output = cn_rw_texture(push.output);
	int2 pixel = id.xy;
	float3 center = input.Load(int3(pixel, 0)).rgb;
	float m = luma(center);
	float n = luma_at(input, pixel, int2(0, -1));
	float s = luma_at(input, pixel, int2(0, 1));
	float w = luma_at(input, pixel, int2(-1, 0));
	float e = luma_at(input, pixel, int2(1, 0));
	float highest = max(m, max(max(n, s), max(w, e)));
	float range = highest - min(m, min(min(n, s), min(w, e)));
	if (range < max(EDGE_THRESHOLD_MIN, highest * EDGE_THRESHOLD)) {
		output[pixel] = float4(center, 1);
		return;
	}
	float nw = luma_at(input, pixel, int2(-1, -1));
	float ne = luma_at(input, pixel, int2(1, -1));
	float sw = luma_at(input, pixel, int2(-1, 1));
	float se = luma_at(input, pixel, int2(1, 1));

	// A lone detail: how far the pixel is from its neighbors' weighted average, as a share of the range.
	float average = (2 * (n + s + w + e) + nw + ne + sw + se) / 12;
	float subpixel = smoothstep(0, 1, saturate(abs(average - m) / range));
	subpixel = subpixel * subpixel * SUBPIXEL;

	// A horizontal edge changes most from row to row.
	float horizontal = abs(nw + sw - 2 * w) + 2 * abs(n + s - 2 * m) + abs(ne + se - 2 * e);
	float vertical = abs(nw + ne - 2 * n) + 2 * abs(w + e - 2 * m) + abs(sw + se - 2 * s);
	bool is_horizontal = horizontal >= vertical;
	// The neighbors across the edge: above and below, or left and right. The side with the steeper change is the
	// edge's other side.
	float before = is_horizontal ? n : w;
	float after = is_horizontal ? s : e;
	float gradient_before = before - m;
	float gradient_after = after - m;
	bool before_steeper = abs(gradient_before) >= abs(gradient_after);
	float gradient = 0.25 * max(abs(gradient_before), abs(gradient_after));
	float across = is_horizontal ? push.texel.y : push.texel.x;
	float edge_luma;
	if (before_steeper) {
		across = -across;
		edge_luma = 0.5 * (before + m);
	} else {
		edge_luma = 0.5 * (after + m);
	}

	// From the middle of the edge, between the pixel and the other side, search along it both ways for its ends: where
	// the bilinear sample, half of each side, leaves the edge's average luma.
	float2 uv = (pixel + 0.5) * push.texel;
	float2 edge_uv = uv;
	float2 along;
	if (is_horizontal) {
		edge_uv.y += 0.5 * across;
		along = float2(push.texel.x, 0);
	} else {
		edge_uv.x += 0.5 * across;
		along = float2(0, push.texel.y);
	}
	float2 uv_back = edge_uv - along * STEP_SIZES[0];
	float2 uv_forward = edge_uv + along * STEP_SIZES[0];
	float end_back = luma(input.SampleLevel(linear_clamp, uv_back, 0).rgb) - edge_luma;
	float end_forward = luma(input.SampleLevel(linear_clamp, uv_forward, 0).rgb) - edge_luma;
	bool done_back = abs(end_back) >= gradient;
	bool done_forward = abs(end_forward) >= gradient;
	for (uint i = 1; i < STEPS && !(done_back && done_forward); i++) {
		if (!done_back) {
			uv_back -= along * STEP_SIZES[i];
			end_back = luma(input.SampleLevel(linear_clamp, uv_back, 0).rgb) - edge_luma;
			done_back = abs(end_back) >= gradient;
		}
		if (!done_forward) {
			uv_forward += along * STEP_SIZES[i];
			end_forward = luma(input.SampleLevel(linear_clamp, uv_forward, 0).rgb) - edge_luma;
			done_forward = abs(end_forward) >= gradient;
		}
	}

	// The nearer end decides. The pixel moves across the edge only when the luma there changes the way the pixel's
	// does: away from the average on the other side from the pixel.
	float distance_back = is_horizontal ? uv.x - uv_back.x : uv.y - uv_back.y;
	float distance_forward = is_horizontal ? uv_forward.x - uv.x : uv_forward.y - uv.y;
	bool back_nearer = distance_back < distance_forward;
	float nearer = min(distance_back, distance_forward);
	float offset = 0.5 - nearer / (distance_back + distance_forward);
	bool pixel_darker = m < edge_luma;
	bool end_darker = (back_nearer ? end_back : end_forward) < 0;
	offset = end_darker != pixel_darker ? offset : 0;
	offset = max(offset, subpixel);

	float2 final_uv = uv;
	if (is_horizontal) {
		final_uv.y += offset * across;
	} else {
		final_uv.x += offset * across;
	}
	output[pixel] = float4(input.SampleLevel(linear_clamp, final_uv, 0).rgb, 1);
}
