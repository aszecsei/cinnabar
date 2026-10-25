// Bakes the tone mapping lookup table (see tone_lut.hlsli): each entry's scene color, color graded, then tone mapped to
// a display color and encoded to sRGB. It runs when the settings change.
#include "tone_lut.hlsli"

// Matches Lut_Push in lib/engine/render/post.odin. tone_mapper is a render.Tone_Mapper.
struct Push {
	uint output;
	uint tone_mapper;
	float contrast;
	float saturation;
	float3 tint;
	uint padding;
};
CN_PUSH_CONSTANTS(Push, push);

static const uint TONE_AGX = 0;
static const uint TONE_PBR_NEUTRAL = 1;
static const uint TONE_ACES = 2;

static const float3 LUMA = float3(0.2126, 0.7152, 0.0722);

// AgX, after Benjamin Wrensch's minimal fit of Troy Sobotka's curve: into AgX's working space, a log2 encoding over its
// range, the sigmoid's polynomial, and back out, which gives display-linear colors.
float3 agx(float3 color) {
	const float3x3 inset = float3x3(
		0.842479062253094, 0.0423282422610123, 0.0423756549057051,
		0.0784335999999992, 0.878468636469772, 0.0784336,
		0.0792237451477643, 0.0791661274605434, 0.879142973793104);
	const float3x3 outset = float3x3(
		1.19687900512017, -0.0528968517574562, -0.0529716355144438,
		-0.0980208811401368, 1.15190312990417, -0.0980434501171241,
		-0.0990297440797205, -0.0989611768448433, 1.15107367264116);
	const float min_stops = -12.47393;
	const float max_stops = 4.026069;
	float3 x = mul(color, inset);
	x = (clamp(log2(max(x, 1e-10)), min_stops, max_stops) - min_stops) / (max_stops - min_stops);
	float3 x2 = x * x;
	float3 x4 = x2 * x2;
	x = 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
	return pow(saturate(mul(x, outset)), 2.2);
}

// Khronos PBR Neutral: colors up to 0.76 stay as they are, so a material's base color shows true, and brighter ones
// compress toward white.
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

// Stephen Hill's fit of ACES's reference rendering and output transforms for sRGB displays.
float3 aces(float3 color) {
	const float3x3 input = float3x3(
		0.59719, 0.35458, 0.04823,
		0.07600, 0.90834, 0.01566,
		0.02840, 0.13383, 0.83777);
	const float3x3 output = float3x3(
		1.60475, -0.53108, -0.07367,
		-0.10208, 1.10813, -0.00605,
		-0.00327, -0.07276, 1.07602);
	float3 v = mul(input, color);
	float3 a = v * (v + 0.0245786) - 0.000090537;
	float3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
	return saturate(mul(output, a / b));
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (id.x >= LUT_SIZE * LUT_SIZE || id.y >= LUT_SIZE) {
		return;
	}
	float3 color = lut_color(float3(id.x % LUT_SIZE, id.y, id.x / LUT_SIZE) / (LUT_SIZE - 1));
	// The grading: the tint, the saturation around the luminance, and the contrast in stops around middle grey.
	color *= push.tint;
	color = max(lerp(dot(color, LUMA).xxx, color, push.saturation), 0);
	color = LUT_MIDDLE_GREY * pow(color / LUT_MIDDLE_GREY, push.contrast);
	float3 display;
	switch (push.tone_mapper) {
	case TONE_PBR_NEUTRAL:
		display = pbr_neutral(color);
		break;
	case TONE_ACES:
		display = aces(color);
		break;
	default:
		display = agx(color);
		break;
	}
	cn_rw_texture(push.output)[id.xy] = float4(encode_srgb(display), 1);
}
