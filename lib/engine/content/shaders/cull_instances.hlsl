// Culls the Instanced_Mesh_Renderers' instance sets (see docs/rendering/gpu-scene.md#instanced-meshes) in three
// phases, a dispatch each, before cull_draws.hlsl:
//   Cull: a group for each cell of each set in each view tests the cell's sphere, then each of its instances' spheres,
//   against the view's frustum, and gives each visible instance a list: its impostor's, or its mesh's for its level
//   bucket, by the camera's level of detail. It writes the cell's visibility bits and lists in the view, and counts the
//   set's instances in each list there.
//   Place: a thread for each of each set's lists in each view takes a range of the visible lists for it.
//   List: a group for each cell in each view writes its visible instances into their lists' ranges.
// cull_draws.hlsl then draws each of a set's items once for each instance in its list's range of the view.
#include "instanced.hlsli"
#include "occlusion.hlsli"

// Matches Instance_Cull_Constants in lib/engine/render/scene.odin. The sets, the jobs and the views are in the upload
// ring, at these offsets of their buffers.
struct Instance_Cull_Constants {
	uint phase;
	uint set_count;
	uint view_count;
	uint job_count;
	uint sets;
	uint sets_offset;
	uint jobs;
	uint jobs_offset;
	uint views;
	uint views_offset;
	uint instances;
	uint bits;
	uint bits_cells;
	uint counters;
	uint visible;
	uint visible_capacity;
	// The camera's offset from the render origin, and its level of detail, which pick between a mesh and its impostor,
	// and a mesh's level bucket, in every view (see Cull_Constants in cull_draws.hlsl).
	float4 camera;
	float lod_scale;
	float lod_near;
	// The views of the dispatch, the early phases' or the late view's, and the frame's Occlusion_Constants.
	uint view_first;
	uint view_rows;
	uint occlusion;
	uint occlusion_offset;
	// The camera's tally (see Cull_Stats in lib/engine/render/occlusion.odin).
	uint stats;
	uint padding;
};
CN_PASS_CONSTANTS(Instance_Cull_Constants, cull);

static const uint PHASE_CULL = 0;
static const uint PHASE_PLACE = 1;
static const uint PHASE_LIST = 2;
// Match INSTANCE_BITS_SIZE, INSTANCE_JOB_ROW, INSTANCE_LEVEL_BUCKETS and INSTANCE_LISTS in lib/engine/render/scene.odin.
// A cell's bits in a view are 256 visibility bits, then 4 bits of each instance's list. A set has a list for each
// level bucket, then its impostor's.
static const uint BITS_SIZE = 160;
static const uint JOB_ROW = 32768;
static const uint LEVEL_BUCKETS = 8;
static const uint LISTS = LEVEL_BUCKETS + 1;
static const uint IMPOSTOR_LIST = LEVEL_BUCKETS;

// Matches Instance_Set_Record in lib/engine/render/scene.odin. levels has, for each level below the last bucket's, the
// largest parent error of the mesh's meshlets there and how far their parents' spheres reach from the mesh's center.
static const uint SET_CASTS_SHADOWS = 1;
static const uint SET_IMPOSTOR = 2;
static const uint SET_BILLBOARD = 4;
// A set whose items are all opaque, which occlusion culling culls.
static const uint SET_OCCLUDABLE = 8;
struct Instance_Set_Record {
	uint instances;
	uint cells;
	uint first_cell;
	uint first_job;
	uint slot;
	uint flags;
	float bound;
	float impostor_error;
	float4 sphere;
	float2 levels[LEVEL_BUCKETS];
};

// Matches format.Instance_Cell in lib/engine/asset/format/instances.odin: a sphere about its instances' positions,
// and the largest scale of their axes.
struct Instance_Cell {
	float3 center;
	float radius;
	float max_scale;
	uint first;
	uint count;
	uint padding;
};

// Matches Cull_View in lib/engine/render/scene.odin and cull_draws.hlsl.
static const uint VIEW_CASTERS = 1;
static const uint VIEW_MODEL = 2;
struct Cull_View {
	float4 planes[6];
	float4 offset;
	uint first_draw;
	uint flags;
	uint2 padding;
};

// Matches the size of Instance_Record in lib/engine/render/scene.odin, whose first 48 bytes are its rows.
static const uint INSTANCE_RECORD_SIZE = 112;

groupshared uint visible_bits[8];
// With occlusion culling, the late view's instances that the depth pyramid shows, which are the cell's bits for next
// frame.
groupshared uint seen_bits[8];
// The late view's instances in the frustum that the depth pyramid hides, for the camera's tally.
groupshared uint hidden_count;
groupshared uint list_bits[32];
groupshared uint list_counts[LISTS];
groupshared uint list_starts[LISTS];

float3 transform_point(float4 rows[3], float3 p) {
	float4 v = float4(p, 1);
	return float3(dot(rows[0], v), dot(rows[1], v), dot(rows[2], v));
}

bool sphere_in_view(Cull_View view, float3 center, float radius) {
	for (uint i = 0; i < 6; i++) {
		if (dot(view.planes[i].xyz, center) + view.planes[i].w < -radius) {
			return false;
		}
	}
	return true;
}

// counter is a word of the counters for one of a set's lists in a view: its count, then its cursor, then its start,
// then the total of the counts.
uint counter(uint region, uint set, uint view, uint list) {
	return ((region * cull.set_count + set) * cull.view_count + view) * LISTS + list;
}

// level_bucket is the finest level of a mesh that the camera could select for an instance, as the mesh shader path
// selects meshlets (see lod_selected in material_mesh.hlsli), up to the last bucket: a meshlet below it has a parent
// whose error projects to at most 1 from anywhere in its sphere, so it never draws.
uint level_bucket(Instance_Set_Record set, float3 mesh_center, float scale) {
	float distance = length(mesh_center - cull.camera.xyz);
	for (uint level = 0; level + 1 < LEVEL_BUCKETS; level++) {
		float2 l = set.levels[level];
		if (l.x * scale / max(distance - l.y * scale, cull.lod_near) * cull.lod_scale > 1) {
			return level;
		}
	}
	return LEVEL_BUCKETS - 1;
}

// cull_cell is a cell's group in a view in the cull phase.
void cull_cell(uint thread, uint set_index, Instance_Set_Record set, uint cell_index, uint view_index, uint bits_at) {
	if (thread < 8) {
		visible_bits[thread] = 0;
		seen_bits[thread] = 0;
	}
	if (thread == 0) {
		hidden_count = 0;
	}
	if (thread < 32) {
		list_bits[thread] = 0;
	}
	if (thread < LISTS) {
		list_counts[thread] = 0;
	}
	GroupMemoryBarrierWithGroupSync();
	Cull_View view = cn_buffer(cull.views).Load<Cull_View>(cull.views_offset + view_index * sizeof(Cull_View));
	// With occlusion culling (see occlusion.hlsli), a set whose items are all opaque is split between the camera's
	// early view, which takes the instances that were visible last frame, and the late view, which takes those that the
	// depth pyramid shows and the early view did not, and keeps them for next frame. A set with other items is the early
	// view's alone.
	bool occludable = (set.flags & SET_OCCLUDABLE) != 0;
	bool early = (view.flags & VIEW_EARLY) != 0 && occludable;
	bool late = (view.flags & VIEW_LATE) != 0;
	Occlusion_Constants o = (Occlusion_Constants)0;
	uint seen_at = (set.first_cell + cell_index) * 32;
	if (early || late) {
		o = load_occlusion(cull.occlusion, cull.occlusion_offset);
	}
	Instance_Cell cell = cn_buffer(set.cells).Load<Instance_Cell>(cell_index * sizeof(Instance_Cell));
	ByteAddressBuffer records = cn_buffer(cull.instances);
	float4 entity[3];
	for (uint k = 0; k < 3; k++) {
		entity[k] = records.Load<float4>(set.slot * INSTANCE_RECORD_SIZE + k * 16);
	}
	float entity_scale = max_axis_scale(entity);
	// The view model's view draws no set, and a shadow view only a set that casts shadows.
	bool takes = (view.flags & VIEW_MODEL) == 0 && ((view.flags & VIEW_CASTERS) == 0 || (set.flags & SET_CASTS_SHADOWS) != 0);
	// The mesh's sphere, moved by an instance's pose, stays within its reach of the instance's position, scaled.
	float reach = length(set.sphere.xyz) + set.sphere.w;
	float3 cell_center = transform_point(entity, cell.center) - view.offset.xyz;
	float cell_radius = (cell.radius + reach * cell.max_scale) * entity_scale + set.bound;
	takes = takes && sphere_in_view(view, cell_center, cell_radius);
	// The late view first tests the whole cell, whose instances are all hidden when it is, as the tally counts them.
	if (takes && late && occludable && sphere_occluded(o, cell_center, cell_radius)) {
		takes = false;
		if (thread == 0) {
			hidden_count = cell.count;
		}
	}
	takes = takes && !(late && !occludable);
	if (takes && thread < cell.count) {
		float4 local[3];
		instance_rows(cn_buffer(set.instances), cell.first + thread, local);
		float4 rows[3];
		compose_rows(entity, local, rows);
		float scale = max_axis_scale(rows);
		float3 mesh_center = transform_point(rows, set.sphere.xyz);
		float3 center = mesh_center - view.offset.xyz;
		float radius = set.sphere.w * scale + set.bound;
		// A billboard's sphere turns about the instance's position.
		if ((set.flags & SET_BILLBOARD) != 0) {
			center = float3(rows[0].w, rows[1].w, rows[2].w) - view.offset.xyz;
			radius = reach * scale + set.bound;
		}
		bool shown = sphere_in_view(view, center, radius);
		uint bit = 1u << (thread % 32);
		bool was_seen = (early || late) && (cn_rw_buffer(o.cell_seen).Load(seen_at + (thread / 32) * 4) & bit) != 0;
		if (early) {
			shown = shown && was_seen;
		} else if (late && shown && !sphere_occluded(o, center, radius)) {
			InterlockedOr(seen_bits[thread / 32], bit);
			shown = !was_seen;
		} else if (late) {
			if (shown) {
				InterlockedAdd(hidden_count, 1);
			}
			shown = false;
		}
		if (shown) {
			InterlockedOr(visible_bits[thread / 32], 1u << (thread % 32));
			// Each view draws the mesh or its impostor, and the mesh's levels, as the camera does, as cull_draws.hlsl
			// picks them, so a shadow is the shape that the camera sees.
			uint list = 0;
			bool far = false;
			if ((set.flags & SET_IMPOSTOR) != 0) {
				float distance = max(length(mesh_center - cull.camera.xyz) - set.sphere.w * scale, cull.lod_near);
				far = set.impostor_error * scale / distance * cull.lod_scale <= 1;
			}
			list = far ? IMPOSTOR_LIST : level_bucket(set, mesh_center, scale);
			InterlockedOr(list_bits[thread / 8], list << ((thread % 8) * 4));
			InterlockedAdd(list_counts[list], 1);
		}
	}
	GroupMemoryBarrierWithGroupSync();
	RWByteAddressBuffer bits = cn_rw_buffer(cull.bits);
	if (thread < 8) {
		bits.Store(bits_at + thread * 4, visible_bits[thread]);
	}
	if (thread < 32) {
		bits.Store(bits_at + 32 + thread * 4, list_bits[thread]);
	}
	// The camera's tally: what its views list, and what the late view's pyramid hides.
	if (thread == 0 && (view_index == 0 || late)) {
		uint listed = 0;
		for (uint w = 0; w < 8; w++) {
			listed += countbits(visible_bits[w]);
		}
		RWByteAddressBuffer stats = cn_rw_buffer(cull.stats);
		stats.InterlockedAdd(late ? 16 : 12, listed);
		if (hidden_count > 0) {
			stats.InterlockedAdd(20, hidden_count);
		}
	}
	// The late view keeps what the pyramid shows for next frame's early view.
	if (late && occludable && thread < 8) {
		cn_rw_buffer(o.cell_seen).Store(seen_at + thread * 4, seen_bits[thread]);
	}
	if (thread < LISTS && list_counts[thread] > 0) {
		cn_rw_buffer(cull.counters).InterlockedAdd(counter(0, set_index, view_index, thread) * 4, list_counts[thread]);
	}
}

// place_lists is the thread of one of a set's lists in a view in the place phase: its range of the visible lists,
// cut short where they are full.
void place_lists(uint i) {
	if (i >= cull.set_count * cull.view_rows * LISTS) {
		return;
	}
	// The dispatch's lists: each set's in each of its views.
	uint per_set = cull.view_rows * LISTS;
	uint set = i / per_set;
	uint view = cull.view_first + (i % per_set) / LISTS;
	uint list = i % LISTS;
	RWByteAddressBuffer counters = cn_rw_buffer(cull.counters);
	uint at = counter(0, set, view, list);
	uint count = counters.Load(at * 4);
	uint start = 0;
	if (count > 0) {
		counters.InterlockedAdd(counter(3, 0, 0, 0) * 4, count, start);
	}
	uint fits = start < cull.visible_capacity ? min(count, cull.visible_capacity - start) : 0;
	counters.Store(at * 4, fits);
	counters.Store(counter(2, set, view, list) * 4, start);
}

// list_cell is a cell's group in a view in the list phase: each instance that its bits have takes the next place of
// its list's range.
void list_cell(uint thread, uint set_index, Instance_Set_Record set, uint cell_index, uint view_index, uint bits_at) {
	// The bits are read through the view that the cull phase wrote them with.
	RWByteAddressBuffer bits = cn_rw_buffer(cull.bits);
	uint4 visible[2] = {bits.Load4(bits_at), bits.Load4(bits_at + 16)};
	// The whole group leaves together.
	if (all((visible[0] | visible[1]) == 0)) {
		return;
	}
	if (thread < LISTS) {
		list_counts[thread] = 0;
	}
	GroupMemoryBarrierWithGroupSync();
	uint word = thread / 32;
	bool shown = (visible[word / 4][word % 4] & (1u << (thread % 32))) != 0;
	uint list = (bits.Load(bits_at + 32 + (thread / 8) * 4) >> ((thread % 8) * 4)) & 0xf;
	uint place = 0;
	if (shown) {
		InterlockedAdd(list_counts[list], 1, place);
	}
	GroupMemoryBarrierWithGroupSync();
	RWByteAddressBuffer counters = cn_rw_buffer(cull.counters);
	if (thread < LISTS) {
		uint start = 0;
		if (list_counts[thread] > 0) {
			counters.InterlockedAdd(counter(1, set_index, view_index, thread) * 4, list_counts[thread], start);
		}
		list_starts[thread] = start;
	}
	GroupMemoryBarrierWithGroupSync();
	if (!shown) {
		return;
	}
	place += list_starts[list];
	if (place >= counters.Load(counter(0, set_index, view_index, list) * 4)) {
		return;
	}
	Instance_Cell cell = cn_buffer(set.cells).Load<Instance_Cell>(cell_index * sizeof(Instance_Cell));
	uint start = counters.Load(counter(2, set_index, view_index, list) * 4);
	cn_rw_buffer(cull.visible).Store((start + place) * 4, cell.first + thread);
}

[numthreads(256, 1, 1)]
void cs_main(uint3 group : SV_GroupID, uint thread : SV_GroupIndex, uint3 id : SV_DispatchThreadID) {
	if (cull.phase == PHASE_PLACE) {
		place_lists(id.x);
		return;
	}
	uint job = group.y * JOB_ROW + group.x;
	if (job >= cull.job_count) {
		return;
	}
	uint view_index = cull.view_first + group.z;
	uint set_index = cn_buffer(cull.jobs).Load(cull.jobs_offset + job * 4);
	Instance_Set_Record set = cn_buffer(cull.sets).Load<Instance_Set_Record>(cull.sets_offset + set_index * sizeof(Instance_Set_Record));
	uint cell_index = job - set.first_job;
	uint bits_at = (view_index * cull.bits_cells + set.first_cell + cell_index) * BITS_SIZE;
	if (cull.phase == PHASE_CULL) {
		cull_cell(thread, set_index, set, cell_index, view_index, bits_at);
	} else {
		list_cell(thread, set_index, set, cell_index, view_index, bits_at);
	}
}
