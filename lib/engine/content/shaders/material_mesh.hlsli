// The mesh shader path of the opaque material passes (see docs/rendering/gpu-scene.md#mesh-shader-path). Culling
// gives each visible submesh one mesh draw, whose amplification groups each test MESHLETS_PER_GROUP of its meshlets:
// each picks its level of detail and culls by its sphere and its normal cone, and the meshlets left launch one mesh
// group each. The mesh shaders place vertices with place_vertex, as vertex pulling does, so both paths draw the same
// depths. Each pass's mesh shader is beside its vertex shader.
#ifndef MATERIAL_MESH_HLSLI
#define MATERIAL_MESH_HLSLI

#include "material_vertex.hlsli"
#include "virtual_shadow.hlsli"
#include "meshlet_lod.hlsli"
#include "mesh_pages.hlsli"
#include "occlusion.hlsli"

// Match MESHLET_MAX_VERTICES and MESHLET_MAX_TRIANGLES in lib/engine/asset/format/mesh.odin. A mesh group's threads
// each write a vertex and a triangle.
#define MESHLET_MAX_VERTICES 64
#define MESHLET_MAX_TRIANGLES 124
#define MESHLET_THREADS 128
// Matches MESHLETS_PER_GROUP in lib/engine/render/scene.odin.
#define MESHLETS_PER_GROUP 32
// Matches INSTANCE_GROUP_ROW and DRAW_INSTANCE_SHIFT in lib/engine/render/scene.odin: an instanced draw's groups have
// its instances in rows of this many, and its draw record's flags have its count of instances above this bit.
static const uint INSTANCE_GROUP_ROW = 32768;
static const uint DRAW_INSTANCE_SHIFT = 8;
// Vertex.cluster has the meshlet's level above its index.
static const uint MESHLET_DEPTH_SHIFT = 24;
// An infinite f16's bits, in a meshlet's radius: a meshlet too far from the mesh's origin for f16, which culling keeps.
// Matches F16_INFINITE_BITS in lib/engine/asset/format/mesh.odin.
static const uint MESHLET_RADIUS_INFINITE = 0x7c00;

// Matches Meshlet in lib/engine/asset/format/mesh.odin. counts has the vertex count in its lowest byte, the triangle
// count in the next, the level in the next, and in the high one 1 when its refs to its vertices are 16 bits; cone has
// the normal cone's axis in its low three bytes and its cutoff in the high one, each snorm8; sphere has the culling
// sphere's center and radius as f16s, each word's lowest half first. A meshlet draws when error projects to at most the
// threshold and parent_error to more, each from its sphere.
struct Meshlet {
	uint vertex_offset;
	uint triangle_offset;
	uint base_vertex;
	uint counts;
	uint cone;
	uint2 sphere;
	float4 error_sphere;
	float4 parent_sphere;
	float error;
	float parent_error;
	// The page of the group that it was simplified from, or MESH_PAGE_NONE.
	uint refined_page;
};

_Static_assert(sizeof(Meshlet) == 72, "Meshlet must match lib/engine/asset/format/mesh.odin");

// The meshlets that an amplification group launches, and its instance's poses, this frame's and last frame's, which
// the group places once, an instanced draw's from its entity's and its own, so neither its threads nor its mesh
// groups' do it again.
struct Cluster_Payload {
	uint meshlets[MESHLETS_PER_GROUP];
	float4 rows[3];
	float4 previous_rows[3];
};

groupshared Cluster_Payload cluster_payload;
groupshared uint cluster_count;

// projected_error is an error within a sphere of the mesh, seen from the camera at its nearest, over the threshold:
// above 1 shows (see lod_error).
float projected_error(float4 rows[3], float scale, float4 sphere, float error) {
	float3 center = transform_point(rows, sphere.xyz) - frame.camera_offset.xyz;
	return lod_error(center, sphere.w, error, scale, frame.lod_near, frame.lod_scale);
}

// lod_selected is whether a meshlet is its part of the mesh's level for the camera: fine enough, and its group's
// simplification too coarse. Errors grow up the hierarchy, so exactly one level of each part is selected. A meshlet
// whose source is absent, the page of the group that it was simplified from, counts as fine enough, as nothing finer
// can draw in its place (see docs/content/kinds/meshes.md#the-cut-with-pages-missing).
bool lod_selected(Meshlet c, float4 rows[3], float scale, bool source_absent) {
	return (source_absent || projected_error(rows, scale, c.error_sphere, c.error) <= 1) && projected_error(rows, scale, c.parent_sphere, c.parent_error) > 1;
}

// cluster_visible is whether a meshlet of an instance draws in the view: its level is selected, its sphere, grown by
// the material's displacement bound, is in the frustum, and its normal cone does not point away from the view. The
// cone is not tested for a two-sided material, for a material that displaces its vertices, which may turn them, for
// an instance whose scale is not uniform, which bends normals, or for a cone too wide to cull. In the late view of
// occlusion culling, its sphere is not behind the depth pyramid either. In a virtual shadow map's level, its sphere
// reaches a page that was allocated. A sphere with an infinite radius passes every test, which would otherwise take it
// through NaNs. A view of the voxel cones' voxelization tests no cone, which faces the camera, not its view.
bool cluster_visible(Meshlet c, Instance_Record instance, float bound, bool source_absent) {
	float3 scales = axis_scales(instance.rows);
	float scale = max(scales.x, max(scales.y, scales.z));
	if (!lod_selected(c, instance.rows, scale, source_absent)) {
		return false;
	}
	if ((c.sphere.y >> 16) == MESHLET_RADIUS_INFINITE) {
		return true;
	}
	float3 sphere_center = float3(f16tof32(c.sphere.x), f16tof32(c.sphere.x >> 16), f16tof32(c.sphere.y));
	float3 center = transform_point(instance.rows, sphere_center) - frame.camera_offset.xyz;
	float radius = f16tof32(c.sphere.y >> 16) * scale + bound;
	for (uint i = 0; i < 6; i++) {
		if (dot(frame.planes[i].xyz, center) + frame.planes[i].w < -radius) {
			return false;
		}
	}
#if !MATERIAL_TWO_SIDED && !MATERIAL_DISPLACES
	int4 packed = int4(c.cone << 24, c.cone << 16, c.cone << 8, c.cone) >> 24;
	float uniformity = min(scales.x, min(scales.y, scales.z)) / scale;
	if (packed.w < 127 && uniformity > 0.99 && frame.voxel_draw == 0) {
		float3 axis = normalize(transform_direction(instance.rows, float3(packed.xyz) / 127.0));
		float cutoff = packed.w / 127.0;
		if (frame.cull_eye.w != 0) {
			float3 v = center - frame.cull_eye.xyz;
			if (dot(v, axis) >= cutoff * length(v) + radius) {
				return false;
			}
		} else if (dot(frame.cull_eye.xyz, axis) >= cutoff) {
			return false;
		}
	}
#endif
	// The late view of occlusion culling tests each meshlet against the depth pyramid too.
	if (frame.occlusion != 0 && sphere_occluded(load_occlusion(frame.occlusion - 1, frame.occlusion_offset), center, radius)) {
		return false;
	}
	if (frame.virtual_draw != 0 && !virtual_sphere_draws(center, radius)) {
		return false;
	}
	return true;
}

// as_cluster is every opaque pass's amplification shader. The draw's meshlets are its draw record's first and count,
// or with DRAW_SELECTED those of the selected meshlets' list, MESHLETS_PER_GROUP to a group along x. A paged mesh's
// meshlets are in the pool: the list has them packed, and a draw without a selection finds each in the page table, and
// draws none of a page that is not resident. What the group launches is a meshlet's index, or its packed word. An instanced draw's groups are its meshlets along z and its instances along x
// and y (see docs/rendering/gpu-scene.md#instanced-meshes).
[numthreads(MESHLETS_PER_GROUP, 1, 1)]
void as_cluster(uint3 group : SV_GroupID, uint thread : SV_GroupIndex) {
	Draw_Record d = load_draw();
	uint chunk = group.x;
	uint instance_id = 0;
	bool listed = true;
	if ((d.flags & DRAW_INSTANCES) != 0) {
		chunk = group.z;
		instance_id = group.y * INSTANCE_GROUP_ROW + group.x;
		listed = instance_id < (d.flags >> DRAW_INSTANCE_SHIFT);
	}
	if (thread == 0) {
		cluster_count = 0;
		if (listed) {
			Instance_Record placed = draw_instance(d, instance_id);
			for (uint k = 0; k < 3; k++) {
				cluster_payload.rows[k] = placed.rows[k];
				cluster_payload.previous_rows[k] = placed.previous_rows[k];
			}
		}
	}
	GroupMemoryBarrierWithGroupSync();
	uint local = chunk * MESHLETS_PER_GROUP + thread;
	if (listed && local < d.count) {
		// A draw with DRAW_SELECTED has the indices of the meshlets that select_meshlets.hlsl picked.
		uint meshlet = d.first + local;
		bool selected = (d.flags & DRAW_SELECTED) != 0;
		if (selected) {
			meshlet = cn_buffer(frame.selected_meshlets).Load(meshlet * 4);
		}
		Mesh_Record m = load_mesh(d);
		Meshlet c = (Meshlet)0;
		bool present = true;
		bool source_absent = false;
		if ((m.flags & MESH_PAGED) != 0) {
			if (!selected) {
				meshlet = mesh_page_find(frame.mesh_pages, m.pages, m.page_count, meshlet);
				present = meshlet != MESH_PAGE_ABSENT;
			}
			if (present) {
				c = cn_buffer(frame.mesh_pool).Load<Meshlet>(mesh_page_meshlet(meshlet));
				source_absent = c.refined_page != MESH_PAGE_NONE && mesh_page_slot(frame.mesh_pages, m.pages + c.refined_page) == MESH_PAGE_ABSENT;
			}
		} else {
			c = cn_buffer(m.meshlets).Load<Meshlet>(meshlet * sizeof(Meshlet));
		}
		Instance_Record instance = load_instance(d);
		for (uint k = 0; k < 3; k++) {
			instance.rows[k] = cluster_payload.rows[k];
		}
		if (present && cluster_visible(c, instance, d.bound, source_absent)) {
			uint slot;
			InterlockedAdd(cluster_count, 1, slot);
			cluster_payload.meshlets[slot] = meshlet;
		}
	}
	GroupMemoryBarrierWithGroupSync();
	DispatchMesh(cluster_count, 1, 1, cluster_payload);
}

// Cluster is what a mesh group draws: a meshlet of a draw, with the buffers that its refs and its triangles are in and
// where they start there, in bytes: the mesh's streams, or its page's in the pool.
struct Cluster {
	Draw_Record draw;
	Mesh_Record mesh;
	Instance_Record instance;
	Meshlet meshlet;
	uint refs;
	uint refs_offset;
	uint triangles;
	uint triangles_offset;
	uint index;
	uint vertex_count;
	uint triangle_count;
};

// load_cluster is a meshlet of the draw, at the instance's poses that its amplification group placed. A paged mesh's
// meshlet is packed: its record, its refs, its triangles and its vertices are in its page, so the cluster's copy of
// the mesh's record names the pool and the page's streams, and place_vertex reads a vertex of the page. DXC cannot pass
// the payload, or an array of it, to a function, so LOAD_CLUSTER passes its rows one by one.
Cluster load_cluster(uint meshlet, float4 r0, float4 r1, float4 r2, float4 p0, float4 p1, float4 p2) {
	Cluster c;
	c.draw = load_draw();
	c.mesh = load_mesh(c.draw);
	c.instance = load_instance(c.draw);
	c.instance.rows[0] = r0;
	c.instance.rows[1] = r1;
	c.instance.rows[2] = r2;
	c.instance.previous_rows[0] = p0;
	c.instance.previous_rows[1] = p1;
	c.instance.previous_rows[2] = p2;
	if ((c.mesh.flags & MESH_PAGED) != 0) {
		uint page = mesh_page_base(meshlet);
		Mesh_Page_Header header = cn_buffer(frame.mesh_pool).Load<Mesh_Page_Header>(page);
		c.meshlet = cn_buffer(frame.mesh_pool).Load<Meshlet>(mesh_page_meshlet(meshlet));
		c.refs = frame.mesh_pool;
		c.refs_offset = page + header.vertex_refs;
		c.triangles = frame.mesh_pool;
		c.triangles_offset = page + header.triangles;
		c.mesh.positions = frame.mesh_pool;
		c.mesh.positions_offset = page + header.positions;
		c.mesh.attributes = frame.mesh_pool;
		c.mesh.attributes_offset = page + header.attributes;
	} else {
		c.meshlet = cn_buffer(c.mesh.meshlets).Load<Meshlet>(meshlet * sizeof(Meshlet));
		c.refs = c.mesh.meshlet_vertices;
		c.refs_offset = 0;
		c.triangles = c.mesh.meshlet_triangles;
		c.triangles_offset = 0;
	}
	// The debug views' color of the meshlet, which has 24 bits.
	c.index = meshlet & ((1u << MESHLET_DEPTH_SHIFT) - 1);
	c.vertex_count = c.meshlet.counts & 0xff;
	c.triangle_count = (c.meshlet.counts >> 8) & 0xff;
	return c;
}

#define LOAD_CLUSTER(clusters, group) load_cluster(clusters.meshlets[group], clusters.rows[0], clusters.rows[1], clusters.rows[2], \
	clusters.previous_rows[0], clusters.previous_rows[1], clusters.previous_rows[2])

// cluster_vertex is a meshlet's vertex: its ref, 16 bits in a whole word or a whole word, from the meshlet's lowest
// vertex. Matches meshlet_vertex in lib/engine/asset/format/mesh.odin.
Material_Vertex cluster_vertex(Cluster c, uint i) {
	uint words = c.refs_offset + c.meshlet.vertex_offset * 4;
	uint ref;
	if ((c.meshlet.counts >> 24) != 0) {
		uint word = cn_buffer(c.refs).Load(words + (i / 2) * 4);
		ref = (i & 1) != 0 ? word >> 16 : word & 0xffff;
	} else {
		ref = cn_buffer(c.refs).Load(words + i * 4);
	}
	Material_Vertex v = place_vertex(c.draw, c.mesh, c.instance, c.meshlet.base_vertex + ref);
	v.cluster = c.index | ((c.meshlet.counts >> 16) & 0xff) << MESHLET_DEPTH_SHIFT;
	return v;
}

// cluster_triangle is a meshlet's triangle, as indices into its vertices: three bytes, which a load of whole aligned
// words reads from the word that they start in and, when they cross into it, the next. The streams start at multiples
// of 4 and are padded to them, so the next word is never past the stream. Matches meshlet_triangle in
// lib/engine/asset/format/mesh.odin.
uint3 cluster_triangle(Cluster c, uint i) {
	uint at = c.triangles_offset + (c.meshlet.triangle_offset + i) * 3;
	uint word = at & ~3u;
	uint shift = (at & 3) * 8;
	uint t = cn_buffer(c.triangles).Load(word) >> shift;
	if (shift > 8) {
		t |= cn_buffer(c.triangles).Load(word + 4) << (32 - shift);
	}
	return uint3(t & 0xff, (t >> 8) & 0xff, (t >> 16) & 0xff);
}

#endif
