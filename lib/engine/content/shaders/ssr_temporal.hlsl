// The screen-space reflections' temporal accumulation (see
// docs/rendering/lighting-and-shadows.md#screen-space-reflections): each pixel blends its resolved reflection into last
// frame's. The history is where the reflected point was: a mirror shows it at its distance behind the surface, along
// the view ray, so the pass reprojects that point and not the surface, and a reflection does not smear as the camera
// moves. A pixel whose rays found nothing reprojects its surface, by its velocity. The history is rescaled by the change
// of the exposure, clamped to the 3x3 neighborhood's mean and standard deviation, and blended with a weight of
// 1 / frames: frames grows from min_frames on a mirror, whose reflection changes with every move, to max_frames at the
// cutoff, whose noise needs the most averaging. The result is Frame.reflections.
#include "ssr_common.hlsli"

// The neighborhood's box, in standard deviations.
static const float CLIP_SIGMAS = 1.25;
// The velocity's value where the prepass drew nothing (see VELOCITY_NONE in post.odin).
static const float VELOCITY_NONE = 1000;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	RWTexture2D<float4> output = cn_rw_texture(constants.output);
	float3 position;
	if (!surface_at(pixel, position)) {
		output[id.xy] = 0;
		return;
	}
	Texture2D<float4> resolved = cn_texture(constants.resolved);
	int2 last = int2(constants.size) - 1;
	float4 current = resolved.Load(int3(pixel, 0));
	float4 mean = 0;
	float4 square = 0;
	[unroll] for (int y = -1; y <= 1; y++) {
		[unroll] for (int x = -1; x <= 1; x++) {
			float4 v = resolved.Load(int3(clamp(pixel + int2(x, y), 0, last), 0));
			mean += v;
			square += v * v;
		}
	}
	mean /= 9;
	float4 sigma = sqrt(max(square / 9 - mean * mean, 0));
	float4 result = current;
	if (constants.history_valid != 0) {
		float2 uv = (float2(pixel) + 0.5) / float2(constants.size);
		float hit_distance = cn_texture(constants.distance).Load(int3(pixel, 0)).r;
		float2 previous = -1;
		if (hit_distance > 0) {
			float3 reflected = position + normalize(position) * hit_distance;
			float4 clip = mul(constants.previous, float4(reflected, 1));
			if (clip.w > 0) {
				previous = clip.xy / clip.w * float2(0.5, -0.5) + 0.5;
			}
		} else {
			float2 velocity = cn_texture(constants.velocity).Load(int3(pixel, 0)).rg;
			if (velocity.x < VELOCITY_NONE) {
				previous = uv - velocity;
			}
		}
		if (all(previous == saturate(previous))) {
			float2 exposure = cn_buffer(constants.exposure).Load<float2>(0);
			float4 history = cn_texture(constants.history).SampleLevel(cn_sampler(constants.sampler_index), previous, 0);
			history.rgb *= exposure.x / max(exposure.y, 1e-10);
			history = clamp(history, mean - CLIP_SIGMAS * sigma, mean + CLIP_SIGMAS * sigma);
			float roughness = roughness_at(pixel);
			float frames = lerp(constants.min_frames, constants.max_frames, saturate(roughness / max(constants.cutoff, 1e-3)));
			result = lerp(history, current, 1 / frames);
		}
	}
	output[id.xy] = max(result, 0);
}
