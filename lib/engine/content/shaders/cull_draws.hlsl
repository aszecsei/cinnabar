// Culls the frame's draw items against the view's frustum, and writes each visible one into its bin (see
// docs/rendering.md#runtime): an indirect draw whose draw ID is its own index, and the draw record at that index, which
// the material's vertex shader reads.
#include "cinnabar.hlsli"

// Matches Cull_Constants in lib/engine/render/scene.odin. The planes are relative to the camera, which is
// camera_offset from the render origin: a point is inside when dot(plane.xyz, p) + plane.w >= 0 for every one.
struct Cull_Constants {
	float4 planes[5];
	float4 camera_offset;
	uint item_count;
	// The items and the bins' first draws are in the upload ring, at these offsets of its buffer.
	uint items;
	uint items_offset;
	uint instances;
	uint arguments;
	uint draws;
	uint counts;
	uint bin_offsets;
	uint bin_offsets_offset;
};
CN_PASS_CONSTANTS(Cull_Constants, cull);

// Matches Cull_Item in lib/engine/render/scene.odin: one submesh of one instance, its bin, and its bounding sphere in
// the mesh's space.
struct Item {
	uint instance;
	uint mesh;
	uint first_index;
	uint index_count;
	uint material;
	uint bin;
	uint2 padding;
	float4 sphere;
};

// Matches Instance_Record in lib/engine/render/scene.odin.
struct Instance_Record {
	float4 rows[3];
	float4 previous_rows[3];
	uint id;
	uint flags;
	uint2 padding;
};

[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (id.x >= cull.item_count) {
		return;
	}
	Item item = cn_buffer(cull.items).Load<Item>(cull.items_offset + id.x * sizeof(Item));
	Instance_Record instance = cn_buffer(cull.instances).Load<Instance_Record>(item.instance * sizeof(Instance_Record));
	float4 center = float4(item.sphere.xyz, 1);
	float3 p = float3(dot(instance.rows[0], center), dot(instance.rows[1], center), dot(instance.rows[2], center)) - cull.camera_offset.xyz;
	// The largest scale of the rows scales the radius.
	float scale = sqrt(max(dot(instance.rows[0].xyz, instance.rows[0].xyz), max(dot(instance.rows[1].xyz, instance.rows[1].xyz), dot(instance.rows[2].xyz, instance.rows[2].xyz))));
	float radius = item.sphere.w * scale;
	for (uint i = 0; i < 5; i++) {
		if (dot(cull.planes[i].xyz, p) + cull.planes[i].w < -radius) {
			return;
		}
	}
	uint slot;
	cn_rw_buffer(cull.counts).InterlockedAdd(item.bin * 4, 1, slot);
	uint index = cn_buffer(cull.bin_offsets).Load(cull.bin_offsets_offset + item.bin * 4) + slot;
	// Draw_Indirect_Args: draw ID, vertex count, instance count, first vertex, first instance.
	cn_rw_buffer(cull.arguments).Store4(index * 20, uint4(index, item.index_count, 1, 0));
	cn_rw_buffer(cull.arguments).Store(index * 20 + 16, 0);
	// Draw_Record: instance, mesh, first index, material.
	cn_rw_buffer(cull.draws).Store4(index * 16, uint4(item.instance, item.mesh, item.first_index, item.material));
}
