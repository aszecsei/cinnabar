// Culls the frame's draw items against each view's frustum: the camera's, the view model's, then each shadow view's
// (see docs/rendering/gpu-scene.md#gpu-scene). Each visible one goes into its bin of that view: an indirect draw whose draw ID is
// its own index, and the draw record at that index, which the material's vertex shader reads. A dispatch row is a
// view.
#include "cinnabar.hlsli"

// Matches Cull_Constants in lib/engine/render/scene.odin. The items, the bins' first draws and the views are in the
// upload ring, at these offsets of its buffer.
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
	uint3 padding;
};
CN_PASS_CONSTANTS(Cull_Constants, cull);

// Matches Cull_View in lib/engine/render/scene.odin. The planes are relative to the camera, which is offset from the
// space of the view's instances: a point is inside when dot(plane.xyz, p) + plane.w >= 0 for every one. A view's draws
// start at first_draw. A shadow view draws only the items that cast shadows. The view model's view draws only the view
// model's items, which are relative to the camera, and every other view leaves them out.
static const uint VIEW_CASTERS = 1;
static const uint VIEW_MODEL = 2;
struct Cull_View {
	float4 planes[6];
	float4 offset;
	uint first_draw;
	uint flags;
	uint2 padding;
};

// Matches Cull_Item in lib/engine/render/scene.odin: one submesh of one instance, its bin, and its bounding sphere in
// the mesh's space.
static const uint ITEM_CASTS_SHADOWS = 1;
static const uint ITEM_VIEW_MODEL = 2;
struct Item {
	uint instance;
	uint mesh;
	uint first_index;
	uint index_count;
	uint material;
	uint bin;
	uint flags;
	uint submesh;
	float4 sphere;
};

// Matches ID_ENTITY_BITS in lib/engine/render/renderer.odin.
static const uint ID_ENTITY_BITS = 25;

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
	Cull_View view = cn_buffer(cull.views).Load<Cull_View>(cull.views_offset + id.y * sizeof(Cull_View));
	Item item = cn_buffer(cull.items).Load<Item>(cull.items_offset + id.x * sizeof(Item));
	if ((view.flags & VIEW_CASTERS) != 0 && (item.flags & ITEM_CASTS_SHADOWS) == 0) {
		return;
	}
	if (((view.flags & VIEW_MODEL) != 0) != ((item.flags & ITEM_VIEW_MODEL) != 0)) {
		return;
	}
	Instance_Record instance = cn_buffer(cull.instances).Load<Instance_Record>(item.instance * sizeof(Instance_Record));
	float4 center = float4(item.sphere.xyz, 1);
	float3 p = float3(dot(instance.rows[0], center), dot(instance.rows[1], center), dot(instance.rows[2], center)) - view.offset.xyz;
	// The largest scale of the rows scales the radius.
	float scale = sqrt(max(dot(instance.rows[0].xyz, instance.rows[0].xyz), max(dot(instance.rows[1].xyz, instance.rows[1].xyz), dot(instance.rows[2].xyz, instance.rows[2].xyz))));
	float radius = item.sphere.w * scale;
	for (uint i = 0; i < 6; i++) {
		if (dot(view.planes[i].xyz, p) + view.planes[i].w < -radius) {
			return;
		}
	}
	uint slot;
	cn_rw_buffer(cull.counts).InterlockedAdd((id.y * cull.bin_count + item.bin) * 4, 1, slot);
	uint index = view.first_draw + cn_buffer(cull.bin_offsets).Load(cull.bin_offsets_offset + item.bin * 4) + slot;
	// Draw_Indirect_Args: draw ID, vertex count, instance count, first vertex, first instance.
	cn_rw_buffer(cull.arguments).Store4(index * 20, uint4(index, item.index_count, 1, 0));
	cn_rw_buffer(cull.arguments).Store(index * 20 + 16, 0);
	// Draw_Record: instance, mesh with the submesh above ID_ENTITY_BITS, first index, material.
	cn_rw_buffer(cull.draws).Store4(index * 16, uint4(item.instance, item.mesh | (item.submesh << ID_ENTITY_BITS), item.first_index, item.material));
}
