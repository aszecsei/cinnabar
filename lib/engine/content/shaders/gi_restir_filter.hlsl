// ReSTIR GI's filter (see docs/rendering/global-illumination.md#restir-gi): one a-trous step of the diffuse light, a
// 5x5 B3 spline kernel whose taps are step pixels apart, which stops at edges by the taps' view depth, which the
// diffuse light keeps in its alpha, their normals and their luminance. Each step doubles the last's, so a few steps
// reach far at the cost of a few taps. The history keeps the light before the filter, so the filter's blur does not
// build up from frame to frame.
#include "gi_restir.hlsli"

static const float KERNEL[3] = {3.0 / 8.0, 1.0 / 4.0, 1.0 / 16.0};
// A tap counts while its depth is within about this share of the pixel's.
static const float FILTER_DEPTH = 0.02;
static const float FILTER_NORMAL_POWER = 32;
// A tap whose luminance differs from the pixel's by about this share of the brighter counts half as much.
static const float FILTER_LUMINANCE = 0.75;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	Texture2D<float4> input = cn_texture(push.filter_in);
	RWTexture2D<float4> output = cn_rw_texture(push.filter_out);
	float4 center = input.Load(int3(pixel, 0));
	// The view model's pixels and the sky have no depth, and keep their light.
	if (center.a <= 0) {
		output[pixel] = center;
		return;
	}
	float3 normal = octahedral_normal(pixel);
	float luminance = restir_luminance(center.rgb);
	float3 sum = 0;
	float total = 0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			int2 q = pixel + int2(x, y) * int(push.step);
			if (any(q < 0) || any(q >= int2(constants.size))) {
				continue;
			}
			float4 tap = input.Load(int3(q, 0));
			if (tap.a <= 0) {
				continue;
			}
			float w = KERNEL[abs(x)] * KERNEL[abs(y)];
			w *= exp(-abs(tap.a - center.a) / (FILTER_DEPTH * center.a * float(push.step)));
			w *= pow(saturate(dot(octahedral_normal(q), normal)), FILTER_NORMAL_POWER);
			float lq = restir_luminance(tap.rgb);
			w *= exp(-abs(lq - luminance) / (FILTER_LUMINANCE * max(max(lq, luminance), 1e-4)));
			sum += tap.rgb * w;
			total += w;
		}
	}
	output[pixel] = float4(total > 0 ? sum / total : center.rgb, center.a);
}
