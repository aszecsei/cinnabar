// The aerial perspective volume (see docs/rendering/sky.md#aerial-perspective, aerial.hlsli): a thread for each texel
// of the screen's 32x32 grid marches its ray outward from the camera, as the sky view table marches (sky_step), and
// writes for each slice the light that the air scatters toward the camera up to the slice's distance, and the mean
// share of light from there that reaches the camera.
#include "sky_common.hlsli"
#include "aerial.hlsli"

// The steps of the march between one slice's distance and the next.
static const uint STEPS_PER_SLICE = 4;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= uint(AERIAL_SLICES))) {
		return;
	}
	float2 ndc = (float2(id.xy) + 0.5) / AERIAL_SLICES * float2(2, -2) + float2(-1, 1);
	float3 d = normalize(sky.right.xyz * (ndc.x / sky.right.w) + sky.up.xyz * (ndc.y / sky.up.w) + sky.forward.xyz);
	float h = sky.heights.x;
	float mu = d.y;
	RWTexture3D<float4> output = cn_rw_texture3d(push.output);
	float3 transmittance = 1;
	float3 light = 0;
	float near = 0;
	for (uint k = 0; k < uint(AERIAL_SLICES); k++) {
		// The sky's distances are in kilometers.
		float far = aerial_slice_distance(k) * 0.001;
		float dt = (far - near) / STEPS_PER_SLICE;
		for (uint s = 0; s < STEPS_PER_SLICE; s++) {
			sky_step(h, mu, d, near + (s + 0.5) * dt, dt, light, transmittance);
		}
		output[uint3(id.xy, k)] = float4(light, dot(transmittance, float3(1, 1, 1) / 3));
		near = far;
	}
}
