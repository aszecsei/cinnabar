// The visibility pass of an opaque material on the mesh shader path (see
// docs/rendering/lighting-and-shadows.md#visibility-buffer): the prepass, which also writes each pixel's triangle into
// the visibility buffer. Each triangle's value is its draw, its instance, its meshlet, its index in the meshlet and the
// pipeline, from the mesh shader, and the pixel shader adds whether the face is a front face. A material's shading
// from the visibility buffer then rebuilds the triangle from them (see material_shade.hlsli).
#ifndef MATERIAL_VISIBILITY_HLSLI
#define MATERIAL_VISIBILITY_HLSLI

#include "material_prepass.hlsli"

struct Visibility_Primitive {
	nointerpolation uint4 value : VISIBILITY;
};

struct Visibility_Targets {
	float2 normal : SV_Target0;
	float2 velocity : SV_Target1;
	uint4 visibility : SV_Target2;
};

[outputtopology("triangle")]
[numthreads(MESHLET_THREADS, 1, 1)]
void ms_visibility(
	uint thread : SV_GroupIndex,
	uint group : SV_GroupID,
	in payload Cluster_Payload clusters,
	out vertices Prepass_Varyings vertices[MESHLET_MAX_VERTICES],
	out indices uint3 triangles[MESHLET_MAX_TRIANGLES],
	out primitives Visibility_Primitive primitives[MESHLET_MAX_TRIANGLES]
) {
	Cluster c = LOAD_CLUSTER(clusters, group);
	SetMeshOutputCounts(c.vertex_count, c.triangle_count);
	if (thread < c.vertex_count) {
		vertices[thread] = prepass_varyings(cluster_vertex(c, thread));
	}
	if (thread < c.triangle_count) {
		triangles[thread] = cluster_triangle(c, thread);
		primitives[thread].value = uint4(CN_DRAW_ID + 1, clusters.instance_id, c.index, thread | push.pipeline << VIS_PIPELINE_SHIFT);
	}
}

Visibility_Targets ps_visibility(Prepass_Varyings i, Visibility_Primitive primitive, bool front : SV_IsFrontFace) {
	Prepass_Targets prepass = prepass_targets(i, front);
	Visibility_Targets o;
	o.normal = prepass.normal;
	o.velocity = prepass.velocity;
	o.visibility = primitive.value | uint4(0, 0, 0, front ? VIS_FRONT : 0);
	return o;
}

#endif
