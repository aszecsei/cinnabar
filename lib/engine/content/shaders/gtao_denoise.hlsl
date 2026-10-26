// Ambient occlusion's denoiser (see docs/rendering/ambient-occlusion.md#ambient-occlusion): it averages gtao.hlsl's noisy result over
// each pixel's 3x3 neighbors, weighted by how much each is on the pixel's surface, from gtao.hlsl's edges. One pass
// runs with temporal AA, which averages the rest over time, and two without it. There is no history. After XeGTAO's
// XeGTAO_Denoise (Copyright (C) 2016-2021, Intel Corporation; SPDX-License-Identifier: MIT).
#include "cinnabar.hlsli"

// Matches Ao_Denoise_Push in lib/engine/render/ambient_occlusion.odin. blur is how much the pixel's own value weighs
// against its neighbors': less on the passes before the last.
struct Push {
	uint source;
	uint edges;
	uint output;
	float blur;
	uint2 size;
};
CN_PUSH_CONSTANTS(Push, push);

// A neighbor's weight across a diagonal, against one across a side.
static const float DIAGONAL_WEIGHT = 0.85 * 0.5;
// A pixel with more than this many edges of its four lets its neighbors leak in by up to LEAK_STRENGTH, so a pixel
// alone on its surface is not left with its own noise.
static const float LEAK_THRESHOLD = 2.5;
static const float LEAK_STRENGTH = 0.5;

// unpack_edges matches pack_edges in gtao.hlsl: left, right, top and bottom, from 0 to 1.
float4 unpack_edges(float packed) {
	uint p = uint(packed * 255.5);
	return saturate(float4((p >> 6) & 3, (p >> 4) & 3, (p >> 2) & 3, p & 3) / 3.0);
}

float4 load_edges(int2 pixel) {
	return unpack_edges(cn_texture(push.edges).Load(int3(clamp(pixel, 0, int2(push.size) - 1), 0)).r);
}

float load_value(int2 pixel) {
	return cn_texture(push.source).Load(int3(clamp(pixel, 0, int2(push.size) - 1), 0)).r;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	float4 edges = load_edges(pixel);
	float4 left = load_edges(pixel + int2(-1, 0));
	float4 right = load_edges(pixel + int2(1, 0));
	float4 top = load_edges(pixel + int2(0, -1));
	float4 bottom = load_edges(pixel + int2(0, 1));
	// A neighbor counts only as much as the pixel counts for it, so the blur is the same both ways across an edge.
	edges *= float4(left.y, right.x, top.w, bottom.z);
	float leak = saturate(4 - LEAK_THRESHOLD - dot(edges, float4(1, 1, 1, 1))) / (4 - LEAK_THRESHOLD) * LEAK_STRENGTH;
	edges = saturate(edges + leak);

	// A diagonal counts through either of the two sides between it and the pixel.
	float top_left = DIAGONAL_WEIGHT * (edges.x * left.z + edges.z * top.x);
	float top_right = DIAGONAL_WEIGHT * (edges.z * top.y + edges.y * right.z);
	float bottom_left = DIAGONAL_WEIGHT * (edges.w * bottom.x + edges.x * left.w);
	float bottom_right = DIAGONAL_WEIGHT * (edges.y * right.w + edges.w * bottom.y);

	float weight = push.blur;
	float sum = load_value(pixel) * weight;
	float4 sides = float4(load_value(pixel + int2(-1, 0)), load_value(pixel + int2(1, 0)), load_value(pixel + int2(0, -1)), load_value(pixel + int2(0, 1)));
	float4 diagonals = float4(load_value(pixel + int2(-1, -1)), load_value(pixel + int2(1, -1)), load_value(pixel + int2(-1, 1)), load_value(pixel + int2(1, 1)));
	float4 diagonal_weights = float4(top_left, top_right, bottom_left, bottom_right);
	sum += dot(sides, edges) + dot(diagonals, diagonal_weights);
	weight += dot(edges, float4(1, 1, 1, 1)) + dot(diagonal_weights, float4(1, 1, 1, 1));
	cn_rw_texture(push.output)[pixel] = sum / weight;
}
