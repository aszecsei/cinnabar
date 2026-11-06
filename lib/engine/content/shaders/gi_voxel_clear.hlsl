// The voxel cones' clear (see docs/rendering/global-illumination.md#voxel-cones): a thread for each voxel of a level
// that the frame voxelizes, which empties its albedo, normal, emission and mask before the voxelization adds its
// surfaces.
#include "gi_voxel_pass.hlsli"

[numthreads(VOXEL_GROUP, VOXEL_GROUP, VOXEL_GROUP)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Voxel_Grid g = frame_voxel_grid();
	if (any(id >= g.res)) {
		return;
	}
	uint4 writes = g.levels[push.level].writes;
	cn_rw_uint_texture3d(writes.x)[id] = 0;
	cn_rw_uint_texture3d(writes.y)[id] = 0;
	cn_rw_uint_texture3d(writes.z)[id] = 0;
	cn_rw_uint_texture3d(g.levels[push.level].mask.y)[id] = 0;
}
