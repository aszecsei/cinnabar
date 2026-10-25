#include "cinnabar.hlsli"

// Matches Post_Constants in game.odin.
struct Push {
	uint input;
	uint output;
	uint2 size;
	// The shadow mask, when has_shadows is not 0.
	uint shadows;
	uint has_shadows;
};
CN_PUSH_CONSTANTS(Push, push);

// The triangles' ray-traced shadows over the scene, in linear HDR, before temporal AA. The lens is a post effect of its
// own (see lens.hlsl).
[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	float3 color = cn_texture(push.input).Load(int3(id.xy, 0)).rgb;
	float light = push.has_shadows != 0 ? cn_texture(push.shadows).Load(int3(id.xy, 0)).r : 1.0;
	cn_rw_texture(push.output)[id.xy] = float4(color * light, 1);
}
