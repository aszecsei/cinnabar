// Gives the virtual shadow map's marked pages their physical pages (see
// docs/rendering/lighting-and-shadows.md#virtual-shadow-maps), in phases, a dispatch each, which the render graph puts
// barriers between. The page table and the physical pages' records last from frame to frame with the pool, so a page
// that the pool holds keeps its physical page and does not draw, and when the pool is full, the pages that were asked for
// longest ago leave first. Matches lib/engine/render/virtual_shadows.odin, whose tests cover the same steps.
#define MATERIAL_PUSH Virtual_Allocate_Push
// Matches Virtual_Allocate_Push in lib/engine/render/virtual_shadows.odin. now is the frame's epoch, which the pages that
// it asks for take, and invalidate the levels whose pages it drops, a bit each. With drops, dropped is a bit for each page
// of each level that the frame drops, in the upload ring, as the requests are laid out: the pages under the casters that
// changed and under the live ones (see virtual_drop_pages).
struct Virtual_Allocate_Push {
	uint requests;
	uint table;
	uint pages;
	uint scratch;
	uint stats;
	uint arguments;
	uint phase;
	uint now;
	uint invalidate;
	uint dropped;
	uint dropped_offset;
	uint drops;
};
#include "virtual_shadow.hlsli"

// Match Allocate_Phase in lib/engine/render/virtual_shadows.odin.
static const uint ALLOCATE_RESET = 0;
static const uint ALLOCATE_CLEAR = 1;
static const uint ALLOCATE_FIT = 2;
static const uint ALLOCATE_RETIRE = 3;
static const uint ALLOCATE_SELECT = 4;
static const uint ALLOCATE_COLLECT = 5;
static const uint ALLOCATE_ASSIGN = 6;
static const uint ALLOCATE_CLEAR_POOL = 7;

// The scratch's words: counters, the histogram of the pages' ages, and the list of the pages that the frame may give
// out. Match VIRTUAL_SCRATCH_* and VIRTUAL_AGE_BINS in lib/engine/render/virtual_shadows.odin.
static const uint SCRATCH_REQUESTED = 0;
static const uint SCRATCH_MOVED = 1;
static const uint SCRATCH_TOTAL = 2;
static const uint SCRATCH_HITS = 3;
static const uint SCRATCH_VALID = 4;
static const uint SCRATCH_THRESHOLD = 5;
static const uint SCRATCH_QUOTA = 6;
static const uint SCRATCH_TAKEN = 7;
static const uint SCRATCH_AVAILABLE = 8;
static const uint SCRATCH_EVICTED = 9;
static const uint VIRTUAL_AGE_BINS = 1024;
static const uint SCRATCH_HISTOGRAM = 16;
static const uint SCRATCH_LIST = SCRATCH_HISTOGRAM + VIRTUAL_AGE_BINS;

// A physical page's record: the level and the absolute page that it holds, with level VIRTUAL_FREE for none, and the
// last frame that asked for it. Matches Virtual_Page in lib/engine/render/virtual_shadows.odin.
struct Virtual_Page {
	uint level;
	int2 page;
	uint last;
};
static const uint VIRTUAL_FREE = ~0u;
static const uint PAGE_SIZE = 16;

uint scratch_load(uint word) {
	return cn_rw_buffer(push.scratch).Load(word * 4);
}

void scratch_add(uint word, uint value) {
	uint previous;
	cn_rw_buffer(push.scratch).InterlockedAdd(word * 4, value, previous);
}

// fit_pool makes the marks fit the pool, if they do not: finest level first, it moves a page's mark to its parent in the
// next coarser level, one page at a time, until they fit. A pixel whose page moved falls back to the parent, whose texels
// are coarser. Marks that fit move nothing, so no level draws pages that nothing reads. Grids nest, so a page's parent is
// its absolute page over 2. It stores how many pages the frame asked for, how many moved, and how many marks are left.
// Matches virtual_fit_pool in virtual_shadows.odin.
void fit_pool() {
	RWByteAddressBuffer requests = cn_rw_buffer(push.requests);
	uint requested = 0;
	for (uint word = 0; word < frame.virtual_levels * VIRTUAL_LEVEL_WORDS; word += 4) {
		uint4 bits = countbits(requests.Load4(word * 4));
		requested += bits.x + bits.y + bits.z + bits.w;
	}
	uint total = requested;
	uint moved = 0;
	for (uint level = 0; level + 1 < frame.virtual_levels && total > frame.virtual_pool_pages; level++) {
		int2 origin = virtual_view(level).page_origin;
		int2 parent_origin = virtual_view(level + 1).page_origin;
		for (uint word = 0; word < VIRTUAL_LEVEL_WORDS && total > frame.virtual_pool_pages; word++) {
			uint at_word = (level * VIRTUAL_LEVEL_WORDS + word) * 4;
			uint bits = requests.Load(at_word);
			while (bits != 0 && total > frame.virtual_pool_pages) {
				uint bit = firstbitlow(bits);
				uint index = word * 32 + bit;
				bits &= bits - 1;
				requests.Store(at_word, bits);
				total--;
				moved++;
				int2 page = int2(index % VIRTUAL_PAGES, index / VIRTUAL_PAGES);
				int2 parent = ((origin + page) >> 1) - parent_origin;
				if (all(parent >= 0) && all(parent < int(VIRTUAL_PAGES))) {
					uint parent_index = (level + 1) * VIRTUAL_LEVEL_PAGES + uint(parent.y) * VIRTUAL_PAGES + uint(parent.x);
					uint at = (parent_index >> 5) * 4;
					uint mask = 1u << (parent_index & 31);
					uint value = requests.Load(at);
					if ((value & mask) == 0) {
						requests.Store(at, value | mask);
						total++;
					}
				}
			}
		}
	}
	RWByteAddressBuffer scratch = cn_rw_buffer(push.scratch);
	scratch.Store3(SCRATCH_REQUESTED * 4, uint3(requested, moved, total));
}

// retire goes over a physical page. It leaves when its level is one that the frame drops, is past the frame's levels, or
// no longer holds its page since the level's origin moved. A page that stays takes its entry again without VIRTUAL_DRAW.
// A page that the frame asks for is a hit: the frame keeps it and does not ask for it again, and its age starts over.
// Every other page's age goes into the histogram. Matches virtual_retire in virtual_shadows.odin.
void retire(uint p) {
	RWByteAddressBuffer pages = cn_rw_buffer(push.pages);
	RWByteAddressBuffer table = cn_rw_buffer(push.table);
	Virtual_Page page = pages.Load<Virtual_Page>(p * PAGE_SIZE);
	if (page.level == VIRTUAL_FREE) {
		return;
	}
	uint slot = virtual_table_slot(page.level, page.page);
	int2 local = 0;
	bool keep = page.level < frame.virtual_levels && ((push.invalidate >> page.level) & 1) == 0;
	if (keep) {
		local = page.page - virtual_view(page.level).page_origin;
		keep = all(local >= 0) && all(local < int(VIRTUAL_PAGES));
	}
	if (keep && push.drops != 0) {
		uint at = page.level * VIRTUAL_LEVEL_PAGES + uint(local.y) * VIRTUAL_PAGES + uint(local.x);
		keep = (cn_buffer(push.dropped).Load(push.dropped_offset + (at >> 5) * 4) & (1u << (at & 31))) == 0;
	}
	if (!keep) {
		table.Store(slot, VIRTUAL_NO_PAGE);
		pages.Store(p * PAGE_SIZE, VIRTUAL_FREE);
		return;
	}
	table.Store(slot, p);
	scratch_add(SCRATCH_VALID, 1);
	// Only this thread clears this page's bit, so the plain load sees it.
	RWByteAddressBuffer requests = cn_rw_buffer(push.requests);
	uint index = page.level * VIRTUAL_LEVEL_PAGES + uint(local.y) * VIRTUAL_PAGES + uint(local.x);
	uint word = (index >> 5) * 4;
	uint bit = 1u << (index & 31);
	if ((requests.Load(word) & bit) != 0) {
		uint previous;
		requests.InterlockedAnd(word, ~bit, previous);
		pages.Store(p * PAGE_SIZE + 12, push.now);
		scratch_add(SCRATCH_HITS, 1);
	} else {
		scratch_add(SCRATCH_HISTOGRAM + min(push.now - page.last, VIRTUAL_AGE_BINS - 1), 1);
	}
}

// select_evictions finds which pages leave for the frame's new pages when the pool's free pages are too few: the oldest
// first, by a running sum of the histogram from its oldest bin. Every page in a bin older than the threshold leaves, and
// the quota of those in the threshold's. With no page to leave, the threshold is past the last bin. Matches
// virtual_select in virtual_shadows.odin.
void select_evictions() {
	uint fresh = scratch_load(SCRATCH_TOTAL) - scratch_load(SCRATCH_HITS);
	uint free = frame.virtual_pool_pages - scratch_load(SCRATCH_VALID);
	uint need = fresh > free ? fresh - free : 0;
	uint threshold = VIRTUAL_AGE_BINS;
	uint quota = 0;
	for (uint b = VIRTUAL_AGE_BINS; b > 0 && need > 0; b--) {
		uint count = scratch_load(SCRATCH_HISTOGRAM + b - 1);
		threshold = b - 1;
		quota = min(count, need);
		need -= quota;
	}
	RWByteAddressBuffer scratch = cn_rw_buffer(push.scratch);
	scratch.Store2(SCRATCH_THRESHOLD * 4, uint2(threshold, quota));
}

// collect lists a physical page if the frame may give it out: a free page, or one that select_evictions chose to leave,
// which leaves the table. A page that the frame asked for took the frame's epoch, and never leaves. Matches
// virtual_collect in virtual_shadows.odin.
void collect(uint p) {
	RWByteAddressBuffer pages = cn_rw_buffer(push.pages);
	Virtual_Page page = pages.Load<Virtual_Page>(p * PAGE_SIZE);
	if (page.level != VIRTUAL_FREE) {
		if (page.last == push.now) {
			return;
		}
		uint bin = min(push.now - page.last, VIRTUAL_AGE_BINS - 1);
		uint threshold = scratch_load(SCRATCH_THRESHOLD);
		bool take = bin > threshold;
		if (!take && bin == threshold) {
			uint taken;
			cn_rw_buffer(push.scratch).InterlockedAdd(SCRATCH_TAKEN * 4, 1, taken);
			take = taken < scratch_load(SCRATCH_QUOTA);
		}
		if (!take) {
			return;
		}
		cn_rw_buffer(push.table).Store(virtual_table_slot(page.level, page.page), VIRTUAL_NO_PAGE);
		pages.Store(p * PAGE_SIZE, VIRTUAL_FREE);
		scratch_add(SCRATCH_EVICTED, 1);
	}
	uint at;
	cn_rw_buffer(push.scratch).InterlockedAdd(SCRATCH_AVAILABLE * 4, 1, at);
	cn_rw_buffer(push.scratch).Store((SCRATCH_LIST + at) * 4, p);
}

// assign gives each page that the frame asks for and the pool does not hold the next page of the list, coarsest level
// first, so the finest go without when the list runs out, and marks it to draw. It counts each level's pages that draw
// in the table, stores the stats, and the pool clear's arguments: a group of 64 texels of a row, 128 rows, for each page
// that draws. Matches virtual_assign in virtual_shadows.odin.
void assign() {
	RWByteAddressBuffer requests = cn_rw_buffer(push.requests);
	RWByteAddressBuffer table = cn_rw_buffer(push.table);
	RWByteAddressBuffer pages = cn_rw_buffer(push.pages);
	uint available = scratch_load(SCRATCH_AVAILABLE);
	uint drawn = 0;
	uint missed = scratch_load(SCRATCH_MOVED);
	for (uint l = frame.virtual_levels; l > 0; l--) {
		uint level = l - 1;
		int2 origin = virtual_view(level).page_origin;
		uint count = 0;
		// Most words are empty, so they are read four at a time.
		for (uint words = 0; words < VIRTUAL_LEVEL_WORDS; words += 4) {
			uint4 run = requests.Load4((level * VIRTUAL_LEVEL_WORDS + words) * 4);
			if (all(run == 0)) {
				continue;
			}
			for (uint k = 0; k < 4; k++) {
				uint bits = run[k];
				while (bits != 0) {
					uint index = (words + k) * 32 + firstbitlow(bits);
					bits &= bits - 1;
					if (drawn >= available) {
						missed++;
						continue;
					}
					uint p = scratch_load(SCRATCH_LIST + drawn);
					drawn++;
					count++;
					int2 page = origin + int2(index % VIRTUAL_PAGES, index / VIRTUAL_PAGES);
					table.Store(virtual_table_slot(level, page), p | VIRTUAL_DRAW);
					pages.Store4(p * PAGE_SIZE, uint4(level, asuint(page), push.now));
				}
			}
		}
		table.Store((VIRTUAL_TABLE_COUNTS + level) * 4, count);
	}
	uint hits = scratch_load(SCRATCH_HITS);
	uint evicted = scratch_load(SCRATCH_EVICTED);
	uint resident = scratch_load(SCRATCH_VALID) - evicted + drawn;
	RWByteAddressBuffer stats = cn_rw_buffer(push.stats);
	stats.Store4(0, uint4(scratch_load(SCRATCH_REQUESTED), hits + drawn, missed, frame.virtual_pool_pages));
	stats.Store4(16, uint4(hits, drawn, evicted, resident));
	cn_rw_buffer(push.arguments).Store3(0, uint3(VIRTUAL_PAGE_TEXELS / 64, VIRTUAL_PAGE_TEXELS, drawn));
}

[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	switch (push.phase) {
	case ALLOCATE_RESET:
		if (id.x < VIRTUAL_TABLE_COUNTS) {
			cn_rw_buffer(push.table).Store(id.x * 4, VIRTUAL_NO_PAGE);
		}
		if (id.x < frame.virtual_pool_pages) {
			cn_rw_buffer(push.pages).Store(id.x * PAGE_SIZE, VIRTUAL_FREE);
		}
		break;
	case ALLOCATE_CLEAR:
		if (id.x < frame.virtual_levels * VIRTUAL_LEVEL_WORDS) {
			cn_rw_buffer(push.requests).Store(id.x * 4, 0);
		}
		if (id.x < SCRATCH_LIST) {
			cn_rw_buffer(push.scratch).Store(id.x * 4, 0);
		}
		if (id.x < VIRTUAL_MAX_LEVELS) {
			cn_rw_buffer(push.table).Store((VIRTUAL_TABLE_COUNTS + id.x) * 4, 0);
		}
		break;
	case ALLOCATE_FIT:
		if (id.x == 0) {
			fit_pool();
		}
		break;
	case ALLOCATE_RETIRE:
		if (id.x < frame.virtual_pool_pages) {
			retire(id.x);
		}
		break;
	case ALLOCATE_SELECT:
		if (id.x == 0) {
			select_evictions();
		}
		break;
	case ALLOCATE_COLLECT:
		if (id.x < frame.virtual_pool_pages) {
			collect(id.x);
		}
		break;
	case ALLOCATE_ASSIGN:
		if (id.x == 0) {
			assign();
		}
		break;
	case ALLOCATE_CLEAR_POOL: {
		// A group's z is its page in the list; the clear is depth's far end, which any caster's depth passes.
		uint page = scratch_load(SCRATCH_LIST + id.z);
		RWTexture2D<uint> pool = cn_rw_uint_texture(frame.virtual_pool_storage);
		pool[virtual_physical(page) + id.xy] = 0;
		break;
	}
	}
}
