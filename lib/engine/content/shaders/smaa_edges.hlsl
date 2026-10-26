// SMAA's first pass (see docs/rendering/anti-aliasing.md#smaa): the edges from the tone-mapped scene's luma, to the
// left in r and above in g, where they differ by more than the threshold and stand out from the local contrast.
#include "smaa.hlsli"

Varyings vs_main(uint vertex_id : SV_VertexID) {
	return smaa_vertex(vertex_id);
}

float2 ps_main(Varyings i) : SV_Target {
	float2 uv = smaa_uv(i);
	float4 offset[3];
	SMAAEdgeDetectionVS(uv, offset);
	return SMAALumaEdgeDetectionPS(uv, offset, cn_texture(push.color));
}
