// The particles' history (see docs/rendering/particles.md#collision): after the prepass, each pixel's view depth and
// world normal, which next frame's particles collide with. Where nothing drew, the depth is as far as the format holds.
#define MATERIAL_PUSH History_Push
// Matches History_Push in lib/engine/render/particles.odin.
struct History_Push {
	uint depth;
	uint normals;
	uint output;
	uint padding;
	uint2 size;
};
#include "material_common.hlsli"

// The farthest view depth that RGBA16_Float holds, in meters.
static const float HISTORY_FAR = 60000;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	float depth = cn_texture(push.depth).Load(int3(id.xy, 0)).r;
	float3 normal = octahedral(cn_texture(push.normals).Load(int3(id.xy, 0)).xy);
	float view_depth = depth > 0 ? min(frame.near / depth, HISTORY_FAR) : HISTORY_FAR;
	cn_rw_texture(push.output)[id.xy] = float4(normal, view_depth);
}
