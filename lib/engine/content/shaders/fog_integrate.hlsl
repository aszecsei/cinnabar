// The fog volume's integration (see docs/rendering.md#volumetric-fog): a thread for each tile walks its froxels from
// the camera outward, and writes for each the light that the fog scatters toward the camera up to the far end of its
// slice, and the share of light from there that reaches the camera. Each slice integrates its light as the fog dims
// it, so the result does not depend on the slices' thickness.
#include "cinnabar.hlsli"

// Matches Integrate_Push in lib/engine/render/fog.odin. scale holds the projection's x and y scales, and slices the
// clusters' slice constants: slice = log2(depth) * slices.x + slices.y.
struct Push {
	uint input;
	uint output;
	uint2 grid;
	float2 scale;
	float2 slices;
	float2 screen_size;
	uint slice_count;
	uint padding;
};
CN_PUSH_CONSTANTS(Push, push);

// Matches FOG_TILE and CLUSTER_SLICES in lib/engine/render.
static const float FOG_TILE = 16;
static const float CLUSTER_SLICES = 32;

float slice_depth(float slice) {
	return exp2((slice * CLUSTER_SLICES / push.slice_count - push.slices.y) / push.slices.x);
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.grid)) {
		return;
	}
	// The froxels' depths are along the view's axis; the ray through the tile is longer by this much.
	float2 pixel = (float2(id.xy) + 0.5) * FOG_TILE;
	float2 ndc = float2(pixel.x / push.screen_size.x * 2 - 1, 1 - pixel.y / push.screen_size.y * 2);
	float stretch = length(float3(ndc / push.scale, 1));
	Texture3D<float4> input = cn_texture3d(push.input);
	RWTexture3D<float4> output = cn_rw_texture3d(push.output);
	float3 scattered = 0;
	float transmittance = 1;
	float near = slice_depth(0);
	for (uint k = 0; k < push.slice_count; k++) {
		float far = slice_depth(k + 1);
		float4 froxel = input.Load(int4(id.xy, k, 0));
		float extinction = max(froxel.a, 1e-7);
		float through = exp(-extinction * (far - near) * stretch);
		scattered += transmittance * froxel.rgb * (1 - through) / extinction;
		transmittance *= through;
		output[uint3(id.xy, k)] = float4(scattered, transmittance);
		near = far;
	}
}
