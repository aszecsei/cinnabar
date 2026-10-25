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

// fog_at is the integrated fog between the camera and a point, from the fog volume: the light that the fog scatters
// toward the camera in rgb, not pre-exposed, and the share of the point's light that reaches the camera in a. Like the
// clusters, the volume is the camera's screen tiles, so the point's place comes from the camera's projection, which
// the view model's pixels are not drawn with. A texel holds the fog up to its slice's far end.
float4 fog_at(float3 p) {
	float4 clip = mul(frame.cluster_view_projection, float4(p, 1));
	float depth = max(clip.w, 1e-7);
	float2 uv = (clip.xy / depth * float2(0.5, -0.5) + 0.5) * frame.fog_scale;
	float slice = (log2(depth) * frame.slice_scale + frame.slice_bias) * (FOG_SLICES / CLUSTER_SLICES);
	float3 coordinates = float3(uv, (slice - 0.5) / FOG_SLICES);
	return cn_texture3d(push.fog).SampleLevel(cn_sampler(frame.fog_sampler), coordinates, 0);
}

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
	// The global illumination's light, or without it the sky's light from above and the ground's from below, which the
	// ambient occlusion takes away from.
	float occlusion = saturate(cn_texture(push.ambient_occlusion).Load(int3(i.position.xy, 0)).r);
	Indirect indirect;
	if (frame.gi != 0) {
		indirect.diffuse = cn_texture(push.gi_diffuse).Load(int3(i.position.xy, 0)).rgb;
		indirect.specular = cn_texture(push.gi_specular).Load(int3(i.position.xy, 0)).rgb;
	} else {
		indirect.diffuse = lerp(frame.ground_color.rgb, frame.sky_color.rgb, p.normal.y * 0.5 + 0.5);
		float3 reflected = reflect(-p.view, p.normal);
		indirect.specular = lerp(frame.ground_color.rgb, frame.sky_color.rgb, reflected.y * 0.5 + 0.5);
	}
	indirect.diffuse *= occlusion;
	indirect.specular *= occlusion;
	color += shade_indirect(s, p, indirect);
#endif
	if (frame.fog != 0) {
		float4 fog = fog_at(i.world);
		color = color * fog.a + fog.rgb;
	}
	Targets o;
	o.color = float4(color * frame_exposure(), 1);
	o.id = i.id;
	return o;
}

#endif
