// Writes the GPU scene's changed records to their slots (see docs/rendering/gpu-scene.md#gpu-scene): the frame's records
// and their slots are in the upload ring, and a thread copies each 16 bytes of a record.
#include "cinnabar.hlsli"

// Matches Scatter_Constants in lib/engine/render/scene.odin. The records and their slots are in the upload ring, at
// these offsets of its buffers, and instances is the persistent buffer's write view.
struct Scatter_Constants {
	uint records;
	uint records_offset;
	uint slots;
	uint slots_offset;
	uint count;
	uint instances;
	uint2 padding;
};
CN_PASS_CONSTANTS(Scatter_Constants, constants);

// Matches size_of(Instance_Record) and SCATTER_GROUP_SIZE in lib/engine/render/scene.odin.
static const uint RECORD_SIZE = 112;
static const uint RECORD_QUADS = RECORD_SIZE / 16;
static const uint SCATTER_GROUP_SIZE = 64;

[numthreads(SCATTER_GROUP_SIZE, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint record = id.x / RECORD_QUADS;
	if (record >= constants.count) {
		return;
	}
	uint quad = id.x % RECORD_QUADS;
	uint slot = cn_buffer(constants.slots).Load(constants.slots_offset + record * 4);
	uint4 value = cn_buffer(constants.records).Load4(constants.records_offset + record * RECORD_SIZE + quad * 16);
	cn_rw_buffer(constants.instances).Store4(slot * RECORD_SIZE + quad * 16, value);
}
