// How a ray's hit picks the light that it takes beside the directional lights (see
// docs/rendering/global-illumination.md#world-probes): resampled importance sampling (RIS) over the punctual lights that
// the frame's light grid lists around the hit. Each candidate is drawn from the lights that can reach the hit, with a
// known chance, and weighed by its light at the hit without a shadow over that chance; the hit keeps one candidate in
// proportion to its weight, and casts one shadow ray toward it. The light that it gives is the candidate's over its
// target times the weights' sum, which is the light of every candidate in expectation, so no light is left out and none
// counts twice. When the hit's lights are no more than its candidates, each is a candidate once, with a chance of one.
// A pass includes it after material_lighting.hlsli, whose lights it reads.
#ifndef GI_LIGHT_SAMPLING_HLSLI
#define GI_LIGHT_SAMPLING_HLSLI

#include "hash.hlsli"

// Match lib/engine/render/hit_lights.odin.
#define LIGHT_GRID_LEVELS 6
static const int LIGHT_GRID_WINDOW = 512;
static const uint LIGHT_GRID_PROBE_STEPS = 32;
static const uint LIGHT_GRID_ENTRY_SIZE = 16;
// The most candidates that a hit weighs, whatever its level asks for.
static const uint MAX_HIT_CANDIDATES = 16;
// The ranges of lists that a hit finds: one cell at each level, then the global list.
#define LIGHT_GRID_RANGES (LIGHT_GRID_LEVELS + 1)

// Matches Light_Grid_Header in lib/engine/render/hit_lights.odin: each level's first cell relative to the camera and
// its cell's size, then the table and the lists, in bytes from the header.
struct Light_Grid {
	float4 levels[LIGHT_GRID_LEVELS];
	uint table_mask;
	uint table_first;
	uint lists_first;
	uint global_first;
	uint global_count;
	uint3 padding;
};

// Light_Cells are the lists of the lights that a point can see: a range of the lists at each level, then the global
// list, and their lights in all.
struct Light_Cells {
	uint first[LIGHT_GRID_RANGES];
	uint count[LIGHT_GRID_RANGES];
	uint total;
};

// light_grid_cells finds the lists of a point relative to the camera, in the grid at an offset of a buffer.
Light_Cells light_grid_cells(uint buffer, uint offset, Light_Grid g, float3 p) {
	ByteAddressBuffer b = cn_buffer(buffer);
	Light_Cells c;
	c.total = 0;
	[unroll] for (uint level = 0; level < LIGHT_GRID_LEVELS; level++) {
		c.first[level] = 0;
		c.count[level] = 0;
		float4 l = g.levels[level];
		int3 u = int3(floor((p - l.xyz) / l.w));
		if (any(u < 0) || any(u >= LIGHT_GRID_WINDOW)) {
			continue;
		}
		uint key = 0x80000000u | (level << 27) | (uint(u.z) << 18) | (uint(u.y) << 9) | uint(u.x);
		uint at = lowbias32(key) & g.table_mask;
		for (uint step = 0; step < LIGHT_GRID_PROBE_STEPS; step++) {
			uint4 entry = b.Load4(offset + g.table_first + at * LIGHT_GRID_ENTRY_SIZE);
			if (entry.x == key) {
				c.first[level] = entry.y;
				c.count[level] = entry.z;
				break;
			}
			if (entry.x == 0) {
				break;
			}
			at = (at + 1) & g.table_mask;
		}
		c.total += c.count[level];
	}
	c.first[LIGHT_GRID_LEVELS] = g.global_first;
	c.count[LIGHT_GRID_LEVELS] = g.global_count;
	c.total += g.global_count;
	return c;
}

// light_cells_at is the k-th light of a point's lists, as an index of the frame's lights.
uint light_cells_at(uint buffer, uint offset, Light_Grid g, Light_Cells c, uint k) {
	uint at = 0;
	[unroll] for (uint range = 0; range < LIGHT_GRID_RANGES; range++) {
		if (k < c.count[range]) {
			at = c.first[range] + k;
			break;
		}
		k -= c.count[range];
	}
	return cn_buffer(buffer).Load(offset + g.lists_first + at * 4);
}

// Hit_Choice is the light that a hit picked: its light at the hit with the cosine, before the shadow, the direction
// toward it and how far its shadow ray goes, and its weight, the weights' sum over its target, which is 0 when the hit
// picked none.
struct Hit_Choice {
	float3 light;
	float3 direction;
	float distance;
	float weight;
};

float hit_target(float3 light) {
	return dot(light, float3(0.2126, 0.7152, 0.0722));
}

// pick_hit_light picks one punctual light for a point relative to the camera with a normal, from candidates of the
// grid's lists around it, by a random sequence's state.
Hit_Choice pick_hit_light(uint buffer, uint offset, uint candidates, float3 p, float3 normal, inout uint state) {
	Hit_Choice choice;
	choice.light = 0;
	choice.direction = normal;
	choice.distance = 0;
	choice.weight = 0;
	Light_Grid g = cn_buffer(buffer).Load<Light_Grid>(offset);
	Light_Cells c = light_grid_cells(buffer, offset, g, p);
	if (c.total == 0) {
		return choice;
	}
	uint m = clamp(candidates, 1, MAX_HIT_CANDIDATES);
	bool every = c.total <= m;
	uint n = every ? c.total : m;
	// Each candidate drawn at random, with a chance of 1 / total, counts for 1 / n of the weights' sum.
	float share = every ? 1 : float(c.total) / float(m);
	float sum = 0;
	float target = 0;
	for (uint i = 0; i < MAX_HIT_CANDIDATES; i++) {
		if (i >= n) {
			break;
		}
		uint k = every ? i : min(uint(random_unit(state) * c.total), c.total - 1);
		Light_Record l = load_light(light_cells_at(buffer, offset, g, c, k));
		Light light = light_falloff(l, p);
		float3 lit = light.color * saturate(dot(normal, light.direction));
		float t = hit_target(lit);
		float w = t * share;
		if (w <= 0) {
			continue;
		}
		sum += w;
		if (random_unit(state) * sum < w) {
			choice.light = lit;
			choice.direction = light.direction;
			choice.distance = length(l.position - p);
			target = t;
		}
	}
	if (target > 0) {
		choice.weight = sum / target;
	}
	return choice;
}

#endif
