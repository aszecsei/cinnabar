// Filters that the post passes share: temporal AA reads its history with Catmull-Rom, and bloom its smallest levels.
#ifndef FILTER_HLSLI
#define FILTER_HLSLI

// sample_catmull_rom filters a texture of a size with a Catmull-Rom spline in five bilinear taps through a bilinear,
// clamped sampler, leaving out the four corners, whose weights are small. It is sharper than a bilinear sample, and
// smooth where a bilinear sample of a texture magnified many times shows its texels. The spline's negative lobes can
// ring below 0 beside a bright texel, so the result is clamped there.
float3 sample_catmull_rom(Texture2D<float4> t, SamplerState s, float2 uv, float2 size, float2 inverse_size) {
	float2 position = uv * size;
	float2 center = floor(position - 0.5) + 0.5;
	float2 f = position - center;
	float2 f2 = f * f;
	float2 f3 = f2 * f;
	float2 w0 = -0.5 * f3 + f2 - 0.5 * f;
	float2 w1 = 1.5 * f3 - 2.5 * f2 + 1;
	float2 w2 = -1.5 * f3 + 2 * f2 + 0.5 * f;
	float2 w3 = 0.5 * f3 - 0.5 * f2;
	float2 w12 = w1 + w2;
	float2 middle = (center + w2 / w12) * inverse_size;
	float2 before = (center - 1) * inverse_size;
	float2 after = (center + 2) * inverse_size;
	float4 sum = 0;
	sum += float4(t.SampleLevel(s, float2(middle.x, before.y), 0).rgb, 1) * (w12.x * w0.y);
	sum += float4(t.SampleLevel(s, float2(before.x, middle.y), 0).rgb, 1) * (w0.x * w12.y);
	sum += float4(t.SampleLevel(s, middle, 0).rgb, 1) * (w12.x * w12.y);
	sum += float4(t.SampleLevel(s, float2(after.x, middle.y), 0).rgb, 1) * (w3.x * w12.y);
	sum += float4(t.SampleLevel(s, float2(middle.x, after.y), 0).rgb, 1) * (w12.x * w3.y);
	return max(sum.rgb / sum.a, 0);
}

#endif
