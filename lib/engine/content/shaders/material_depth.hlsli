// The depth pass of every material (see docs/rendering/lighting-and-shadows.md#shadows), which the shadow maps draw. An opaque material
// has no pixel shader. A masked one evaluates its opacity and discards below the cutoff.
#ifndef MATERIAL_DEPTH_HLSLI
#define MATERIAL_DEPTH_HLSLI

#include "material_vertex.hlsli"
#include "material_mesh.hlsli"

#if MATERIAL_MASKED
Varyings vs_depth(uint vertex_id : SV_VertexID) {
	return vertex_varyings(load_vertex(vertex_id));
}

Varyings depth_varyings(Material_Vertex v) {
	return vertex_varyings(v);
}

void ps_depth(Varyings i, bool front : SV_IsFrontFace) {
	Surface s = evaluate(material_inputs(i, front));
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
}
#else
float4 vs_depth(uint vertex_id : SV_VertexID) : SV_Position {
	return clip_position(load_vertex(vertex_id).world);
}

// What an opaque material's mesh shader gives the depth pass, which has no pixel shader.
struct Depth_Varyings {
	float4 position : SV_Position;
};

Depth_Varyings depth_varyings(Material_Vertex v) {
	Depth_Varyings o;
	o.position = clip_position(v.world);
	return o;
}
#endif

#if MATERIAL_MASKED
#define DEPTH_VARYINGS Varyings
#else
#define DEPTH_VARYINGS Depth_Varyings
#endif

[outputtopology("triangle")]
[numthreads(MESHLET_THREADS, 1, 1)]
void ms_depth(
	uint thread : SV_GroupIndex,
	uint group : SV_GroupID,
	in payload Cluster_Payload clusters,
	out vertices DEPTH_VARYINGS vertices[MESHLET_MAX_VERTICES],
	out indices uint3 triangles[MESHLET_MAX_TRIANGLES]
) {
	Cluster c = load_cluster(clusters.meshlets[group]);
	SetMeshOutputCounts(c.vertex_count, c.triangle_count);
	if (thread < c.vertex_count) {
		vertices[thread] = depth_varyings(cluster_vertex(c, thread));
	}
	if (thread < c.triangle_count) {
		triangles[thread] = cluster_triangle(c, thread);
	}
}

#endif
