// The exposure (see docs/rendering/post-processing.md#post-processing): from the luminance histogram, the mean log2 luminance between
// its 10th and 90th percentiles, clamped to the settings' range, gives the exposure that maps it to middle grey. The
// exposure moves toward it, and pre-exposes the next frame. With a manual exposure, it takes that at once. An empty
// histogram holds the exposure where it is, and an exposure that is not finite and positive goes to the target at once.
#include "cinnabar.hlsli"

// Matches Exposure_Push in lib/engine/render/post.odin. The histogram's bins 1 to 255 cover log2 luminance from min_log
// over range stops. The exposure buffer holds two floats: the exposure that pre-exposed this frame, then the last
// frame's. adapt is the share of the way to the target to go this frame; reset goes all the way.
struct Push {
	uint histogram;
	uint exposure;
	uint manual;
	uint reset;
	float min_log;
	float range;
	float low_log;
	float high_log;
	float compensation;
	float scale;
	float adapt;
	uint padding;
};
CN_PUSH_CONSTANTS(Push, push);

static const uint BINS = 256;
static const float MIDDLE_GREY = 0.18;
static const float LOW_PERCENTILE = 0.1;
static const float HIGH_PERCENTILE = 0.9;
// The exposure stays in this range, far beyond any that shows a picture, so it is never infinite or zero, from which
// the adaptation, in log2, could not come back.
static const float MIN_EXPOSURE = exp2(-64.0);
static const float MAX_EXPOSURE = exp2(64.0);

groupshared uint bins[BINS];

// bin_log is the log2 luminance at a bin's middle. Black pixels count as the darkest.
float bin_log(uint bin) {
	return bin == 0 ? push.min_log : push.min_log + (bin - 0.5) / (BINS - 2) * push.range;
}

[numthreads(256, 1, 1)]
void cs_main(uint index : SV_GroupIndex) {
	if (push.manual == 0) {
		RWByteAddressBuffer histogram = cn_rw_buffer(push.histogram);
		bins[index] = histogram.Load(index * 4);
		histogram.Store(index * 4, 0);
	}
	GroupMemoryBarrierWithGroupSync();
	if (index != 0) {
		return;
	}
	RWByteAddressBuffer buffer = cn_rw_buffer(push.exposure);
	float current = asfloat(buffer.Load(0));
	bool valid = isfinite(current) && current > 0;
	if (!valid) {
		current = 1;
	}
	float target = push.scale * exp2(push.compensation);
	if (push.manual == 0) {
		float total = 0;
		for (uint i = 0; i < BINS; i++) {
			total += bins[i];
		}
		float low = total * LOW_PERCENTILE;
		float high = total * HIGH_PERCENTILE;
		float seen = 0;
		float sum = 0;
		float weight = 0;
		for (uint b = 0; b < BINS; b++) {
			float count = bins[b];
			float taken = clamp(seen + count, low, high) - clamp(seen, low, high);
			sum += taken * bin_log(b);
			weight += taken;
			seen += count;
		}
		// With no pixels to count, as while the sky compiles in an empty world, the exposure stays: it holds the
		// compensation already, so applying it again would compound it each frame.
		target = weight > 0
			? MIDDLE_GREY / exp2(clamp(sum / weight, push.low_log, push.high_log)) * exp2(push.compensation)
			: current;
	}
	bool at_once = push.reset != 0 || push.manual != 0 || !valid;
	float next = at_once ? target : exp2(lerp(log2(current), log2(target), push.adapt));
	next = clamp(next, MIN_EXPOSURE, MAX_EXPOSURE);
	buffer.Store2(0, asuint(float2(next, current)));
}
