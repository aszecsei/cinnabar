// ReSTIR GI's ray guide (see docs/rendering/global-illumination.md#ray-guiding): a distribution of the light that
// reaches each cell of the world probes' first levels, which the rays draw some of their directions from. A cell is the
// space nearest one probe, at the same storage as the probe's, so the guide follows the camera as the probes do. Each
// cell keeps 8 x 8 leaves over the probes' octahedron, each the light that reaches the cell through it, integrated over
// its solid angle, and a quadtree of their sums above them: 4 x 4, 2 x 2 and the root. A ray walks the quadtree from the
// root, weighing each node by its light times a bound of the cosine at the ray's surface over the node, and then takes a
// point of its leaf uniformly in the octahedron's square. Every pixel of a cell teaches it: the temporal pass adds each
// ray's light over its pdf to its leaf, and the build pass makes the frame's sums the cells' learned light each frame,
// blended with the world probes' radiance where the cell has learned little. A guide that is wrong costs noise and
// never brightness: the rays take a share of cosine-weighted directions, and the pdf of the mixture weighs every ray.
#ifndef GI_RESTIR_GUIDE_HLSLI
#define GI_RESTIR_GUIDE_HLSLI

#include "gi_restir.hlsli"

// Match lib/engine/render/gi_restir_guide.odin.
static const uint GUIDE_SIDE = 8;
static const uint GUIDE_LEAVES = 64;
// A cell's floats: its learned light, its quadtree, the rays that it has learned from, its key and its tag.
static const uint GUIDE_STRIDE = 160;
static const uint GUIDE_LEARNED = 0;
static const uint GUIDE_CONFIDENCE = 149;
static const uint GUIDE_KEY = 150;
static const uint GUIDE_TAG_AT = 153;
static const uint GUIDE_TAG = 0x67756964;
// A cell's sums of this frame's rays: one for each leaf, then their count.
static const uint GUIDE_ACCUM_STRIDE = 68;
// The sums are in fixed point, in units of 1 / GUIDE_UNITS, and one ray adds at most GUIDE_DEPOSIT_MAX.
static const float GUIDE_UNITS = 64;
static const float GUIDE_DEPOSIT_MAX = 64;
// A ray's light over its pdf, as it adds to its leaf, takes a pdf of at least this, so a ray near the horizon does not
// add a spike.
static const float GUIDE_PDF_FLOOR = 0.1;
// Each node's cosine bound is at least this, so a node below the surface's horizon is still a little likely.
static const float GUIDE_HORIZON = 0.02;
static const float GUIDE_PI = 3.14159265;

// Matches Restir_Guide in lib/engine/render/gi_restir_guide.odin: each level's first world cell, the levels that have a
// guide, the share of the rays that it draws, its buffers, how many rays the world probes' prior counts as, and the
// share of a cell's light that its leaves take evenly.
struct Restir_Guide {
	int4 keys[MAX_PROBE_LEVELS];
	uint level_count;
	float mix;
	uint guide;
	uint guide_out;
	uint accum;
	uint accum_out;
	float prior_rays;
	float floor_share;
};

Restir_Guide restir_guide() {
	return cn_buffer(push.guide_grid).Load<Restir_Guide>(push.guide_offset);
}

// guide_level_offset is where a level of a cell's quadtree starts: the root at level 0, the leaves at level 3.
uint guide_level_offset(uint k) {
	return k == 0 ? 148 : k == 1 ? 144 : k == 2 ? 128 : 64;
}

// guide_cell is the cell of a point relative to the camera: the nearest probe of the finest level with a guide whose
// box holds it, as its level times the probes of a level plus its storage. It is false outside them.
bool guide_cell(Restir_Guide gd, Probe_Grid grid, float3 p, out uint cell) {
	cell = 0;
	uint levels = min(gd.level_count, grid.level_count);
	for (uint l = 0; l < levels; l++) {
		Probe_Level level = grid.levels[l];
		int3 c = int3(round((p - level.min.xyz) / level.min.w));
		if (all(c >= 0) && all(c < PROBE_GRID)) {
			cell = l * PROBE_COUNT + probe_storage(level, c);
			return true;
		}
	}
	return false;
}

// guide_leaf is the leaf of a direction, in the octahedron's square.
uint2 guide_leaf(float3 d) {
	float2 uv = probe_octahedral(d) * 0.5 + 0.5;
	return min(uint2(uv * GUIDE_SIDE), GUIDE_SIDE - 1);
}

// guide_jacobian is the solid angle of a direction per area of the octahedron's square, from -1 to 1 on each side: the
// cube of the direction's L1 length, from 1 at the poles to about 5.2 between them.
float guide_jacobian(float3 d) {
	float l1 = abs(d.x) + abs(d.y) + abs(d.z);
	return l1 * l1 * l1;
}

float guide_load(uint buffer, uint cell, uint at) {
	return asfloat(cn_buffer(buffer).Load((cell * GUIDE_STRIDE + at) * 4));
}

// guide_node_weight is how likely a walk that reaches a node's parent takes the node, before its siblings are summed:
// its light times a bound of the cosine over it at a surface, the largest cosine at its corners and center.
float guide_node_weight(uint buffer, uint cell, uint k, uint2 xy, float3 n) {
	uint side = 1u << k;
	float light = guide_load(buffer, cell, guide_level_offset(k) + xy.y * side + xy.x);
	float2 lo = float2(xy) / side * 2 - 1;
	float2 hi = float2(xy + 1) / side * 2 - 1;
	float c = dot(n, probe_unfold((lo + hi) * 0.5));
	c = max(c, dot(n, probe_unfold(lo)));
	c = max(c, dot(n, probe_unfold(hi)));
	c = max(c, dot(n, probe_unfold(float2(lo.x, hi.y))));
	c = max(c, dot(n, probe_unfold(float2(hi.x, lo.y))));
	return light * (saturate(c) + GUIDE_HORIZON);
}

// guide_sample is a direction from a cell's guide at a surface with a normal: a walk down the quadtree, a child at each
// level by its weight, then a point of the leaf uniformly in the octahedron's square.
float3 guide_sample(uint buffer, uint cell, float3 n, inout uint state) {
	uint2 xy = 0;
	for (uint k = 1; k <= 3; k++) {
		float w[4];
		float total = 0;
		[unroll] for (uint i = 0; i < 4; i++) {
			w[i] = guide_node_weight(buffer, cell, k, xy * 2 + uint2(i & 1, i >> 1), n);
			total += w[i];
		}
		float r = random_unit(state) * total;
		uint pick = 3;
		[unroll] for (uint j = 0; j < 3; j++) {
			if (r < w[j]) {
				pick = j;
				break;
			}
			r -= w[j];
		}
		xy = xy * 2 + uint2(pick & 1, pick >> 1);
	}
	float2 u = float2(random_unit(state), random_unit(state));
	return probe_unfold((float2(xy) + u) / GUIDE_SIDE * 2 - 1);
}

// guide_chance is the chance that a walk at a surface with a normal ends in a leaf.
float guide_chance(uint buffer, uint cell, float3 n, uint2 leaf) {
	float chance = 1;
	for (uint k = 1; k <= 3; k++) {
		uint2 parent = leaf >> (4 - k);
		uint2 mine = leaf >> (3 - k);
		float total = 0;
		float chosen = 0;
		[unroll] for (uint i = 0; i < 4; i++) {
			uint2 c = parent * 2 + uint2(i & 1, i >> 1);
			float w = guide_node_weight(buffer, cell, k, c, n);
			total += w;
			chosen = all(c == mine) ? w : chosen;
		}
		if (total <= 0) {
			return 0;
		}
		chance *= chosen / total;
	}
	return chance;
}

// guide_pdf is the density in solid angle of guide_sample's directions at a direction: the walk's chance of its leaf,
// over the leaf's area of the square, over the solid angle per area there.
float guide_pdf(uint buffer, uint cell, float3 n, float3 d) {
	float leaf_area = 4.0 / (GUIDE_SIDE * GUIDE_SIDE);
	return guide_chance(buffer, cell, n, guide_leaf(d)) / leaf_area / guide_jacobian(d);
}

// guide_mixture_pdf is the pdf of a ray's direction: a share of mix from the guide, the rest cosine-weighted.
float guide_mixture_pdf(uint buffer, uint cell, bool guided, float mix, float3 n, float3 d) {
	float cosine = saturate(dot(n, d)) / GUIDE_PI;
	if (!guided) {
		return cosine;
	}
	return (1 - mix) * cosine + mix * guide_pdf(buffer, cell, n, d);
}

// guide_deposit adds a ray's light over its pdf, pre-exposed, to the leaf of its direction in the cell of the point
// that it started from, and counts the ray there, in fixed point with a dither that keeps dim light's mean. The build
// pass takes the sums next frame. A point outside the guide's levels teaches nothing.
void guide_deposit(float3 p, float3 direction, float value, inout uint state) {
	Restir_Guide gd = restir_guide();
	uint cell;
	if (gd.level_count == 0 || constants.probes == 0 || !guide_cell(gd, load_probe_grid(constants.probe_grid, constants.probe_grid_offset), p, cell)) {
		return;
	}
	uint2 leaf = guide_leaf(direction);
	uint units = uint(min(value, GUIDE_DEPOSIT_MAX) * GUIDE_UNITS + random_unit(state));
	RWByteAddressBuffer accum = cn_rw_buffer(gd.accum_out);
	uint at = cell * GUIDE_ACCUM_STRIDE;
	if (units > 0) {
		accum.InterlockedAdd((at + leaf.y * GUIDE_SIDE + leaf.x) * 4, units);
	}
	accum.InterlockedAdd((at + GUIDE_LEAVES) * 4, 1);
}

#endif
