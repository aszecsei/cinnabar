// One mip of a cube's mip chain (see docs/rendering/lighting-and-shadows.md#reflection-probes): each texel is the mean of the block
// of texels under it in a finer mip, read through that mip's storage view. A pass a mip, from the finest, so each reads
// the one that the pass before it wrote. A group's z is the face.
#include "cinnabar.hlsli"

// Matches Cube_Downsample_Push in lib/engine/render/reflection_probes.odin: the finer mip's storage view, the mip's, the
// mip's size, and how many of the finer mip's texels each of its texels covers across.
struct Cube_Downsample_Push {
	uint source;
	uint output;
	uint size;
	uint block;
};
CN_PUSH_CONSTANTS(Cube_Downsample_Push, push);

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	RWTexture2DArray<float4> source = cn_rw_texture_array(push.source);
	uint2 first = id.xy * push.block;
	float3 sum = 0;
	for (uint y = 0; y < push.block; y++) {
		for (uint x = 0; x < push.block; x++) {
			sum += source[uint3(first + uint2(x, y), id.z)].rgb;
		}
	}
	cn_rw_texture_array(push.output)[id] = float4(sum / (push.block * push.block), 1);
}
