// The mesh shader path of the opaque material passes (see docs/rendering/gpu-scene.md#mesh-shader-path). Culling
// gives each visible submesh one mesh draw, whose amplification groups each test MESHLETS_PER_GROUP of its meshlets:
// each picks its level of detail and culls by its sphere and its normal cone, and the meshlets left launch one mesh
// group each. The mesh shaders place vertices with place_vertex, as vertex pulling does, so both paths draw the same
// depths. Each pass's mesh shader is beside its vertex shader.
#ifndef MATERIAL_MESH_HLSLI
#define MATERIAL_MESH_HLSLI

#include "material_vertex.hlsli"

// Match MESHLET_MAX_VERTICES and MESHLET_MAX_TRIANGLES in lib/engine/asset/format/mesh.odin. A mesh group's threads
// each write a vertex and a triangle.
#define MESHLET_MAX_VERTICES 64
#define MESHLET_MAX_TRIANGLES 124
#define MESHLET_THREADS 128
// Matches MESHLETS_PER_GROUP in lib/engine/render/scene.odin.
#define MESHLETS_PER_GROUP 32
// Vertex.cluster has the meshlet's level above its index.
static const uint MESHLET_DEPTH_SHIFT = 24;

// Matches Meshlet in lib/engine/asset/format/mesh.odin. counts has the vertex count in its lowest byte, the triangle
// count in the next and the level in its high half; cone has the normal cone's axis in its low three bytes and its
// cutoff in the high one, each snorm8. A meshlet draws when error projects to at most the threshold and parent_error
// to more, each from its sphere.
struct Meshlet {
	uint vertex_offset;
	uint triangle_offset;
	uint counts;
	uint cone;
	float4 sphere;
	float4 error_sphere;
	float4 parent_sphere;
	float error;
	float parent_error;
	uint2 padding;
};

struct Cluster_Payload {
	uint meshlets[MESHLETS_PER_GROUP];
};

groupshared Cluster_Payload cluster_payload;
groupshared uint cluster_count;

// axis_scales are how much an instance's rows scale each of the mesh's axes: the lengths of their columns.
float3 axis_scales(float4 rows[3]) {
	return sqrt(rows[0].xyz * rows[0].xyz + rows[1].xyz * rows[1].xyz + rows[2].xyz * rows[2].xyz);
}

// projected_error is an error within a sphere of the mesh, seen from the camera at its nearest, over the threshold:
// above 1 shows. The camera is at 0, since positions are relative to it.
float projected_error(float4 rows[3], float scale, float4 sphere, float error) {
	float3 center = transform_point(rows, sphere.xyz) - frame.camera_offset.xyz;
	float distance = max(length(center) - sphere.w * scale, frame.lod_near);
	return error * scale / distance * frame.lod_scale;
}

// lod_selected is whether a meshlet is its part of the mesh's level for the camera: fine enough, and its group's
// simplification too coarse. Errors grow up the hierarchy, so exactly one level of each part is selected.
bool lod_selected(Meshlet c, float4 rows[3], float scale) {
	return projected_error(rows, scale, c.error_sphere, c.error) <= 1 && projected_error(rows, scale, c.parent_sphere, c.parent_error) > 1;
}

// cluster_visible is whether a meshlet of an instance draws in the view: its level is selected, its sphere is in the
// frustum, and its normal cone does not point away from the view. The cone is not tested for a two-sided material,
// for an instance whose scale is not uniform, which bends normals, or for a cone too wide to cull.
bool cluster_visible(Meshlet c, Instance_Record instance) {
	float3 scales = axis_scales(instance.rows);
	float scale = max(scales.x, max(scales.y, scales.z));
	if (!lod_selected(c, instance.rows, scale)) {
		return false;
	}
	float3 center = transform_point(instance.rows, c.sphere.xyz) - frame.camera_offset.xyz;
	float radius = c.sphere.w * scale;
	for (uint i = 0; i < 6; i++) {
		if (dot(frame.planes[i].xyz, center) + frame.planes[i].w < -radius) {
			return false;
		}
	}
#if !MATERIAL_TWO_SIDED
	int4 packed = int4(c.cone << 24, c.cone << 16, c.cone << 8, c.cone) >> 24;
	float uniformity = min(scales.x, min(scales.y, scales.z)) / scale;
	if (packed.w < 127 && uniformity > 0.99) {
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
	return true;
}

// as_cluster is every opaque pass's amplification shader. The draw's meshlets are its draw record's first and count.
[numthreads(MESHLETS_PER_GROUP, 1, 1)]
void as_cluster(uint group : SV_GroupID, uint thread : SV_GroupIndex) {
	if (thread == 0) {
		cluster_count = 0;
	}
	GroupMemoryBarrierWithGroupSync();
	Draw_Record d = load_draw();
	uint local = group * MESHLETS_PER_GROUP + thread;
	if (local < d.count) {
		uint meshlet = d.first + local;
		Mesh_Record m = load_mesh(d);
		Meshlet c = cn_buffer(m.meshlets).Load<Meshlet>(meshlet * sizeof(Meshlet));
		if (cluster_visible(c, load_instance(d))) {
			uint slot;
			InterlockedAdd(cluster_count, 1, slot);
			cluster_payload.meshlets[slot] = meshlet;
		}
	}
	GroupMemoryBarrierWithGroupSync();
	DispatchMesh(cluster_count, 1, 1, cluster_payload);
}

// Cluster is what a mesh group draws: a meshlet of a draw.
struct Cluster {
	Draw_Record draw;
	Mesh_Record mesh;
	Instance_Record instance;
	Meshlet meshlet;
	uint index;
	uint vertex_count;
	uint triangle_count;
};

Cluster load_cluster(uint meshlet) {
	Cluster c;
	c.draw = load_draw();
	c.mesh = load_mesh(c.draw);
	c.instance = load_instance(c.draw);
	c.meshlet = cn_buffer(c.mesh.meshlets).Load<Meshlet>(meshlet * sizeof(Meshlet));
	c.index = meshlet;
	c.vertex_count = c.meshlet.counts & 0xff;
	c.triangle_count = (c.meshlet.counts >> 8) & 0xff;
	return c;
}

// cluster_vertex is a meshlet's vertex.
Material_Vertex cluster_vertex(Cluster c, uint i) {
	uint index = cn_buffer(c.mesh.meshlet_vertices).Load((c.meshlet.vertex_offset + i) * 4);
	Material_Vertex v = place_vertex(c.draw, c.mesh, c.instance, index);
	v.cluster = c.index | (c.meshlet.counts >> 16) << MESHLET_DEPTH_SHIFT;
	return v;
}

// cluster_triangle is a meshlet's triangle, as indices into its vertices.
uint3 cluster_triangle(Cluster c, uint i) {
	uint t = cn_buffer(c.mesh.meshlet_triangles).Load((c.meshlet.triangle_offset + i) * 4);
	return uint3(t & 0xff, (t >> 8) & 0xff, (t >> 16) & 0xff);
}

#endif
