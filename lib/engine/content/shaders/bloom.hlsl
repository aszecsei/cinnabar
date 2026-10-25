// Bloom's chain (see docs/rendering.md#post-processing): each level halves the one before with a 13-tap filter, then
// from the smallest level up, each level adds the level below it, blurred with a 3x3 tent. The output pass adds the
// largest level to the scene.
#include "cinnabar.hlsli"

// Matches Bloom_Push in lib/engine/render/post.odin. The source is read with a bilinear, clamped sampler; source_texel
// is a texel of it in UV. base is the downsampled level that an upsample adds to.
struct Push {
	uint source;
	uint base;
	uint output;
	uint sampler_index;
	float2 source_texel;
	uint2 size;
	uint mode;
	uint3 padding;
};
CN_PUSH_CONSTANTS(Push, push);

static const uint BLOOM_FIRST = 0;
static const uint BLOOM_DOWN = 1;
static const uint BLOOM_UP = 2;

float luma(float3 c) {
	return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// karis weighs a group of samples down by its brightness, so a single bright pixel does not flicker into a large
// blob as it moves between pixels.
float karis(float3 c) {
	return 1 / (1 + luma(c));
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	Texture2D<float4> source = cn_texture(push.source);
	SamplerState s = cn_sampler(push.sampler_index);
	float2 uv = (float2(id.xy) + 0.5) / float2(push.size);
	float2 t = push.source_texel;
	float3 color;
	if (push.mode == BLOOM_UP) {
		color = source.SampleLevel(s, uv + t * float2(-1, -1), 0).rgb;
		color += source.SampleLevel(s, uv + t * float2(0, -1), 0).rgb * 2;
		color += source.SampleLevel(s, uv + t * float2(1, -1), 0).rgb;
		color += source.SampleLevel(s, uv + t * float2(-1, 0), 0).rgb * 2;
		color += source.SampleLevel(s, uv, 0).rgb * 4;
		color += source.SampleLevel(s, uv + t * float2(1, 0), 0).rgb * 2;
		color += source.SampleLevel(s, uv + t * float2(-1, 1), 0).rgb;
		color += source.SampleLevel(s, uv + t * float2(0, 1), 0).rgb * 2;
		color += source.SampleLevel(s, uv + t * float2(1, 1), 0).rgb;
		color = color / 16 + cn_texture(push.base).Load(int3(id.xy, 0)).rgb;
	} else {
		// Jimenez's 13 taps: an inner box of four and an outer grid of nine, each a bilinear average of four texels.
		float3 a = source.SampleLevel(s, uv + t * float2(-2, -2), 0).rgb;
		float3 b = source.SampleLevel(s, uv + t * float2(0, -2), 0).rgb;
		float3 c = source.SampleLevel(s, uv + t * float2(2, -2), 0).rgb;
		float3 d = source.SampleLevel(s, uv + t * float2(-2, 0), 0).rgb;
		float3 e = source.SampleLevel(s, uv, 0).rgb;
		float3 f = source.SampleLevel(s, uv + t * float2(2, 0), 0).rgb;
		float3 g = source.SampleLevel(s, uv + t * float2(-2, 2), 0).rgb;
		float3 h = source.SampleLevel(s, uv + t * float2(0, 2), 0).rgb;
		float3 i = source.SampleLevel(s, uv + t * float2(2, 2), 0).rgb;
		float3 j = source.SampleLevel(s, uv + t * float2(-1, -1), 0).rgb;
		float3 k = source.SampleLevel(s, uv + t * float2(1, -1), 0).rgb;
		float3 l = source.SampleLevel(s, uv + t * float2(-1, 1), 0).rgb;
		float3 m = source.SampleLevel(s, uv + t * float2(1, 1), 0).rgb;
		// Five overlapping boxes: the inner one carries half the weight, the four corner ones an eighth each.
		float3 boxes[5] = {(j + k + l + m) * 0.25, (a + b + d + e) * 0.25, (b + c + e + f) * 0.25, (d + e + g + h) * 0.25, (e + f + h + i) * 0.25};
		float weights[5] = {0.5, 0.125, 0.125, 0.125, 0.125};
		color = 0;
		float total = 0;
		for (uint n = 0; n < 5; n++) {
			float w = push.mode == BLOOM_FIRST ? weights[n] * karis(boxes[n]) : weights[n];
			color += boxes[n] * w;
			total += w;
		}
		color = max(color / total, 0);
	}
	cn_rw_texture(push.output)[id.xy] = float4(color, 1);
}
