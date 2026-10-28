// What sprite_moments.hlsl and sprite_shade.hlsl share (see docs/rendering/transparency.md#sprites): their push
// constants, and the lookups of a pixel's opaque depth and of the sprites that sprite_bin.hlsl placed. Each defines
// MATERIAL_PUSH as Raster_Push before it includes this, and the frame's constants are the camera's.
#ifndef SPRITE_RASTER_HLSLI
#define SPRITE_RASTER_HLSLI

// Matches Raster_Push in lib/engine/render/sprites.odin. The moments pass writes moments_zeroth and moments; the shade
// pass reads them and writes accumulated. light_texel is one texel of the light textures, in UV.
struct Raster_Push {
	uint depth;
	uint screen;
	uint bins;
	uint words;
	uint tile_columns;
	uint records;
	uint records_offset;
	uint moments_zeroth;
	uint moments;
	uint accumulated;
	uint light;
	uint fog_light;
	uint light_sampler;
	uint padding;
	uint2 size;
	float2 light_texel;
};
#include "material_common.hlsli"
#include "moments.hlsli"
#include "sprites.hlsli"

// opaque_depth is the view depth of a pixel's opaque surface, from its reversed depth with the far plane at infinity.
float opaque_depth(uint2 pixel) {
	return frame.near / max(cn_texture(push.depth).Load(int3(pixel, 0)).r, 1e-7);
}

Screen_Sprite load_screen_sprite(uint index) {
	return cn_buffer(push.screen).Load<Screen_Sprite>(index * sizeof(Screen_Sprite));
}

#endif
