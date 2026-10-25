// The forward pass of every material (see docs/rendering.md#materials). It draws after the prepass with an Equal depth
// test, so each pixel shades once. The cooker includes it after the shading model, the Params struct and the
// material's evaluate, with these defined:
//   MATERIAL_TWO_SIDED, MATERIAL_MASKED and MATERIAL_CUTOFF: the material's settings.
//   SHADING_NO_LIGHTING: the shading model only emits.
//   SHADING_HAS_NORMAL: the shading model's Surface has a tangent-space normal, which the passes map to the world.
#ifndef MATERIAL_FORWARD_HLSLI
#define MATERIAL_FORWARD_HLSLI

#include "material_vertex.hlsli"
#include "material_lighting.hlsli"

// The scene's HDR colors, pre-exposed, and the entity IDs that the editor picks from.
struct Targets {
	float4 color : SV_Target0;
	uint id : SV_Target1;
};

Varyings vs_forward(uint vertex_id : SV_VertexID) {
	return vertex_varyings(load_vertex(vertex_id));
}

Targets ps_forward(Varyings i, bool front : SV_IsFrontFace) {
	Material_Inputs inputs = material_inputs(i, front);
	Surface s = evaluate(inputs);
#if MATERIAL_MASKED
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
#endif
	float3 color = shade_emission(s);
#if !SHADING_NO_LIGHTING
	Shading_Point p;
	p.position = i.world;
	p.view = inputs.view;
	p.normal = shading_normal(inputs, s);
	color += direct_light(s, p, inputs.normal, i.position);
	// The sky's light from above and the ground's from below, until global illumination.
	Indirect indirect;
	indirect.diffuse = lerp(frame.ground_color.rgb, frame.sky_color.rgb, p.normal.y * 0.5 + 0.5);
	float3 reflected = reflect(-p.view, p.normal);
	indirect.specular = lerp(frame.ground_color.rgb, frame.sky_color.rgb, reflected.y * 0.5 + 0.5);
	color += shade_indirect(s, p, indirect);
#endif
	Targets o;
	o.color = float4(color * frame_exposure(), 1);
	o.id = i.id;
	return o;
}

#endif
