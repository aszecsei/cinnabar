// The Texture sky over the background (see docs/rendering/sky.md#texture): where nothing drew, the texture's light from
// the pixel's direction, turned about +y, scaled by its intensity and pre-exposed. The mip is the one whose texels are
// about as wide as a pixel, so the far sky does not shimmer.
#include "sky_texture.hlsli"

// Matches Sky_Texture_Constants in lib/engine/render/sky_texture.odin. right and up have the projection's scales in w;
// turn has the rotation's cosine and sine, the intensity, and the texture's width.
struct Sky_Texture_Constants {
	float4 right;
	float4 up;
	float4 forward;
	float4 turn;
	uint2 size;
	uint texture;
	uint sampler_index;
};
CN_PASS_CONSTANTS(Sky_Texture_Constants, sky);

// Keeps the brightest texel within the scene's format, as sky.hlsl does.
static const float MAX_SCENE = 60000;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= sky.size) || cn_texture(push.depth).Load(int3(id.xy, 0)).r > 0) {
		return;
	}
	float2 ndc = (float2(id.xy) + 0.5) / float2(sky.size) * float2(2, -2) + float2(-1, 1);
	float3 d = normalize(sky.right.xyz * (ndc.x / sky.right.w) + sky.up.xyz * (ndc.y / sky.up.w) + sky.forward.xyz);
	// The direction's azimuth less the rotation.
	float c = sky.turn.x;
	float s = sky.turn.y;
	float3 t = float3(d.x * c - d.z * s, d.y, d.z * c + d.x * s);
	// A pixel's angle over a texel's, which is 2 pi over the width.
	float pixel = 2 / (sky.up.w * sky.size.y);
	float lod = max(log2(pixel * sky.turn.w / (2 * SKY_TEXTURE_PI)), 0);
	float3 light = cn_texture(sky.texture).SampleLevel(cn_sampler(sky.sampler_index), texture_uv(t), lod).rgb * sky.turn.z;
	float exposure = cn_buffer(push.exposure).Load<float>(0);
	cn_rw_texture(push.output)[id.xy] = float4(min(light * exposure, MAX_SCENE), 1);
}
