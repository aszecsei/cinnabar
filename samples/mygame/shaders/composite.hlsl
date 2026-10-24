#include "cinnabar.hlsli"

// Matches Composite_Constants in game.odin.
struct Push {
	uint input;
	uint sampler_index;
};
CN_PUSH_CONSTANTS(Push, push);

struct Varyings {
	float4 position : SV_Position;
	float2 uv : TEXCOORD0;
};

// Three vertices make one triangle that covers the screen.
Varyings vs_main(uint vertex_id : SV_VertexID) {
	float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
	Varyings o;
	o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
	o.uv = uv;
	return o;
}

// Reinhard tone mapping. The frame target's sRGB view encodes the result.
float4 ps_main(Varyings i) : SV_Target {
	float3 hdr = cn_texture(push.input).Sample(cn_sampler(push.sampler_index), i.uv).rgb;
	return float4(hdr / (1.0 + hdr), 1);
}
