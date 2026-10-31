// A traced ray's hit that the screen shows takes its light from the global illumination's lit scene of last frame (see
// docs/rendering/global-illumination.md#world-probes), as the cascades' rays do: the light of small emissive surfaces
// that few rays hit, and of everything that the cascades lit. A pass includes it with the camera's frame constants set,
// and calls it in a pass of its own, after the hits' light: folded into the light's shader beside its probe lookups, it
// hung the GPU on an RTX 5090.
#ifndef GI_HIT_SCREEN_HLSLI
#define GI_HIT_SCREEN_HLSLI

// A point is the surface that a pixel shows when its view depth is within this share of the pixel's, plus a few
// centimeters.
static const float SCREEN_TOLERANCE = 0.05;
static const float SCREEN_SLACK = 0.05;

// screen_light is the light of a point relative to the camera in last frame's lit scene, where it was then, when this
// frame's depth shows it. The caller checks that the lit scene has a frame of history.
bool screen_light(float3 p, uint depth, uint lit, uint sampler_index, out float3 light) {
	light = 0;
	float4 clip = mul(frame.view_projection, float4(p, 1));
	if (clip.w <= frame.near) {
		return false;
	}
	float2 ndc = clip.xy / clip.w;
	if (any(abs(ndc) >= 1)) {
		return false;
	}
	uint2 pixel = min(uint2((ndc * float2(0.5, -0.5) + 0.5) * frame.screen_size), uint2(frame.screen_size) - 1);
	float z = cn_texture(depth).Load(int3(pixel, 0)).r;
	if (z <= 0 || abs(clip.w - frame.near / z) > SCREEN_TOLERANCE * clip.w + SCREEN_SLACK) {
		return false;
	}
	float4 previous = mul(frame.previous_view_projection, float4(p + frame.camera_offset.xyz - frame.previous_camera_offset.xyz, 1));
	float2 uv = previous.xy / previous.w * float2(0.5, -0.5) + 0.5;
	if (previous.w <= 0 || any(uv != saturate(uv))) {
		return false;
	}
	light = cn_texture(lit).SampleLevel(cn_sampler(sampler_index), uv, 0).rgb;
	return true;
}

#endif
