// The split radiance cascades' tables (see docs/rendering/global-illumination.md#split-cascades), in phases, a dispatch
// each:
//   Clear: new storage zeroes every slot and every bin's accumulators.
//   Index: empties every table and zeroes the counters.
//   Rebuild: a thread for each slot moves its probe's key by the window's move, frees it when it left the window or
//   went unused for the lifetime, and otherwise puts it back in its table and its cascade's active list. The free list
//   is built anew, so no slot is taken and freed in one pass.
//   Allocate: a thread for each traced pixel puts its cell's probe at each cascade, of each of its levels, in the
//   tables. The first thread to claim a key takes a free slot; with none left, the key has no slot and the gather and
//   the merge take the light from beyond it.
//   Arguments: the merge's dispatches, a group for each 64 bins of each active probe.
#include "gi_split.hlsli"

static const uint PHASE_CLEAR = 0;
static const uint PHASE_INDEX = 1;
static const uint PHASE_REBUILD = 2;
static const uint PHASE_ALLOCATE = 3;
static const uint PHASE_ARGUMENTS = 4;

// split_insert puts a key in a cascade's table with its slot, and is false when the table has no room near its place.
bool split_insert(Split_Cascade c, uint key, uint slot) {
	RWByteAddressBuffer index = cn_rw_buffer(push.index);
	uint mask = c.entries - 1;
	uint at = split_hash(key) & mask;
	for (uint step = 0; step < SPLIT_PROBE_STEPS; step++) {
		uint address = (c.first_entry + at) * SPLIT_ENTRY_SIZE;
		uint original;
		index.InterlockedCompareExchange(address, 0, key, original);
		if (original == 0 || original == key) {
			index.Store(address + 4, slot);
			return true;
		}
		at = (at + 1) & mask;
	}
	return false;
}

void free_slot(Split_Grid g, uint k, uint slot) {
	RWByteAddressBuffer counters = cn_rw_buffer(push.counters);
	uint n;
	counters.InterlockedAdd(k * SPLIT_COUNTERS_SIZE + SPLIT_FREE_COUNT, 1, n);
	cn_rw_buffer(push.lists).Store((g.cascades[k].first_slot + n) * 4, slot);
}

void activate_slot(Split_Grid g, uint k, uint slot) {
	RWByteAddressBuffer counters = cn_rw_buffer(push.counters);
	uint n;
	counters.InterlockedAdd(k * SPLIT_COUNTERS_SIZE + SPLIT_ACTIVE, 1, n);
	cn_rw_buffer(push.lists).Store((g.total_slots + g.cascades[k].first_slot + n) * 4, slot);
}

void rebuild(Split_Grid g, uint slot) {
	uint k = 0;
	for (uint c = 1; c < g.cascade_count; c++) {
		if (slot >= g.cascades[c].first_slot) {
			k = c;
		}
	}
	RWByteAddressBuffer slots = cn_rw_buffer(push.slots);
	uint4 record = slots.Load4(slot * SPLIT_SLOT_SIZE);
	if (record.x == 0) {
		free_slot(g, k, slot);
		return;
	}
	uint level = split_key_level(record.x);
	int3 u = int3(split_key_cell(record.x)) - (g.levels[level].delta.xyz >> k);
	uint key = split_key(level, uint3(u));
	if (!split_inside(u, k) || g.frame - record.y > g.lifetime || !split_insert(g.cascades[k], key, slot)) {
		slots.Store(slot * SPLIT_SLOT_SIZE, 0);
		free_slot(g, k, slot);
		return;
	}
	slots.Store(slot * SPLIT_SLOT_SIZE, key);
	slots.Store(slot * SPLIT_SLOT_SIZE + 8, 0);
	activate_slot(g, k, slot);
}

// allocate puts a probe's key in its cascade's table, with a free slot when it is new.
void allocate(Split_Grid g, uint k, uint key) {
	Split_Cascade c = g.cascades[k];
	RWByteAddressBuffer index = cn_rw_buffer(push.index);
	RWByteAddressBuffer counters = cn_rw_buffer(push.counters);
	uint mask = c.entries - 1;
	uint at = split_hash(key) & mask;
	for (uint step = 0; step < SPLIT_PROBE_STEPS; step++) {
		uint address = (c.first_entry + at) * SPLIT_ENTRY_SIZE;
		uint seen = index.Load(address);
		if (seen == key) {
			return;
		}
		if (seen == 0) {
			uint original;
			index.InterlockedCompareExchange(address, 0, key, original);
			if (original == key) {
				return;
			}
			if (original == 0) {
				uint n;
				counters.InterlockedAdd(k * SPLIT_COUNTERS_SIZE + SPLIT_TAKEN, 1, n);
				if (n < counters.Load(k * SPLIT_COUNTERS_SIZE + SPLIT_FREE_COUNT)) {
					uint slot = cn_rw_buffer(push.lists).Load((c.first_slot + n) * 4);
					cn_rw_buffer(push.slots).Store4(slot * SPLIT_SLOT_SIZE, uint4(key, g.frame, SPLIT_FRESH, 0));
					index.Store(address + 4, slot);
					activate_slot(g, k, slot);
				} else {
					index.Store(address + 4, SPLIT_NO_SLOT);
					counters.InterlockedAdd(k * SPLIT_COUNTERS_SIZE + SPLIT_DROPPED, 1);
				}
				return;
			}
		}
		at = (at + 1) & mask;
	}
	counters.InterlockedAdd(k * SPLIT_COUNTERS_SIZE + SPLIT_DROPPED, 1);
}

void allocate_pixel(Split_Grid g, uint ray) {
	int2 pixel;
	float3 p;
	float z;
	if (!split_pixel(g, ray, pixel, p, z)) {
		return;
	}
	Split_Lod lod = split_lod(g, chebyshev(p));
	for (uint n = 0; n < 2; n++) {
		uint l = lod.level + n;
		if (l >= g.level_count || (n == 1 && lod.blend <= 0)) {
			break;
		}
		int3 u = split_cell(g.levels[l], p);
		for (uint k = 0; k < g.cascade_count; k++) {
			int3 uk = u >> k;
			if (split_inside(uk, k)) {
				allocate(g, k, split_key(l, uint3(uk)));
			}
		}
	}
}

[numthreads(SPLIT_GROUP, 1, 1)]
void cs_main(uint3 group : SV_GroupID, uint thread : SV_GroupIndex) {
	Split_Grid g = split_grid();
	uint i = split_thread(group, thread);
	switch (push.phase) {
	case PHASE_CLEAR:
		if (i < g.total_bins) {
			RWByteAddressBuffer accum = cn_rw_buffer(push.accum);
			accum.Store4(i * SPLIT_ACCUM_SIZE, 0);
			accum.Store(i * SPLIT_ACCUM_SIZE + 16, 0);
		}
		if (i < g.total_slots) {
			cn_rw_buffer(push.slots).Store4(i * SPLIT_SLOT_SIZE, 0);
			cn_rw_buffer(push.deposits).Store(i * 4, 0);
		}
		break;
	case PHASE_INDEX:
		if (i < g.total_entries) {
			cn_rw_buffer(push.index).Store2(i * SPLIT_ENTRY_SIZE, 0);
		}
		if (i < g.cascade_count) {
			cn_rw_buffer(push.counters).Store4(i * SPLIT_COUNTERS_SIZE, 0);
		}
		break;
	case PHASE_REBUILD:
		if (i < g.total_slots) {
			rebuild(g, i);
		}
		break;
	case PHASE_ALLOCATE:
		if (i < g.ray_count) {
			allocate_pixel(g, i);
		}
		break;
	case PHASE_ARGUMENTS:
		if (i < g.cascade_count) {
			uint active = cn_rw_buffer(push.counters).Load(i * SPLIT_COUNTERS_SIZE + SPLIT_ACTIVE);
			uint groups = active * g.cascades[i].chunks;
			cn_rw_buffer(push.arguments).Store3(i * 12, uint3(min(groups, 65535), (groups + 65534) / 65535, 1));
		}
		break;
	}
}
