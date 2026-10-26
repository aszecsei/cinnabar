// The prepass of every material (see docs/rendering/lighting-and-shadows.md#prepass): depth, the surface's normal and the velocity. The
// pixel shader evaluates only what the normal and the opacity mask need; DXC drops the rest of evaluate.
#ifndef MATERIAL_PREPASS_HLSLI
#define MATERIAL_PREPASS_HLSLI

#include "material_vertex.hlsli"

struct Prepass_Varyings {
	Varyings v;
	float4 current : CLIP0;
	float4 previous : CLIP1;
};

// The normal in the world, folded into the octahedron, and the velocity: how far the surface moved on the screen since
// last frame, in UV, without the camera's jitter. The pass clears it to render.VELOCITY_NONE where it draws nothing.
struct Prepass_Targets {
	float2 normal : SV_Target0;
	float2 velocity : SV_Target1;
};

Prepass_Varyings vs_prepass(uint vertex_id : SV_VertexID) {
	Material_Vertex v = load_vertex(vertex_id);
	Prepass_Varyings o;
	o.v = vertex_varyings(v);
	o.current = o.v.position;
	o.previous = mul(frame.previous_view_projection, float4(v.previous, 1));
	return o;
}

Prepass_Targets ps_prepass(Prepass_Varyings i, bool front : SV_IsFrontFace) {
	Material_Inputs inputs = material_inputs(i.v, front);
	Surface s = evaluate(inputs);
#if MATERIAL_MASKED
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
#endif
	Prepass_Targets o;
	o.normal = octahedral_encode(shading_normal(inputs, s));
	float2 current = i.current.xy / i.current.w - frame.jitter;
	float2 previous = i.previous.xy / i.previous.w;
	o.velocity = (current - previous) * float2(0.5, -0.5);
	return o;
}

#endif
