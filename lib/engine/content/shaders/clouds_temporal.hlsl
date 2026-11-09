// The clouds' temporal accumulation (see docs/rendering/clouds.md#temporal): a thread for each texel of the cloud
// buffer. It finds where this frame's clouds were last frame, through the march's mean distance and last frame's
// projection, reads the history there, clamps it to the 3x3 neighborhood of this frame's march, and blends this frame's
// share in. Without a history, off the screen or behind the camera, the texel is this frame's march alone.
#include "clouds_common.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= clouds.size)) {
		return;
	}
	Texture2D<float4> current = cn_texture(push.current);
	RWTexture2D<float4> output = cn_rw_texture(push.output);
	int2 texel = int2(id.xy);
	float4 now = current.Load(int3(texel, 0));
	float4 result = now;
	if (push.valid != 0) {
		float3 d = cloud_direction(id.xy);
		float mean = cn_texture(push.distance).Load(int3(texel, 0)).r;
		float4 clip = mul(clouds.previous, float4(d * mean, 1));
		if (clip.w > 0) {
			float2 uv = clip.xy / clip.w * float2(0.5, -0.5) + 0.5;
			if (all(uv == saturate(uv))) {
				int2 last = int2(clouds.size) - 1;
				float4 low = now;
				float4 high = now;
				[unroll] for (int y = -1; y <= 1; y++) {
					[unroll] for (int x = -1; x <= 1; x++) {
						float4 v = current.Load(int3(clamp(texel + int2(x, y), 0, last), 0));
						low = min(low, v);
						high = max(high, v);
					}
				}
				float4 history = cn_texture(push.history).SampleLevel(cn_sampler(clouds.clamp_sampler), uv, 0);
				history = clamp(history, low, high);
				result = lerp(history, now, clouds.history_blend);
			}
		}
	}
	output[id.xy] = max(result, 0);
}
