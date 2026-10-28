// The sprites' shading (see docs/rendering/transparency.md#sprites): at each pixel, the sprites of its tile in front of
// its opaque surface add their light and opacity, each times the transmittance in front of it that the moments give, to
// what the transparent pass wrote there, as ps_transparent's surfaces do. A sprite's light is its color times its
// texture's tint and the light at its point, which the light textures hold, plus its emission, then the fog's,
// pre-exposed.
#define MATERIAL_PUSH Raster_Push
#include "sprite_raster.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID, uint3 group : SV_GroupID) {
	uint2 pixel = min(id.xy, push.size - 1);
	float opaque = opaque_depth(pixel);
	float b0 = cn_texture(push.moments_zeroth).Load(int3(pixel, 0)).r;
	float4 moments = cn_texture(push.moments).Load(int3(pixel, 0));
	Texture2D<float4> light = cn_texture(push.light);
	Texture2D<float4> fog_light = cn_texture(push.fog_light);
	SamplerState light_sampler = cn_sampler(push.light_sampler);
	float exposure = frame_exposure();
	ByteAddressBuffer bins = cn_buffer(push.bins);
	uint tile = sprite_tile(group.xy, push.tile_columns);
	float4 sum = 0;
	for (uint w = 0; w < push.words; w++) {
		// Every thread of the group is in the tile, so the loop is uniform.
		uint bits = WaveReadLaneFirst(bins.Load((tile * push.words + w) * 4));
		while (bits != 0) {
			uint index = w * 32 + firstbitlow(bits);
			bits &= bits - 1;
			Screen_Sprite s = load_screen_sprite(index);
			float2 q = sprite_quad(s, float2(pixel) + 0.5);
			if (s.depth >= opaque || any(abs(q) > 1)) {
				continue;
			}
			float4 texel = sprite_texel(s, q, frame.sampler_index);
			float alpha = sprite_alpha(s, texel, opaque);
			if (alpha <= 0) {
				continue;
			}
			Sprite_Record r = load_sprite(push.records, push.records_offset, index);
			float2 uv = sprite_light_uv(index, q, push.light_texel);
			float4 lit = light.SampleLevel(light_sampler, uv, 0);
			float3 fog = fog_light.SampleLevel(light_sampler, uv, 0).rgb;
			float3 color = (r.color.rgb * texel.rgb * lit.rgb + r.emission * lit.a + fog) * exposure;
			sum += float4(color, 1) * alpha * transmittance_at(b0, moments, s.z);
		}
	}
	if (any(id.xy >= push.size) || sum.a == 0) {
		return;
	}
	RWTexture2D<float4> accumulated = cn_rw_texture(push.accumulated);
	accumulated[pixel] = accumulated[pixel] + sum;
}
