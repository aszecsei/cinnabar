// The upscalers' motion (see docs/rendering/anti-aliasing.md#fsr): the prepass's velocity, and where the prepass drew
// nothing, the motion of the point at the pixel's depth with the camera, as temporal AA finds it. An upscaler takes a
// motion for every pixel. With moment-based transparency, it also writes the upscalers' mask: how much the transparent
// surfaces and sprites cover the pixel, 1 - e^-b0, as the composite blends them over the scene.
#include "cinnabar.hlsli"

// Matches Motion_Push in lib/engine/render/upscalers.odin. reproject maps a pixel's clip position in this frame,
// without the jitter, to its clip position in the last frame for a point that did not move.
struct Push {
	float4x4 reproject;
	float2 jitter;
	float2 inverse_size;
	uint2 size;
	uint velocity;
	uint depth;
	uint output;
	// Zero without a mask.
	uint moments_zeroth;
	uint mask;
};
CN_PUSH_CONSTANTS(Push, push);

// The prepass clears the velocity to render.VELOCITY_NONE where it draws nothing; anything this large is that.
static const float VELOCITY_NONE = 1000;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	float2 velocity = cn_texture(push.velocity).Load(int3(id.xy, 0)).rg;
	if (velocity.x >= VELOCITY_NONE) {
		float depth = cn_texture(push.depth).Load(int3(id.xy, 0)).r;
		float2 ndc = (float2(id.xy) + 0.5) * push.inverse_size * float2(2, -2) + float2(-1, 1) - push.jitter;
		float4 previous = mul(push.reproject, float4(ndc, depth, 1));
		velocity = previous.w > 0 ? (ndc - previous.xy / previous.w) * float2(0.5, -0.5) : 0;
	}
	cn_rw_texture(push.output)[id.xy] = float4(velocity, 0, 0);
	if (push.mask != 0) {
		float b0 = cn_texture(push.moments_zeroth).Load(int3(id.xy, 0)).r;
		cn_rw_texture(push.mask)[id.xy] = 1 - exp(-b0);
	}
}
