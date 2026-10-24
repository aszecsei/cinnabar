#include "cinnabar.hlsli"

// Matches Pick_Constants in viewport.odin.
struct Push {
	uint ids;
	uint depth;
	uint results;
	uint request;
	int2 origin;
	uint2 size;
	uint2 target_size;
	// The number of entity slots: an ID buffer value is an index + 1 below it.
	uint slots;
};
CN_PUSH_CONSTANTS(Push, push);

// Matches PICK_HEADER in viewport.odin: the request, the ID and depth at the rectangle's origin, and then a bit for
// each entity slot that the rectangle shows. A pass before this one zeroed the results.
static const uint HEADER_SIZE = 16;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	int2 pixel = push.origin + int2(id.xy);
	if (any(pixel < 0) || any(pixel >= int2(push.target_size))) {
		return;
	}
	uint entity = cn_uint_texture(push.ids).Load(int3(pixel, 0));
	RWByteAddressBuffer results = cn_rw_buffer(push.results);
	if (all(id.xy == 0)) {
		results.Store3(0, uint3(push.request, entity, asuint(cn_texture(push.depth).Load(int3(pixel, 0)).r)));
	}
	if (entity != 0 && entity <= push.slots) {
		uint slot = entity - 1;
		results.InterlockedOr(HEADER_SIZE + slot / 32 * 4, 1u << (slot % 32));
	}
}
