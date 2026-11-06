// The voxel cones' clipmap (see docs/rendering/global-illumination.md#voxel-cones): nested boxes of res^3 voxels around
// the camera, each level's voxels twice the size of the one before's. Each level keeps the surfaces that its voxels
// hold, which the voxelization writes, and the light that they send out, which the injection writes and cones trace
// through. A level's storage is toroidal: a voxel's texel is its world cell modulo res, so the box follows the camera
// without moving what it holds, and a sampler that wraps filters across the seam.
#ifndef GI_VOXEL_HLSLI
#define GI_VOXEL_HLSLI

#include "cinnabar.hlsli"

// Match lib/engine/render/gi_voxel.odin.
static const uint VOXEL_MAX_LEVELS = 8;
static const uint VOXEL_MAX_CONES = 16;
static const uint VOXEL_GROUP = 4;
// A cone stops once this much of its light is blocked.
static const float VOXEL_MAX_ALPHA = 0.95;
// A cone's steps are this share of its width.
static const float VOXEL_STEP = 0.5;
// The most steps of one cone, past which it stops.
static const uint VOXEL_MAX_STEPS = 96;

// Matches Voxel_Level in lib/engine/render/gi_voxel.odin. min is the level's first voxel's corner relative to the camera,
// with the voxel's size in w. uvw maps a point relative to the camera to the level's textures: p * uvw.w + uvw.xyz.
// phase is the first voxel's texel, with whether the level holds voxels yet in w. reads and writes are the albedo's,
// the normal's, the emission's and the radiance's views, and mask the mask's read and write views.
struct Voxel_Level {
	float4 min;
	float4 uvw;
	int4 phase;
	uint4 reads;
	uint4 writes;
	uint4 mask;
};

// Matches Voxel_Grid in lib/engine/render/gi_voxel.odin. cones are the diffuse cones' directions around +z, each with
// its weight in w, and cone_aperture the tangent of their half angle. lights lists the punctual lights that the
// injection lights the voxels with, after the directional ones.
struct Voxel_Grid {
	Voxel_Level levels[VOXEL_MAX_LEVELS];
	float4 cones[VOXEL_MAX_CONES];
	uint level_count;
	uint res;
	uint sampler_index;
	uint cone_count;
	float cone_aperture;
	float specular_aperture;
	float shadow_aperture;
	uint frame;
	uint lights;
	uint lights_offset;
	uint light_count;
	uint padding;
};

Voxel_Grid load_voxel_grid(uint buffer, uint offset) {
	return cn_buffer(buffer).Load<Voxel_Grid>(offset);
}

float voxel_size(Voxel_Level l) {
	return l.min.w;
}

// voxel_local is a point's place in a level's box, in voxels from its first corner.
float3 voxel_local(Voxel_Level l, float3 p) {
	return (p - l.min.xyz) / l.min.w;
}

// voxel_inside is whether a level holds a point, at least margin voxels in from its faces.
bool voxel_inside(Voxel_Grid g, uint k, float3 p, float margin) {
	if (k >= g.level_count || g.levels[k].phase.w == 0) {
		return false;
	}
	float3 local = voxel_local(g.levels[k], p);
	return all(local >= margin) && all(local <= float(g.res) - margin);
}

// voxel_texel is the texel of a voxel of a level, by its place in the box.
uint3 voxel_texel(Voxel_Grid g, uint k, int3 cell) {
	int res = int(g.res);
	return uint3(((cell + g.levels[k].phase.xyz) % res + res) % res);
}

// voxel_cell_center is the middle of a voxel of a level, relative to the camera.
float3 voxel_cell_center(Voxel_Level l, int3 cell) {
	return l.min.xyz + (float3(cell) + 0.5) * l.min.w;
}

// voxel_level_of is the finest level whose box holds a point, from a level up, or level_count for none.
uint voxel_level_of(Voxel_Grid g, uint from, float3 p, float margin) {
	uint k = from;
	while (k < g.level_count && !voxel_inside(g, k, p, margin)) {
		k++;
	}
	return k;
}

// The surfaces' attributes, each in an R32_Uint texel. A voxel's fragments all write the same voxel at once, so the
// albedo and the normal are each one fragment's, the one with the largest key, a hash of where in the voxel it is,
// which InterlockedMax picks whatever the order the fragments come in. So a level that voxelizes the same surfaces
// again holds the same voxels: running means in a compare and swap, as Crassin and Green keep them ("Octree-Based
// Sparse Voxelization Using the GPU Hardware Rasterizer", OpenGL Insights 22), took the fragments in the order that
// they came, and moved a little each time, which flickered.
static const uint VOXEL_KEY_SHIFT = 24;

// voxel_key is a fragment's key: a hash of the quarter of a voxel that it is in.
uint voxel_key(float3 local) {
	uint3 q = uint3(int3(floor(local * 4)) & 0x3ff);
	uint h = q.x * 73856093u ^ q.y * 19349663u ^ q.z * 83492791u;
	h ^= h >> 15;
	h *= 0x2c1b3c6du;
	h ^= h >> 12;
	return (h & 0xff) << VOXEL_KEY_SHIFT;
}

// The albedo's texel: the key, then 8 bits a channel.
uint voxel_pack_albedo(float3 albedo, uint key) {
	uint3 a = uint3(round(saturate(albedo) * 255));
	return key | a.r | (a.g << 8) | (a.b << 16);
}

float3 voxel_albedo(uint word) {
	return float3(word & 255, (word >> 8) & 255, (word >> 16) & 255) / 255;
}

// The normal's texel: the key, then the normal folded into the octahedron, 12 bits a coordinate.
uint voxel_pack_normal(float3 n, uint key) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	float2 p = n.xy;
	if (n.z < 0) {
		p = (1 - abs(p.yx)) * float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
	}
	uint2 q = uint2(round(saturate(p * 0.5 + 0.5) * 4095));
	return key | q.x | (q.y << 12);
}

float3 voxel_normal(uint word) {
	float2 p = float2(word & 4095, (word >> 12) & 4095) / 4095 * 2 - 1;
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		n.xy = (1 - abs(n.yx)) * float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
	}
	return normalize(n);
}

// The mask's texel: which of the voxel's eight half-size cubes a fragment covered, which gives its opacity.
//
// voxel_opacity is how much of the light through a voxel its surfaces block: the largest share of its cross-section
// that they cover along any axis, from which of its half-size cubes they are in. A wall through a voxel covers half of
// its cubes but blocks all of a ray across it; a share of the cubes would let half of the light through.
float voxel_opacity(uint mask) {
	uint x = countbits((mask | (mask >> 1)) & 0x55);
	uint y = countbits((mask | (mask >> 2)) & 0x33);
	uint z = countbits((mask | (mask >> 4)) & 0x0f);
	return max(x, max(y, z)) / 4.0;
}

// The emission's texel: RGB9E5, a 5-bit exponent that the three 9-bit mantissas share. InterlockedMax keeps the
// fragment whose packed emission is largest, whatever the order.
static const int RGB9E5_BIAS = 15;
static const int RGB9E5_MANTISSA = 9;
static const float RGB9E5_MAX = 65408;

uint voxel_pack_emission(float3 c) {
	c = clamp(c, 0, RGB9E5_MAX);
	float m = max(c.r, max(c.g, c.b));
	int e = max(-RGB9E5_BIAS - 1, int(floor(log2(max(m, 1e-30))))) + 1 + RGB9E5_BIAS;
	float denom = exp2(float(e - RGB9E5_BIAS - RGB9E5_MANTISSA));
	if (uint(round(m / denom)) == (1u << RGB9E5_MANTISSA)) {
		denom *= 2;
		e += 1;
	}
	uint3 q = min(uint3(round(c / denom)), 511u);
	return q.r | (q.g << 9) | (q.b << 18) | (uint(e) << 27);
}

float3 voxel_emission(uint word) {
	float scale = exp2(float(int(word >> 27) - RGB9E5_BIAS - RGB9E5_MANTISSA));
	return float3(word & 511, (word >> 9) & 511, (word >> 18) & 511) * scale;
}

// voxel_sample is a level's light and opacity at a point, filtered: the radiance premultiplied by the opacity.
float4 voxel_sample(Voxel_Grid g, uint k, float3 p) {
	Voxel_Level l = g.levels[k];
	return cn_texture3d(NonUniformResourceIndex(l.reads.w)).SampleLevel(cn_sampler(g.sampler_index), p * l.uvw.w + l.uvw.xyz, 0);
}

// cone_trace marches a cone from a point along a direction, whose width is 2 * aperture times the distance, front to
// back through the levels' light, from a distance to another, never finer than a level. Each step samples the level
// whose voxels are as wide as the cone, blended with the next by how far between them it is, or the last level once the
// cone is wider than its voxels, and its opacity is corrected for the step's length. It gives the light that reaches the
// point and the share blocked, and stops past the last level's box: the caller adds what lies beyond, by what is not
// blocked.
float4 cone_trace(Voxel_Grid g, float3 origin, float3 direction, float aperture, float start, float end, uint min_level) {
	float3 light = 0;
	float alpha = 0;
	float t = start;
	float finest = voxel_size(g.levels[0]);
	for (uint i = 0; i < VOXEL_MAX_STEPS && alpha < VOXEL_MAX_ALPHA && t < end; i++) {
		float3 p = origin + direction * t;
		float width = max(2 * aperture * t, finest * exp2(float(min_level)));
		float lod = clamp(log2(width / finest), float(min_level), float(g.level_count - 1));
		uint k = voxel_level_of(g, uint(lod), p, 1);
		if (k >= g.level_count) {
			break;
		}
		float4 s = voxel_sample(g, k, p);
		float blend = k == uint(lod) ? frac(lod) : 0;
		if (blend > 0 && voxel_inside(g, k + 1, p, 1)) {
			s = lerp(s, voxel_sample(g, k + 1, p), blend);
		}
		float size = voxel_size(g.levels[k]);
		float step = max(width, size) * VOXEL_STEP;
		if (s.a > 0) {
			float corrected = 1 - pow(saturate(1 - s.a), step / size);
			light += (1 - alpha) * s.rgb * (corrected / s.a);
			alpha += (1 - alpha) * corrected;
		}
		t += step;
	}
	return float4(light, alpha);
}

// cone_basis is two directions that make a frame with a normal.
void cone_basis(float3 n, out float3 t, out float3 b) {
	float3 up = abs(n.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0);
	t = normalize(cross(up, n));
	b = cross(n, t);
}

#endif
