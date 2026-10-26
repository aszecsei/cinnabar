// Temporal anti-aliasing (see docs/rendering/post-processing.md#post-processing). The camera's jitter moves the scene's samples within
// each pixel from frame to frame, and this pass blends each pixel with its history: last frame's result where the
// surface was then, found by the velocity, and clipped to the colors around the pixel so that what the history saw and
// the pixel does not see fades out. Colors are blended after a reversible tone map, so one bright sample does not
// dominate. When the scene is smaller than the output (see docs/rendering/anti-aliasing.md#upscaling), the history is
// at the output's size, and each output pixel takes this frame's color from the scene's samples around it, weighted by
// how near their jittered positions are, and blends in as much of it as its nearest sample is near.
#include "cinnabar.hlsli"

// Matches Temporal_Constants in lib/engine/render/post.odin. reproject maps a pixel's clip position in this frame,
// without the jitter, to its clip position in the last frame for a point that did not move. exposure holds this
// frame's exposure and then last frame's, by which the history was pre-exposed.
struct Temporal_Constants {
	float4x4 reproject;
	float2 jitter;
	float2 inverse_size;
	uint2 size;
	uint scene;
	uint velocity;
	uint depth;
	uint history;
	uint output;
	uint exposure;
	uint sampler_index;
	uint valid;
	float blend;
	uint upscale;
	uint2 render_size;
	float2 inverse_render_size;
};
CN_PASS_CONSTANTS(Temporal_Constants, constants);

// The prepass clears the velocity to render.VELOCITY_NONE where it draws nothing; anything this large is that.
static const float VELOCITY_NONE = 1000;
// How many standard deviations of the neighborhood's colors the history may stray from their mean.
static const float CLIP_SIGMAS = 1.25;
// When upscaling, a sample's weight at a distance d in output pixels is exp(-SAMPLE_FALLOFF d^2), Karis's fit of a
// Blackman-Harris window. This frame's share is at least MIN_BLEND_SHARE of the blend, so the history does not linger
// where no sample lands near.
static const float SAMPLE_FALLOFF = 2.29;
static const float MIN_BLEND_SHARE = 0.2;

float3 to_ycocg(float3 c) {
	return float3(dot(c, float3(0.25, 0.5, 0.25)), dot(c, float3(0.5, 0, -0.5)), dot(c, float3(-0.25, 0.5, -0.25)));
}

float3 from_ycocg(float3 c) {
	return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// compress maps HDR colors into [0, 1) by their largest channel, which expand reverses.
float3 compress(float3 c) {
	return c / (1 + max(c.r, max(c.g, c.b)));
}

float3 expand(float3 c) {
	return c / max(1 - max(c.r, max(c.g, c.b)), 1e-4);
}

// sample_history filters the history with a Catmull-Rom spline in five bilinear taps, which keeps it sharp where a
// bilinear filter would blur it a little more every frame.
float3 sample_history(Texture2D<float4> history, SamplerState s, float2 uv) {
	float2 size = float2(constants.size);
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
	float2 middle = (center + w2 / w12) * constants.inverse_size;
	float2 before = (center - 1) * constants.inverse_size;
	float2 after = (center + 2) * constants.inverse_size;
	float4 sum = 0;
	sum += float4(history.SampleLevel(s, float2(middle.x, before.y), 0).rgb, 1) * (w12.x * w0.y);
	sum += float4(history.SampleLevel(s, float2(before.x, middle.y), 0).rgb, 1) * (w0.x * w12.y);
	sum += float4(history.SampleLevel(s, middle, 0).rgb, 1) * (w12.x * w12.y);
	sum += float4(history.SampleLevel(s, float2(after.x, middle.y), 0).rgb, 1) * (w3.x * w12.y);
	sum += float4(history.SampleLevel(s, float2(middle.x, after.y), 0).rgb, 1) * (w12.x * w3.y);
	return max(sum.rgb / sum.a, 0);
}

// clip_to_box moves a color toward the box's center until it is inside the box.
float3 clip_to_box(float3 color, float3 low, float3 high) {
	float3 center = 0.5 * (low + high);
	float3 extent = 0.5 * (high - low) + 1e-5;
	float3 offset = color - center;
	float3 units = abs(offset / extent);
	float most = max(units.x, max(units.y, units.z));
	return most > 1 ? center + offset / most : color;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	Texture2D<float4> scene = cn_texture(constants.scene);
	Texture2D<float4> depth = cn_texture(constants.depth);
	int2 pixel = int2(id.xy);
	float2 uv = (float2(pixel) + 0.5) * constants.inverse_size;
	int2 last = int2(constants.render_size) - 1;
	// The scene's pixel whose sample is nearest: a sample was taken the jitter's pixels from its pixel's center, which
	// at the output's size is the pixel itself.
	float2 jitter_pixels = constants.jitter * float2(0.5, -0.5) * float2(constants.render_size);
	float2 position = uv * float2(constants.render_size);
	int2 center = constants.upscale != 0 ? int2(floor(position + jitter_pixels)) : pixel;
	float2 output_pixels = float2(constants.size) * constants.inverse_render_size;

	// The neighborhood's mean and spread, and its nearest pixel, whose motion the pixel takes so edges move with the
	// surface in front. Depth is reversed, so the nearest is the largest. Upscaling, this frame's color is the samples'
	// weighted by how near they are, and nearest_weight how near the nearest is.
	float3 current = 0;
	float current_weight = 0;
	float nearest_weight = 1;
	float3 sum = 0;
	float3 squares = 0;
	float nearest_depth = -1;
	int2 nearest = center;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			int2 p = clamp(center + int2(x, y), 0, last);
			float3 c = to_ycocg(compress(max(scene.Load(int3(p, 0)).rgb, 0)));
			sum += c;
			squares += c * c;
			if (constants.upscale != 0) {
				float2 offset = (float2(center + int2(x, y)) + 0.5 - jitter_pixels - position) * output_pixels;
				float w = exp(-SAMPLE_FALLOFF * dot(offset, offset));
				current += c * w;
				current_weight += w;
			} else if (x == 0 && y == 0) {
				current = c;
				current_weight = 1;
			}
			float d = depth.Load(int3(p, 0)).r;
			if (d > nearest_depth) {
				nearest_depth = d;
				nearest = p;
			}
		}
	}
	current /= max(current_weight, 1e-6);
	if (constants.upscale != 0) {
		float2 offset = (float2(center) + 0.5 - jitter_pixels - position) * output_pixels;
		nearest_weight = max(exp(-SAMPLE_FALLOFF * dot(offset, offset)), MIN_BLEND_SHARE);
	}

	float2 velocity = cn_texture(constants.velocity).Load(int3(nearest, 0)).rg;
	bool moved = true;
	if (velocity.x >= VELOCITY_NONE) {
		// The prepass drew nothing there, so the point moves only with the camera.
		float2 ndc = (float2(nearest) + 0.5) * constants.inverse_render_size * float2(2, -2) + float2(-1, 1) - constants.jitter;
		float4 previous = mul(constants.reproject, float4(ndc, nearest_depth, 1));
		moved = previous.w > 0;
		velocity = (ndc - previous.xy / previous.w) * float2(0.5, -0.5);
	}
	float2 previous_uv = uv - velocity;

	float3 result = current;
	if (constants.valid != 0 && moved && all(previous_uv == saturate(previous_uv))) {
		float2 exposure = cn_buffer(constants.exposure).Load<float2>(0);
		float3 history = sample_history(cn_texture(constants.history), cn_sampler(constants.sampler_index), previous_uv);
		history = to_ycocg(compress(history * (exposure.x / max(exposure.y, 1e-10))));
		float3 mean = sum / 9;
		float3 sigma = sqrt(max(squares / 9 - mean * mean, 0));
		history = clip_to_box(history, mean - CLIP_SIGMAS * sigma, mean + CLIP_SIGMAS * sigma);
		result = lerp(history, current, constants.blend * nearest_weight);
	}
	cn_rw_texture(constants.output)[pixel] = float4(max(expand(from_ycocg(result)), 0), 1);
}
