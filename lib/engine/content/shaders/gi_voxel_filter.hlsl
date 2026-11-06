// The voxel cones' filter (see docs/rendering/global-illumination.md#voxel-cones): a thread for each voxel of the next
// level that a level covers, which takes the eight voxels of the level that it holds. Its opacity is what a ray across
// them sees: along each axis, the two voxels of each of the four columns block one after the other, and the axis whose
// columns block the most is taken, so a wall one voxel thick still blocks the next level's light. A mean would halve it
// at each level, and wide cones would see through every wall. Its light keeps the eight voxels' mean color.
#include "gi_voxel_pass.hlsli"

[numthreads(VOXEL_GROUP, VOXEL_GROUP, VOXEL_GROUP)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Voxel_Grid g = frame_voxel_grid();
	if (any(id >= g.res / 2)) {
		return;
	}
	uint k = push.level;
	Voxel_Level source = g.levels[k];
	Texture3D<float4> fine = cn_texture3d(source.reads.w);
	float4 children[8];
	float4 sum = 0;
	[unroll] for (uint c = 0; c < 8; c++) {
		int3 cell = int3(id * 2) + int3(c & 1, (c >> 1) & 1, c >> 2);
		children[c] = fine.Load(int4(voxel_texel(g, k, cell), 0));
		sum += children[c];
	}
	// The children of a column along an axis are c and c + step, for each c whose bit for the axis is clear.
	float opacity = 0;
	[unroll] for (uint axis = 0; axis < 3; axis++) {
		uint step = 1u << axis;
		float covered = 0;
		[unroll] for (uint c = 0; c < 8; c++) {
			if ((c & step) == 0) {
				covered += 1 - (1 - children[c].a) * (1 - children[c + step].a);
			}
		}
		opacity = max(opacity, covered / 4);
	}
	float4 filtered = sum.a > 0 ? float4(sum.rgb / sum.a * opacity, opacity) : 0;
	Voxel_Level target = g.levels[k + 1];
	float3 center = source.min.xyz + (float3(id) * 2 + 1) * source.min.w;
	int3 cell = int3(floor(voxel_local(target, center)));
	cn_rw_texture3d(target.writes.w)[voxel_texel(g, k + 1, cell)] = filtered;
}
