// The output pass (see docs/rendering.md#output): it adds bloom to the scene, tone maps it through the lookup table
// into sRGB-encoded colors, blends the UI and then the debug layer over it as sRGB-encoded values, and writes the frame
// target.
#include "tone_lut.hlsli"

// Matches Output_Push in lib/engine/render/renderer.odin.
struct Push {
	uint scene;
	uint ui;
	uint debug;
	uint has_ui;
	uint has_debug;
	uint bloom;
	uint has_bloom;
	uint lut;
	uint has_lut;
	uint sampler_index;
	float scene_scale;
	float bloom_scale;
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

float4 ps_main(Varyings i) : SV_Target {
	int3 pixel = int3(i.position.xy, 0);
	Texture2D<float4> scene = cn_texture(push.scene);
	SamplerState linear_clamp = cn_sampler(push.sampler_index);
	float3 hdr = max(scene.Load(pixel).rgb, 0) * push.scene_scale;
	if (push.has_bloom != 0) {
		float2 size;
		scene.GetDimensions(size.x, size.y);
		hdr += cn_texture(push.bloom).SampleLevel(linear_clamp, i.position.xy / size, 0).rgb * push.bloom_scale;
	}
	// Until the table is baked, a plain roll-off to white.
	float3 color = push.has_lut != 0 ? lut_sample(cn_texture(push.lut), linear_clamp, hdr) : encode_srgb(hdr / (1 + hdr));
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
