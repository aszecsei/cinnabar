// A level of the depth pyramid that occlusion culling tests against (see docs/rendering/gpu-scene.md#occlusion-culling):
// each texel the farthest depth, the smallest since the depth is reversed, of the two texels by two of the level
// below it, the depth itself for the first level. A level below of odd size gives its last texel's extra row or column
// to the last texel above it, so every texel below is under one above.
#include "cinnabar.hlsli"

// Matches Hzb_Push in lib/engine/render/occlusion.odin.
struct Hzb_Push {
	uint source;
	uint output;
	uint2 source_size;
	uint2 size;
	uint2 padding;
};
CN_PUSH_CONSTANTS(Hzb_Push, push);

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	Texture2D<float4> source = cn_texture(push.source);
	uint2 first = id.xy * 2;
	// The last texel takes what is left of an odd level below.
	uint2 last = select(id.xy + 1 == push.size, push.source_size - 1, first + 1);
	last = min(last, push.source_size - 1);
	float farthest = 1;
	for (uint y = first.y; y <= last.y; y++) {
		for (uint x = first.x; x <= last.x; x++) {
			farthest = min(farthest, source.Load(int3(x, y, 0)).r);
		}
	}
	cn_rw_texture(push.output)[id.xy] = float4(farthest, 0, 0, 0);
}
