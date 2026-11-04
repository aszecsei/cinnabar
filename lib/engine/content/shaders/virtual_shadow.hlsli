// The virtual shadow map's lookups (see docs/rendering/lighting-and-shadows.md#virtual-shadow-maps): a directional
// light's clipmap levels, each a virtual texture of VIRTUAL_PAGES pages on a side, whose pages have physical pages in
// one pool through a page table. The marking, the depth pass and the lights all pick levels and pages here, so they
// agree. Levels are the first shadow views. Matches lib/engine/render/virtual_shadows.odin.
#ifndef VIRTUAL_SHADOW_HLSLI
#define VIRTUAL_SHADOW_HLSLI

#include "material_common.hlsli"

static const uint VIRTUAL_PAGE_TEXELS = 128;
static const uint VIRTUAL_PAGE_SHIFT = 7;
static const uint VIRTUAL_PAGES = 128;
static const uint VIRTUAL_SIZE = VIRTUAL_PAGE_TEXELS * VIRTUAL_PAGES;
static const uint VIRTUAL_NO_PAGE = ~0u;
// A level's request words, and the page table's entries.
static const uint VIRTUAL_LEVEL_PAGES = VIRTUAL_PAGES * VIRTUAL_PAGES;
static const uint VIRTUAL_LEVEL_WORDS = VIRTUAL_LEVEL_PAGES / 32;
// Match SHADOW_DEPTH_BIAS and SHADOW_SLOPE_BIAS in lib/engine/render/shadows.odin, which a pipeline with a depth
// attachment applies itself.
static const float VIRTUAL_DEPTH_BIAS = -64;
static const float VIRTUAL_SLOPE_BIAS = -2;

Shadow_View virtual_view(uint level) {
	return cn_buffer(frame.shadow_views).Load<Shadow_View>(frame.shadow_views_offset + level * sizeof(Shadow_View));
}

// virtual_footprint_level is the level whose texel is nearest a pixel's footprint at a distance from the camera, with
// the quality's bias. Only the distance counts, so turning the camera changes no point's level. Matches
// virtual_footprint_level in virtual_shadows.odin.
uint virtual_footprint_level(float distance) {
	float level = floor(log2(max(distance * frame.virtual_pixel_angle / frame.virtual_first_texel, 1e-6)) + frame.virtual_bias + 0.5);
	return uint(clamp(level, 0, float(frame.virtual_levels) - 1));
}

// A level's position: the XY of its clip space as virtual texels, and its depth.
float3 virtual_project(Shadow_View view, float3 p) {
	float4 v = float4(p, 1);
	float2 ndc = float2(dot(view.rows[0], v), dot(view.rows[1], v));
	return float3((ndc * float2(0.5, -0.5) + 0.5) * float(VIRTUAL_SIZE), dot(view.rows[2], v));
}

// Virtual_Block is the texels of one lookup, which frame.shadow_filter gives: the same weights as 1, 4 or 9 bilinear
// comparisons, over 2x2, 3x3 or 4x4 texels. Matches virtual_block in virtual_shadows.odin.
struct Virtual_Block {
	int2 base;
	int size;
	float4 weights_x;
	float4 weights_y;
};

Virtual_Block virtual_block(float2 texel) {
	Virtual_Block b;
	if (frame.shadow_filter == 4) {
		float2 i = floor(texel);
		float2 f = texel - i;
		b.base = int2(i) - 1;
		b.size = 3;
		b.weights_x = float4(1 - f.x, 1, f.x, 0) * 0.5;
		b.weights_y = float4(1 - f.y, 1, f.y, 0) * 0.5;
		return b;
	}
	float2 i = floor(texel - 0.5);
	float2 f = texel - 0.5 - i;
	if (frame.shadow_filter == 9) {
		b.base = int2(i) - 1;
		b.size = 4;
		b.weights_x = float4(1 - f.x, 1, 1, f.x) / 3;
		b.weights_y = float4(1 - f.y, 1, 1, f.y) / 3;
	} else {
		b.base = int2(i);
		b.size = 2;
		b.weights_x = float4(1 - f.x, f.x, 0, 0);
		b.weights_y = float4(1 - f.y, f.y, 0, 0);
	}
	return b;
}

// virtual_in_rect is whether texels from low to high are in a level's valid rectangle, the only part of it that draws.
bool virtual_in_rect(Shadow_View view, int2 low, int2 high) {
	float2 lower = view.rect.xy * float(VIRTUAL_SIZE);
	float2 upper = view.rect.zw * float(VIRTUAL_SIZE);
	return all(float2(low) >= lower) && all(float2(high) < upper);
}

uint virtual_table_entry(uint level, uint2 page) {
	return (level * VIRTUAL_LEVEL_PAGES + page.y * VIRTUAL_PAGES + page.x) * 4;
}

// virtual_physical is the texel of the pool that a physical page's corner is at.
uint2 virtual_physical(uint page) {
	return uint2(page % frame.virtual_pool_pages_per_row, page / frame.virtual_pool_pages_per_row) * VIRTUAL_PAGE_TEXELS;
}

// virtual_sphere_has_pages is whether a sphere relative to the camera reaches a page of the level that this view draws.
// Near a view's camera, most of a coarser level's casters are over no page, so the depth pass culls them here. A sphere
// over more than VIRTUAL_CULL_PAGES pages on a side counts as reaching one, which is cheaper to draw than to test.
static const int VIRTUAL_CULL_PAGES = 8;
bool virtual_sphere_has_pages(float3 center, float radius) {
	Shadow_View view = virtual_view(frame.virtual_level);
	float2 texel = virtual_project(view, center).xy;
	float reach = radius / view.texel + 1;
	int2 low = max(int2(floor(texel - reach)) >> VIRTUAL_PAGE_SHIFT, 0);
	int2 high = min(int2(ceil(texel + reach)) >> VIRTUAL_PAGE_SHIFT, int(VIRTUAL_PAGES) - 1);
	if (any(high - low >= VIRTUAL_CULL_PAGES)) {
		return true;
	}
	ByteAddressBuffer table = cn_buffer(frame.virtual_table);
	for (int y = low.y; y <= high.y; y++) {
		for (int x = low.x; x <= high.x; x++) {
			if (table.Load(virtual_table_entry(frame.virtual_level, uint2(x, y))) != VIRTUAL_NO_PAGE) {
				return true;
			}
		}
	}
	return false;
}

// virtual_quad_has_page is whether a fragment's 2x2 quad has a fragment on a page of the level that this view draws, so a
// fragment whose search for its surface costs more than this can leave first.
bool virtual_quad_has_page(float2 pixel) {
	uint page = cn_buffer(frame.virtual_table).Load(virtual_table_entry(frame.virtual_level, uint2(pixel) >> VIRTUAL_PAGE_SHIFT));
	uint has_page = page != VIRTUAL_NO_PAGE ? 1 : 0;
	return (has_page | QuadReadAcrossX(has_page) | QuadReadAcrossY(has_page) | QuadReadAcrossDiagonal(has_page)) != 0;
}

// Virtual_Write is a fragment's write to the pool: the pool's texel, and the depth.
struct Virtual_Write {
	bool wanted;
	uint2 texel;
	float depth;
};

// virtual_test is what a fragment would write to its level's page. It is not wanted if the page does not exist, or if a
// nearer depth is there already, so a fragment that is not wanted need not run the material. A pass with no depth
// attachment has no pipeline bias, so this applies it, and clamps depth as the cascades' pipelines do, so casters
// between the light and the view still cast. Depth is reversed, so the nearest to the light is the largest.
Virtual_Write virtual_test(float2 pixel, float z, float slope) {
	Virtual_Write w = (Virtual_Write)0;
	uint2 texel = uint2(pixel);
	uint page = cn_buffer(frame.virtual_table).Load(virtual_table_entry(frame.virtual_level, texel >> VIRTUAL_PAGE_SHIFT));
	if (page == VIRTUAL_NO_PAGE) {
		return w;
	}
	// The unit of a 32-bit float at z, as a depth bias's constant is in.
	float unit = z > 0 ? exp2(floor(log2(z)) - 23) : 0;
	w.depth = saturate(z + VIRTUAL_DEPTH_BIAS * unit + VIRTUAL_SLOPE_BIAS * slope);
	w.texel = virtual_physical(page) + (texel & (VIRTUAL_PAGE_TEXELS - 1));
	RWTexture2D<uint> pool = cn_rw_uint_texture(frame.virtual_pool_storage);
	w.wanted = asuint(w.depth) > pool[w.texel];
	return w;
}

// virtual_write writes a fragment's depth, and keeps the nearest to the light. The bits of a float that is not negative
// order as the float does.
void virtual_write(Virtual_Write w) {
	if (w.wanted) {
		RWTexture2D<uint> pool = cn_rw_uint_texture(frame.virtual_pool_storage);
		uint previous;
		InterlockedMax(pool[w.texel], asuint(w.depth), previous);
	}
}

// virtual_quad_wanted is whether a fragment's 2x2 quad has a fragment that is wanted. A material's texture lookups take
// derivatives across the quad, so a quad's lanes run the material or leave together.
bool virtual_quad_wanted(Virtual_Write w) {
	uint wanted = w.wanted ? 1 : 0;
	return (wanted | QuadReadAcrossX(wanted) | QuadReadAcrossY(wanted) | QuadReadAcrossDiagonal(wanted)) != 0;
}

// Virtual_Hit is what a lookup found: the level, the depth of the point in it, its block of texels, the physical pages at
// the block's corners, VIRTUAL_NO_PAGE for one that has none, and the page that holds the point.
struct Virtual_Hit {
	uint level;
	float z;
	Virtual_Block block;
	uint pages[4];
	int2 center;
	uint center_page;
};

// virtual_block_page is a page's entry in a level's table, or VIRTUAL_NO_PAGE outside the level.
uint virtual_block_page(ByteAddressBuffer table, uint level, int2 page) {
	if (any(page < 0) || any(page >= int(VIRTUAL_PAGES))) {
		return VIRTUAL_NO_PAGE;
	}
	return table.Load(virtual_table_entry(level, uint2(page)));
}

// virtual_find finds the finest level from the point's footprint on that has the page that holds the point. A level
// without it leaves the point to the next coarser level, so a pool that runs out costs detail and not shadows. Marks
// propagate only to the parents of the pages that hold each point, so that page exists in every coarser level, but a
// block across the coarser level's page line may reach a page that does not, and virtual_shadow keeps such a block's
// texels in the point's page. The block is at the point as shadow_map offsets it (see there), by the level's texel.
// Matches virtual_lookup in virtual_shadows.odin.
bool virtual_find(float3 p, float3 normal, float3 to_light, out Virtual_Hit hit) {
	float cos_light = dot(normal, to_light);
	float sin_light = sqrt(saturate(1 - cos_light * cos_light));
	hit = (Virtual_Hit)0;
	ByteAddressBuffer table = cn_buffer(frame.virtual_table);
	for (uint level = virtual_footprint_level(length(p)); level < frame.virtual_levels; level++) {
		Shadow_View view = virtual_view(level);
		int2 texel = int2(floor(virtual_project(view, p).xy));
		if (!virtual_in_rect(view, texel, texel)) {
			continue;
		}
		int2 center = texel >> VIRTUAL_PAGE_SHIFT;
		uint center_page = virtual_block_page(table, level, center);
		if (center_page == VIRTUAL_NO_PAGE) {
			continue;
		}
		float3 at = virtual_project(view, p + to_light * (view.texel * 0.5) + normal * (view.texel * 0.5 * sin_light));
		hit.level = level;
		hit.z = at.z;
		hit.block = virtual_block(at.xy);
		hit.center = center;
		hit.center_page = center_page;
		int2 low = hit.block.base >> VIRTUAL_PAGE_SHIFT;
		int2 high = (hit.block.base + hit.block.size - 1) >> VIRTUAL_PAGE_SHIFT;
		hit.pages[0] = virtual_block_page(table, level, low);
		hit.pages[1] = virtual_block_page(table, level, int2(high.x, low.y));
		hit.pages[2] = virtual_block_page(table, level, int2(low.x, high.y));
		hit.pages[3] = virtual_block_page(table, level, high);
		return true;
	}
	return false;
}

// virtual_shadow is how lit a point is by the light of the virtual shadow map, from its block's comparisons. Outside
// every level, and with no page in any, it is lit.
float virtual_shadow(float3 p, float3 normal, float3 to_light) {
	Virtual_Hit hit;
	if (!virtual_find(p, normal, to_light, hit)) {
		return 1;
	}
	Texture2D<uint> pool = cn_uint_texture(frame.virtual_pool);
	int2 low = hit.block.base >> VIRTUAL_PAGE_SHIFT;
	int2 center_first = hit.center << VIRTUAL_PAGE_SHIFT;
	float lit = 0;
	for (int y = 0; y < hit.block.size; y++) {
		for (int x = 0; x < hit.block.size; x++) {
			int2 texel = hit.block.base + int2(x, y);
			int2 page = texel >> VIRTUAL_PAGE_SHIFT;
			uint physical = hit.pages[(page.x != low.x ? 1 : 0) + (page.y != low.y ? 2 : 0)];
			int2 local = texel & int(VIRTUAL_PAGE_TEXELS - 1);
			if (physical == VIRTUAL_NO_PAGE) {
				physical = hit.center_page;
				local = clamp(texel - center_first, 0, int(VIRTUAL_PAGE_TEXELS) - 1);
			}
			uint stored = pool.Load(int3(int2(virtual_physical(physical)) + local, 0));
			lit += hit.block.weights_x[x] * hit.block.weights_y[y] * (hit.z >= asfloat(stored) ? 1 : 0);
		}
	}
	return lit;
}

// virtual_debug_color is the Shadow_Virtual debug view's color: each level's own where the point's pages were allocated,
// half red where the pool ran out and the point fell back to a coarser level, and magenta where it found no page.
float3 virtual_debug_color(float3 p) {
	if (frame.virtual_levels == 0) {
		return 0.4;
	}
	Virtual_Hit hit;
	if (!virtual_find(p, 0, 0, hit)) {
		return float3(1, 0, 1);
	}
	float3 color = hash_color(hit.level + 1);
	return hit.level == virtual_footprint_level(length(p)) ? color : lerp(color, float3(1, 0, 0), 0.5);
}

#endif
