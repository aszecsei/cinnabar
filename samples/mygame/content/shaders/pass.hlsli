// The pass constants that every scene shader reads.
#ifndef PASS_HLSLI
#define PASS_HLSLI

#include "cinnabar.hlsli"

// Matches Pass_Constants in game.odin. Positions reach the GPU relative to the camera, so view_projection maps them
// straight to clip space, with the camera's jitter for temporal AA (see render.jittered_view_projection).
struct Pass {
	float4x4 view_projection;
	// The camera's axes in the world: right, up and forward. w is unused.
	float4 right;
	float4 up;
	float4 forward;
	float time;
	float aspect;
	// The tangent of half the vertical field of view.
	float tan_half_fov;
	float near;
	// The renderer pre-exposes the scene: colors in the world pass scale by the float at 0 of this buffer.
	uint exposure;
	uint3 padding;
};
CN_PASS_CONSTANTS(Pass, pass);

// exposure scales a color that the world pass writes, as the renderer's materials do.
float exposure() {
	return cn_buffer(pass.exposure).Load<float>(0);
}

#endif
