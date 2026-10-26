#include "cinnabar.hlsli"

// Matches UI_Constants in game.odin: a panel's rectangle in pixels, its corner radius, and its colors as a designer
// picks them, sRGB-encoded.
struct Push {
	float2 origin;
	float2 size;
	float4 color;
	float4 accent;
	float radius;
	float accent_width;
};
CN_PUSH_CONSTANTS(Push, push);

struct Varyings {
	float4 position : SV_Position;
};

// Three vertices make one triangle that covers the screen, and the pixel shader keeps the panel's pixels.
Varyings vs_main(uint vertex_id : SV_VertexID) {
	float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
	Varyings o;
	o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
	return o;
}

// A HUD panel with rounded corners and an accent stripe on its left, into the UI layer, which is premultiplied and
// sRGB-encoded, so it blends as the designer's tools do (see docs/rendering/layers-and-output.md#ui).
float4 ps_main(Varyings i) : SV_Target {
	float2 p = i.position.xy - push.origin;
	float2 half_size = push.size * 0.5;
	float2 q = abs(p - half_size) - (half_size - push.radius);
	float distance = length(max(q, 0)) + min(max(q.x, q.y), 0) - push.radius;
	float coverage = saturate(0.5 - distance);
	if (coverage <= 0) {
		discard;
	}
	float4 color = p.x < push.accent_width ? push.accent : push.color;
	color.a *= coverage;
	return float4(color.rgb * color.a, color.a);
}
