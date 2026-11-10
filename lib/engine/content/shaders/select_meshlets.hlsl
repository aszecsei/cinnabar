// Walks the trees over each level's groups of meshlets of each draw item that has them, from the camera, one group a
// item (see docs/rendering/gpu-scene.md#mesh-shader-path). A node whose error does not show has no meshlet below it
// that the camera draws, so the walk stops there; a leaf whose error shows is a group whose meshlets the camera may
// draw, which go into the frame's list of selected meshlets. cull_draws.hlsl gives the item's mesh draws its range of
// the list, whose meshlets as_cluster tests in place of all of its submesh's. The walk goes a depth of the trees at a
// time through two queues in group memory: an item whose nodes or groups the queues cannot hold, or whose meshlets the
// list cannot, tests all of its meshlets. A paged mesh's group is in a page (see docs/rendering/assets.md#mesh-pages):
// the walk lists the meshlets of a group whose page is resident, packed with the page's slot, and marks the page as
// used in the feedback; it lists none of a group whose page is absent, and raises the page's word of the feedback to
// the group's projected error, which is how much the page is wanted.
#include "cinnabar.hlsli"
#include "meshlet_lod.hlsli"
#include "mesh_pages.hlsli"

// Matches Meshlet_Select_Constants in lib/engine/render/meshlet_select.odin. The items to walk, by their index, the
// draw items and the mesh records are in the upload ring, at these offsets of its buffer. selections has the list's
// counter in its first word, then each item's range of selected, from its eighth byte. camera is the camera's offset
// from the render origin, and lod_scale and lod_near its level of detail, as material_mesh.hlsli has them.
struct Meshlet_Select_Constants {
	float4 camera;
	float lod_scale;
	float lod_near;
	uint walk_count;
	uint walks;
	uint walks_offset;
	uint items;
	uint items_offset;
	uint meshes;
	uint meshes_offset;
	uint instances;
	uint selections;
	uint selected;
	uint stats;
	// The page table, and the feedback: a word for each of its entries, 0 when the frame has no pool.
	uint pages;
	uint feedback;
	uint padding;
};
CN_PASS_CONSTANTS(Meshlet_Select_Constants, walk);

// Matches Item in cull_draws.hlsl. An item that walks has its submesh's meshlets in first and count, its first node in
// entry and its count of roots, one for each level, in list.
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
	uint entry;
	uint list;
	float4 lod_sphere;
};

// Matches Instance_Record in lib/engine/render/scene.odin.
struct Instance_Record {
	float4 rows[3];
	float4 previous_rows[3];
	uint id;
	uint flags;
	uint2 padding;
};

// Mesh_Record in lib/engine/render/scene.odin is this many bytes, with its meshlet nodes' index at this byte.
static const uint MESH_RECORD_SIZE = 80;
static const uint MESH_RECORD_FLAGS = 16;
static const uint MESH_RECORD_NODES = 40;
static const uint MESH_RECORD_PAGES = 64;
// Matches MESH_PAGED in material_common.hlsli.
static const uint MESH_PAGED = 16;
// Match MAX_SELECTED_MESHLETS, SELECTION_NONE and MESHLET_SELECT_ROW in lib/engine/render/meshlet_select.odin.
static const uint MAX_SELECTED_MESHLETS = 1u << 20;
static const uint SELECTION_NONE = 0xffffffffu;
static const uint MESHLET_SELECT_ROW = 32768;
// The words of Cull_Stats in lib/engine/render/occlusion.odin that the walk adds to: the walked items' meshlets, and
// those that their amplification shaders test.
static const uint STATS_HIERARCHY_MESHLETS = 24;
static const uint STATS_SELECTED_MESHLETS = 28;

static const uint WALK_GROUP_SIZE = 64;
// The nodes of one depth of the trees, the groups whose error shows, and the depths, that a walk can hold. A tree of
// eight children a node is 8 deep at 2^24 groups.
static const uint WALK_QUEUE = 1024;
static const uint WALK_LEAVES = 512;
static const uint WALK_DEPTHS = 24;
// A node is walked, and a group's meshlets selected, when its error projects to more than this: a little under the
// amplification shaders' 1, so rounding cannot leave out a meshlet that they draw. They test each meshlet again.
static const float WALK_THRESHOLD = 0.99;

groupshared uint queue[2][WALK_QUEUE];
groupshared uint queue_count[2];
// Each selected group: its first meshlet, from the submesh's, its count, and its first place in the item's range.
groupshared uint3 leaves[WALK_LEAVES];
groupshared uint leaf_count;
groupshared uint total;
groupshared uint overflow;
groupshared uint base;

float3 transform_point(float4 rows[3], float3 p) {
	float4 v = float4(p, 1);
	return float3(dot(rows[0], v), dot(rows[1], v), dot(rows[2], v));
}

[numthreads(WALK_GROUP_SIZE, 1, 1)]
void cs_main(uint3 group : SV_GroupID, uint thread : SV_GroupIndex) {
	uint walk_index = group.y * MESHLET_SELECT_ROW + group.x;
	if (walk_index >= walk.walk_count) {
		return;
	}
	uint item_index = cn_buffer(walk.walks).Load(walk.walks_offset + walk_index * 4);
	Item item = cn_buffer(walk.items).Load<Item>(walk.items_offset + item_index * sizeof(Item));
	Instance_Record instance = cn_buffer(walk.instances).Load<Instance_Record>(item.instance * sizeof(Instance_Record));
	uint record = walk.meshes_offset + item.mesh * MESH_RECORD_SIZE;
	uint nodes = cn_buffer(walk.meshes).Load(record + MESH_RECORD_NODES);
	bool paged = (cn_buffer(walk.meshes).Load(record + MESH_RECORD_FLAGS) & MESH_PAGED) != 0;
	uint pages = cn_buffer(walk.meshes).Load(record + MESH_RECORD_PAGES);
	// The largest scale of an axis, a column's length, as as_cluster takes it.
	float3 scales = sqrt(instance.rows[0].xyz * instance.rows[0].xyz + instance.rows[1].xyz * instance.rows[1].xyz + instance.rows[2].xyz * instance.rows[2].xyz);
	float scale = max(scales.x, max(scales.y, scales.z));

	// The roots, one for each level, are the submesh's first nodes.
	uint roots = item.list;
	if (thread == 0) {
		queue_count[0] = min(roots, WALK_QUEUE);
		queue_count[1] = 0;
		leaf_count = 0;
		total = 0;
		overflow = roots > WALK_QUEUE ? 1 : 0;
	}
	for (uint r = thread; r < min(roots, WALK_QUEUE); r += WALK_GROUP_SIZE) {
		queue[0][r] = r;
	}
	GroupMemoryBarrierWithGroupSync();
	uint in_queue = 0;
	for (uint depth = 0; depth < WALK_DEPTHS; depth++) {
		uint count = min(queue_count[in_queue], WALK_QUEUE);
		if (count == 0) {
			break;
		}
		uint out_queue = in_queue ^ 1;
		for (uint i = thread; i < count; i += WALK_GROUP_SIZE) {
			Meshlet_Node n = cn_buffer(nodes).Load<Meshlet_Node>((item.entry + queue[in_queue][i]) * sizeof(Meshlet_Node));
			float3 center = transform_point(instance.rows, n.sphere.xyz) - walk.camera.xyz;
			float shows = lod_error(center, n.sphere.w, n.error, scale, walk.lod_near, walk.lod_scale);
			if (shows <= WALK_THRESHOLD) {
				continue;
			}
			uint children = n.count & ~MESHLET_NODE_LEAF;
			uint slot;
			if ((n.count & MESHLET_NODE_LEAF) != 0) {
				// A paged mesh's group: its first meshlet is in its page, packed with the page's slot.
				uint first = n.first;
				if (paged) {
					uint entry = pages + n.page;
					uint page_slot = mesh_page_slot(walk.pages, entry);
					uint previous;
					if (page_slot == MESH_PAGE_ABSENT) {
						// Wanted by how much its error shows: a float over 0 orders as its bits do.
						cn_rw_buffer(walk.feedback).InterlockedMax(entry * 4, asuint(min(shows, 3.0e38)), previous);
						continue;
					}
					cn_rw_buffer(walk.feedback).InterlockedMax(entry * 4, 1, previous);
					first = mesh_page_packed(page_slot, n.first);
				}
				uint offset;
				InterlockedAdd(leaf_count, 1, slot);
				InterlockedAdd(total, children, offset);
				if (slot < WALK_LEAVES) {
					leaves[slot] = uint3(first, children, offset);
				}
			} else {
				InterlockedAdd(queue_count[out_queue], children, slot);
				if (slot + children <= WALK_QUEUE) {
					for (uint k = 0; k < children; k++) {
						queue[out_queue][slot + k] = n.first + k;
					}
				} else {
					InterlockedOr(overflow, 1);
				}
			}
		}
		GroupMemoryBarrierWithGroupSync();
		if (thread == 0) {
			queue_count[in_queue] = 0;
		}
		GroupMemoryBarrierWithGroupSync();
		in_queue = out_queue;
	}

	// The item's range of the list, or SELECTION_NONE, when it tests all of its meshlets.
	if (thread == 0) {
		bool whole = overflow != 0 || queue_count[in_queue] != 0 || leaf_count > WALK_LEAVES;
		uint first = 0;
		if (!whole) {
			cn_rw_buffer(walk.selections).InterlockedAdd(0, total, first);
			whole = first + total > MAX_SELECTED_MESHLETS;
		}
		base = whole ? SELECTION_NONE : first;
		cn_rw_buffer(walk.selections).Store2(8 + item_index * 8, uint2(first, whole ? SELECTION_NONE : total));
		cn_rw_buffer(walk.stats).InterlockedAdd(STATS_HIERARCHY_MESHLETS, item.count);
		cn_rw_buffer(walk.stats).InterlockedAdd(STATS_SELECTED_MESHLETS, whole ? item.count : total);
	}
	GroupMemoryBarrierWithGroupSync();
	if (base == SELECTION_NONE) {
		return;
	}
	for (uint l = thread; l < leaf_count; l += WALK_GROUP_SIZE) {
		uint3 leaf = leaves[l];
		// A paged mesh's meshlets are packed, from their page's first. Another's are from the item's first.
		uint first = paged ? leaf.x : item.first + leaf.x;
		for (uint k = 0; k < leaf.y; k++) {
			cn_rw_buffer(walk.selected).Store((base + leaf.z + k) * 4, first + k);
		}
	}
}
