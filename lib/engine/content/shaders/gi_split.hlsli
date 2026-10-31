// What the split radiance cascades' shaders share (see docs/rendering/global-illumination.md#split-cascades): their
// push constants, the grid in the upload ring, and the tables. The probes are sparse, in world space, on the surfaces
// that the screen shows: each level of detail is a window of 512 cells on each axis around the camera, whose cells
// double each level, and cascade k's probe is the cell's coordinates shifted right by k, so its cells are 2^k times as
// large, with (directions << k)^2 directions. A probe's key is its window coordinates and level, and a hash table for
// each cascade finds its slot. Each traced pixel's ray splits by its hit's distance: the cascade whose interval holds
// it takes the hit's light, and every cascade before it counts the ray as passing through. The pass constants are the
// global illumination's (gi_common.hlsli), for the pixels' surfaces and the world probes' light.
#ifndef GI_SPLIT_HLSLI
#define GI_SPLIT_HLSLI

#include "gi_common.hlsli"
#include "ray_scene.hlsli"

// Match lib/engine/render/gi_split.odin.
static const uint MAX_SPLIT_LEVELS = 8;
static const uint MAX_SPLIT_CASCADES = 4;
static const int SPLIT_WINDOW = 512;
static const uint SPLIT_GROUP = 64;
// A table's linear probing stops after this many entries, so no lookup can spin.
static const uint SPLIT_PROBE_STEPS = 32;
static const uint SPLIT_NO_SLOT = 0xffffffff;
// A slot that the frame allocated: its history is not yet its own.
static const uint SPLIT_FRESH = 1;
// Each slot: its key, the frame that last used it, its flags and its confidence.
static const uint SPLIT_SLOT_SIZE = 16;
// Each entry of a table: a key and its slot.
static const uint SPLIT_ENTRY_SIZE = 8;
// Each bin's accumulators this frame: its rays, its hits, and the hits' light in fixed point.
static const uint SPLIT_ACCUM_SIZE = 20;
// Each bin's history: the mean light and the share that passes through as halves, and the rays that it holds.
static const uint SPLIT_HISTORY_SIZE = 12;
// Each bin's merged light, as halves.
static const uint SPLIT_MERGED_SIZE = 8;
// Each cascade's counters: its free slots, the slots that the frame took from them, its active slots and the keys that
// found no room.
static const uint SPLIT_COUNTERS_SIZE = 16;
static const uint SPLIT_FREE_COUNT = 0;
static const uint SPLIT_TAKEN = 4;
static const uint SPLIT_ACTIVE = 8;
static const uint SPLIT_DROPPED = 12;
static const float SPLIT_TAU = 6.28318531;
// The square root of the sphere's solid angle.
static const float SPLIT_SQRT_SPHERE = 3.54490770;

// Matches Split_Push in lib/engine/render/gi_split.odin. phase is the table's phase, and cascade the merge's cascade.
// Each pass binds the tables for writing where it writes them. With view, the gather draws the probes into view_output
// for the Gi_Probes debug view.
struct Split_Push {
	uint grid;
	uint grid_offset;
	uint phase;
	uint cascade;
	uint slots;
	uint deposits;
	uint index;
	uint lists;
	uint counters;
	uint arguments;
	uint accum;
	uint history;
	uint merged;
	uint atlas;
	uint hits;
	uint rays;
	uint accel;
	uint exposure;
	uint view;
	uint view_output;
};
CN_PUSH_CONSTANTS(Split_Push, push);

// Matches Split_Level in lib/engine/render/gi_split.odin: the window's first cell relative to the camera in xyz and the
// level's cell in w, and how far the window moved this frame, in cells.
struct Split_Level {
	float4 min;
	int4 delta;
};

// Matches Split_Cascade in lib/engine/render/gi_split.odin: the cascade's slots, its table's entries, a power of two,
// its first bin, the directions along each side of its probes' octahedron, and the merge's groups for each probe.
struct Split_Cascade {
	uint first_slot;
	uint slots;
	uint first_entry;
	uint entries;
	uint first_bin;
	uint side;
	uint chunks;
	uint padding;
};

// Matches Split_Grid in lib/engine/render/gi_split.odin.
struct Split_Grid {
	Split_Level levels[MAX_SPLIT_LEVELS];
	Split_Cascade cascades[MAX_SPLIT_CASCADES];
	float4 camera_offset;
	uint level_count;
	uint cascade_count;
	uint directions;
	uint frame;
	uint2 tile;
	uint2 tiles;
	uint2 rotation;
	uint lifetime;
	uint ray_count;
	float level_distance;
	float band;
	float interval;
	float bias;
	float decay;
	float max_count;
	float confidence_half;
	float radiance_scale;
	float radiance_max;
	uint total_slots;
	uint total_entries;
	uint total_bins;
	uint atlas_columns;
	uint padding0;
	uint padding1;
	uint padding2;
};

Split_Grid split_grid() {
	return cn_buffer(push.grid).Load<Split_Grid>(push.grid_offset);
}

// split_thread is a thread's index in a dispatch of groups of SPLIT_GROUP in rows of at most 65535 groups.
uint split_thread(uint3 group, uint thread) {
	return (group.y * 65535 + group.x) * SPLIT_GROUP + thread;
}

// split_key is a probe's key: its window coordinates at its cascade, its level, and a high bit, so no key is 0, which
// is an empty entry.
uint split_key(uint level, uint3 u) {
	return 0x80000000u | (level << 27) | (u.z << 18) | (u.y << 9) | u.x;
}

uint split_key_level(uint key) {
	return (key >> 27) & 7;
}

uint3 split_key_cell(uint key) {
	return uint3(key & 511, (key >> 9) & 511, (key >> 18) & 511);
}

// split_hash is a key's place in a table (lowbias32, Chris Wellons).
uint split_hash(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

// split_find is the slot of a probe's key at a cascade, or SPLIT_NO_SLOT when the cascade has no such probe.
uint split_find(Split_Cascade c, uint key) {
	ByteAddressBuffer index = cn_buffer(push.index);
	uint mask = c.entries - 1;
	uint at = split_hash(key) & mask;
	for (uint step = 0; step < SPLIT_PROBE_STEPS; step++) {
		uint2 entry = index.Load2((c.first_entry + at) * SPLIT_ENTRY_SIZE);
		if (entry.x == key) {
			return entry.y;
		}
		if (entry.x == 0) {
			return SPLIT_NO_SLOT;
		}
		at = (at + 1) & mask;
	}
	return SPLIT_NO_SLOT;
}

// split_cell is the first cascade's window coordinates of a point relative to the camera, at a level.
int3 split_cell(Split_Level level, float3 p) {
	return int3(floor((p - level.min.xyz) / level.min.w));
}

bool split_inside(int3 u, uint k) {
	return all(u >= 0) && all(u < (SPLIT_WINDOW >> k));
}

// split_center is the center of cascade k's probe at window coordinates u, relative to the camera.
float3 split_center(Split_Level level, int3 u, uint k) {
	return level.min.xyz + (float3(u) + 0.5) * level.min.w * float(1u << k);
}

// Split_Lod is the levels of detail at a point: level, and level + 1 by blend. A level past the last is the world
// probes'.
struct Split_Lod {
	uint level;
	float blend;
};

// split_lod is the levels at a Chebyshev distance from the camera: level L holds the distances from level_distance
// times 2^L to twice that, and the last band of each blends into the next.
Split_Lod split_lod(Split_Grid g, float r) {
	float x = log2(max(r, g.level_distance) / g.level_distance);
	Split_Lod lod;
	lod.level = uint(floor(x));
	lod.blend = saturate((frac(x) - (1 - g.band)) / g.band);
	return lod;
}

float chebyshev(float3 p) {
	return max(abs(p.x), max(abs(p.y), abs(p.z)));
}

// split_reach is how far a level's rays reach: the end of the last cascade's interval.
float split_reach(Split_Grid g, float cell) {
	return g.interval * cell * float(1u << (2 * (g.cascade_count - 1)));
}

// split_hit_cascade is the cascade whose interval holds a hit's distance: the first cascade's ends at interval times
// the level's cell, and each is four times as long as the one before. It is cascade_count or more beyond the last.
uint split_hit_cascade(float t, float first) {
	return uint(ceil(max(0.5 * log2(max(t, 1e-6) / first), 0)));
}

// split_bin is a probe's bin of a direction texel, in the bins of every cascade.
uint split_bin(Split_Cascade c, uint slot, uint bin) {
	return c.first_bin + (slot - c.first_slot) * c.side * c.side + bin;
}

// split_direction_bin is the direction texel of a direction, at a side.
uint split_direction_bin(float3 d, uint side) {
	uint2 t = min(uint2((octahedral_encode(d) * 0.5 + 0.5) * side), side - 1);
	return t.y * side + t.x;
}

// split_pixel is the pixel that a ray traces from: its tile's pixel this frame, and its surface relative to the
// camera. It is false off the screen and where the pixel has no surface.
bool split_pixel(Split_Grid g, uint ray, out int2 pixel, out float3 p, out float z) {
	uint2 tile = uint2(ray % g.tiles.x, ray / g.tiles.x);
	pixel = int2(tile * g.tile + g.rotation);
	p = 0;
	z = 0;
	if (any(pixel >= int2(constants.size))) {
		return false;
	}
	return surface_at(pixel, p, z);
}

float3 split_load_merged(uint bin) {
	uint2 m = cn_buffer(push.merged).Load2(bin * SPLIT_MERGED_SIZE);
	return float3(f16tof32(m.x), f16tof32(m.x >> 16), f16tof32(m.y));
}

#endif
