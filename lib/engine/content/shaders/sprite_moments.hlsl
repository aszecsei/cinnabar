// The sprites' moments (see docs/rendering/transparency.md#sprites): at each pixel, the sprites of its tile in front of
// its opaque surface add their optical depth and its moments to what the moments pass wrote there. In the overdraw
// view, each adds 1 instead.
#define MATERIAL_PUSH Raster_Push
#include "sprite_raster.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID, uint3 group : SV_GroupID) {
	uint2 pixel = min(id.xy, push.size - 1);
	float opaque = opaque_depth(pixel);
	bool overdraw = frame.debug_view == DEBUG_TRANSPARENT_OVERDRAW;
	ByteAddressBuffer bins = cn_buffer(push.bins);
	uint tile = sprite_tile(group.xy, push.tile_columns);
	float b0 = 0;
	float4 moments = 0;
	uint words = used_words();
	for (uint w = 0; w < words; w++) {
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
			if (overdraw) {
				b0 += 1;
				continue;
			}
			float alpha = sprite_alpha(s, sprite_texel(s, q, frame.sampler_index), opaque);
			float depth = optical_depth(alpha);
			b0 += depth;
			moments += depth_moments(s.z, depth);
		}
	}
	if (any(id.xy >= push.size) || b0 == 0) {
		return;
	}
	RWTexture2D<float4> zeroth = cn_rw_texture(push.moments_zeroth);
	RWTexture2D<float4> moment_sums = cn_rw_texture(push.moments);
	zeroth[pixel] = zeroth[pixel] + b0;
	moment_sums[pixel] = moment_sums[pixel] + moments;
}
