// The screen-space reflections' depth pyramid (see docs/rendering/lighting-and-shadows.md#screen-space-reflections): each
// level keeps the nearest depth of the 2x2 texels under each of its own, which is the largest with the depth reversed,
// so a ray that passes in front of a texel passes in front of everything under it. Each level is half the size of the
// one before, rounded up, so its last row and column cover what is left. A group covers 16x16 texels of its source and
// writes four levels: the first dispatch reads the depth buffer, copies it into level 0 with the view model's pixels
// at the far plane, as the view model is not where it seems to be, and writes levels 1 to 4; the second reads level 4
// and writes levels 5 to 8.
#include "ssr_common.hlsli"

groupshared float scratch[8][8];

float nearest(float4 v) {
	return max(max(v.x, v.y), max(v.z, v.w));
}

void store(uint level, uint2 texel, float value) {
	if (all(texel < level_size(level))) {
		cn_rw_texture(level_index(level))[texel] = value;
	}
}

[numthreads(8, 8, 1)]
void cs_main(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID) {
	// The first level that this dispatch reduces into, from the one before.
	uint base = constants.first != 0 ? 1 : 5;
	uint2 texel = group.xy * 8 + local.xy;
	int2 last = int2(level_size(base - 1)) - 1;
	float4 v;
	[unroll] for (uint n = 0; n < 4; n++) {
		int2 p = int2(texel * 2 + uint2(n & 1, n >> 1));
		int2 at = min(p, last);
		if (constants.first != 0) {
			float depth = cn_texture(constants.depth).Load(int3(at, 0)).r;
			bool view_model = (cn_stencil_texture(constants.stencil).Load(int3(at, 0)).g & VIEW_MODEL_STENCIL) != 0;
			v[n] = view_model ? 0 : depth;
			if (all(p == at)) {
				store(0, uint2(p), v[n]);
			}
		} else {
			v[n] = cn_texture(constants.source).Load(int3(at, 0)).r;
		}
	}
	float value = nearest(v);
	store(base, texel, value);
	scratch[local.y][local.x] = value;
	[unroll] for (uint k = 1; k < 4; k++) {
		GroupMemoryBarrierWithGroupSync();
		uint width = 8u >> k;
		bool active = all(local.xy < width);
		if (active) {
			uint2 s = local.xy * 2;
			value = nearest(float4(scratch[s.y][s.x], scratch[s.y][s.x + 1], scratch[s.y + 1][s.x], scratch[s.y + 1][s.x + 1]));
		}
		GroupMemoryBarrierWithGroupSync();
		if (active) {
			scratch[local.y][local.x] = value;
			store(base + k, group.xy * width + local.xy, value);
		}
	}
}
