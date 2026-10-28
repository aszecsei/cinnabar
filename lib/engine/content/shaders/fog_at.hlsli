// fog_at, the fog volume's lookup, which the forward template and the sprites' light pass share (see
// docs/rendering/fog.md#volumetric-fog). The file that includes it includes material_lighting.hlsli first, and its push
// constants have the integrated volume in fog.
#ifndef FOG_AT_HLSLI
#define FOG_AT_HLSLI

// fog_at is the integrated fog between the camera and a point, from the fog volume: the light that the fog scatters
// toward the camera in rgb, not pre-exposed, and the share of the point's light that reaches the camera in a. Like the
// clusters, the volume is the camera's screen tiles, so the point's place comes from the camera's projection, which
// the view model's pixels are not drawn with. A texel holds the fog up to its slice's far end.
float4 fog_at(float3 p) {
	float4 clip = mul(frame.cluster_view_projection, float4(p, 1));
	float depth = max(clip.w, 1e-7);
	float2 uv = (clip.xy / depth * float2(0.5, -0.5) + 0.5) * frame.fog_scale;
	float slices = float(frame.fog_slices);
	float slice = (log2(depth) * frame.slice_scale + frame.slice_bias) * (slices / CLUSTER_SLICES);
	float3 coordinates = float3(uv, (slice - 0.5) / slices);
	return cn_texture3d(push.fog).SampleLevel(cn_sampler(frame.fog_sampler), coordinates, 0);
}

#endif
