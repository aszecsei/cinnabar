// SMAA's second pass (see docs/rendering/anti-aliasing.md#smaa): at each edge, the shape that it is part of, from searches
// along it for its ends and its crossing edges, and from the shape the area of the pixel on each side of the line that
// the edge stands for, through the area table. They are the weights with which the third pass blends each pixel with
// its neighbors.
#include "smaa.hlsli"

Varyings vs_main(uint vertex_id : SV_VertexID) {
	return smaa_vertex(vertex_id);
}

float4 ps_main(Varyings i) : SV_Target {
	float2 uv = smaa_uv(i);
	float2 pixel;
	float4 offset[3];
	SMAABlendingWeightCalculationVS(uv, pixel, offset);
	// SMAA 1x has one sample a pixel, so no subsample indices.
	return SMAABlendingWeightCalculationPS(uv, pixel, offset, cn_texture(push.edges), cn_texture(push.area), cn_texture(push.search), 0);
}
