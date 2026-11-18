// Walks each patch surface's quadtree from the camera (see docs/rendering/surfaces.md#surfaces), one group a surface: a
// node splits while it is nearer the camera than the next finer level's range, a node outside the surface's rectangle
// is dropped, and the rest are the patches that every view draws this frame, which cull_patches.hlsl tests. The walk
// goes level by level through two queues in group memory, so it is bounded by MAX_SURFACE_PATCHES: a node that the
// queue cannot hold draws as it is.
//
// The virtual shadow map's levels take a walk of their own, once the page table is written (shadow_levels above 0): a
// node splits while its child's cell is more than SURFACE_CELL_PIXELS texels of the finest level whose drawn pages the
// node's box, grown by its own size, reaches, so the cut does not depend on the camera. The grown box keeps the tree 2:1
// balanced, and each emitted patch carries 4 bits, one for each edge whose neighbour is coarser, which its vertices
// snap to (see docs/rendering/surfaces.md#shadows).
#include "cinnabar.hlsli"
#include "virtual_pages.hlsli"

// Matches Cull_Constants in lib/engine/render/scene.odin.
struct Cull_Constants {
	uint item_count;
	uint items;
	uint items_offset;
	uint instances;
	uint arguments;
	uint draws;
	uint counts;
	uint bin_offsets;
	uint bin_offsets_offset;
	uint views;
	uint views_offset;
	uint bin_count;
	uint mesh_arguments;
	uint surfaces;
	uint surfaces_offset;
	uint surface_count;
	uint patches;
	uint patch_counts;
	uint patches_read;
	uint patch_counts_read;
	float4 camera;
	float lod_scale;
	float lod_near;
	uint instance_counters;
	uint instance_views;
	uint instance_ranges;
	uint occlusion;
	uint occlusion_offset;
	uint view_first;
	uint stats;
	uint selections;
	uint view_skip;
	uint shadow_levels;
};
CN_PASS_CONSTANTS(Cull_Constants, cull);

// Match lib/engine/render/surfaces.odin.
#define MAX_SURFACE_PATCHES 2048
#define SURFACE_GROUP_SIZE 256
#define SURFACE_PATCH_QUADS 16
// How many texels a child's cell may cover in the virtual shadow map's walk.
#define SURFACE_CELL_PIXELS 8
// A patch's edge bits are above its level: bit i is set when the neighbour across edge i is coarser, for -x, +x, -z, +z.
#define SURFACE_EDGE_SHIFT 28

// Matches Surface_Record in lib/engine/render/surfaces.odin.
struct Surface_Record {
	float2 size;
	float cell;
	uint levels;
	float2 root_origin;
	float root_size;
	float range0;
	float3 camera_local;
	uint hole_mask;
	float2 height_range;
	float bound;
	uint item;
	uint4 padding;
};

// Matches Cull_View in cull_draws.hlsl.
struct Cull_View {
	float4 planes[6];
	float4 offset;
	uint first_draw;
	uint flags;
	uint virtual_table;
	uint virtual_page;
};

// Match Item and Instance_Record in cull_patches.hlsl.
struct Item {
	uint instance;
	uint mesh;
	uint first;
	uint count;
	uint material;
	uint bin;
	uint flags;
	uint submesh;
	float4 sphere;
	float bound;
	float impostor_error;
	uint2 padding;
	float4 lod_sphere;
};

struct Instance_Record {
	float4 rows[3];
	float4 previous_rows[3];
	uint id;
	uint flags;
	uint2 padding;
	float4 tint;
};

groupshared uint queue[2][MAX_SURFACE_PATCHES];
groupshared uint queue_count[2];
groupshared uint emitted;
// A bit for each tile of 8 by 8 pages of each level of the virtual shadow map, set when the tile has a page that the frame
// draws, so a box over many pages tests its tiles in place of its pages.
static const uint TILE_PAGES = 8;
static const uint TILES_WIDE = VIRTUAL_PAGES / TILE_PAGES;
static const uint TILE_WORDS = TILES_WIDE * TILES_WIDE / 32;
groupshared uint drawn_tiles[VIRTUAL_MAX_LEVELS * TILE_WORDS];

// A patch, as material_patch.hlsli unpacks it: its column, its row and its level.
uint pack_patch(uint x, uint y, uint level) {
	return x | y << 12 | level << 24;
}

// The surface as the virtual shadow map's walk sees it: its instance's rows, the largest scale of their axes, and the
// item's displacement bound.
struct Shadow_Surface {
	float4 rows[3];
	float scale;
	float bound;
};

// level_origin is a level's origin modulo the table's wrap, from its page fields.
int2 level_origin(uint fields) {
	return int2((fields >> 18) & 0x7f, (fields >> 25) & 0x7f);
}

// build_drawn_tiles sets drawn_tiles, a work item for each tile of each level, shared by the group's threads. Every
// thread calls it.
void build_drawn_tiles(uint thread) {
	for (uint i = thread; i < VIRTUAL_MAX_LEVELS * TILE_WORDS; i += SURFACE_GROUP_SIZE) {
		drawn_tiles[i] = 0;
	}
	GroupMemoryBarrierWithGroupSync();
	for (uint item = thread; item < cull.shadow_levels * TILES_WIDE * TILES_WIDE; item += SURFACE_GROUP_SIZE) {
		uint level = item / (TILES_WIDE * TILES_WIDE);
		uint tile = item % (TILES_WIDE * TILES_WIDE);
		Cull_View view = cn_buffer(cull.views).Load<Cull_View>(cull.views_offset + (cull.view_first + level) * sizeof(Cull_View));
		ByteAddressBuffer table = cn_buffer(view.virtual_table - 1);
		if (table.Load((VIRTUAL_TABLE_COUNTS + level) * 4) == 0) {
			continue;
		}
		int2 origin = level_origin(view.virtual_page);
		int2 low = int2(tile % TILES_WIDE, tile / TILES_WIDE) * TILE_PAGES;
		bool drawn = false;
		for (int y = 0; y < int(TILE_PAGES) && !drawn; y++) {
			for (int x = 0; x < int(TILE_PAGES) && !drawn; x++) {
				drawn = virtual_entry_draws(table.Load(virtual_table_entry(level, origin, low + int2(x, y))));
			}
		}
		if (drawn) {
			uint ignored;
			InterlockedOr(drawn_tiles[level * TILE_WORDS + tile / 32], 1u << (tile % 32), ignored);
		}
	}
	GroupMemoryBarrierWithGroupSync();
}

// tiles_draw is whether the tiles over pages from low to high, which are in the level's valid rectangle, have a page that
// the frame draws.
bool tiles_draw(uint level, int2 low, int2 high) {
	for (int ty = low.y / int(TILE_PAGES); ty <= high.y / int(TILE_PAGES); ty++) {
		for (int tx = low.x / int(TILE_PAGES); tx <= high.x / int(TILE_PAGES); tx++) {
			uint tile = uint(ty) * TILES_WIDE + uint(tx);
			if ((drawn_tiles[level * TILE_WORDS + tile / 32] & (1u << (tile % 32))) != 0) {
				return true;
			}
		}
	}
	return false;
}

// shadow_rect_draws is whether pages from low to high of a level have a page that the frame draws: its pages, when the
// rectangle spans fewer than VIRTUAL_CULL_PAGES on each side, and its tiles of pages when it spans more. Matches
// surface_rect_draws in lib/engine/render/surfaces.odin.
bool shadow_rect_draws(ByteAddressBuffer table, uint level, int2 origin, int2 low, int2 high) {
	low = max(low, 0);
	high = min(high, int(VIRTUAL_PAGES) - 1);
	if (any(low > high)) {
		return false;
	}
	if (any(high - low >= VIRTUAL_CULL_PAGES)) {
		return tiles_draw(level, low, high);
	}
	for (int y = low.y; y <= high.y; y++) {
		for (int x = low.x; x <= high.x; x++) {
			if (virtual_entry_draws(table.Load(virtual_table_entry(level, origin, int2(x, y))))) {
				return true;
			}
		}
	}
	return false;
}

// shadow_box_texel is the texel in meters of the finest level whose drawn pages a box of the surface reaches, or 0 when
// it reaches none: the box over a square of the surface's plane and between its heights, as the pages' own axes see it,
// with the displacement bound. A coarser level's texel is larger, so the finest holds every level's. The box's extent
// along a level's axes is exact, so a box inside another reaches no finer level than it does. Matches
// surface_box_texel in lib/engine/render/surfaces.odin.
float shadow_box_texel(Surface_Record s, Shadow_Surface sh, float2 center, float half_size) {
	float4 local = float4(center.x, (s.height_range.x + s.height_range.y) * 0.5, center.y, 1);
	float3 extent = float3(half_size, (s.height_range.y - s.height_range.x) * 0.5, half_size);
	float3 world = float3(dot(sh.rows[0], local), dot(sh.rows[1], local), dot(sh.rows[2], local));
	float3 axis_x = float3(sh.rows[0].x, sh.rows[1].x, sh.rows[2].x);
	float3 axis_y = float3(sh.rows[0].y, sh.rows[1].y, sh.rows[2].y);
	float3 axis_z = float3(sh.rows[0].z, sh.rows[1].z, sh.rows[2].z);
	for (uint level = 0; level < cull.shadow_levels; level++) {
		Cull_View view = cn_buffer(cull.views).Load<Cull_View>(cull.views_offset + (cull.view_first + level) * sizeof(Cull_View));
		float3 n0 = view.planes[0].xyz;
		float3 n1 = view.planes[3].xyz;
		float3 relative = world - view.offset.xyz;
		float page = VIRTUAL_FIRST_PAGE * float(1u << level);
		float2 at = float2(dot(n0, relative) + view.planes[0].w, dot(n1, relative) + view.planes[3].w) / page;
		float2 along = float2(dot(abs(float3(dot(n0, axis_x), dot(n0, axis_y), dot(n0, axis_z))), extent), dot(abs(float3(dot(n1, axis_x), dot(n1, axis_y), dot(n1, axis_z))), extent));
		float2 reach = (along + sh.bound) / page + 1.0 / VIRTUAL_PAGE_TEXELS;
		uint fields = view.virtual_page;
		int2 first = int2((fields >> 4) & 0x7f, (fields >> 11) & 0x7f);
		int2 origin = level_origin(fields);
		if (shadow_rect_draws(cn_buffer(view.virtual_table - 1), level, origin, first + int2(floor(at - reach)), first + int2(floor(at + reach)))) {
			return page / VIRTUAL_PAGE_TEXELS;
		}
	}
	return 0;
}

// shadow_splits is whether a node splits in the virtual shadow map's walk: its child's cell, in the world, covers more
// than SURFACE_CELL_PIXELS texels of the finest level that the node's box, grown by its size on each side, reaches. A
// node that reaches no page does not split. Matches surface_shadow_splits in lib/engine/render/surfaces.odin.
bool shadow_splits(Surface_Record s, Shadow_Surface sh, uint2 xy, uint level) {
	if (level == 0) {
		return false;
	}
	float size = s.cell * SURFACE_PATCH_QUADS * float(1u << level);
	float2 center = s.root_origin + (float2(xy) + 0.5) * size;
	float texel = shadow_box_texel(s, sh, center, size * 1.5);
	float child = s.cell * float(1u << (level - 1)) * sh.scale;
	return texel > 0 && child > SURFACE_CELL_PIXELS * texel;
}

// node_in_rectangle is whether a node of a level overlaps the surface's rectangle.
bool node_in_rectangle(Surface_Record s, int2 xy, uint level) {
	float size = s.cell * SURFACE_PATCH_QUADS * float(1u << level);
	float2 lo = s.root_origin + float2(xy) * size;
	float2 hi = lo + size;
	float2 half_size = s.size * 0.5;
	return !(hi.x <= -half_size.x || hi.y <= -half_size.y || lo.x >= half_size.x || lo.y >= half_size.y);
}

// shadow_edges are a node's edge bits: bit i is set when the neighbour across edge i is a leaf of the next coarser
// level. The tree is balanced, so a coarser neighbour is its parent's neighbour, and it is a leaf when it does not
// split. Matches surface_shadow_edges in lib/engine/render/surfaces.odin.
uint shadow_edges(Surface_Record s, Shadow_Surface sh, uint2 xy, uint level) {
	if (level + 1 >= s.levels) {
		return 0;
	}
	int grid = int(1u << (s.levels - 1 - level));
	static const int2 DIRECTIONS[4] = {int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1)};
	uint edges = 0;
	for (uint i = 0; i < 4; i++) {
		int2 n = int2(xy) + DIRECTIONS[i];
		if (any(n < 0) || any(n >= grid)) {
			continue;
		}
		int2 parent = n >> 1;
		if (all(parent == int2(xy >> 1)) || !node_in_rectangle(s, parent, level + 1)) {
			continue;
		}
		if (!shadow_splits(s, sh, uint2(parent), level + 1)) {
			edges |= 1u << i;
		}
	}
	return edges;
}

[numthreads(SURFACE_GROUP_SIZE, 1, 1)]
void cs_main(uint group : SV_GroupID, uint thread : SV_GroupIndex) {
	Surface_Record s = cn_buffer(cull.surfaces).Load<Surface_Record>(cull.surfaces_offset + group * sizeof(Surface_Record));
	if (thread == 0) {
		queue[0][0] = pack_patch(0, 0, s.levels - 1);
		queue_count[0] = 1;
		queue_count[1] = 0;
		emitted = 0;
	}
	GroupMemoryBarrierWithGroupSync();
	float2 half_size = s.size * 0.5;
	bool shadow = cull.shadow_levels > 0;
	Shadow_Surface sh = (Shadow_Surface)0;
	if (shadow) {
		build_drawn_tiles(thread);
		Item item = cn_buffer(cull.items).Load<Item>(cull.items_offset + s.item * sizeof(Item));
		Instance_Record instance = cn_buffer(cull.instances).Load<Instance_Record>(item.instance * sizeof(Instance_Record));
		sh.rows = instance.rows;
		float3 scales = instance.rows[0].xyz * instance.rows[0].xyz + instance.rows[1].xyz * instance.rows[1].xyz + instance.rows[2].xyz * instance.rows[2].xyz;
		sh.scale = sqrt(max(scales.x, max(scales.y, scales.z)));
		sh.bound = item.bound;
	}
	for (int level = int(s.levels) - 1; level >= 0; level--) {
		uint in_queue = uint(int(s.levels) - 1 - level) & 1;
		uint out_queue = in_queue ^ 1;
		uint count = min(queue_count[in_queue], MAX_SURFACE_PATCHES);
		for (uint i = thread; i < count; i += SURFACE_GROUP_SIZE) {
			uint node = queue[in_queue][i];
			uint2 xy = uint2(node & 0xfff, (node >> 12) & 0xfff);
			float size = s.cell * SURFACE_PATCH_QUADS * float(1u << uint(level));
			float2 lo = s.root_origin + float2(xy) * size;
			float2 hi = lo + size;
			if (hi.x <= -half_size.x || hi.y <= -half_size.y || lo.x >= half_size.x || lo.y >= half_size.y) {
				continue;
			}
			bool split;
			if (shadow) {
				// A node that reaches no page that the levels draw is not drawn.
				if (shadow_box_texel(s, sh, (lo + hi) * 0.5, size * 0.5) == 0) {
					continue;
				}
				split = shadow_splits(s, sh, xy, uint(level));
			} else {
				// The distance to the node's box: its square, between the surface's heights.
				float3 nearest = float3(clamp(s.camera_local.x, lo.x, hi.x), clamp(s.camera_local.y, s.height_range.x, s.height_range.y), clamp(s.camera_local.z, lo.y, hi.y));
				float d = distance(s.camera_local, nearest);
				split = level > 0 && d < s.range0 * float(1u << uint(level - 1));
			}
			if (split) {
				uint slot;
				InterlockedAdd(queue_count[out_queue], 4, slot);
				if (slot + 4 <= MAX_SURFACE_PATCHES) {
					queue[out_queue][slot] = pack_patch(2 * xy.x, 2 * xy.y, uint(level - 1));
					queue[out_queue][slot + 1] = pack_patch(2 * xy.x + 1, 2 * xy.y, uint(level - 1));
					queue[out_queue][slot + 2] = pack_patch(2 * xy.x, 2 * xy.y + 1, uint(level - 1));
					queue[out_queue][slot + 3] = pack_patch(2 * xy.x + 1, 2 * xy.y + 1, uint(level - 1));
				} else {
					split = false;
				}
			}
			if (!split) {
				uint e;
				InterlockedAdd(emitted, 1, e);
				if (e < MAX_SURFACE_PATCHES) {
					uint edges = shadow ? shadow_edges(s, sh, xy, uint(level)) : 0;
					cn_rw_buffer(cull.patches).Store((group * MAX_SURFACE_PATCHES + e) * 4, node | edges << SURFACE_EDGE_SHIFT);
				}
			}
		}
		GroupMemoryBarrierWithGroupSync();
		if (thread == 0) {
			queue_count[in_queue] = 0;
		}
		GroupMemoryBarrierWithGroupSync();
	}
	if (thread == 0) {
		cn_rw_buffer(cull.patch_counts).Store(group * 4, min(emitted, MAX_SURFACE_PATCHES));
	}
}
