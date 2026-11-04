// Gives the virtual shadow map's marked pages their physical pages (see
// docs/rendering/lighting-and-shadows.md#virtual-shadow-maps), in three phases, a dispatch each: clearing the requests
// and the page table, allocating, and clearing the pool's pages that were allocated. Matches
// lib/engine/render/virtual_shadows.odin, whose tests cover the same steps.
#define MATERIAL_PUSH Virtual_Allocate_Push
// Matches Virtual_Allocate_Push in lib/engine/render/virtual_shadows.odin.
struct Virtual_Allocate_Push {
	uint requests;
	uint table;
	uint stats;
	uint arguments;
	uint phase;
};
#include "virtual_shadow.hlsli"

static const uint ALLOCATE_CLEAR = 0;
static const uint ALLOCATE_PAGES = 1;
static const uint ALLOCATE_CLEAR_POOL = 2;

// propagate sets each marked page's parent in the next coarser level, finest first, so a pixel whose page the pool
// cannot hold has a coarser one to fall back to. Grids nest, so a page's parent is its absolute page over 2.
void propagate(RWByteAddressBuffer requests) {
	for (uint level = 0; level + 1 < frame.virtual_levels; level++) {
		int2 origin = virtual_view(level).page_origin;
		int2 parent_origin = virtual_view(level + 1).page_origin;
		for (uint word = 0; word < VIRTUAL_LEVEL_WORDS; word++) {
			uint bits = requests.Load((level * VIRTUAL_LEVEL_WORDS + word) * 4);
			while (bits != 0) {
				uint index = word * 32 + firstbitlow(bits);
				bits &= bits - 1;
				int2 page = int2(index % VIRTUAL_PAGES, index / VIRTUAL_PAGES);
				int2 parent = ((origin + page) >> 1) - parent_origin;
				if (all(parent >= 0) && all(parent < int(VIRTUAL_PAGES))) {
					uint parent_index = (level + 1) * VIRTUAL_LEVEL_PAGES + uint(parent.y) * VIRTUAL_PAGES + uint(parent.x);
					uint at = (parent_index >> 5) * 4;
					requests.Store(at, requests.Load(at) | (1u << (parent_index & 31)));
				}
			}
		}
	}
}

// allocate gives pages out in order from the coarsest level, so the finest go first when pages are short. Allocated
// pages are the pool's first pages, so the pass that clears them clears only the rows that they take.
void allocate(RWByteAddressBuffer requests, RWByteAddressBuffer table) {
	uint requested = 0;
	uint allocated = 0;
	uint missed = 0;
	for (uint l = frame.virtual_levels; l > 0; l--) {
		uint level = l - 1;
		for (uint word = 0; word < VIRTUAL_LEVEL_WORDS; word++) {
			uint bits = requests.Load((level * VIRTUAL_LEVEL_WORDS + word) * 4);
			requested += countbits(bits);
			while (bits != 0) {
				uint index = word * 32 + firstbitlow(bits);
				bits &= bits - 1;
				if (allocated < frame.virtual_pool_pages) {
					table.Store((level * VIRTUAL_LEVEL_PAGES + index) * 4, allocated);
					allocated++;
				} else {
					missed++;
				}
			}
		}
	}
	RWByteAddressBuffer stats = cn_rw_buffer(push.stats);
	stats.Store4(0, uint4(requested, allocated, missed, frame.virtual_pool_pages));
	uint rows = (allocated + frame.virtual_pool_pages_per_row - 1) / frame.virtual_pool_pages_per_row;
	// A group is 64 texels of a row of texels.
	cn_rw_buffer(push.arguments).Store3(0, uint3(frame.virtual_pool_pages_per_row * VIRTUAL_PAGE_TEXELS / 64, rows * VIRTUAL_PAGE_TEXELS, 1));
}

[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	RWByteAddressBuffer requests = cn_rw_buffer(push.requests);
	RWByteAddressBuffer table = cn_rw_buffer(push.table);
	switch (push.phase) {
	case ALLOCATE_CLEAR:
		table.Store(id.x * 4, VIRTUAL_NO_PAGE);
		if (id.x < frame.virtual_levels * VIRTUAL_LEVEL_WORDS) {
			requests.Store(id.x * 4, 0);
		}
		break;
	case ALLOCATE_PAGES:
		if (id.x == 0) {
			propagate(requests);
			allocate(requests, table);
		}
		break;
	case ALLOCATE_CLEAR_POOL: {
		// The clear is depth's far end, which any caster's depth passes.
		RWTexture2D<uint> pool = cn_rw_uint_texture(frame.virtual_pool_storage);
		pool[id.xy] = 0;
		break;
	}
	}
}
