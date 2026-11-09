// The cloud shadow's receiver (see docs/rendering/clouds.md#shadow): how much of the sun reaches a point under the
// clouds, from the cloud shadow map in Frame_Constants. material_lighting.hlsli includes it after material_common.hlsli,
// whose frame constants it reads, so every pass with the light loop takes it: the forward pass, the transparent
// surfaces, the sprites, the fog's injection, the global illumination's hit light and the voxel cones' injection. It
// includes nothing of the clouds' own shaders.
#ifndef CLOUD_SHADOW_HLSLI
#define CLOUD_SHADOW_HLSLI

// Below this height of the sun, the shadow map holds 1, and the receiver takes no shadow.
static const float CLOUD_SHADOW_MIN_SUN_Y = 0.05;

// cloud_shadow is the share of the sun's light that reaches a point relative to the camera, along the direction toward
// the sun: the transmittance of the shadow map where the sun's ray through the point meets the layer's bottom, scaled
// by the shadow's strength and its fade near the horizon. 1 without a map, outside it, with the sun too low, or at the
// layer's top and above; a point inside the layer takes the shadow faded by its height in it, since the map holds the
// whole layer's transmittance and such a point has only the cloud above it between it and the sun.
float cloud_shadow(float3 p, float3 to_sun) {
	if (frame.cloud_shadow == 0 || to_sun.y <= CLOUD_SHADOW_MIN_SUN_Y || p.y >= frame.cloud_shadow_top) {
		return 1;
	}
	float3 q = p + to_sun * ((frame.cloud_shadow_bottom - p.y) / to_sun.y);
	float2 uv = (q.xz - frame.cloud_shadow_center) * frame.cloud_shadow_inv_extent + 0.5;
	if (any(uv < 0) || any(uv > 1)) {
		return 1;
	}
	float transmittance = cn_texture(frame.cloud_shadow).SampleLevel(cn_sampler(frame.cloud_shadow_sampler), uv, 0).r;
	float inside = saturate((p.y - frame.cloud_shadow_bottom) / max(frame.cloud_shadow_top - frame.cloud_shadow_bottom, 1));
	return lerp(1, transmittance, frame.cloud_shadow_strength * frame.cloud_shadow_fade * (1 - inside));
}

#endif
