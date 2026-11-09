// The cloud shadow map (see docs/rendering/clouds.md#shadow): a thread for each texel of a square of shadow_extent
// meters on the layer's bottom, centered on shadow_center. Each marches toward the sun through the low layer in
// shadow_steps even steps of the cheap density, and writes the transmittance, which every lit thing reads through
// cloud_shadow in cloud_shadow.hlsli. With the sun near the horizon, the map is 1: the receiver fades it out too.
#include "clouds_common.hlsli"

static const float SHADOW_MIN_SUN_Y = 0.05;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= clouds.shadow_size)) {
		return;
	}
	RWTexture2D<float4> output = cn_rw_texture(push.output);
	float3 to_sun = clouds.sun_direction.xyz;
	if (clouds.sun_direction.w == 0 || to_sun.y < SHADOW_MIN_SUN_Y) {
		output[id.xy] = 1;
		return;
	}
	float2 uv = (float2(id.xy) + 0.5) / float(clouds.shadow_size);
	float2 xz = clouds.shadow_center + (uv - 0.5) * clouds.shadow_extent;
	float3 p = float3(xz.x, clouds.bottom - clouds.camera_height, xz.y);
	float path = (clouds.top - clouds.bottom) / to_sun.y;
	float ds = path / float(max(clouds.shadow_steps, 1));
	float depth = 0;
	for (uint i = 0; i < clouds.shadow_steps; i++) {
		float s = (float(i) + 0.5) * ds;
		float3 q = p + to_sun * s;
		float h = clouds.bottom + to_sun.y * s;
		depth += cheap_sigma(q, h, length(q.xz)) * ds;
	}
	output[id.xy] = exp(-depth);
}
