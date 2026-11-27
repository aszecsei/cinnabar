// How the GI's rays and its hits' shadow rays pass through glass (see docs/rendering/global-illumination.md#many-lights):
// an instance with a translucent submesh is not opaque in the scene's structure, and the rays look each of its
// triangles that they meet up in the hit table. A translucent submesh's triangle lets through its transmittance, which
// the GI's emitters keep for each triangle in their pool (see gi_emitters.hlsl), or all the light while it has none.
#ifndef GI_TRANSLUCENCY_HLSLI
#define GI_TRANSLUCENCY_HLSLI

#include "ray_scene.hlsli"
#include "gi_emitter_samples.hlsli"

// A slot's submeshes. Match MAX_SUBMESHES in lib/engine/render/residency.odin.
static const uint HIT_MAX_SUBMESHES = 16;
// A GI ray keeps at most this many translucent triangles that it crosses; one more is a hit, so its loop is bounded.
static const uint TRACE_MAX_CROSSINGS = 8;

// Matches Translucency in lib/engine/render/gi_translucency.odin: the frame's hit table, and the GI's emitters' table
// and pool, whose cells give the translucent triangles' transmittance, when valid is 1: a bindless index of 0 is a
// buffer too.
struct Translucency {
	uint hit_instances;
	uint hit_instances_offset;
	uint hit_submeshes;
	uint hit_submeshes_offset;
	uint table;
	uint table_offset;
	uint pool;
	uint valid;
};

// hit_translucent is whether a primitive of a slot is a translucent submesh's, by the hit table, and the light that
// passes through it: its cell of the emitters' pool, or all of it while it has none or no ray has reached its cell.
bool hit_translucent(Translucency tr, uint slot, uint primitive, out float3 transmittance) {
	transmittance = 1;
	Hit_Instance instance = cn_buffer(tr.hit_instances).Load<Hit_Instance>(tr.hit_instances_offset + slot * sizeof(Hit_Instance));
	if ((instance.flags & HIT_INSTANCE_TRANSLUCENT) == 0) {
		return false;
	}
	for (uint k = 0; k < min(instance.count, HIT_MAX_SUBMESHES); k++) {
		uint entry = instance.first + k;
		Hit_Submesh submesh = cn_buffer(tr.hit_submeshes).Load<Hit_Submesh>(tr.hit_submeshes_offset + entry * sizeof(Hit_Submesh));
		if (primitive - submesh.first_primitive >= submesh.primitive_count) {
			continue;
		}
		if ((submesh.bin & HIT_TRANSLUCENT) == 0) {
			return false;
		}
		if (tr.valid != 0) {
			Emitter_Table_Header header = load_emitter_header(tr.table, tr.table_offset);
			if (entry < header.entries) {
				uint base = cn_buffer(tr.table).Load(tr.table_offset + header.hit_transmitters + entry * 4);
				if (base != ~0u) {
					float4 cell = cn_buffer(tr.pool).Load<float4>((base + primitive - submesh.first_primitive) * 16);
					transmittance = cell.w > 0 ? saturate(cell.rgb) : 1;
				}
			}
		}
		return true;
	}
	return false;
}

// trace_hit_through traces a ray as trace_hit does, nearest hit first, against the instances of mask and the
// translucent ones, but passes through the translucent triangles in front of its hit, and gives the product of their
// transmittance: the share of the hit's light, or of the sky's on a miss, that reaches the ray's origin. The triangles
// come in no order, so it keeps each that it crosses with its distance, and counts those nearer than the hit.
Hit_Record trace_hit_through(RaytracingAccelerationStructure accel, RayDesc ray, uint mask, float spread, Translucency tr, out float3 transmittance) {
	RayQuery<RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES> query;
	query.TraceRayInline(accel, 0, mask | RAY_MASK_TRANSLUCENT, ray);
	float crossed_t[TRACE_MAX_CROSSINGS];
	float3 crossed[TRACE_MAX_CROSSINGS];
	uint count = 0;
	while (query.Proceed()) {
		if (query.CandidateType() != CANDIDATE_NON_OPAQUE_TRIANGLE) {
			continue;
		}
		float3 through;
		if (count < TRACE_MAX_CROSSINGS && hit_translucent(tr, query.CandidateInstanceID(), query.CandidatePrimitiveIndex(), through)) {
			crossed_t[count] = query.CandidateTriangleRayT();
			crossed[count] = through;
			count++;
		} else {
			// An opaque submesh of an instance that is not opaque, or a crossing past the last that the ray keeps.
			query.CommitNonOpaqueTriangleHit();
		}
	}
	bool hit = query.CommittedStatus() == COMMITTED_TRIANGLE_HIT;
	float end = hit ? query.CommittedRayT() : ray.TMax;
	transmittance = 1;
	for (uint k = 0; k < TRACE_MAX_CROSSINGS; k++) {
		if (k >= count) {
			break;
		}
		if (crossed_t[k] < end) {
			transmittance *= crossed[k];
		}
	}
	if (!hit) {
		return make_miss(ray);
	}
	return make_hit(ray, spread, query.CommittedInstanceID(), query.CommittedTriangleFrontFace(), query.CommittedPrimitiveIndex(), query.CommittedTriangleBarycentrics(), end);
}

// store_transmittance keeps a ray's transmittance beside its hit, as RGB9E5.
void store_transmittance(uint buffer, uint ray, float3 transmittance) {
	cn_rw_buffer(buffer).Store(ray * 4, pack_rgb9e5(transmittance));
}

float3 load_transmittance(uint buffer, uint ray) {
	return unpack_rgb9e5(cn_buffer(buffer).Load(ray * 4));
}

#endif
