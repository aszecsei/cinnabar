// The fog over the background (see docs/rendering.md#volumetric-fog): where nothing drew, the scene holds the clear
// color, which the forward pass's fog did not reach, so this pass dims it by the whole volume and adds the volume's
// light, pre-exposed.
#include "cinnabar.hlsli"

// Matches Background_Push in lib/engine/render/fog.odin. fog_scale is the share of the volume's width and height that
// the screen covers.
struct Push {
	uint depth;
	uint scene;
	uint fog;
	uint sampler_index;
	uint exposure;
	uint padding;
	uint2 size;
	float2 fog_scale;
};
CN_PUSH_CONSTANTS(Push, push);

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size) || cn_texture(push.depth).Load(int3(id.xy, 0)).r > 0) {
		return;
	}
	float2 uv = (float2(id.xy) + 0.5) / float2(push.size) * push.fog_scale;
	float4 fog = cn_texture3d(push.fog).SampleLevel(cn_sampler(push.sampler_index), float3(uv, 1), 0);
	RWTexture2D<float4> scene = cn_rw_texture(push.scene);
	float exposure = cn_buffer(push.exposure).Load<float>(0);
	scene[id.xy] = float4(scene[id.xy].rgb * fog.a + fog.rgb * exposure, 1);
}
