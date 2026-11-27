// The ray guide's cells (see docs/rendering/global-illumination.md#ray-guiding): the layout of a cell in the guide's
// buffer, its leaves over the probes' octahedron, and the walk of a probe, which has no surface, by the leaves' light
// alone. ReSTIR GI's rays walk with a cosine bound at their surface (gi_restir_guide.hlsli); the world probes' guided rays
// warp stratified points here, and read last frame's guide, before ReSTIR GI's build changes it (see
// docs/rendering/global-illumination.md#guided-probe-rays).
#ifndef GI_GUIDE_HLSLI
#define GI_GUIDE_HLSLI

#include "gi_probes.hlsli"
#include "hash.hlsli"

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
static const float GUIDE_PI = 3.14159265;

// guide_level_offset is where a level of a cell's quadtree starts: the root at level 0, the leaves at level 3.
uint guide_level_offset(uint k) {
	return k == 0 ? 148 : k == 1 ? 144 : k == 2 ? 128 : 64;
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

// guide_cell_valid is whether a cell holds a guide that its build made for a world cell's key, with light in it: a
// cell that its level's box moved over since, or that no build reached, is not.
bool guide_cell_valid(uint buffer, uint cell, int3 key) {
	ByteAddressBuffer b = cn_buffer(buffer);
	uint base = cell * GUIDE_STRIDE * 4;
	if (b.Load(base + GUIDE_TAG_AT * 4) != GUIDE_TAG || any(int3(b.Load3(base + GUIDE_KEY * 4)) != key)) {
		return false;
	}
	float root = guide_load(buffer, cell, guide_level_offset(0));
	return isfinite(root) && root > 0;
}

// guide_sphere_warp is a direction from a cell's guide over the whole sphere, from a point of the unit square warped
// down the quadtree: at each level the column of the four children by u.x against the columns' light, then the row by
// u.y against the chosen column's two, each rescaled, so the rest of u is the point in the leaf, uniformly in the
// octahedron's square. Its chance of a leaf is the leaf over the root, as a walk's, and stratified points stay
// stratified, so a probe's guided rays cover the guide as its Fibonacci rays cover the sphere.
float3 guide_sphere_warp(uint buffer, uint cell, float2 u) {
	uint2 xy = 0;
	for (uint k = 1; k <= 3; k++) {
		uint side = 1u << k;
		uint at = guide_level_offset(k);
		uint2 b = xy * 2;
		float n00 = max(guide_load(buffer, cell, at + b.y * side + b.x), 0);
		float n10 = max(guide_load(buffer, cell, at + b.y * side + b.x + 1), 0);
		float n01 = max(guide_load(buffer, cell, at + (b.y + 1) * side + b.x), 0);
		float n11 = max(guide_load(buffer, cell, at + (b.y + 1) * side + b.x + 1), 0);
		float left = n00 + n01;
		float right = n10 + n11;
		float x = u.x * (left + right);
		uint col = x < left ? 0 : 1;
		u.x = col == 0 ? x / left : (x - left) / right;
		float top = col == 0 ? n00 : n10;
		float bottom = col == 0 ? n01 : n11;
		float y = u.y * (top + bottom);
		uint row = y < top ? 0 : 1;
		u.y = row == 0 ? y / top : (y - top) / bottom;
		u = clamp(u, 0, 0.99999);
		xy = b + uint2(col, row);
	}
	return probe_unfold((float2(xy) + u) / GUIDE_SIDE * 2 - 1);
}

// guide_sphere_pdf is the density in solid angle of guide_sphere_warp's directions, from uniform points, at a direction.
// Each node is the sum of its children, so the chance of a leaf is the leaf over the root; over the leaf's area of the
// square and the solid angle per area there, it is a density.
float guide_sphere_pdf(uint buffer, uint cell, float3 d) {
	uint2 leaf = guide_leaf(d);
	float root = guide_load(buffer, cell, guide_level_offset(0));
	float light = max(guide_load(buffer, cell, guide_level_offset(3) + leaf.y * GUIDE_SIDE + leaf.x), 0);
	float leaf_area = 4.0 / (GUIDE_SIDE * GUIDE_SIDE);
	return light / root / leaf_area / guide_jacobian(d);
}

#endif
