// The virtual shadow map's pages (see docs/rendering/lighting-and-shadows.md#virtual-shadow-maps), without the frame's
// constants, so the passes that cull a level's casters share them with the passes that draw it. Matches
// lib/engine/render/virtual_shadows.odin.
#ifndef VIRTUAL_PAGES_HLSLI
#define VIRTUAL_PAGES_HLSLI

#include "cinnabar.hlsli"

static const uint VIRTUAL_PAGE_TEXELS = 128;
static const uint VIRTUAL_PAGE_SHIFT = 7;
static const uint VIRTUAL_PAGES = 128;
static const uint VIRTUAL_SIZE = VIRTUAL_PAGE_TEXELS * VIRTUAL_PAGES;
static const uint VIRTUAL_NO_PAGE = ~0u;
// An entry of a page that the frame draws, which only the depth pass and its culling look for; the lookups take its
// physical page without the bit (see virtual_entry_page).
static const uint VIRTUAL_DRAW = 1u << 31;
// A level's request words, and the page table's entries.
static const uint VIRTUAL_LEVEL_PAGES = VIRTUAL_PAGES * VIRTUAL_PAGES;
static const uint VIRTUAL_LEVEL_WORDS = VIRTUAL_LEVEL_PAGES / 32;
// After the levels' entries, the table holds each level's count of the pages that the frame draws. Matches
// VIRTUAL_MAX_LEVELS and VIRTUAL_TABLE_COUNTS in lib/engine/render/virtual_shadows.odin.
static const uint VIRTUAL_MAX_LEVELS = 13;
static const uint VIRTUAL_TABLE_COUNTS = VIRTUAL_MAX_LEVELS * VIRTUAL_LEVEL_PAGES;
// The first level's page in meters. Matches VIRTUAL_FIRST_EXTENT in lib/engine/render/virtual_shadows.odin.
static const float VIRTUAL_FIRST_PAGE = 16.0 / VIRTUAL_PAGES;
// A sphere over more than this many pages on a side counts as reaching one, which is cheaper to draw than to test.
static const int VIRTUAL_CULL_PAGES = 8;

// virtual_table_slot is the byte offset of an absolute page's entry in its level's table, which is toroidal: a page's
// entry is at its absolute page modulo VIRTUAL_PAGES, so a page keeps its entry as the level's origin moves. Matches
// virtual_table_slot in lib/engine/render/virtual_shadows.odin.
uint virtual_table_slot(uint level, int2 page) {
	uint2 wrapped = uint2(page) & (VIRTUAL_PAGES - 1);
	return (level * VIRTUAL_LEVEL_PAGES + wrapped.y * VIRTUAL_PAGES + wrapped.x) * 4;
}

// virtual_table_entry is the byte offset of the entry of a level's page, by its place in a level whose first page is
// origin.
uint virtual_table_entry(uint level, int2 origin, int2 page) {
	return virtual_table_slot(level, origin + page);
}

// virtual_entry_page is a table entry's physical page, or VIRTUAL_NO_PAGE.
uint virtual_entry_page(uint entry) {
	return entry == VIRTUAL_NO_PAGE ? VIRTUAL_NO_PAGE : entry & ~VIRTUAL_DRAW;
}

// virtual_entry_draws is whether a table entry's page draws this frame.
bool virtual_entry_draws(uint entry) {
	return entry != VIRTUAL_NO_PAGE && (entry & VIRTUAL_DRAW) != 0;
}

// virtual_rect_draws is whether pages from low to high, by their places in a level whose first page is origin, have a
// page that the frame draws. A sphere over more than VIRTUAL_CULL_PAGES pages on a side counts as reaching one if the
// level draws any. Matches virtual_rect_draws in lib/engine/render/virtual_shadows.odin.
bool virtual_rect_draws(ByteAddressBuffer table, uint level, int2 origin, int2 low, int2 high) {
	low = max(low, 0);
	high = min(high, int(VIRTUAL_PAGES) - 1);
	if (any(low > high)) {
		return false;
	}
	if (any(high - low >= VIRTUAL_CULL_PAGES)) {
		return table.Load((VIRTUAL_TABLE_COUNTS + level) * 4) > 0;
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

// virtual_view_reaches_draws is whether a sphere relative to the camera reaches a page that the level of a culling view
// draws, from what Cull_View holds. The view's left and bottom planes are at its valid rectangle's low corner, along the
// level's axes, so a point's distances from them are its place in the rectangle, in meters. The fields are the table's
// read index plus 1, and the level with its rectangle's first page and its origin modulo the table's wrap: level |
// x << 4 | y << 11 | origin.x << 18 | origin.y << 25. Matches virtual_reaches_draws in
// lib/engine/render/virtual_shadows.odin.
bool virtual_view_reaches_draws(float4 planes[6], uint table_index, uint page_fields, float3 center, float radius) {
	uint level = page_fields & 0xf;
	float page = VIRTUAL_FIRST_PAGE * float(1u << level);
	float2 at = float2(dot(planes[0].xyz, center) + planes[0].w, dot(planes[3].xyz, center) + planes[3].w) / page;
	// A texel's margin, for the fragments whose centers are outside the sphere's texels.
	float reach = radius / page + 1.0 / VIRTUAL_PAGE_TEXELS;
	int2 first = int2((page_fields >> 4) & 0x7f, (page_fields >> 11) & 0x7f);
	int2 origin = int2((page_fields >> 18) & 0x7f, (page_fields >> 25) & 0x7f);
	return virtual_rect_draws(cn_buffer(table_index - 1), level, origin, first + int2(floor(at - reach)), first + int2(floor(at + reach)));
}

#endif
