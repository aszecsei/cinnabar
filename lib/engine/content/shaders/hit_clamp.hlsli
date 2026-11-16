// What the passes that keep a ray's light in a history share (see docs/rendering/global-illumination.md#world-probes):
// a clamp of a ray's light, so that one very bright sample, such as a ray that finds a small, bright emitter or the sun,
// does not stay in the history for many frames.
#ifndef HIT_CLAMP_HLSLI
#define HIT_CLAMP_HLSLI

// clamp_hit_light is a hit's light, with its luminance, pre-exposed by exposure, at most limit, and its color kept. The
// light and what it gives are not pre-exposed.
float3 clamp_hit_light(float3 light, float exposure, float limit) {
	float luminance = dot(light, float3(0.2126, 0.7152, 0.0722)) * exposure;
	return luminance > limit ? light * (limit / luminance) : light;
}

#endif
