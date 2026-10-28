// The ribbons' build (see docs/rendering/particles.md#ribbons), after the particles' update: a group for each ribbon, a
// thread for each particle of its emitter's range in the order that they spawned, oldest first. The living ones are
// compacted in that order, and each writes the ribbon's two edges at it, across the ribbon's direction there and facing
// the camera, its size's width apart, with its color, both from the emitter's curves at its age. Then the ribbon takes
// its draw in its item's bin of the camera's view, as cull_draws.hlsl gives a mesh's item: a segment of two triangles
// between each two particles.
#include "particles.hlsli"
#include "ribbons.hlsli"

// Matches Ribbon_Push in lib/engine/render/particles.odin. The ribbons' records, the items, the views and the bins'
// first draws are in the upload ring; counts, arguments and draws are the scene's.
struct Ribbon_Push {
	uint ribbons;
	uint ribbons_offset;
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
	uint vertices;
};
CN_PUSH_CONSTANTS(Ribbon_Push, push);

// Matches Ribbon_Record in lib/engine/render/particles.odin: the ribbon's emitter in the frame's, its item, and its first
// vertex.
struct Ribbon_Record {
	uint emitter;
	uint item;
	uint first_vertex;
	uint padding;
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

// Matches MAX_RIBBON_CAPACITY in lib/engine/asset/format/effect.odin, and VIEW_CAMERA and ID_ENTITY_BITS in
// lib/engine/render.
static const uint MAX_RIBBON_CAPACITY = 1024;
static const uint VIEW_CAMERA = 0;
static const uint ID_ENTITY_BITS = 25;

groupshared float3 centers[MAX_RIBBON_CAPACITY];
// Each wave's living particles, then the waves before it, and the ribbon's.
groupshared uint wave_counts[MAX_RIBBON_CAPACITY / 4];
groupshared uint living;

[numthreads(MAX_RIBBON_CAPACITY, 1, 1)]
void cs_main(uint3 group : SV_GroupID, uint index : SV_GroupIndex) {
	Ribbon_Record ribbon = cn_buffer(push.ribbons).Load<Ribbon_Record>(push.ribbons_offset + group.x * sizeof(Ribbon_Record));
	Emitter_Record e = load_emitter(ribbon.emitter);
	// The oldest particle is where this frame's spawning stopped.
	Particle p = (Particle)0;
	bool live = false;
	if (index < e.capacity) {
		uint slot = (e.head + e.spawn + index) % e.capacity;
		// The pool's index is its write view's, which the update writes it through.
		p = cn_rw_buffer(constants.pool).Load<Particle>((e.first + slot) * sizeof(Particle));
		live = p.lifetime > 0 && p.age < p.lifetime;
	}
	uint lanes = WaveGetLaneCount();
	uint wave = index / lanes;
	uint before = WavePrefixCountBits(live);
	// Counted by the whole wave, before only its first lane writes it.
	uint wave_living = WaveActiveCountBits(live);
	if (WaveIsFirstLane()) {
		wave_counts[wave] = wave_living;
	}
	GroupMemoryBarrierWithGroupSync();
	if (index == 0) {
		uint sum = 0;
		for (uint w = 0; w < (MAX_RIBBON_CAPACITY + lanes - 1) / lanes; w++) {
			uint count = wave_counts[w];
			wave_counts[w] = sum;
			sum += count;
		}
		living = sum;
	}
	GroupMemoryBarrierWithGroupSync();
	uint k = wave_counts[wave] + before;
	if (live) {
		centers[k] = p.position;
	}
	GroupMemoryBarrierWithGroupSync();
	uint n = living;

	if (live) {
		// Along the ribbon: from the particle before to the one after, or along the particle's velocity at an end
		// without a neighbour.
		float3 along = centers[min(k + 1, n - 1)] - centers[k > 0 ? k - 1 : 0];
		if (dot(along, along) < 1e-12) {
			along = p.velocity;
		}
		float3 tangent = dot(along, along) > 1e-12 ? normalize(along) : float3(0, 1, 0);
		// The camera is at the anchor's negation in the anchor's space.
		float3 to_camera = -e.anchor - p.position;
		float3 side = cross(tangent, to_camera);
		side = dot(side, side) > 1e-12 ? normalize(side) : normalize(cross(tangent, abs(tangent.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0)));
		float t = p.age / p.lifetime;
		float width = curve_at(e.curves + CURVE_SIZE, t).x;
		Ribbon_Vertex v;
		v.u = t;
		v.normal = cross(side, tangent);
		v.tangent = tangent;
		v.padding = 0;
		v.color = curve_at(e.curves + CURVE_COLOR, t);
		RWByteAddressBuffer vertices = cn_rw_buffer(push.vertices);
		uint at = (ribbon.first_vertex + k * 2) * sizeof(Ribbon_Vertex);
		v.position = p.position - side * width;
		v.v = 0;
		vertices.Store<Ribbon_Vertex>(at, v);
		v.position = p.position + side * width;
		v.v = 1;
		vertices.Store<Ribbon_Vertex>(at + sizeof(Ribbon_Vertex), v);
	}

	if (index != 0 || n < 2) {
		return;
	}
	Item item = cn_buffer(push.items).Load<Item>(push.items_offset + ribbon.item * sizeof(Item));
	Cull_View view = cn_buffer(push.views).Load<Cull_View>(push.views_offset + VIEW_CAMERA * sizeof(Cull_View));
	uint slot;
	cn_rw_buffer(push.counts).InterlockedAdd((VIEW_CAMERA * push.bin_count + item.bin) * 4, 1, slot);
	uint draw = view.first_draw + cn_buffer(push.bin_offsets).Load(push.bin_offsets_offset + item.bin * 4) + slot;
	uint vertex_count = (n - 1) * 6;
	// Draw_Indirect_Args: draw ID, vertex count, instance count, first vertex, first instance.
	cn_rw_buffer(push.arguments).Store4(draw * 20, uint4(draw, vertex_count, 1, 0));
	cn_rw_buffer(push.arguments).Store(draw * 20 + 16, 0);
	// Draw_Record: instance, the submesh above ID_ENTITY_BITS, the first vertex, material, then count and the bound.
	cn_rw_buffer(push.draws).Store4(draw * 32, uint4(item.instance, item.submesh << ID_ENTITY_BITS, ribbon.first_vertex, item.material));
	cn_rw_buffer(push.draws).Store4(draw * 32 + 16, uint4(vertex_count, 0, 0, 0));
}
