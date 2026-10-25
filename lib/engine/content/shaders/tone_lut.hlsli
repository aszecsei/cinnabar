// The tone mapping lookup table (see docs/rendering.md#post-processing): LUT_SIZE^3 entries over a range of stops
// around middle grey, its blue slices side by side in one 2D texture. Each entry holds the display color of a
// pre-exposed scene color: sRGB-encoded for SDR output, and for HDR output its nits with Rec. 709 primaries, encoded
// with the PQ curve. tone_lut.hlsl bakes it, and the output pass reads it.
#ifndef TONE_LUT_HLSLI
#define TONE_LUT_HLSLI

#include "cinnabar.hlsli"

// Match LUT_SIZE in lib/engine/render/post.odin. The entries reach from LUT_MIN_STOPS to LUT_MAX_STOPS around middle
// grey; AgX's black is at -12.47 stops, and every tone mapper is white well before the top.
static const uint LUT_SIZE = 32;
static const float LUT_MIDDLE_GREY = 0.18;
static const float LUT_MIN_STOPS = -12.47393;
static const float LUT_MAX_STOPS = 8.0;

// lut_color is the scene color of an entry's coordinates, each in [0, 1].
float3 lut_color(float3 coordinates) {
	return LUT_MIDDLE_GREY * exp2(lerp(LUT_MIN_STOPS, LUT_MAX_STOPS, coordinates));
}

// lut_coordinates are the coordinates of a scene color, the inverse of lut_color, clamped to the table.
float3 lut_coordinates(float3 color) {
	float3 stops = log2(max(color, 1e-10) / LUT_MIDDLE_GREY);
	return saturate((stops - LUT_MIN_STOPS) / (LUT_MAX_STOPS - LUT_MIN_STOPS));
}

// lut_sample looks a scene color up: bilinear within the two nearest blue slices, then between them.
float3 lut_sample(Texture2D<float4> lut, SamplerState s, float3 color) {
	float3 texel = lut_coordinates(color) * (LUT_SIZE - 1);
	float slice = floor(texel.b);
	float between = texel.b - slice;
	float2 size = float2(LUT_SIZE * LUT_SIZE, LUT_SIZE);
	float2 uv = float2(slice * LUT_SIZE + texel.r + 0.5, texel.g + 0.5) / size;
	float2 next = float2(min(slice + 1, LUT_SIZE - 1) * LUT_SIZE + texel.r + 0.5, texel.g + 0.5) / size;
	return lerp(lut.SampleLevel(s, uv, 0).rgb, lut.SampleLevel(s, next, 0).rgb, between);
}

float3 encode_srgb(float3 c) {
	c = saturate(c);
	return select(c <= 0.0031308, c * 12.92, 1.055 * pow(c, 1 / 2.4) - 0.055);
}

// encode_srgb_extended encodes HDR colors too: above 1, the curve goes on as it does below.
float3 encode_srgb_extended(float3 c) {
	c = max(c, 0);
	return select(c <= 0.0031308, c * 12.92, 1.055 * pow(c, 1 / 2.4) - 0.055);
}

float3 decode_srgb(float3 c) {
	return select(c <= 0.04045, c / 12.92, pow((c + 0.055) / 1.055, 2.4));
}

// The PQ curve of SMPTE ST 2084, which HDR10 encodes with: 1 is PQ_MAX_NITS.
static const float PQ_MAX_NITS = 10000;
static const float PQ_M1 = 0.1593017578125;
static const float PQ_M2 = 78.84375;
static const float PQ_C1 = 0.8359375;
static const float PQ_C2 = 18.8515625;
static const float PQ_C3 = 18.6875;

float3 encode_pq(float3 nits) {
	float3 p = pow(saturate(nits / PQ_MAX_NITS), PQ_M1);
	return pow((PQ_C1 + PQ_C2 * p) / (1 + PQ_C3 * p), PQ_M2);
}

float3 decode_pq(float3 c) {
	float3 p = pow(saturate(c), 1 / PQ_M2);
	return pow(max(p - PQ_C1, 0) / (PQ_C2 - PQ_C3 * p), 1 / PQ_M1) * PQ_MAX_NITS;
}

// Linear colors with Rec. 709 primaries to Rec. 2020's.
static const float3x3 REC709_TO_REC2020 = float3x3(
	0.6274040, 0.3292820, 0.0433136,
	0.0690970, 0.9195400, 0.0113612,
	0.0163916, 0.0880132, 0.8955950);

#endif
