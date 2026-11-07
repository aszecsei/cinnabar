// The screen-space reflections' lit scene (see docs/rendering/lighting-and-shadows.md#screen-space-reflections): after the
// world pass, the scene without its pre-exposure, which the next frame's rays take where they hit. At full resolution
// each texel is the scene's pixel; at half, the mean of a 2x2 block, as the global illumination's lit scene is.
#include "ssr_common.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.lit_size)) {
		return;
	}
	Texture2D<float4> scene = cn_texture(constants.scene);
	float exposure = max(cn_buffer(constants.exposure).Load<float>(0), 1e-10);
	float3 light;
	if (all(constants.lit_size == constants.size)) {
		light = max(scene.Load(int3(id.xy, 0)).rgb, 0);
	} else {
		int2 last = int2(constants.size) - 1;
		light = 0;
		[unroll] for (uint n = 0; n < 4; n++) {
			int2 p = min(int2(id.xy * 2 + uint2(n & 1, n >> 1)), last);
			light += max(scene.Load(int3(p, 0)).rgb, 0);
		}
		light *= 0.25;
	}
	cn_rw_texture(constants.output)[id.xy] = float4(light / exposure, 1);
}
