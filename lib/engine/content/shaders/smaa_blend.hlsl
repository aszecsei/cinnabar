// SMAA's third pass (see docs/rendering/anti-aliasing.md#smaa): each pixel blends with its neighbors by its and their
// weights from the second pass, with one bilinear sample of the tone-mapped scene.
#include "smaa.hlsli"

Varyings vs_main(uint vertex_id : SV_VertexID) {
	return smaa_vertex(vertex_id);
}

float4 ps_main(Varyings i) : SV_Target {
	float2 uv = smaa_uv(i);
	float4 offset;
	SMAANeighborhoodBlendingVS(uv, offset);
	return SMAANeighborhoodBlendingPS(uv, offset, cn_texture(push.color), cn_texture(push.weights));
}
