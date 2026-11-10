// The sprite renderers' draw (see docs/rendering/2d.md#drawing): a quad for each Sprite_Renderer that faces the camera,
// with a frame of its sheet's texture, in the order that the CPU sorted them, blended over the scene. A lit sprite takes
// every directional light and its cluster's punctual lights with their shadow maps, from whichever side they are, and
// the ambient light; an unlit one shows its colors as they are. Both take the fog and the exposure.
// sheet_sprite_ids.hlsl writes their entity IDs.
#include "sheet_sprite.hlsli"

Varyings vs_main(uint vertex_id : SV_VertexID) {
	return sheet_sprite_vertex(vertex_id);
}

float4 ps_main(Varyings i) : SV_Target0 {
	return sheet_sprite_color(i);
}
