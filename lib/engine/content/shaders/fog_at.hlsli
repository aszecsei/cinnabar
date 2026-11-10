// fog_at and air_and_fog_at, the fog volume's lookup and the aerial perspective volume's with it, which the forward
// template, the sprite renderers and the sprites' light pass share (see docs/rendering/fog.md#volumetric-fog and
// docs/rendering/sky.md#aerial-perspective). The file that includes it includes material_lighting.hlsli first, and its
// push constants have the integrated fog volume in fog and the aerial perspective volume in aerial.
#ifndef FOG_AT_HLSLI
#define FOG_AT_HLSLI

#include "aerial.hlsli"

// fog_at is the integrated fog between the camera and a point, relative to the camera, from the fog volume: the light
// that the fog scatters toward the camera in rgb, not pre-exposed, and the share of the point's light that reaches the
// camera in a. Like the clusters, the volume is the camera's screen tiles, so the point's place comes from the camera's
// projection, which the view model's pixels are not drawn with. A texel holds the fog up to its slice's far end.
float4 fog_at(float3 p) {
	float4 clip = mul(frame.cluster_view_projection, float4(p, 1));
	float depth = max(clip_view_z(frame.projection, clip), 1e-7);
	float2 uv = (clip.xy / max(clip.w, 1e-7) * float2(0.5, -0.5) + 0.5) * frame.fog_scale;
	float slices = float(frame.fog_slices);
	float slice = slice_of(frame.projection, depth, frame.slice_scale, frame.slice_bias) * (slices / CLUSTER_SLICES);
	float3 coordinates = float3(uv, (slice - 0.5) / slices);
	return cn_texture3d(push.fog).SampleLevel(cn_sampler(frame.fog_sampler), coordinates, 0);
}

// aerial_at is the air of the atmosphere between the camera and a point, relative to the camera, as fog_at gives the
// fog. The volume covers the camera's screen, so the point's place comes from the camera's projection too.
float4 aerial_at(float3 p) {
	float4 clip = mul(frame.cluster_view_projection, float4(p, 1));
	float2 uv = clip.xy / max(clip.w, 1e-7) * float2(0.5, -0.5) + 0.5;
	return aerial_sample(cn_texture3d(push.aerial), cn_sampler(frame.aerial_sampler), uv, length(p));
}

// air_and_fog_at is the air and then the fog between the camera and a point, as one: the point's light is dimmed by the
// air and takes the air's light, and the fog in front of it dims both and adds its own, so
// (c * air.a + air.rgb) * fog.a + fog.rgb = c * (air.a * fog.a) + (air.rgb * fog.a + fog.rgb). The fog volume ends at
// CLUSTER_FAR and the air goes on, and the first 500 m that both count are an error of about 0.5 %.
float4 air_and_fog_at(float3 p) {
	float4 air = frame.aerial != 0 ? aerial_at(p) : float4(0, 0, 0, 1);
	float4 fog = frame.fog != 0 ? fog_at(p) : float4(0, 0, 0, 1);
	return float4(air.rgb * fog.a + fog.rgb, air.a * fog.a);
}

#endif
