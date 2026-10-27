// Walks each patch surface's quadtree from the camera (see docs/rendering/surfaces.md#surfaces), one group a surface: a
// node splits while it is nearer the camera than the next finer level's range, a node outside the surface's rectangle
// is dropped, and the rest are the patches that every view draws this frame, which cull_patches.hlsl tests. The walk
// goes level by level through two queues in group memory, so it is bounded by MAX_SURFACE_PATCHES: a node that the
// queue cannot hold draws as it is.
#include "cinnabar.hlsli"

// Matches Cull_Constants in lib/engine/render/scene.odin.
struct Cull_Constants {
	uint item_count;
	uint items;
	uint items_offset;
	uint instances;
	uint arguments;
	uint draws;
	uint counts;
	uint bin_offsets;
	uint bin_offsets_offset;
	uint views;
	uint views_offset;
	uint bin_count;
	uint mesh_arguments;
	uint surfaces;
	uint surfaces_offset;
	uint surface_count;
	uint patches;
	uint patch_counts;
	uint patches_read;
	uint patch_counts_read;
};
CN_PASS_CONSTANTS(Cull_Constants, cull);

// Match lib/engine/render/surfaces.odin.
#define MAX_SURFACE_PATCHES 2048
#define SURFACE_GROUP_SIZE 256
#define SURFACE_PATCH_QUADS 16

// Matches Surface_Record in lib/engine/render/surfaces.odin.
struct Surface_Record {
	float2 size;
	float cell;
	uint levels;
	float2 root_origin;
	float root_size;
	float range0;
	float3 camera_local;
	uint hole_mask;
	float2 height_range;
	float bound;
	uint item;
	uint4 padding;
};

groupshared uint queue[2][MAX_SURFACE_PATCHES];
groupshared uint queue_count[2];
groupshared uint emitted;

// A patch, as material_patch.hlsli unpacks it: its column, its row and its level.
uint pack_patch(uint x, uint y, uint level) {
	return x | y << 12 | level << 24;
}

[numthreads(SURFACE_GROUP_SIZE, 1, 1)]
void cs_main(uint group : SV_GroupID, uint thread : SV_GroupIndex) {
	Surface_Record s = cn_buffer(cull.surfaces).Load<Surface_Record>(cull.surfaces_offset + group * sizeof(Surface_Record));
	if (thread == 0) {
		queue[0][0] = pack_patch(0, 0, s.levels - 1);
		queue_count[0] = 1;
		queue_count[1] = 0;
		emitted = 0;
	}
	GroupMemoryBarrierWithGroupSync();
	float2 half_size = s.size * 0.5;
	for (int level = int(s.levels) - 1; level >= 0; level--) {
		uint in_queue = uint(int(s.levels) - 1 - level) & 1;
		uint out_queue = in_queue ^ 1;
		uint count = min(queue_count[in_queue], MAX_SURFACE_PATCHES);
		for (uint i = thread; i < count; i += SURFACE_GROUP_SIZE) {
			uint node = queue[in_queue][i];
			uint2 xy = uint2(node & 0xfff, (node >> 12) & 0xfff);
			float size = s.cell * SURFACE_PATCH_QUADS * float(1u << uint(level));
			float2 lo = s.root_origin + float2(xy) * size;
			float2 hi = lo + size;
			if (hi.x <= -half_size.x || hi.y <= -half_size.y || lo.x >= half_size.x || lo.y >= half_size.y) {
				continue;
			}
			// The distance to the node's box: its square, between the surface's heights.
			float3 nearest = float3(clamp(s.camera_local.x, lo.x, hi.x), clamp(s.camera_local.y, s.height_range.x, s.height_range.y), clamp(s.camera_local.z, lo.y, hi.y));
			float d = distance(s.camera_local, nearest);
			bool split = level > 0 && d < s.range0 * float(1u << uint(level - 1));
			if (split) {
				uint slot;
				InterlockedAdd(queue_count[out_queue], 4, slot);
				if (slot + 4 <= MAX_SURFACE_PATCHES) {
					queue[out_queue][slot] = pack_patch(2 * xy.x, 2 * xy.y, uint(level - 1));
					queue[out_queue][slot + 1] = pack_patch(2 * xy.x + 1, 2 * xy.y, uint(level - 1));
					queue[out_queue][slot + 2] = pack_patch(2 * xy.x, 2 * xy.y + 1, uint(level - 1));
					queue[out_queue][slot + 3] = pack_patch(2 * xy.x + 1, 2 * xy.y + 1, uint(level - 1));
				} else {
					split = false;
				}
			}
			if (!split) {
				uint e;
				InterlockedAdd(emitted, 1, e);
				if (e < MAX_SURFACE_PATCHES) {
					cn_rw_buffer(cull.patches).Store((group * MAX_SURFACE_PATCHES + e) * 4, node);
				}
			}
		}
		GroupMemoryBarrierWithGroupSync();
		if (thread == 0) {
			queue_count[in_queue] = 0;
		}
		GroupMemoryBarrierWithGroupSync();
	}
	if (thread == 0) {
		cn_rw_buffer(cull.patch_counts).Store(group * 4, min(emitted, MAX_SURFACE_PATCHES));
	}
}
