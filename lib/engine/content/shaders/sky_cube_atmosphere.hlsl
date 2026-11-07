// The sky cubemap's capture of the atmosphere (see docs/rendering/sky.md#specular-light): each texel of one mip of the
// source cube averages the sky view table's light across it, in subsamples squared directions, scaled by the ambient
// intensity and not pre-exposed. The sun's and the moon's discs and the stars are left out: the directional lights
// give the specular highlights, and a star is narrower than a texel. A group's z is the face.
#include "sky_common.hlsli"
#include "sky_directions.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.face)) {
		return;
	}
	float h = sky.heights.x;
	Texture2D<float4> view = cn_texture(push.view);
	SamplerState s = cn_sampler(push.sampler_index);
	float3 light = 0;
	for (uint i = 0; i < push.subsamples * push.subsamples; i++) {
		float2 within = (float2(i % push.subsamples, i / push.subsamples) + 0.5) / push.subsamples;
		float3 d = cube_texel_direction(id.z, id.xy, push.face, within);
		light += view.SampleLevel(s, sky_view_uv(d, h), 0).rgb;
	}
	light *= push.intensity / (push.subsamples * push.subsamples);
	cn_rw_texture_array(push.output)[id] = float4(light, 1);
}
