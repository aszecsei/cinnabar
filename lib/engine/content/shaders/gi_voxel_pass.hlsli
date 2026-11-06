// What the voxel cones' clear, injection and filter share (see docs/rendering/global-illumination.md#voxel-cones): their
// push constants, which start with Material_Push's shadow textures, so the light loop's lookups compile, and the
// clipmap. The passes set the camera's frame constants.
#ifndef GI_VOXEL_PASS_HLSLI
#define GI_VOXEL_PASS_HLSLI

// Matches Voxel_Push in lib/engine/render/gi_voxel.odin. level is the level that the pass writes: the filter's source.
struct Voxel_Push {
	uint shadow_atlas;
	uint shadow_mask;
	uint grid;
	uint grid_offset;
	uint level;
	uint view_output;
	uint padding[2];
};
#define MATERIAL_PUSH Voxel_Push
// No shading model: the injection needs only the light loop's lookups.
#define SHADING_NO_LIGHTING 1
#include "material_lighting.hlsli"
#include "ambient.hlsli"
#include "gi_voxel.hlsli"

Voxel_Grid frame_voxel_grid() {
	return load_voxel_grid(push.grid, push.grid_offset);
}

#endif
