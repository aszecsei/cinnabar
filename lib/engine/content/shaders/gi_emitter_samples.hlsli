// What the GI's emitters give the passes that light hits (see docs/rendering/global-illumination.md#emitters): the
// frame's table of listed submeshes, and the samples buffer, which gi_emitters.hlsl builds each frame: a header of the
// triangles' count and their total power, the distribution, each triangle's end of the cumulative share of the power,
// then the triangles relative to the camera.
#ifndef GI_EMITTER_SAMPLES_HLSLI
#define GI_EMITTER_SAMPLES_HLSLI

// Match lib/engine/render/gi_emitters.odin.
static const uint MAX_EMITTER_SUBMESHES = 256;
static const uint MAX_EMITTER_TRIANGLES = 16384;
static const uint EMITTER_SAMPLES_HEADER = 16;
static const uint EMITTER_TRIANGLES_FIRST = EMITTER_SAMPLES_HEADER + MAX_EMITTER_TRIANGLES * 4;
static const uint EMITTER_TWO_SIDED = 1;
// A built triangle whose front is against cross(e1, e2), by its vertices' normals.
static const uint EMITTER_FLIPPED = 2;
// The distribution's search takes at most this many steps: log2(MAX_EMITTER_TRIANGLES) + 1.
static const uint EMITTER_SEARCH_STEPS = 15;

// Matches Emitter_Table_Header in lib/engine/render/gi_emitters.odin: the listed submeshes and their triangles this
// frame, where hit_emitters, the listed submesh of each hit table record or ~0, starts, in bytes, the records, and
// where hit_transmitters, each record's first cell of the pool's transmittance or ~0, starts.
struct Emitter_Table_Header {
	uint count;
	uint triangles;
	uint hit_emitters;
	uint entries;
	uint hit_transmitters;
	uint3 padding;
};

// Matches Emitter_Submesh in lib/engine/render/gi_emitters.odin.
struct Emitter_Submesh {
	uint slot;
	uint mesh;
	uint first_primitive;
	uint primitive_count;
	uint first_triangle;
	uint radiance_base;
	uint flags;
	uint padding;
};

// A listed triangle as the build places it: its first corner relative to the camera and its edges, its emitted
// radiance as RGB9E5, its flags and its area.
struct Emitter_Triangle {
	float3 p0;
	uint radiance;
	float3 e1;
	uint flags;
	float3 e2;
	float area;
};

Emitter_Table_Header load_emitter_header(uint table, uint offset) {
	return cn_buffer(table).Load<Emitter_Table_Header>(offset);
}

Emitter_Submesh load_emitter_submesh(uint table, uint offset, uint index) {
	return cn_buffer(table).Load<Emitter_Submesh>(offset + sizeof(Emitter_Table_Header) + index * sizeof(Emitter_Submesh));
}

// emitter_front is a built triangle's front normal.
float3 emitter_front(Emitter_Triangle t) {
	float3 n = normalize(cross(t.e1, t.e2));
	return (t.flags & EMITTER_FLIPPED) != 0 ? -n : n;
}

// Emitter_Draw is a triangle drawn from the distribution, and the chance that it was.
struct Emitter_Draw {
	uint index;
	float chance;
};

// draw_emitter draws a triangle by a number in [0, 1): the first whose end of the cumulative share is above it. Its
// chance is its share, the difference of its end and the one before.
Emitter_Draw draw_emitter(ByteAddressBuffer samples, uint count, float u) {
	uint lo = 0;
	uint hi = count - 1;
	for (uint step = 0; step < EMITTER_SEARCH_STEPS && lo < hi; step++) {
		uint mid = (lo + hi) / 2;
		if (asfloat(samples.Load(EMITTER_SAMPLES_HEADER + mid * 4)) > u) {
			hi = mid;
		} else {
			lo = mid + 1;
		}
	}
	Emitter_Draw d;
	d.index = lo;
	float end = asfloat(samples.Load(EMITTER_SAMPLES_HEADER + lo * 4));
	float start = lo > 0 ? asfloat(samples.Load(EMITTER_SAMPLES_HEADER + (lo - 1) * 4)) : 0;
	d.chance = end - start;
	return d;
}

#endif
