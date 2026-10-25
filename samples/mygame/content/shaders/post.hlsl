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

// Shadows, chromatic aberration and a vignette, in linear HDR.
[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	Texture2D<float4> input = cn_texture(push.input);
	float2 from_center = (id.xy + 0.5) / float2(push.size) - 0.5;
	int2 shift = int2(from_center * 24.0);
	int2 last = int2(push.size) - 1;
	float r = input.Load(int3(clamp(int2(id.xy) + shift, 0, last), 0)).r;
	float g = input.Load(int3(id.xy, 0)).g;
	float b = input.Load(int3(clamp(int2(id.xy) - shift, 0, last), 0)).b;
	float vignette = saturate(1.0 - dot(from_center, from_center) * 1.6);
	float light = push.has_shadows != 0 ? cn_texture(push.shadows).Load(int3(id.xy, 0)).r : 1.0;
	cn_rw_texture(push.output)[id.xy] = float4(float3(r, g, b) * vignette * light, 1);
}
