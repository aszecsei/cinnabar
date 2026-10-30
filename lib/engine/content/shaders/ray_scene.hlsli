// The ray scene's records (see docs/rendering/ray-scene.md#ray-scene): what a pass that traces the scene's
// acceleration structure writes for each ray, and what hit shading gives back. A client traces with trace_hit, which
// stores a Hit_Record for the ray, and once lib/engine/render's add_hit_shading has run, reads each hit's surface with
// load_hit_surface.
#ifndef RAY_SCENE_HLSLI
#define RAY_SCENE_HLSLI

#include "cinnabar.hlsli"

// Match RAY_MASK_SHADOWS and RAY_MASK_SURFACES in lib/engine/render/ray_scene.odin: the instance mask bits of the
// scene's structure. The shadow rays see the instances that cast shadows, and hit shading those with a surface.
static const uint RAY_MASK_SHADOWS = 0x01;
static const uint RAY_MASK_SURFACES = 0x02;

// Matches HIT_GROUP_SIZE in lib/engine/render/ray_scene.odin: the threads of each group of the binning and of each
// hit shader.
static const uint HIT_GROUP_SIZE = 64;
// Matches MAX_HIT_BINS: bin 0, the fallback's, then a bin for each material pipeline.
static const uint MAX_HIT_BINS = 257;

// A Hit_Record's instance: the ray's hit's slot in the GPU scene, with HIT_FRONT when it hit a front face, or
// HIT_MISS when it hit nothing.
static const uint HIT_MISS = ~0u;
static const uint HIT_FRONT = 1u << 31;
static const uint HIT_SLOT_MASK = HIT_FRONT - 1;

// Matches Hit_Record in lib/engine/render/ray_scene.odin: one ray's hit. barycentrics are the hit's second and third
// corners' weights as unorm16, and direction the ray's, folded into the octahedron as snorm16. cone_width is how wide
// the ray's cone is at the hit, which picks the textures' levels; 0 samples their finest. The binning writes bin and
// entry, the hit's submesh in the frame's Hit_Submesh records.
struct Hit_Record {
	uint instance;
	uint primitive;
	uint barycentrics;
	uint direction;
	float t;
	float cone_width;
	uint bin;
	uint entry;
};

// Hit_Surface's flags, in the high byte of albedo. A fallback surface's material was not evaluated: a translucent one,
// or one whose hit pipeline is not ready. A cutout is a masked material's hole, which rays do not pass through. A
// surface without lighting gives only its emission. A back is a back face of a one-sided surface.
static const uint HIT_SURFACE_FALLBACK = 1;
static const uint HIT_SURFACE_CUTOUT = 2;
static const uint HIT_SURFACE_NO_LIGHTING = 4;
static const uint HIT_SURFACE_BACK = 8;

// Matches Hit_Surface in lib/engine/render/ray_scene.odin: what hit shading gives for one ray's hit. position is
// relative to the render origin. normal is the shading normal and geometric the triangle's, toward the side the ray came
// from, each folded into the octahedron as snorm16. albedo is the diffuse albedo as unorm8, with the flags in its high
// byte. emission is its light, and roughness the shading model's, or 1, as halves.
struct Hit_Surface {
	float3 position;
	uint normal;
	uint geometric;
	uint albedo;
	uint emission_rg;
	uint emission_b_roughness;
};

// Match Hit_Instance and Hit_Submesh in lib/engine/render/ray_scene.odin: the hit table, which the frame uploads. A
// slot's instance names its mesh record and its submeshes' first record and count. A submesh's record has its
// primitives, its material's block and its bin, with HIT_TRANSLUCENT for a transparent or additive material's.
static const uint HIT_BIN_MASK = 0xffffff;
static const uint HIT_TRANSLUCENT = 1u << 24;
struct Hit_Instance {
	uint mesh;
	uint first;
	uint count;
	uint flags;
};
struct Hit_Submesh {
	uint first_primitive;
	uint primitive_count;
	uint block;
	uint bin;
};

// Matches Hit_Push in lib/engine/render/ray_scene.odin: what each bin's dispatch of hit shading pushes. bins holds each
// bin's count, then its offset in order, which lists the rays of each bin.
struct Hit_Push {
	uint bin;
	uint hits;
	uint order;
	uint bins;
	uint surfaces;
	uint hit_instances;
	uint hit_instances_offset;
	uint hit_submeshes;
	uint hit_submeshes_offset;
};
// The words of the bins buffer: each bin's count, its first ray in order, and its cursor for the scatter.
static const uint HIT_BIN_COUNTS = 0;
static const uint HIT_BIN_OFFSETS = MAX_HIT_BINS * 4;
static const uint HIT_BIN_CURSORS = 2 * MAX_HIT_BINS * 4;

// hit_pack_unit folds a unit vector into the octahedron, as two snorm16.
uint hit_pack_unit(float3 n) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	float2 p = n.xy;
	if (n.z < 0) {
		float2 sign_xy = float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
		p = (1 - abs(p.yx)) * sign_xy;
	}
	int2 v = int2(round(clamp(p, -1, 1) * 32767));
	return (uint(v.x) & 0xffff) | (uint(v.y) << 16);
}

float3 hit_unpack_unit(uint word) {
	int2 v = int2(int(word << 16) >> 16, int(word) >> 16);
	float2 p = max(float2(v) / 32767.0, -1.0);
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

// trace_hit traces a ray, whose origin is relative to the render origin as the structure is, against the instances of
// mask, nearest hit first, and gives its record. Each triangle is opaque. spread is the cone's angle per meter of
// distance, which cone_width grows by.
Hit_Record trace_hit(RaytracingAccelerationStructure accel, RayDesc ray, uint mask, float spread) {
	RayQuery<RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES | RAY_FLAG_FORCE_OPAQUE> query;
	query.TraceRayInline(accel, 0, mask, ray);
	query.Proceed();
	Hit_Record hit;
	hit.direction = hit_pack_unit(ray.Direction);
	hit.bin = 0;
	hit.entry = 0;
	if (query.CommittedStatus() != COMMITTED_TRIANGLE_HIT) {
		hit.instance = HIT_MISS;
		hit.primitive = 0;
		hit.barycentrics = 0;
		hit.t = ray.TMax;
		hit.cone_width = 0;
		return hit;
	}
	float2 b = saturate(query.CommittedTriangleBarycentrics());
	hit.instance = query.CommittedInstanceID() | (query.CommittedTriangleFrontFace() ? HIT_FRONT : 0);
	hit.primitive = query.CommittedPrimitiveIndex();
	hit.barycentrics = uint(round(b.x * 65535)) | (uint(round(b.y * 65535)) << 16);
	hit.t = query.CommittedRayT();
	hit.cone_width = spread * hit.t;
	return hit;
}

bool hit_missed(Hit_Record hit) {
	return hit.instance == HIT_MISS;
}

void store_hit(uint hits, uint ray, Hit_Record hit) {
	cn_rw_buffer(hits).Store<Hit_Record>(ray * sizeof(Hit_Record), hit);
}

Hit_Record load_hit(uint hits, uint ray) {
	return cn_buffer(hits).Load<Hit_Record>(ray * sizeof(Hit_Record));
}

Hit_Surface load_hit_surface(uint surfaces, uint ray) {
	return cn_buffer(surfaces).Load<Hit_Surface>(ray * sizeof(Hit_Surface));
}

float3 hit_albedo(Hit_Surface s) {
	return float3(s.albedo & 0xff, (s.albedo >> 8) & 0xff, (s.albedo >> 16) & 0xff) / 255.0;
}

uint hit_flags(Hit_Surface s) {
	return s.albedo >> 24;
}

float3 hit_emission(Hit_Surface s) {
	return float3(f16tof32(s.emission_rg), f16tof32(s.emission_rg >> 16), f16tof32(s.emission_b_roughness));
}

float hit_roughness(Hit_Surface s) {
	return f16tof32(s.emission_b_roughness >> 16);
}

// pack_hit_surface gives a surface as hit shading writes it.
Hit_Surface pack_hit_surface(float3 position, float3 normal, float3 geometric, float3 albedo, float3 emission, float roughness, uint flags) {
	uint3 a = uint3(round(saturate(albedo) * 255));
	Hit_Surface s;
	s.position = position;
	s.normal = hit_pack_unit(normal);
	s.geometric = hit_pack_unit(geometric);
	s.albedo = a.x | (a.y << 8) | (a.z << 16) | (flags << 24);
	s.emission_rg = f32tof16(emission.r) | (f32tof16(emission.g) << 16);
	s.emission_b_roughness = f32tof16(emission.b) | (f32tof16(roughness) << 16);
	return s;
}

#endif
