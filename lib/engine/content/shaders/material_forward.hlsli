// The forward pass of every material (see docs/rendering/materials.md#materials). It draws after the prepass with an Equal depth
// test, so each pixel shades once. The cooker includes it after the shading model, the Params struct and the
// material's evaluate, with these defined:
//   MATERIAL_TWO_SIDED, MATERIAL_MASKED and MATERIAL_CUTOFF: the material's settings.
//   MATERIAL_TRANSPARENT: a transparent or additive material, which has no forward pass of its own; its passes shade
//   with forward_color (see material_transparent.hlsli).
//   SHADING_NO_LIGHTING: the shading model only emits.
//   SHADING_HAS_NORMAL: the shading model's Surface has a tangent-space normal, which the passes map to the world.
#ifndef MATERIAL_FORWARD_HLSLI
#define MATERIAL_FORWARD_HLSLI

#include "material_vertex.hlsli"
#include "material_mesh.hlsli"
#include "material_lighting.hlsli"
#include "fog_at.hlsli"

// The scene's HDR colors, pre-exposed, and the entity IDs that the editor picks from.
struct Targets {
	float4 color : SV_Target0;
	uint id : SV_Target1;
};

Varyings vs_forward(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
	return vertex_varyings(load_vertex(vertex_id, instance_id));
}

[outputtopology("triangle")]
[numthreads(MESHLET_THREADS, 1, 1)]
void ms_forward(
	uint thread : SV_GroupIndex,
	uint group : SV_GroupID,
	in payload Cluster_Payload clusters,
	out vertices Varyings vertices[MESHLET_MAX_VERTICES],
	out indices uint3 triangles[MESHLET_MAX_TRIANGLES]
) {
	Cluster c = LOAD_CLUSTER(clusters, group);
	SetMeshOutputCounts(c.vertex_count, c.triangle_count);
	if (thread < c.vertex_count) {
		vertices[thread] = vertex_varyings(cluster_vertex(c, thread));
	}
	if (thread < c.triangle_count) {
		triangles[thread] = cluster_triangle(c, thread);
	}
}

// The colors of the directional lights' cascades, and beyond the last.
static const float3 CASCADE_COLORS[5] = {float3(1, 0.3, 0.3), float3(0.3, 1, 0.3), float3(0.3, 0.5, 1), float3(1, 1, 0.3), float3(0.4, 0.4, 0.4)};

// forward_color is a surface's shaded color: its emission, its lights' light and its indirect light, fogged and
// pre-exposed, or a debug view's color as it is, without the exposure or the fog. The fog dims the color, and adds the
// light that it scatters toward the camera times scatter: an additive surface adds none, since the fog's light is
// already in front of what it adds to.
float3 forward_color(Varyings i, Material_Inputs inputs, Surface s, float scatter) {
	// The debug views (see docs/rendering/post-processing.md#debug-views). A dynamic branch on the frame's constant, so they need no
	// permutations.
	uint debug_view = frame.debug_view;
	if (debug_view == DEBUG_ALBEDO) {
#if SHADING_HAS_BASE_COLOR
		return s.base_color;
#else
		return shade_emission(s);
#endif
	}
	if (debug_view == DEBUG_EMISSION) {
		return shade_emission(s) * frame_exposure();
	}
	// Lit in grey where the light comes from a cluster, so the light count shows over the shapes.
	float lambert = 0.5 + 0.5 * saturate(dot(inputs.normal, normalize(float3(0.3, 1, 0.5))));
	if (debug_view == DEBUG_LIGHT_COMPLEXITY) {
		return heat(light_count(i.world, i.position) / 16.0) * lambert;
	}
	if (debug_view == DEBUG_SHADOW_CASCADES) {
		return CASCADE_COLORS[cascade_at(frame.near / max(i.position.z, 1e-7))] * lambert;
	}
	// Vertex pulling draws no meshlets, so its surfaces are all one color, at level 0.
	if (debug_view == DEBUG_MESHLETS) {
		return hash_color(i.cluster & ((1u << MESHLET_DEPTH_SHIFT) - 1)) * lambert;
	}
	if (debug_view == DEBUG_LOD_DEPTH) {
		return heat((i.cluster >> MESHLET_DEPTH_SHIFT) / 8.0) * lambert;
	}
#if SHADING_HAS_BASE_COLOR
	if (debug_view == DEBUG_LIGHTING_ONLY) {
		s.base_color = 0.5;
	}
#endif
	bool direct_only = debug_view == DEBUG_DIRECT_LIGHT;
	bool indirect_only = debug_view == DEBUG_INDIRECT_LIGHT;
	bool fog_only = debug_view == DEBUG_FOG;
	float3 color = debug_view == DEBUG_LIT ? shade_emission(s) : 0;
#if !SHADING_NO_LIGHTING
	Shading_Point p;
	p.position = i.world;
	p.view = inputs.view;
	p.normal = shading_normal(inputs, s);
	if (!indirect_only && !fog_only) {
		color += direct_light(s, p, inputs.normal, i.position);
	}
	// The global illumination's light, or without it the Environment's ambient light, which the ambient occlusion takes
	// away from. The occlusion is the opaque surfaces', from the prepass, so a transparent surface has none.
#if MATERIAL_TRANSPARENT
	float occlusion = 1;
#else
	float occlusion = saturate(load_screen(push.ambient_occlusion, i.position.xy).r);
#endif
	Indirect indirect;
	if (frame.gi != 0) {
		indirect.diffuse = cn_texture(push.gi_diffuse).Load(int3(i.position.xy, 0)).rgb;
		indirect.specular = cn_texture(push.gi_specular).Load(int3(i.position.xy, 0)).rgb;
	} else {
		indirect.diffuse = ambient_light(frame.ambient, p.normal);
		indirect.specular = ambient_light(frame.ambient, reflect(-p.view, p.normal));
	}
	indirect.diffuse *= occlusion;
	indirect.specular *= occlusion;
	if (!direct_only && !fog_only) {
		color += shade_indirect(s, p, indirect);
	}
#endif
	if (frame.fog != 0) {
		float4 fog = fog_at(i.world);
		color = color * fog.a + fog.rgb * scatter;
	}
	return color * frame_exposure();
}

#if !MATERIAL_TRANSPARENT
Targets ps_forward(Varyings i, bool front : SV_IsFrontFace) {
	Material_Inputs inputs = material_inputs(i, front);
	Surface s = evaluate(inputs);
#if MATERIAL_MASKED
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
#endif
	Targets o;
	o.color = float4(forward_color(i, inputs, s, 1), 1);
	o.id = i.id;
	return o;
}
#endif

#endif
