// The sprites' binning (see docs/rendering/transparency.md#sprites): a thread for each sprite, which places it on the
// screen with the camera's jittered projection, and sets its bit in every tile that its square covers where it is in
// front of the tile's farthest opaque surface. A sprite behind the near plane, or under a hundredth of a pixel, sets
// none.
#define MATERIAL_PUSH Bin_Push
// Matches Bin_Push in lib/engine/render/sprites.odin. count is the sprites' counter, and capacity the most that the
// frame draws. scale is the projection's x and y scales.
struct Bin_Push {
	uint records;
	uint count;
	uint capacity;
	uint screen;
	uint tile_depths;
	uint bins;
	uint words;
	uint padding;
	uint2 tiles;
	float2 scale;
};
#include "material_common.hlsli"
#include "moments.hlsli"
#include "sprites.hlsli"

[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint index = id.x;
	if (index >= sprite_count(push.count, push.capacity)) {
		return;
	}
	Sprite_Record r = load_sprite(push.records, index);
	float4 clip = mul(frame.view_projection, float4(r.position, 1));
	float depth = clip.w;
	if (depth <= frame.near) {
		return;
	}
	float2 center = (clip.xy / depth * float2(0.5, -0.5) + 0.5) * frame.screen_size;
	float radius = r.size * push.scale.y * 0.5 * frame.screen_size.y / depth;
	if (radius < 0.01) {
		return;
	}
	float2 rotation = float2(cos(r.rotation), sin(r.rotation));
	// The rotated square's bounds.
	float extent = radius * (abs(rotation.x) + abs(rotation.y));
	int2 low = int2(floor((center - extent) / SPRITE_TILE));
	int2 high = int2(floor((center + extent) / SPRITE_TILE));
	if (any(high < 0) || any(low >= int2(push.tiles))) {
		return;
	}
	low = max(low, 0);
	high = min(high, int2(push.tiles) - 1);

	Screen_Sprite s;
	s.center = center;
	s.axis = rotation / radius;
	s.uv_rect = r.uv_rect;
	s.depth = depth;
	s.z = warp_depth(depth, frame.near);
	s.opacity = r.color.a;
	s.softness = r.softness;
	s.texture = r.texture;
	s.lod = 0;
	if (r.texture != SPRITE_NO_TEXTURE) {
		uint2 size;
		cn_texture(r.texture).GetDimensions(size.x, size.y);
		float texels = max(size.x * r.uv_rect.z, size.y * r.uv_rect.w);
		s.lod = max(log2(texels / (2 * radius)), 0);
	}
	s.padding = 0;
	cn_rw_buffer(push.screen).Store<Screen_Sprite>(index * sizeof(Screen_Sprite), s);

	ByteAddressBuffer tile_depths = cn_buffer(push.tile_depths);
	RWByteAddressBuffer bins = cn_rw_buffer(push.bins);
	float nearest = depth - r.size;
	uint bit = 1u << (index % 32);
	for (int y = low.y; y <= high.y; y++) {
		for (int x = low.x; x <= high.x; x++) {
			uint tile = uint(y) * push.tiles.x + uint(x);
			float farthest = frame.near / max(tile_depths.Load<float>(tile * 4), 1e-7);
			if (nearest < farthest) {
				bins.InterlockedOr((tile * push.words + index / 32) * 4, bit);
			}
		}
	}
}
