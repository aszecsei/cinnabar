// The mesh shader path's level of detail (see docs/rendering/gpu-scene.md#mesh-shader-path), which as_cluster in
// material_mesh.hlsli and select_meshlets.hlsl share: how an error shows from the camera, and the trees over each
// level's groups of meshlets that select_meshlets.hlsl walks.
#ifndef MESHLET_LOD_HLSLI
#define MESHLET_LOD_HLSLI

// lod_error is an error within a sphere of an instance's mesh, seen from the camera at its nearest, over the threshold:
// above 1 shows. center is the sphere's center moved by the instance's rows, relative to the camera, and scale the
// rows' largest axis scale, which scales the radius and the error. lod_scale is the camera's pixels per unit of error at
// a distance of 1, over the error in pixels that may show, and lod_near the nearest distance that it divides by.
float lod_error(float3 center, float radius, float error, float scale, float lod_near, float lod_scale) {
	float distance = max(length(center) - radius * scale, lod_near);
	return error * scale / distance * lod_scale;
}

// Matches Meshlet_Node in lib/engine/asset/format/mesh.odin: a node of the tree over one level's groups of meshlets.
// Its sphere holds every group's below it, and its error is the largest of theirs. An internal node's children are
// count nodes from first, relative to its submesh's first node; a leaf, whose count has MESHLET_NODE_LEAF, is one
// group: count meshlets from first, relative to its submesh's first meshlet, whose parent sphere and error are the
// node's.
static const uint MESHLET_NODE_LEAF = 1u << 31;
struct Meshlet_Node {
	float4 sphere;
	float error;
	uint first;
	uint count;
	uint padding;
};

#endif
