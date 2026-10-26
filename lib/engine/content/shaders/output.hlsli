// What the output pass and the tone map pass share (see docs/rendering/layers-and-output.md#output): their constants,
// and the scene's tone mapping. The output pass tone maps the scene itself, unless FXAA or SMAA needs the tone-mapped
// scene first (see docs/rendering/anti-aliasing.md#anti-aliasing): then the tone map pass writes it, and the output
// pass only encodes it.
#ifndef OUTPUT_HLSLI
#define OUTPUT_HLSLI

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
	uint lut_hdr;
	uint mode;
	float paper_white;
	// The scene holds a debug view's colors as they are (see docs/rendering/post-processing.md#debug-views): no tone mapping.
	uint raw;
	// The output pass's scene is tone mapped already, as tone_map gives it.
	uint tone_mapped;
	// The tone map pass's target. size is the pass's target's size: a scene or a debug layer that is smaller, at a
	// render scale below 1, is stretched to it bilinearly.
	uint output;
	uint2 size;
};
CN_PUSH_CONSTANTS(Push, push);

// tone_map is the display color of the scene at a point in UV: with bloom added, through the lookup table into
// sRGB-encoded colors. In HDR, they are sRGB-encoded relative to paper white, so the scene's go above 1. At a pixel's
// center in a scene of the target's size, the bilinear sample is that pixel.
float3 tone_map(float2 uv) {
	SamplerState linear_clamp = cn_sampler(push.sampler_index);
	float3 hdr = max(cn_texture(push.scene).SampleLevel(linear_clamp, uv, 0).rgb, 0) * push.scene_scale;
	if (push.has_bloom != 0) {
		hdr += cn_texture(push.bloom).SampleLevel(linear_clamp, uv, 0).rgb * push.bloom_scale;
	}
	// Until the table is baked, a plain roll-off to white.
	float3 color = encode_srgb(hdr / (1 + hdr));
	if (push.raw != 0) {
		color = encode_srgb(saturate(hdr));
	} else if (push.has_lut != 0) {
		color = lut_sample(cn_texture(push.lut), linear_clamp, hdr);
		if (push.lut_hdr != 0) {
			color = encode_srgb_extended(decode_pq(color) / push.paper_white);
		}
	}
	return color;
}

#endif
