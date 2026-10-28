// Compute sprites (see docs/rendering/transparency.md#sprites): camera-facing quads that compute passes rasterize into
// moment-based transparency, by screen tiles, in place of drawing them. The frame's sprites are records in one buffer,
// the CPU's first, then those that GPU passes append with append_sprite, with a counter of them all, and
// sprite_arguments.hlsl turns the count into the dispatches of the passes that run a thread or a group for each sprite.
// sprite_tiles.hlsl finds each tile's farthest opaque depth, sprite_bin.hlsl places each sprite on the screen and marks
// the tiles that it covers in front of that, sprite_light.hlsl lights an 8x8 grid of points on each, and
// sprite_moments.hlsl and sprite_shade.hlsl visit, at each pixel, the sprites of its tile: the first adds their optical
// depth and moments to the moments pass's, and the second adds their light, dimmed by what is in front of them, to the
// transparent pass's.
#ifndef SPRITES_HLSLI
#define SPRITES_HLSLI

// Match SPRITE_TILE, SPRITE_LIGHT_TEXELS, SPRITE_LIGHT_COLUMNS and SPRITE_NO_TEXTURE in lib/engine/render/sprites.odin.
// A tile is SPRITE_TILE pixels a side, so an 8x8 group of the raster passes is in one tile. A sprite's light is
// SPRITE_LIGHT_TEXELS texels a side in the light textures, which hold SPRITE_LIGHT_COLUMNS sprites a row.
static const uint SPRITE_TILE = 32;
static const uint SPRITE_LIGHT_TEXELS = 8;
static const uint SPRITE_LIGHT_COLUMNS = 128;
static const uint SPRITE_NO_TEXTURE = 0xffffffff;
// Matches MAX_SPRITES in lib/engine/render/sprites.odin: the records buffer's size, in sprites.
static const uint MAX_SPRITES = 65536;

// Matches Sprite_Record in lib/engine/render/sprites.odin: a sprite, with its position relative to the camera and its
// texture's bindless index, or SPRITE_NO_TEXTURE.
struct Sprite_Record {
	float3 position;
	float size;
	float4 color;
	float3 emission;
	float rotation;
	float4 uv_rect;
	uint texture;
	float softness;
	uint2 padding;
};

// Matches SCREEN_SPRITE_SIZE in lib/engine/render/sprites.odin: where sprite_bin.hlsl placed a sprite. center is in
// pixels, and axis is its rotation's cosine and sine over its radius in pixels (see sprite_quad). depth is its view
// depth, z that depth warped for the moments, and lod the mip level of its texture that matches its size on the screen.
struct Screen_Sprite {
	float2 center;
	float2 axis;
	float4 uv_rect;
	float depth;
	float z;
	float opacity;
	float softness;
	uint texture;
	float lod;
	uint2 padding;
};

Sprite_Record load_sprite(uint records, uint index) {
	return cn_buffer(records).Load<Sprite_Record>(index * sizeof(Sprite_Record));
}

// sprite_count is how many sprites the frame draws: those written, up to the frame's capacity, which sized its
// buffers.
uint sprite_count(uint count, uint capacity) {
	return min(cn_buffer(count).Load(0), capacity);
}

// append_sprite adds a sprite to the frame's records from a GPU pass, after the CPU's and the other passes'. A sprite past
// MAX_SPRITES is dropped, and one past the frame's capacity, which the passes reserved, is left out.
void append_sprite(uint records, uint count, Sprite_Record s) {
	uint index;
	cn_rw_buffer(count).InterlockedAdd(0, 1, index);
	if (index < MAX_SPRITES) {
		cn_rw_buffer(records).Store<Sprite_Record>(index * sizeof(Sprite_Record), s);
	}
}

// sprite_quad is where a pixel center is on a sprite: along the sprite's right and up, in [-1, 1] on the sprite.
float2 sprite_quad(Screen_Sprite s, float2 pixel) {
	float2 e = (pixel - s.center) * float2(1, -1);
	return float2(dot(e, s.axis), dot(e, float2(-s.axis.y, s.axis.x)));
}

// sprite_texel is a sprite's texture at a point of it: a tint in rgb and its coverage in a. Without a texture, a sprite
// is a soft round puff.
float4 sprite_texel(Screen_Sprite s, float2 q, uint sampler_index) {
	if (s.texture == SPRITE_NO_TEXTURE) {
		float c = saturate(1 - dot(q, q));
		return float4(1, 1, 1, c * c);
	}
	float2 uv = s.uv_rect.xy + (float2(q.x, -q.y) * 0.5 + 0.5) * s.uv_rect.zw;
	return cn_texture(s.texture).SampleLevel(cn_sampler(sampler_index), uv, s.lod);
}

// sprite_alpha is a sprite's opacity at a point of it, faded where it nears the opaque surface behind it.
float sprite_alpha(Screen_Sprite s, float4 texel, float opaque_depth) {
	float alpha = texel.a * s.opacity;
	if (s.softness > 0) {
		alpha *= saturate((opaque_depth - s.depth) / s.softness);
	}
	return saturate(alpha);
}

// sprite_tile is the tile of an 8x8 group of the raster passes.
uint sprite_tile(uint2 group, uint columns) {
	uint2 tile = group / (SPRITE_TILE / 8);
	return tile.y * columns + tile.x;
}

// sprite_light_uv is where a point of a sprite is in the light textures: in its own block, kept half a texel inside it,
// so the bilinear lookup never reads a neighbour's.
float2 sprite_light_uv(uint index, float2 q, float2 texel_size) {
	float2 block = float2(index % SPRITE_LIGHT_COLUMNS, index / SPRITE_LIGHT_COLUMNS) * SPRITE_LIGHT_TEXELS;
	float2 t = clamp((q * 0.5 + 0.5) * SPRITE_LIGHT_TEXELS, 0.5, SPRITE_LIGHT_TEXELS - 0.5);
	return (block + t) * texel_size;
}

#endif
