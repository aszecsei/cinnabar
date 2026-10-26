// The auto exposure's luminance histogram (see docs/rendering/post-processing.md#post-processing): each pixel's luminance, without this
// frame's pre-exposure, counts into one of 256 bins of log2 luminance. Pixels where nothing drew hold the clear color,
// which is not pre-exposed, so they do not count: the exposure would chase its own scale. Each thread group counts in
// shared memory, then adds its counts to the histogram, which exposure_adapt.hlsl reads and clears.
#include "cinnabar.hlsli"

// Matches Histogram_Push in lib/engine/render/post.odin. Bin 0 holds black pixels, and bins 1 to 255 cover log2
// luminance from min_log over 1 / inverse_range stops.
struct Push {
	uint scene;
	uint depth;
	uint exposure;
	uint histogram;
	uint2 size;
	float min_log;
	float inverse_range;
	// The depth's pixels for each of the scene's, less than 1 after temporal AA upscales the scene.
	float2 depth_scale;
};
CN_PUSH_CONSTANTS(Push, push);

static const uint BINS = 256;

groupshared uint bins[BINS];

[numthreads(16, 16, 1)]
void cs_main(uint3 id : SV_DispatchThreadID, uint index : SV_GroupIndex) {
	bins[index] = 0;
	GroupMemoryBarrierWithGroupSync();
	if (all(id.xy < push.size) && cn_texture(push.depth).Load(int3(id.xy * push.depth_scale, 0)).r > 0) {
		float exposure = cn_buffer(push.exposure).Load<float>(0);
		float3 color = cn_texture(push.scene).Load(int3(id.xy, 0)).rgb / exposure;
		float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
		uint bin = 0;
		if (luminance > 1e-6) {
			bin = 1 + uint(saturate((log2(luminance) - push.min_log) * push.inverse_range) * (BINS - 2));
		}
		InterlockedAdd(bins[bin], 1);
	}
	GroupMemoryBarrierWithGroupSync();
	if (bins[index] != 0) {
		cn_rw_buffer(push.histogram).InterlockedAdd(index * 4, bins[index]);
	}
}
