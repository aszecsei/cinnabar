// Ambient occlusion's depth (see docs/rendering/ambient-occlusion.md#ambient-occlusion): the prepass's depth as view depth, and four
// levels below it, each half the size of the one above. gtao.hlsl reads a step far from its pixel from a smaller
// level, where one texel stands for the area around it. After XeGTAO's XeGTAO_PrefilterDepths16x16 (Copyright (C)
// 2016-2021, Intel Corporation; SPDX-License-Identifier: MIT).
#include "cinnabar.hlsli"

// Matches Ao_Depth_Constants in lib/engine/render/ambient_occlusion.odin. levels and level4 are the five levels'
// storage views. A view model's pixel stores its depth negated, from the view model's near plane.
struct Depth_Constants {
	uint4 levels;
	uint level4;
	uint depth;
	uint stencil;
	float radius;
	uint2 size;
	float near;
	float view_model_near;
};
CN_PASS_CONSTANTS(Depth_Constants, constants);

// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;
// A level's texel weighs the depths below it within this share of the radius of the farthest of them.
static const float FILTER_FALLOFF_SHARE = 0.75;

groupshared float level_scratch[8][8];

// view_depth is a pixel's view depth, negated for the view model. Off the screen it is the edge's.
float view_depth(int2 pixel) {
	pixel = clamp(pixel, 0, int2(constants.size) - 1);
	float depth = cn_texture(constants.depth).Load(int3(pixel, 0)).r;
	bool view_model = (cn_stencil_texture(constants.stencil).Load(int3(pixel, 0)).g & VIEW_MODEL_STENCIL) != 0;
	float z = (view_model ? constants.view_model_near : constants.near) / max(depth, 1e-7);
	return view_model ? -z : z;
}

// filter is one texel of a level from the four below it. Each weighs by how near it is to the farthest of them, so a
// texel takes the surface behind rather than a thin one in front, which would occlude more than it does. The world's
// depths count over the view model's, which is negative, unless all four are the view model's.
float filter(float4 z) {
	bool4 world = z > 0;
	bool any_world = any(world);
	float4 depth = abs(z);
	float4 counts = any_world ? float4(world) : float4(1, 1, 1, 1);
	float farthest = max(max(depth.x * counts.x, depth.y * counts.y), max(depth.z * counts.z, depth.w * counts.w));
	float falloff_range = FILTER_FALLOFF_SHARE * constants.radius;
	float falloff_from = constants.radius * (1 - FILTER_FALLOFF_SHARE);
	float falloff_mul = -1 / falloff_range;
	float falloff_add = falloff_from / falloff_range + 1;
	float4 weights = saturate((farthest - depth) * falloff_mul + falloff_add) * counts;
	float result = dot(weights, depth) / max(dot(weights, float4(1, 1, 1, 1)), 1e-5);
	return any_world ? result : -result;
}

void store(uint index, uint level, uint2 texel, float z) {
	uint2 size = (constants.size + (1u << level) - 1) >> level;
	if (all(texel < size)) {
		cn_rw_texture(index)[texel] = z;
	}
}

// Each group covers 16x16 pixels and each thread a 2x2 quad: the thread writes level 0's four texels and level 1's
// one, and every second thread, then every fourth and every eighth, combines four of the level above from the group's
// scratch.
[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID, uint3 group_thread : SV_GroupThreadID) {
	int2 base = int2(id.xy) * 2;
	float4 z = float4(view_depth(base), view_depth(base + int2(1, 0)), view_depth(base + int2(0, 1)), view_depth(base + int2(1, 1)));
	store(constants.levels.x, 0, base, z.x);
	store(constants.levels.x, 0, base + uint2(1, 0), z.y);
	store(constants.levels.x, 0, base + uint2(0, 1), z.z);
	store(constants.levels.x, 0, base + uint2(1, 1), z.w);

	float level1 = filter(z);
	store(constants.levels.y, 1, id.xy, level1);
	level_scratch[group_thread.x][group_thread.y] = level1;
	GroupMemoryBarrierWithGroupSync();

	uint4 indices = uint4(constants.levels.zw, constants.level4, 0);
	[unroll] for (uint level = 2; level <= 4; level++) {
		// The level above's texels are this many threads apart in the scratch: level 1's are at every thread.
		uint stride = 1u << (level - 2);
		bool active = all(group_thread.xy % (stride * 2) == 0);
		float result = 0;
		if (active) {
			uint2 t = group_thread.xy;
			float4 above = float4(level_scratch[t.x][t.y], level_scratch[t.x + stride][t.y], level_scratch[t.x][t.y + stride], level_scratch[t.x + stride][t.y + stride]);
			result = filter(above);
			store(indices[level - 2], level, id.xy / (stride * 2), result);
		}
		GroupMemoryBarrierWithGroupSync();
		if (active) {
			level_scratch[group_thread.x][group_thread.y] = result;
		}
		GroupMemoryBarrierWithGroupSync();
	}
}
