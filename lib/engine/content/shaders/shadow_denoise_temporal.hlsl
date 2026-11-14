// The traced mask's temporal pass (see docs/rendering/lighting-and-shadows.md#the-traced-mask): each soft channel's
// visibility, one ray a frame toward a point on its light's shape, averages with its history, last frame's average where
// the surface was then, found by the velocity. The average holds up to MAX_FRAMES frames, and the history is clamped to
// the visibilities around the pixel, so a shadow that moves or a surface that the history did not see starts again.
// The history follows its light: history_channel says which of last frame's channels held each channel's light, or ~0
// when none did, and that channel starts again. A hard channel's visibility passes through.
#include "cinnabar.hlsli"

// Matches Denoise_Temporal_Constants in lib/engine/render/shadows.odin. raw is this frame's visibility, previous and
// previous_frames the history's average and its frames over MAX_FRAMES, current and current_frames this frame's.
struct Denoise_Temporal_Constants {
	uint4 history_channel;
	uint2 size;
	float2 inverse_size;
	uint raw;
	uint velocity;
	uint previous;
	uint previous_frames;
	uint current;
	uint current_frames;
	uint sampler_index;
	uint soft;
	uint valid;
	uint3 padding;
};
CN_PASS_CONSTANTS(Denoise_Temporal_Constants, constants);

// Matches MASK_HISTORY_FRAMES in lib/engine/render/shadows.odin.
static const float MAX_FRAMES = 16;
// The prepass clears the velocity to render.VELOCITY_NONE where it draws nothing; anything this large is that.
static const float VELOCITY_NONE = 1000;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	int2 last = int2(constants.size) - 1;
	Texture2D<float4> raw_texture = cn_texture(constants.raw);
	float4 raw = raw_texture.Load(int3(pixel, 0));
	// The visibilities around the pixel, two pixels apart, so that a penumbra's lit or shaded side, where few rays
	// differ, still holds the history's average.
	float4 low = raw;
	float4 high = raw;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float4 v = raw_texture.Load(int3(clamp(pixel + int2(x, y) * 2, 0, last), 0));
			low = min(low, v);
			high = max(high, v);
		}
	}

	float2 velocity = cn_texture(constants.velocity).Load(int3(pixel, 0)).rg;
	float2 previous_uv = (float2(pixel) + 0.5) * constants.inverse_size - velocity;
	bool reprojected = constants.valid != 0 && velocity.x < VELOCITY_NONE && all(previous_uv == saturate(previous_uv));
	float4 history = 0;
	float4 frames = 0;
	if (reprojected) {
		SamplerState s = cn_sampler(constants.sampler_index);
		history = cn_texture(constants.previous).SampleLevel(s, previous_uv, 0);
		frames = cn_texture(constants.previous_frames).Load(int3(min(int2(previous_uv * constants.size), last), 0)) * MAX_FRAMES;
	}

	float4 result = raw;
	float4 result_frames = 0;
	[unroll] for (uint c = 0; c < 4; c++) {
		if ((constants.soft & (1u << c)) == 0) {
			continue;
		}
		uint p = constants.history_channel[c];
		if (!reprojected || p >= 4) {
			result_frames[c] = 1;
			continue;
		}
		float n = min(round(frames[p]) + 1, MAX_FRAMES);
		result[c] = lerp(clamp(history[p], low[c], high[c]), raw[c], 1 / n);
		result_frames[c] = n;
	}
	cn_rw_texture(constants.current)[pixel] = result;
	cn_rw_texture(constants.current_frames)[pixel] = result_frames / MAX_FRAMES;
}
