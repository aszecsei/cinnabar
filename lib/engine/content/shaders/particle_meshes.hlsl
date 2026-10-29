// The mesh particles' draws (see docs/rendering/particles.md#mesh-particles), after the particles' update: a thread for
// each submesh item of a mesh emitter, a dispatch row for each view. The update appended an instance for each living
// particle and counted them, so each item takes one draw in its bin of the view, as cull_draws.hlsl gives a mesh's
// item, which draws its submesh once for each instance. The view model's view draws none, and a shadow view only the
// items that cast shadows.
#include "particles.hlsli"

// Matches Mesh_Particle_Push in lib/engine/render/particles.odin. The records, the items, the views and the bins' first
// draws are in the upload ring; counts, arguments and draws are the scene's.
struct Mesh_Particle_Push {
	uint records;
	uint records_offset;
	uint count;
	uint items;
	uint items_offset;
	uint views;
	uint views_offset;
	uint bin_offsets;
	uint bin_offsets_offset;
	uint bin_count;
	uint counts;
	uint arguments;
	uint draws;
};
CN_PUSH_CONSTANTS(Mesh_Particle_Push, push);

// Matches Mesh_Particle_Record in lib/engine/render/particles.odin: the item's emitter in the frame's, and the item.
struct Mesh_Particle_Record {
	uint emitter;
	uint item;
};

// Matches Cull_Item in lib/engine/render/scene.odin.
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

// Matches Cull_View in lib/engine/render/scene.odin.
struct Cull_View {
	float4 planes[6];
	float4 offset;
	uint first_draw;
	uint flags;
	uint2 padding;
};

// Match ITEM_CASTS_SHADOWS, VIEW_CASTERS, VIEW_MODEL and ID_ENTITY_BITS in lib/engine/render, and DRAW_PARTICLES in
// material_common.hlsli.
static const uint ITEM_CASTS_SHADOWS = 1;
static const uint VIEW_CASTERS = 1;
static const uint VIEW_MODEL = 2;
static const uint ID_ENTITY_BITS = 25;
static const uint DRAW_PARTICLES = 1;

[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (id.x >= push.count) {
		return;
	}
	Mesh_Particle_Record record = cn_buffer(push.records).Load<Mesh_Particle_Record>(push.records_offset + id.x * sizeof(Mesh_Particle_Record));
	Item item = cn_buffer(push.items).Load<Item>(push.items_offset + record.item * sizeof(Item));
	Cull_View view = cn_buffer(push.views).Load<Cull_View>(push.views_offset + id.y * sizeof(Cull_View));
	if ((view.flags & VIEW_MODEL) != 0 || ((view.flags & VIEW_CASTERS) != 0 && (item.flags & ITEM_CASTS_SHADOWS) == 0)) {
		return;
	}
	uint living = cn_rw_buffer(constants.counters).Load((MAX_FRAME_EMITTERS + record.emitter) * 4);
	if (living == 0) {
		return;
	}
	Emitter_Record e = load_emitter(record.emitter);
	uint slot;
	cn_rw_buffer(push.counts).InterlockedAdd((id.y * push.bin_count + item.bin) * 4, 1, slot);
	uint draw = view.first_draw + cn_buffer(push.bin_offsets).Load(push.bin_offsets_offset + item.bin * 4) + slot;
	// Draw_Indirect_Args: draw ID, vertex count, instance count, first vertex, first instance.
	cn_rw_buffer(push.arguments).Store4(draw * 20, uint4(draw, item.count * living, 1, 0));
	cn_rw_buffer(push.arguments).Store(draw * 20 + 16, 0);
	// Draw_Record: the first instance, the mesh with the submesh above ID_ENTITY_BITS, first, material, then count, the
	// bound and the flags.
	cn_rw_buffer(push.draws).Store4(draw * 32, uint4(e.instances, item.mesh | (item.submesh << ID_ENTITY_BITS), item.first, item.material));
	cn_rw_buffer(push.draws).Store4(draw * 32 + 16, uint4(item.count, asuint(item.bound), DRAW_PARTICLES, 0));
}
