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
// A level's request words, and the page table's entries.
static const uint VIRTUAL_LEVEL_PAGES = VIRTUAL_PAGES * VIRTUAL_PAGES;
static const uint VIRTUAL_LEVEL_WORDS = VIRTUAL_LEVEL_PAGES / 32;
// The first level's page in meters. Matches VIRTUAL_FIRST_EXTENT in lib/engine/render/virtual_shadows.odin.
static const float VIRTUAL_FIRST_PAGE = 16.0 / VIRTUAL_PAGES;
// A sphere over more than this many pages on a side counts as reaching one, which is cheaper to draw than to test.
static const int VIRTUAL_CULL_PAGES = 8;

uint virtual_table_entry(uint level, uint2 page) {
	return (level * VIRTUAL_LEVEL_PAGES + page.y * VIRTUAL_PAGES + page.x) * 4;
}

// virtual_rect_has_pages is whether pages from low to high have a physical page in a level. Matches
// virtual_rect_has_pages in lib/engine/render/virtual_shadows.odin.
bool virtual_rect_has_pages(ByteAddressBuffer table, uint level, int2 low, int2 high) {
	low = max(low, 0);
	high = min(high, int(VIRTUAL_PAGES) - 1);
	if (any(low > high)) {
		return false;
	}
	if (any(high - low >= VIRTUAL_CULL_PAGES)) {
		return true;
	}
	for (int y = low.y; y <= high.y; y++) {
		for (int x = low.x; x <= high.x; x++) {
			if (table.Load(virtual_table_entry(level, uint2(x, y))) != VIRTUAL_NO_PAGE) {
				return true;
			}
		}
	}
	return false;
}

// virtual_view_reaches_pages is whether a sphere relative to the camera reaches a page of the level of a culling view,
// from what Cull_View holds. The view's left and bottom planes are at its valid rectangle's low corner, along the level's
// axes, so a point's distances from them are its place in the rectangle, in meters. The fields are the table's read index
// plus 1, and the level with its rectangle's first page: level | x << 8 | y << 16. Matches virtual_reaches_pages in
// lib/engine/render/virtual_shadows.odin.
bool virtual_view_reaches_pages(float4 planes[6], uint table_index, uint page_fields, float3 center, float radius) {
	uint level = page_fields & 0xff;
	float page = VIRTUAL_FIRST_PAGE * float(1u << level);
	float2 at = float2(dot(planes[0].xyz, center) + planes[0].w, dot(planes[3].xyz, center) + planes[3].w) / page;
	// A texel's margin, for the fragments whose centers are outside the sphere's texels.
	float reach = radius / page + 1.0 / VIRTUAL_PAGE_TEXELS;
	int2 first = int2((page_fields >> 8) & 0xff, (page_fields >> 16) & 0xff);
	return virtual_rect_has_pages(cn_buffer(table_index - 1), level, first + int2(floor(at - reach)), first + int2(floor(at + reach)));
}

#endif
