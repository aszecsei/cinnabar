// The sprites' tiles (see docs/rendering/transparency.md#sprites): a group for each tile of SPRITE_TILE pixels, which
// finds the farthest opaque depth in it, so sprite_bin.hlsl leaves out the sprites behind every opaque surface there,
// and clears the tile's bits.
#include "cinnabar.hlsli"
#include "sprites.hlsli"

// Matches Tiles_Push in lib/engine/render/sprites.odin. Each tile has words words of bits in bins.
struct Push {
	uint depth;
	uint tile_depths;
	uint bins;
	uint words;
	uint2 size;
	uint2 tiles;
};
CN_PUSH_CONSTANTS(Push, push);

// The smallest reversed depth in the tile, as its bits: depths are not negative, so their bits order as they do.
groupshared uint farthest;

// Each thread takes 4x4 pixels of the tile.
[numthreads(8, 8, 1)]
void cs_main(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID, uint index : SV_GroupIndex) {
	if (index == 0) {
		farthest = asuint(1.0f);
	}
	GroupMemoryBarrierWithGroupSync();
	Texture2D<float4> depth = cn_texture(push.depth);
	float nearest = 1;
	uint2 first = group.xy * SPRITE_TILE + thread.xy * 4;
	for (uint y = 0; y < 4; y++) {
		for (uint x = 0; x < 4; x++) {
			uint2 pixel = first + uint2(x, y);
			if (all(pixel < push.size)) {
				nearest = min(nearest, depth.Load(int3(pixel, 0)).r);
			}
		}
	}
	InterlockedMin(farthest, asuint(WaveActiveMin(nearest)));
	uint tile = group.y * push.tiles.x + group.x;
	RWByteAddressBuffer bins = cn_rw_buffer(push.bins);
	for (uint w = index; w < push.words; w += 64) {
		bins.Store((tile * push.words + w) * 4, 0);
	}
	GroupMemoryBarrierWithGroupSync();
	if (index == 0) {
		cn_rw_buffer(push.tile_depths).Store(tile * 4, farthest);
	}
}
