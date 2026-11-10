// The sprite renderers' entity IDs and depth (see docs/rendering/2d.md#drawing): the quads of sheet_sprite.hlsl again,
// where a sprite is not clear, for the editor's picks and its outline.
#include "sheet_sprite.hlsli"

Varyings vs_main(uint vertex_id : SV_VertexID) {
	return sheet_sprite_vertex(vertex_id);
}

uint ps_main(Varyings i) : SV_Target0 {
	return sheet_sprite_id(i);
}
