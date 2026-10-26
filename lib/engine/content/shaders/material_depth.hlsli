// The depth pass of every material (see docs/rendering/lighting-and-shadows.md#shadows), which the shadow maps draw. An opaque material
// has no pixel shader. A masked one evaluates its opacity and discards below the cutoff.
#ifndef MATERIAL_DEPTH_HLSLI
#define MATERIAL_DEPTH_HLSLI

#include "material_vertex.hlsli"

#if MATERIAL_MASKED
Varyings vs_depth(uint vertex_id : SV_VertexID) {
	return vertex_varyings(load_vertex(vertex_id));
}

void ps_depth(Varyings i, bool front : SV_IsFrontFace) {
	Surface s = evaluate(material_inputs(i, front));
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
}
#else
float4 vs_depth(uint vertex_id : SV_VertexID) : SV_Position {
	return clip_position(load_vertex(vertex_id).world);
}
#endif

#endif
