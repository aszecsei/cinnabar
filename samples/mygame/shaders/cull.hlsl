#include "cinnabar.hlsli"
#include "pass.hlsli"
#include "objects.hlsli"

// Matches Cull_Constants in game.odin.
struct Push {
	uint arguments;
	uint count;
	uint visible;
	uint object_count;
	uint2 grid;
};
CN_PUSH_CONSTANTS(Push, push);


// Matches gpu.Draw_Indexed_Indirect_Args.
static const uint DRAW_RECORD_SIZE = 24;

// Each visible object gets an indexed draw record, and its object index at the same slot in the visible list.
// The draw ID is the record's index, which is portable (see gpu.Draw_Indirect_Args).
[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (id.x >= push.object_count) {
		return;
	}
	float2 center = object_center(id.x, push.grid, pass.time, pass.aspect);
	if (length(center) - OBJECT_RADIUS > cull_radius(pass.time)) {
		return;
	}
	uint slot;
	cn_rw_buffer(push.count).InterlockedAdd(0, 1, slot);
	RWByteAddressBuffer arguments = cn_rw_buffer(push.arguments);
	uint offset = slot * DRAW_RECORD_SIZE;
	// draw_id, index_count, instance_count, first_index, then vertex_offset and first_instance.
	arguments.Store4(offset, uint4(slot, 3, 1, 0));
	arguments.Store2(offset + 16, uint2(0, 0));
	cn_rw_buffer(push.visible).Store(slot * 4, id.x);
}
