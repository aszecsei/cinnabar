// The clouds' noise textures (see docs/rendering/clouds.md#shape), which the GPU makes once: the shape noise, the
// detail noise and the curl noise. Every texel is sampled at its center, and every lattice lookup wraps at the
// texture's cells, the Worley search's neighbors included, so a repeat sampler reads them without a seam. push.kind
// picks the texture: 0 the shape, 128^3, 1 the detail, 32^3, 2 the curl, 128^2.
#include "clouds_common.hlsli"

static const uint KIND_SHAPE = 0;
static const uint KIND_DETAIL = 1;
static const uint KIND_CURL = 2;
static const uint SHAPE_SIZE = 128;
static const uint DETAIL_SIZE = 32;
static const uint CURL_SIZE = 128;

uint pcg(uint x) {
	uint state = x * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

// lattice_hash is the hash of a lattice point, wrapped at the cells, so the noise tiles.
uint lattice_hash(int3 c, int cells) {
	c = ((c % cells) + cells) % cells;
	return pcg(uint(c.x) + pcg(uint(c.y) + pcg(uint(c.z) + 0x9e3779b9u)));
}

uint lattice_hash2(int2 c, int cells) {
	c = ((c % cells) + cells) % cells;
	return pcg(uint(c.x) + pcg(uint(c.y) + 0x7f4a7c15u));
}

float unit_float(uint h) {
	return (h >> 8) * (1.0 / 16777216.0);
}

float3 gradient3(uint h) {
	// The twelve edge directions of a cube, as Perlin's improved noise has them.
	const float3 g[12] = {
		float3(1, 1, 0), float3(-1, 1, 0), float3(1, -1, 0), float3(-1, -1, 0),
		float3(1, 0, 1), float3(-1, 0, 1), float3(1, 0, -1), float3(-1, 0, -1),
		float3(0, 1, 1), float3(0, -1, 1), float3(0, 1, -1), float3(0, -1, -1),
	};
	return g[h % 12];
}

float2 gradient2(uint h) {
	float angle = unit_float(h) * 2 * CLOUD_PI;
	return float2(cos(angle), sin(angle));
}

float3 fade(float3 t) {
	return t * t * t * (t * (t * 6 - 15) + 10);
}

float2 fade2(float2 t) {
	return t * t * t * (t * (t * 6 - 15) + 10);
}

float2 dfade2(float2 t) {
	return 30 * t * t * (t * (t - 2) + 1);
}

// perlin3 is tiling gradient noise at a point in cells, in about [-1, 1].
float perlin3(float3 p, int cells) {
	float3 c = floor(p);
	float3 f = p - c;
	float3 u = fade(f);
	int3 cell = int3(c);
	float result = 0;
	[unroll] for (uint i = 0; i < 8; i++) {
		int3 corner = int3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
		float3 g = gradient3(lattice_hash(cell + corner, cells));
		float3 w = lerp(1 - u, u, float3(corner));
		result += dot(g, f - float3(corner)) * w.x * w.y * w.z;
	}
	return result;
}

// perlin_fbm is perlin3 over octaves from a number of cells, each twice the one before with half the amplitude,
// remapped to [0, 1].
float perlin_fbm(float3 uvw, int first_cells, uint octaves) {
	float result = 0;
	float amplitude = 1;
	float total = 0;
	int cells = first_cells;
	for (uint i = 0; i < octaves; i++) {
		result += perlin3(uvw * float(cells), cells) * amplitude;
		total += amplitude;
		amplitude *= 0.5;
		cells *= 2;
	}
	return saturate(result / total * 0.5 + 0.5);
}

// worley3 is the distance, in cells, from a point to the nearest feature point of a tiling cell grid.
float worley3(float3 p, int cells) {
	int3 cell = int3(floor(p));
	float nearest = 1e9;
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				int3 n = cell + int3(x, y, z);
				uint h = lattice_hash(n, cells);
				float3 feature = float3(n) + float3(unit_float(h), unit_float(pcg(h)), unit_float(pcg(pcg(h))));
				float3 d = p - feature;
				nearest = min(nearest, dot(d, d));
			}
		}
	}
	return sqrt(nearest);
}

// inverted_worley is 1 at a feature point and 0 a cell away: the billows of a cloud.
float inverted_worley(float3 uvw, int cells) {
	return saturate(1 - worley3(uvw * float(cells), cells));
}

// perlin2_gradient is tiling 2D gradient noise and its derivative, for the curl.
float perlin2_gradient(float2 p, int cells, out float2 derivative) {
	float2 c = floor(p);
	float2 f = p - c;
	float2 u = fade2(f);
	float2 du = dfade2(f);
	int2 cell = int2(c);
	float2 g00 = gradient2(lattice_hash2(cell, cells));
	float2 g10 = gradient2(lattice_hash2(cell + int2(1, 0), cells));
	float2 g01 = gradient2(lattice_hash2(cell + int2(0, 1), cells));
	float2 g11 = gradient2(lattice_hash2(cell + int2(1, 1), cells));
	float n00 = dot(g00, f);
	float n10 = dot(g10, f - float2(1, 0));
	float n01 = dot(g01, f - float2(0, 1));
	float n11 = dot(g11, f - float2(1, 1));
	float nx0 = lerp(n00, n10, u.x);
	float nx1 = lerp(n01, n11, u.x);
	float value = lerp(nx0, nx1, u.y);
	float2 gx0 = lerp(g00, g10, u.x);
	float2 gx1 = lerp(g01, g11, u.x);
	float2 g = lerp(gx0, gx1, u.y);
	derivative.x = g.x + du.x * lerp(n10 - n00, n11 - n01, u.y);
	derivative.y = g.y + du.y * (nx1 - nx0);
	return value;
}

[numthreads(8, 8, 8)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	switch (push.kind) {
	case KIND_SHAPE: {
		if (any(id >= SHAPE_SIZE)) {
			return;
		}
		float3 uvw = (float3(id) + 0.5) / SHAPE_SIZE;
		float perlin = perlin_fbm(uvw, 4, 5);
		float w4 = inverted_worley(uvw, 4);
		float w8 = inverted_worley(uvw, 8);
		float w16 = inverted_worley(uvw, 16);
		float worley = 0.625 * w4 + 0.25 * w8 + 0.125 * w16;
		// Perlin-Worley: the billows carve the gradient noise's low end.
		float r = remap(perlin, 0, 1, worley, 1);
		cn_rw_texture3d(push.output)[id] = float4(saturate(r), w4, w8, w16);
		break;
	}
	case KIND_DETAIL: {
		if (any(id >= DETAIL_SIZE)) {
			return;
		}
		float3 uvw = (float3(id) + 0.5) / DETAIL_SIZE;
		cn_rw_texture3d(push.output)[id] = float4(inverted_worley(uvw, 2), inverted_worley(uvw, 4), inverted_worley(uvw, 8), 1);
		break;
	}
	case KIND_CURL: {
		if (id.z != 0 || any(id.xy >= CURL_SIZE)) {
			return;
		}
		float2 uv = (float2(id.xy) + 0.5) / CURL_SIZE;
		float2 d;
		perlin2_gradient(uv * 4, 4, d);
		// The curl of the potential is divergence-free: (d/dy, -d/dx). The derivative of a unit gradient's noise stays
		// within about 2.5 per cell.
		float2 curl = float2(d.y, -d.x) / 2.5;
		cn_rw_texture(push.output)[id.xy] = float4(saturate(curl * 0.5 + 0.5), 0, 1);
		break;
	}
	}
}
