// The world probes' grid (see docs/rendering/global-illumination.md#world-probes): camera-following clipmap levels of
// probes in world space, each level a box of PROBE_GRID probes, twice as far apart as the level before. A probe keeps
// an octahedral tile of the radiance that reaches it from each direction, the cosine-weighted mean of that radiance
// around each direction, and the mean distance and squared distance to what its rays hit, for visibility. A probe's
// storage is its world cell modulo the grid, so a level that follows the camera keeps every probe where it was, and a
// render-origin rebase moves nothing. sample_probes reads them at a point.
#ifndef GI_PROBES_HLSLI
#define GI_PROBES_HLSLI

#include "cinnabar.hlsli"

// Match GI_PROBE_GRID, GI_PROBE_INTERIOR, GI_PROBE_TILE and MAX_PROBE_LEVELS in lib/engine/render/gi_probes.odin.
static const int3 PROBE_GRID = int3(32, 16, 32);
static const uint PROBE_COUNT = 32 * 16 * 32;
static const uint PROBE_INTERIOR = 6;
static const uint PROBE_TILE = 8;
static const uint MAX_PROBE_LEVELS = 4;
// A probe's state: how many updates it has had, at most 255, 0 for none since it was reset, and whether it is inside
// geometry, which its back-facing hits say.
static const uint PROBE_UPDATES_MASK = 0xff;
static const uint PROBE_INACTIVE = 0x100;

// Matches Probe_Level in lib/engine/render/gi_probes.odin: the level's first probe relative to the camera in xyz and
// its spacing in w, the storage of its first probe, and how far its box moved this frame, in probes.
struct Probe_Level {
	float4 min;
	int4 phase;
	int4 delta;
};

// Matches Probe_Grid in lib/engine/render/gi_probes.odin: the levels, the rays' rotation this frame, and the probes'
// textures and states, for reading and, in the update and the reset, for writing, with the frame's updated probes in
// jobs, each its level above 24 bits and its storage below.
struct Probe_Grid {
	Probe_Level levels[MAX_PROBE_LEVELS];
	float4 rotation[3];
	uint level_count;
	uint radiance;
	uint irradiance;
	uint states;
	uint radiance_out;
	uint irradiance_out;
	uint states_out;
	uint sampler_index;
	uint rays;
	uint jobs;
	uint jobs_offset;
	uint job_count;
	float hysteresis;
	float bias;
	uint2 padding;
};

Probe_Grid load_probe_grid(uint buffer, uint offset) {
	return cn_buffer(buffer).Load<Probe_Grid>(offset);
}

int3 probe_wrap(int3 v) {
	return ((v % PROBE_GRID) + PROBE_GRID) % PROBE_GRID;
}

// probe_storage is the storage of the probe at a place in a level's box.
uint probe_storage(Probe_Level level, int3 cell) {
	int3 s = probe_wrap(cell + level.phase.xyz);
	return uint(s.x + s.y * PROBE_GRID.x + s.z * PROBE_GRID.x * PROBE_GRID.y);
}

// probe_cell is the place in a level's box of the probe at a storage.
int3 probe_cell(Probe_Level level, uint storage) {
	int3 s = int3(storage % PROBE_GRID.x, (storage / PROBE_GRID.x) % PROBE_GRID.y, storage / (PROBE_GRID.x * PROBE_GRID.y));
	return probe_wrap(s - level.phase.xyz);
}

float3 probe_position(Probe_Level level, int3 cell) {
	return level.min.xyz + float3(cell) * level.min.w;
}

// A probe's rays reach this far: twice its level's box.
float probe_distance(Probe_Level level) {
	return level.min.w * PROBE_GRID.x * 2;
}

// The first texel of a probe's tile in the atlas, whose border is a texel wide.
uint2 probe_tile(uint level, uint storage) {
	uint x = storage % PROBE_GRID.x;
	uint y = (storage / PROBE_GRID.x) % PROBE_GRID.y;
	uint z = storage / (PROBE_GRID.x * PROBE_GRID.y);
	return uint2(x + y * PROBE_GRID.x, z + level * PROBE_GRID.z) * PROBE_TILE;
}

uint probe_state_index(uint level, uint storage) {
	return (level * PROBE_COUNT + storage) * 4;
}

float2 probe_octahedral(float3 n) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	float2 p = n.xy;
	if (n.z < 0) {
		float2 sign_xy = float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
		p = (1 - abs(p.yx)) * sign_xy;
	}
	return p;
}

float3 probe_unfold(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

// probe_ray_direction is a probe's ray: a spherical Fibonacci point, turned by the frame's rotation, so each update
// sees new directions.
float3 probe_ray_direction(Probe_Grid grid, uint ray) {
	float golden = 2.39996323;
	float z = 1 - (2 * ray + 1) / float(grid.rays);
	float r = sqrt(saturate(1 - z * z));
	float phi = ray * golden;
	float3 d = float3(r * cos(phi), r * sin(phi), z);
	return normalize(float3(dot(grid.rotation[0].xyz, d), dot(grid.rotation[1].xyz, d), dot(grid.rotation[2].xyz, d)));
}

// interior_of is the interior texel that a texel of a tile shows: itself, or for the border, the interior texel
// across the octahedron's fold.
int2 interior_of(int2 t) {
	int last = PROBE_INTERIOR - 1;
	int2 i = t - 1;
	if (i.x < 0 || i.x > last) {
		i.y = last - i.y;
		i.x = clamp(i.x, 0, last);
	}
	if (i.y < 0 || i.y > last) {
		i.x = last - i.x;
		i.y = clamp(i.y, 0, last);
	}
	return clamp(i, 0, last);
}

// probe_uv is where a direction is in a probe's tile, in the atlas's UV, for a bilinear sample within its interior.
float2 probe_uv(Probe_Grid grid, uint level, uint storage, float3 direction) {
	uint width, height;
	cn_texture(grid.radiance).GetDimensions(width, height);
	float2 texel = float2(probe_tile(level, storage)) + 1 + (probe_octahedral(direction) * 0.5 + 0.5) * PROBE_INTERIOR;
	return texel / float2(width, height);
}

// sample_level is one level's light at a point p relative to the camera with a normal n: the radiance arriving from
// direction, or the cosine-weighted mean radiance around n. The eight probes around p each count by their trilinear
// weight, by whether they are in front of the surface, and by whether they can see p, from the mean and the variance of
// their rays' distances toward it (Chebyshev). Probes that were never updated, or are inside geometry, do not count. It
// is false when no probe counts.
bool sample_level(Probe_Grid grid, uint l, float3 p, float3 n, float3 direction, bool radiance, out float3 light) {
	light = 0;
	Probe_Level level = grid.levels[l];
	float spacing = level.min.w;
	// The point moves off its surface, so the probes behind it on the surface do not see it in their own shadow.
	float3 biased = p + n * grid.bias * spacing;
	float3 u = (biased - level.min.xyz) / spacing;
	if (any(u < 0) || any(u > float3(PROBE_GRID - 1))) {
		return false;
	}
	int3 base = min(int3(floor(u)), PROBE_GRID - 2);
	float3 f = saturate(u - float3(base));
	Texture2D<float4> values = cn_texture(radiance ? grid.radiance : grid.irradiance);
	Texture2D<float4> distances = cn_texture(grid.radiance);
	Texture2D<float4> squares = cn_texture(grid.irradiance);
	SamplerState s = cn_sampler(grid.sampler_index);
	float3 sum = 0;
	float total = 0;
	[unroll] for (uint c = 0; c < 8; c++) {
		int3 offset = int3(c & 1, (c >> 1) & 1, c >> 2);
		int3 cell = base + offset;
		uint storage = probe_storage(level, cell);
		uint state = cn_buffer(grid.states).Load(probe_state_index(l, storage));
		if ((state & PROBE_UPDATES_MASK) == 0 || (state & PROBE_INACTIVE) != 0) {
			continue;
		}
		float3 to_point = biased - probe_position(level, cell);
		float distance = length(to_point);
		float3 toward = distance > 1e-4 ? to_point / distance : n;
		float3 w3 = lerp(1 - f, f, float3(offset));
		float weight = w3.x * w3.y * w3.z;
		float facing = (dot(-toward, n) + 1) * 0.5;
		weight *= facing * facing + 0.05;
		float2 moments_uv = probe_uv(grid, l, storage, toward);
		float mean = distances.SampleLevel(s, moments_uv, 0).a;
		float square = squares.SampleLevel(s, moments_uv, 0).a;
		if (distance > mean) {
			float variance = abs(square - mean * mean);
			float d = distance - mean;
			float chebyshev = variance / max(variance + d * d, 1e-6);
			weight *= max(chebyshev * chebyshev * chebyshev, 0.02);
		}
		weight = max(weight, 1e-6);
		sum += values.SampleLevel(s, probe_uv(grid, l, storage, radiance ? direction : n), 0).rgb * weight;
		total += weight;
	}
	if (total < 1e-5) {
		return false;
	}
	light = sum / total;
	return true;
}

// sample_probes is the probes' light at a point relative to the camera: the finest level whose box holds it, blended
// into the next one over its outermost probe, so the levels meet without a seam. It is false outside every level, or
// where no probe counts; the caller then takes the ambient light.
bool sample_probes(Probe_Grid grid, float3 p, float3 n, float3 direction, bool radiance, out float3 light) {
	light = 0;
	for (uint l = 0; l < grid.level_count; l++) {
		Probe_Level level = grid.levels[l];
		float3 u = (p - level.min.xyz) / level.min.w;
		float3 inside = min(u, float3(PROBE_GRID - 1) - u);
		float edge = min(inside.x, min(inside.y, inside.z));
		if (edge < 0) {
			continue;
		}
		float3 here;
		if (!sample_level(grid, l, p, n, direction, radiance, here)) {
			continue;
		}
		float fade = saturate(edge - 1);
		float3 next;
		if (fade < 1 && l + 1 < grid.level_count && sample_level(grid, l + 1, p, n, direction, radiance, next)) {
			here = lerp(next, here, fade);
		}
		light = here;
		return true;
	}
	return false;
}

#endif
