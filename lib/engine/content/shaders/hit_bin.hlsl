// Bins a client's ray hits by the material pipeline of what each hit (see docs/rendering/ray-scene.md#hit-shading), in
// four phases, a dispatch each:
//   Clear: zeroes each bin's count and cursor.
//   Count: a thread for each ray finds its hit's submesh in the hit table, writes the hit's bin and entry, and counts
//   it in its bin.
//   Offsets: one thread gives each bin its first ray in the order and its dispatch's arguments.
//   Scatter: a thread for each ray writes it into its bin's range of the order.
// Each bin's material then evaluates its rays with one indirect dispatch (see material_hit.hlsli).
#include "ray_scene.hlsli"

// Matches Hit_Bin_Constants in lib/engine/render/ray_scene.odin. The hit table is in the upload ring, at these offsets
// of its buffers.
struct Hit_Bin_Constants {
	uint phase;
	uint ray_count;
	uint hits;
	uint order;
	uint bins;
	uint arguments;
	uint hit_instances;
	uint hit_instances_offset;
	uint hit_submeshes;
	uint hit_submeshes_offset;
	uint instance_count;
	uint padding;
};
CN_PASS_CONSTANTS(Hit_Bin_Constants, constants);

static const uint PHASE_CLEAR = 0;
static const uint PHASE_COUNT = 1;
static const uint PHASE_OFFSETS = 2;
static const uint PHASE_SCATTER = 3;

[numthreads(HIT_GROUP_SIZE, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	RWByteAddressBuffer bins = cn_rw_buffer(constants.bins);
	if (constants.phase == PHASE_CLEAR) {
		if (id.x < MAX_HIT_BINS) {
			bins.Store(HIT_BIN_COUNTS + id.x * 4, 0);
			bins.Store(HIT_BIN_CURSORS + id.x * 4, 0);
		}
		return;
	}
	if (constants.phase == PHASE_OFFSETS) {
		if (id.x != 0) {
			return;
		}
		RWByteAddressBuffer arguments = cn_rw_buffer(constants.arguments);
		uint offset = 0;
		for (uint b = 0; b < MAX_HIT_BINS; b++) {
			uint count = bins.Load(HIT_BIN_COUNTS + b * 4);
			bins.Store(HIT_BIN_OFFSETS + b * 4, offset);
			arguments.Store3(b * 12, uint3((count + HIT_GROUP_SIZE - 1) / HIT_GROUP_SIZE, 1, 1));
			offset += count;
		}
		return;
	}
	uint ray = id.x;
	if (ray >= constants.ray_count) {
		return;
	}
	RWByteAddressBuffer hits = cn_rw_buffer(constants.hits);
	Hit_Record hit = hits.Load<Hit_Record>(ray * sizeof(Hit_Record));
	if (hit_missed(hit)) {
		return;
	}
	if (constants.phase == PHASE_COUNT) {
		// The submesh whose primitives hold the hit's: a mesh's structure is one geometry of all its triangles. A hit of
		// an instance without records, which cannot be, takes the fallback.
		uint slot = hit.instance & HIT_SLOT_MASK;
		hit.bin = 0;
		hit.entry = ~0u;
		if (slot < constants.instance_count) {
			Hit_Instance instance = cn_buffer(constants.hit_instances).Load<Hit_Instance>(constants.hit_instances_offset + slot * sizeof(Hit_Instance));
			for (uint k = 0; k < instance.count; k++) {
				uint entry = instance.first + k;
				Hit_Submesh submesh = cn_buffer(constants.hit_submeshes).Load<Hit_Submesh>(constants.hit_submeshes_offset + entry * sizeof(Hit_Submesh));
				if (hit.primitive - submesh.first_primitive < submesh.primitive_count) {
					hit.bin = submesh.bin & HIT_BIN_MASK;
					hit.entry = entry;
					break;
				}
			}
		}
		hits.Store<Hit_Record>(ray * sizeof(Hit_Record), hit);
		uint ignored;
		bins.InterlockedAdd(HIT_BIN_COUNTS + hit.bin * 4, 1, ignored);
		return;
	}
	// PHASE_SCATTER
	uint index;
	bins.InterlockedAdd(HIT_BIN_CURSORS + hit.bin * 4, 1, index);
	cn_rw_buffer(constants.order).Store((bins.Load(HIT_BIN_OFFSETS + hit.bin * 4) + index) * 4, ray);
}
