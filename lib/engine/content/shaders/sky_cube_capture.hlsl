// The sky cubemap's capture of a Flat or a Texture sky (see docs/rendering/sky.md#specular-light): each texel of one mip
// of the source cube averages the sky's light across it, in subsamples squared directions, not pre-exposed. The
// Ambient source is the frame's linear ambient light, which is Flat's colors, or the ambient light of a sky whose own
// source is not ready. The Texture source is the texture's light, turned about +y and scaled as sky_texture.hlsl does,
// at the mip whose texels are about as wide as a subsample. A group's z is the face.
#include "ambient.hlsli"
#include "cinnabar.hlsli"
#include "sky_directions.hlsli"

// Matches Sky_Cube_Source.Texture in lib/engine/render/sky_cube.odin. Every other source is the ambient light.
static const uint SOURCE_TEXTURE = 2;

// Matches Sky_Cube_Push in lib/engine/render/sky_cube.odin. turn has the rotation's cosine and sine, the intensity, and
// the texture's texels around the horizon.
struct Sky_Cube_Push {
	float4 ambient[4];
	float4 turn;
	uint output;
	uint face;
	uint subsamples;
	uint source;
	uint texture;
	uint cube;
	uint sampler_index;
};
CN_PUSH_CONSTANTS(Sky_Cube_Push, push);

float3 texture_light(float3 d, float lod) {
	float c = push.turn.x;
	float s = push.turn.y;
	float3 t = float3(d.x * c - d.z * s, d.y, d.z * c + d.x * s);
	SamplerState linear_sampler = cn_sampler(push.sampler_index);
	float3 light;
	if (push.cube != 0) {
		light = cn_texture_cube(push.texture).SampleLevel(linear_sampler, t, lod).rgb;
	} else {
		light = cn_texture(push.texture).SampleLevel(linear_sampler, texture_uv(t), lod).rgb;
	}
	return light * push.turn.z;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.face)) {
		return;
	}
	// A subsample spans about a quarter turn over the texels across the face, and a texel of the texture 2 pi over its
	// texels around the horizon.
	float subsample = SKY_TEXTURE_PI * 0.5 / (push.face * push.subsamples);
	float lod = max(log2(subsample * push.turn.w / (2 * SKY_TEXTURE_PI)), 0);
	float3 light = 0;
	for (uint i = 0; i < push.subsamples * push.subsamples; i++) {
		float2 within = (float2(i % push.subsamples, i / push.subsamples) + 0.5) / push.subsamples;
		float3 d = cube_texel_direction(id.z, id.xy, push.face, within);
		light += push.source == SOURCE_TEXTURE ? texture_light(d, lod) : ambient_light(push.ambient, d);
	}
	cn_rw_texture_array(push.output)[id] = float4(light / (push.subsamples * push.subsamples), 1);
}
