// The output pass (see docs/rendering.md#output): it tone maps the scene, encodes it to sRGB, blends the UI and then the
// debug layer over it as sRGB-encoded values, and writes the frame target.
#include "cinnabar.hlsli"

// Matches Output_Push in lib/engine/render/renderer.odin.
struct Push {
	uint scene;
	uint ui;
	uint debug;
	uint has_ui;
	uint has_debug;
	float exposure;
};
CN_PUSH_CONSTANTS(Push, push);

struct Varyings {
	float4 position : SV_Position;
};

// Three vertices make one triangle that covers the screen.
Varyings vs_main(uint vertex_id : SV_VertexID) {
	float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
	Varyings o;
	o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
	return o;
}

// Khronos PBR Neutral: colors up to 0.76 stay as they are, so a material's base color shows true, and brighter ones
// compress toward white. The fixed tone mapper until the lookup table (docs/rendering.md#post-processing).
float3 pbr_neutral(float3 color) {
	const float start_compression = 0.8 - 0.04;
	const float desaturation = 0.15;
	float x = min(color.r, min(color.g, color.b));
	float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
	color -= offset;
	float peak = max(color.r, max(color.g, color.b));
	if (peak < start_compression) {
		return color;
	}
	const float d = 1 - start_compression;
	float new_peak = 1 - d * d / (peak + d - start_compression);
	color *= new_peak / peak;
	float g = 1 - 1 / (desaturation * (peak - new_peak) + 1);
	return lerp(color, new_peak.xxx, g);
}

float3 encode_srgb(float3 c) {
	c = saturate(c);
	return select(c <= 0.0031308, c * 12.92, 1.055 * pow(c, 1 / 2.4) - 0.055);
}

float3 decode_srgb(float3 c) {
	return select(c <= 0.04045, c / 12.92, pow((c + 0.055) / 1.055, 2.4));
}

float4 ps_main(Varyings i) : SV_Target {
	int3 pixel = int3(i.position.xy, 0);
	float3 hdr = cn_texture(push.scene).Load(pixel).rgb * push.exposure;
	float3 color = encode_srgb(pbr_neutral(max(hdr, 0)));
	// The UI is premultiplied and sRGB-encoded already, as designers' tools blend.
	if (push.has_ui != 0) {
		float4 ui = cn_texture(push.ui).Load(pixel);
		color = ui.rgb + color * (1 - ui.a);
	}
	// The debug layer's sRGB view gives premultiplied linear colors, which blend as encoded ones too.
	if (push.has_debug != 0) {
		float4 debug = cn_texture(push.debug).Load(pixel);
		if (debug.a > 0) {
			color = encode_srgb(debug.rgb / debug.a) * debug.a + color * (1 - debug.a);
		}
	}
	// The frame target's sRGB view encodes what it is given, so the encoded color goes back to linear.
	return float4(decode_srgb(color), 1);
}
