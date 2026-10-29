// The Texture sky's ambient light (see docs/rendering/sky.md#texture), as sky_ambient in lib/engine/render/sky.odin
// takes the atmosphere's: the average light over the sphere, and twice the average of the light times its direction,
// from every texel of one small mip, weighted by the solid angle that it covers. One group sums the texels, and the
// result goes to a buffer with the ticket that the CPU asked for, which it reads back.
#include "sky_texture.hlsli"

#define THREADS 256

groupshared float4 sums[THREADS][4];

[numthreads(THREADS, 1, 1)]
void cs_main(uint thread : SV_GroupIndex) {
	Texture2D<float4> texture = cn_texture(push.texture);
	float4 total[4] = {float4(0, 0, 0, 0), float4(0, 0, 0, 0), float4(0, 0, 0, 0), float4(0, 0, 0, 0)};
	uint count = push.width * push.height;
	for (uint i = thread; i < count; i += THREADS) {
		uint2 texel = uint2(i % push.width, i / push.width);
		float2 uv = (float2(texel) + 0.5) / float2(push.width, push.height);
		float3 d = texture_direction(uv);
		// A texel's solid angle is in proportion to the sine of its angle from straight up.
		float weight = sin(uv.y * SKY_TEXTURE_PI);
		float3 light = texture.Load(int3(texel, push.mip)).rgb * weight;
		total[0] += float4(light, weight);
		total[1].rgb += light * d.x;
		total[2].rgb += light * d.y;
		total[3].rgb += light * d.z;
	}
	for (uint k = 0; k < 4; k++) {
		sums[thread][k] = total[k];
	}
	GroupMemoryBarrierWithGroupSync();
	for (uint stride = THREADS / 2; stride > 0; stride /= 2) {
		if (thread < stride) {
			for (uint k = 0; k < 4; k++) {
				sums[thread][k] += sums[thread + stride][k];
			}
		}
		GroupMemoryBarrierWithGroupSync();
	}
	if (thread == 0) {
		float weight = max(sums[0][0].w, 1e-6);
		RWByteAddressBuffer output = cn_rw_buffer(push.output);
		output.Store4(0, asuint(float4(sums[0][0].rgb / weight, 0)));
		for (uint axis = 1; axis < 4; axis++) {
			output.Store4(axis * 16, asuint(float4(sums[0][axis].rgb * 2 / weight, 0)));
		}
		output.Store(64, push.ticket);
	}
}
