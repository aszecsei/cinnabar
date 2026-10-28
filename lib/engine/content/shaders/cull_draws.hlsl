// Culls the frame's draw items against each view's frustum: the camera's, the view model's, then each shadow view's
// (see docs/rendering/gpu-scene.md#gpu-scene). Each visible one goes into its bin of that view: an indirect draw whose draw ID is
// its own index, and the draw record at that index, which the material's vertex shader reads. An item on the mesh
// shader path writes a mesh draw instead, of an amplification group for each MESHLETS_PER_GROUP of its meshlets, which
// cull them (see material_mesh.hlsli). An item with an impostor draws as its mesh up to where the impostor takes over,
// and its impostor's item past it, by the camera's level of detail in every view (see
// docs/rendering/gpu-scene.md#impostors). A dispatch row is a view.
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
	uint mesh_arguments;
	// The patch surfaces' records and patches, which select_patches.hlsl and cull_patches.hlsl take.
	uint surfaces;
	uint surfaces_offset;
	uint surface_count;
	uint patches;
	uint patch_counts;
	uint patches_read;
	uint patch_counts_read;
	// The camera's offset from the render origin, and its level of detail (see Frame_Constants.lod_scale), which pick
	// between a mesh and its impostor.
	float4 camera;
	float lod_scale;
	float lod_near;
	uint2 padding;
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
// the mesh's space. first and count are its indices, or on the mesh shader path its meshlets. bound is how far the
// material's displacement may move a vertex, in meters, which grows the sphere after the instance's scale. An item
// with ITEM_IMPOSTOR or ITEM_HAS_IMPOSTOR has its mesh's sphere in lod_sphere, and its impostor's error.
static const uint ITEM_CASTS_SHADOWS = 1;
static const uint ITEM_VIEW_MODEL = 2;
static const uint ITEM_MESH_PATH = 4;
// A patch surface's item, whose draws cull_patches.hlsl writes.
static const uint ITEM_SURFACE = 8;
// A billboard's item, which turns about its instance's position (see billboard_rows in material_vertex.hlsli).
static const uint ITEM_BILLBOARD = 16;
// An impostor's item, which draws past where it takes over, and a mesh's item with an impostor, which draws up to it.
static const uint ITEM_IMPOSTOR = 32;
static const uint ITEM_HAS_IMPOSTOR = 64;
struct Item {
	uint instance;
	uint mesh;
	uint first;
	uint count;
	uint material;
	uint bin;
	uint flags;
	uint submesh;
	float4 sphere;
	float bound;
	float impostor_error;
	uint2 padding;
	float4 lod_sphere;
};

// Matches ID_ENTITY_BITS in lib/engine/render/renderer.odin.
static const uint ID_ENTITY_BITS = 25;
// Matches MESHLETS_PER_GROUP in lib/engine/render/scene.odin.
static const uint MESHLETS_PER_GROUP = 32;

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
	if ((item.flags & ITEM_SURFACE) != 0) {
		return;
	}
	if ((view.flags & VIEW_CASTERS) != 0 && (item.flags & ITEM_CASTS_SHADOWS) == 0) {
		return;
	}
	if (((view.flags & VIEW_MODEL) != 0) != ((item.flags & ITEM_VIEW_MODEL) != 0)) {
		return;
	}
	Instance_Record instance = cn_buffer(cull.instances).Load<Instance_Record>(item.instance * sizeof(Instance_Record));
	float4 center = float4(item.sphere.xyz, 1);
	float3 p = float3(dot(instance.rows[0], center), dot(instance.rows[1], center), dot(instance.rows[2], center)) - view.offset.xyz;
	// The largest scale of an axis, a column's length, scales the radius.
	float3 scales = instance.rows[0].xyz * instance.rows[0].xyz + instance.rows[1].xyz * instance.rows[1].xyz + instance.rows[2].xyz * instance.rows[2].xyz;
	float scale = sqrt(max(scales.x, max(scales.y, scales.z)));
	// Each view draws a mesh or its impostor as the camera does, so a shadow is the shape that the camera sees.
	if ((item.flags & (ITEM_IMPOSTOR | ITEM_HAS_IMPOSTOR)) != 0) {
		float4 mesh_center = float4(item.lod_sphere.xyz, 1);
		float3 to_mesh = float3(dot(instance.rows[0], mesh_center), dot(instance.rows[1], mesh_center), dot(instance.rows[2], mesh_center)) - cull.camera.xyz;
		float distance = max(length(to_mesh) - item.lod_sphere.w * scale, cull.lod_near);
		bool far = item.impostor_error * scale / distance * cull.lod_scale <= 1;
		if (far != ((item.flags & ITEM_IMPOSTOR) != 0)) {
			return;
		}
	}
	float radius = item.sphere.w * scale + item.bound;
	// A billboard's sphere turns about the instance's position, so the sphere about that position that holds it.
	if ((item.flags & ITEM_BILLBOARD) != 0) {
		p = float3(instance.rows[0].w, instance.rows[1].w, instance.rows[2].w) - view.offset.xyz;
		radius = (length(item.sphere.xyz) + item.sphere.w) * scale + item.bound;
	}
	for (uint i = 0; i < 6; i++) {
		if (dot(view.planes[i].xyz, p) + view.planes[i].w < -radius) {
			return;
		}
	}
	uint slot;
	cn_rw_buffer(cull.counts).InterlockedAdd((id.y * cull.bin_count + item.bin) * 4, 1, slot);
	uint index = view.first_draw + cn_buffer(cull.bin_offsets).Load(cull.bin_offsets_offset + item.bin * 4) + slot;
	if ((item.flags & ITEM_MESH_PATH) != 0) {
		// Draw_Mesh_Indirect_Args: draw ID, then the amplification groups.
		cn_rw_buffer(cull.mesh_arguments).Store4(index * 16, uint4(index, (item.count + MESHLETS_PER_GROUP - 1) / MESHLETS_PER_GROUP, 1, 1));
	} else {
		// Draw_Indirect_Args: draw ID, vertex count, instance count, first vertex, first instance.
		cn_rw_buffer(cull.arguments).Store4(index * 20, uint4(index, item.count, 1, 0));
		cn_rw_buffer(cull.arguments).Store(index * 20 + 16, 0);
	}
	// Draw_Record: instance, mesh with the submesh above ID_ENTITY_BITS, first, material, then count and the bound.
	cn_rw_buffer(cull.draws).Store4(index * 32, uint4(item.instance, item.mesh | (item.submesh << ID_ENTITY_BITS), item.first, item.material));
	cn_rw_buffer(cull.draws).Store4(index * 32 + 16, uint4(item.count, asuint(item.bound), 0, 0));
}
