// The pass constants that every scene shader reads.
#ifndef PASS_HLSLI
#define PASS_HLSLI

#include "cinnabar.hlsli"

// Matches Pass_Constants in game.odin. Positions reach the GPU relative to the camera, so view_projection maps them
// straight to clip space (see render.view_projection).
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
};
CN_PASS_CONSTANTS(Pass, pass);

#endif
