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

// debug_targets is a debug view's color as it is, without the exposure or the fog.
Targets debug_targets(float3 color, uint id) {
	Targets o;
	o.color = float4(color, 1);
	o.id = id;
	return o;
}

// The colors of the directional lights' cascades, and beyond the last.
static const float3 CASCADE_COLORS[5] = {float3(1, 0.3, 0.3), float3(0.3, 1, 0.3), float3(0.3, 0.5, 1), float3(1, 1, 0.3), float3(0.4, 0.4, 0.4)};

Targets ps_forward(Varyings i, bool front : SV_IsFrontFace) {
	Material_Inputs inputs = material_inputs(i, front);
	Surface s = evaluate(inputs);
#if MATERIAL_MASKED
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
#endif
	// The debug views (see docs/rendering.md#debug-views). A dynamic branch on the frame's constant, so they need no
	// permutations.
	uint debug_view = frame.debug_view;
	if (debug_view == DEBUG_ALBEDO) {
#if SHADING_HAS_BASE_COLOR
		return debug_targets(s.base_color, i.id);
#else
		return debug_targets(shade_emission(s), i.id);
#endif
	}
	// Lit in grey where the light comes from a cluster, so the light count shows over the shapes.
	float lambert = 0.5 + 0.5 * saturate(dot(inputs.normal, normalize(float3(0.3, 1, 0.5))));
	if (debug_view == DEBUG_LIGHT_COMPLEXITY) {
		return debug_targets(heat(light_count(i.world, i.position) / 16.0) * lambert, i.id);
	}
	if (debug_view == DEBUG_SHADOW_CASCADES) {
		return debug_targets(CASCADE_COLORS[cascade_at(frame.near / max(i.position.z, 1e-7))] * lambert, i.id);
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
	if (!direct_only && !fog_only) {
		color += shade_indirect(s, p, indirect);
	}
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
