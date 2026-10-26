// The output pass (see docs/rendering/layers-and-output.md#output): it adds bloom to the scene, tone maps it through the lookup table
// into sRGB-encoded colors, blends the UI and then the debug layer over it as sRGB-encoded values, and writes the frame
// target, encoded for its output mode (see docs/rendering/layers-and-output.md#hdr-output). In HDR, the colors are relative to paper
// white, so the UI's white is paper white, and the scene's go above 1. After FXAA or SMAA, the scene is tone mapped
// already, and the pass blends and encodes it.
#include "output.hlsli"

struct Varyings {
	float4 position : SV_Position;
};

// Three vertices make one triangle that covers the screen.
// Match gpu.Output_Mode.
static const uint OUTPUT_HDR10 = 1;
static const uint OUTPUT_SCRGB = 2;
// scRGB's 1 is this many nits.
static const float SCRGB_NITS = 80;

Varyings vs_main(uint vertex_id : SV_VertexID) {
	float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
	Varyings o;
	o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
	return o;
}

float4 ps_main(Varyings i) : SV_Target {
	int3 pixel = int3(i.position.xy, 0);
	float2 uv = i.position.xy / float2(push.size);
	SamplerState linear_clamp = cn_sampler(push.sampler_index);
	float3 color = push.tone_mapped != 0 ? cn_texture(push.scene).SampleLevel(linear_clamp, uv, 0).rgb : tone_map(uv);
	// The UI is premultiplied and sRGB-encoded already, as designers' tools blend.
	if (push.has_ui != 0) {
		float4 ui = cn_texture(push.ui).Load(pixel);
		color = ui.rgb + color * (1 - ui.a);
	}
	// The debug layer's sRGB view gives premultiplied linear colors, which blend as encoded ones too. It has the scene's
	// size, which filters as it stretches, since its colors are premultiplied.
	if (push.has_debug != 0) {
		float4 debug = cn_texture(push.debug).SampleLevel(linear_clamp, uv, 0);
		if (debug.a > 0) {
			color = encode_srgb(debug.rgb / debug.a) * debug.a + color * (1 - debug.a);
		}
	}
	float3 linear_color = decode_srgb(color);
	if (push.mode == OUTPUT_HDR10) {
		return float4(encode_pq(mul(REC709_TO_REC2020, linear_color) * push.paper_white), 1);
	}
	if (push.mode == OUTPUT_SCRGB) {
		return float4(linear_color * (push.paper_white / SCRGB_NITS), 1);
	}
	// The frame target's sRGB view encodes what it is given, so the encoded color goes back to linear.
	return float4(linear_color, 1);
}
