// The global illumination's lit scene (see docs/rendering.md#global-illumination): after the world pass, each texel
// keeps the mean of a 2x2 block of the scene, without its pre-exposure, so the next frame's rays read the light that
// each surface reflects. It holds this frame's indirect light too, so the light bounces on from frame to frame.
#include "gi_common.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.lit_size)) {
		return;
	}
	Texture2D<float4> scene = cn_texture(constants.scene);
	int2 last = int2(constants.size) - 1;
	float3 sum = 0;
	[unroll] for (uint n = 0; n < 4; n++) {
		int2 p = min(int2(id.xy * 2 + uint2(n & 1, n >> 1)), last);
		sum += max(scene.Load(int3(p, 0)).rgb, 0);
	}
	float exposure = cn_buffer(constants.exposure).Load<float>(0);
	cn_rw_texture(constants.lit)[id.xy] = float4(sum * 0.25 / max(exposure, 1e-10), 1);
}
