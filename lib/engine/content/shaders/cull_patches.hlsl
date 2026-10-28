// Culls each patch surface's selected patches against each view (see docs/rendering/surfaces.md#surfaces), after
// select_patches.hlsl: a thread a patch, a surface and a view. A visible patch takes the next draw of its surface's
// item's bin of that view, as cull_draws.hlsl gives a mesh's item, and writes its indirect draw and its draw record,
// whose first is the packed patch that material_patch.hlsli builds the vertices from.
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
	float4 camera;
	float lod_scale;
	float lod_near;
	uint2 padding;
};
CN_PASS_CONSTANTS(Cull_Constants, cull);

// Match lib/engine/render/surfaces.odin.
#define MAX_SURFACE_PATCHES 2048
#define SURFACE_PATCH_QUADS 16
#define SURFACE_PATCH_VERTICES 1536

// Matches Cull_View in lib/engine/render/scene.odin (see cull_draws.hlsl).
static const uint VIEW_CASTERS = 1;
static const uint VIEW_MODEL = 2;
struct Cull_View {
	float4 planes[6];
	float4 offset;
	uint first_draw;
	uint flags;
	uint2 padding;
};

// Matches Cull_Item in lib/engine/render/scene.odin.
static const uint ITEM_CASTS_SHADOWS = 1;
static const uint ITEM_VIEW_MODEL = 2;
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

// Matches Instance_Record in lib/engine/render/scene.odin.
struct Instance_Record {
	float4 rows[3];
	float4 previous_rows[3];
	uint id;
	uint flags;
	uint2 padding;
};

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

[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint count = cn_buffer(cull.patch_counts_read).Load(id.y * 4);
	if (id.x >= count) {
		return;
	}
	Surface_Record s = cn_buffer(cull.surfaces).Load<Surface_Record>(cull.surfaces_offset + id.y * sizeof(Surface_Record));
	Item item = cn_buffer(cull.items).Load<Item>(cull.items_offset + s.item * sizeof(Item));
	Cull_View view = cn_buffer(cull.views).Load<Cull_View>(cull.views_offset + id.z * sizeof(Cull_View));
	if ((view.flags & VIEW_CASTERS) != 0 && (item.flags & ITEM_CASTS_SHADOWS) == 0) {
		return;
	}
	if (((view.flags & VIEW_MODEL) != 0) != ((item.flags & ITEM_VIEW_MODEL) != 0)) {
		return;
	}
	uint node = cn_buffer(cull.patches_read).Load((id.y * MAX_SURFACE_PATCHES + id.x) * 4);
	uint level = node >> 24;
	uint2 xy = uint2(node & 0xfff, (node >> 12) & 0xfff);
	float size = s.cell * SURFACE_PATCH_QUADS * float(1u << level);
	float2 lo = s.root_origin + float2(xy) * size;
	// The patch's box in the surface's space: its square, between the surface's heights.
	float3 center = float3(lo.x + size * 0.5, (s.height_range.x + s.height_range.y) * 0.5, lo.y + size * 0.5);
	float3 extent = float3(size * 0.5, (s.height_range.y - s.height_range.x) * 0.5, size * 0.5);
	Instance_Record instance = cn_buffer(cull.instances).Load<Instance_Record>(item.instance * sizeof(Instance_Record));
	float4 c = float4(center, 1);
	float3 p = float3(dot(instance.rows[0], c), dot(instance.rows[1], c), dot(instance.rows[2], c)) - view.offset.xyz;
	float3 scales = instance.rows[0].xyz * instance.rows[0].xyz + instance.rows[1].xyz * instance.rows[1].xyz + instance.rows[2].xyz * instance.rows[2].xyz;
	float scale = sqrt(max(scales.x, max(scales.y, scales.z)));
	float radius = length(extent) * scale + item.bound;
	for (uint i = 0; i < 6; i++) {
		if (dot(view.planes[i].xyz, p) + view.planes[i].w < -radius) {
			return;
		}
	}
	uint slot;
	cn_rw_buffer(cull.counts).InterlockedAdd((id.z * cull.bin_count + item.bin) * 4, 1, slot);
	uint index = view.first_draw + cn_buffer(cull.bin_offsets).Load(cull.bin_offsets_offset + item.bin * 4) + slot;
	// Draw_Indirect_Args: draw ID, vertex count, instance count, first vertex, first instance.
	cn_rw_buffer(cull.arguments).Store4(index * 20, uint4(index, SURFACE_PATCH_VERTICES, 1, 0));
	cn_rw_buffer(cull.arguments).Store(index * 20 + 16, 0);
	// Draw_Record: instance, the surface's record with the submesh above ID_ENTITY_BITS, the patch, material, then
	// count and the bound.
	cn_rw_buffer(cull.draws).Store4(index * 32, uint4(item.instance, item.mesh | (item.submesh << ID_ENTITY_BITS), node, item.material));
	cn_rw_buffer(cull.draws).Store4(index * 32 + 16, uint4(SURFACE_PATCH_VERTICES, asuint(item.bound), 0, 0));
}
