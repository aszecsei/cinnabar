// What the clouds' shaders share (see docs/rendering/clouds.md#clouds): their constants, the geometry of the layer's
// shells over the planet, the weather at a point, the clouds' shape and density from the noise textures, and the
// lighting's phase functions. Distances are in meters. A point is its height above the ground and the cosine of the
// ray's angle from the zenith, mu, never a position from the planet's center, as the sky's shaders keep it (see
// sky_common.hlsli): a float keeps about a meter of the planet's radius.
#ifndef CLOUDS_COMMON_HLSLI
#define CLOUDS_COMMON_HLSLI

#include "ambient.hlsli"
#include "cinnabar.hlsli"

// Matches Cloud_Constants in lib/engine/render/clouds.odin. right and up have the projection's scales in w.
// previous takes a point relative to this frame's camera to last frame's clip space. sun_direction points toward the
// sun, with 1 in w when a sun lights the clouds. sun_illuminance is the sun's light at the low layer's middle, and
// cirrus_illuminance at the cirrus layer; ambient is the frame's ambient light times ambient_intensity. Heights are
// above the ground: the camera's, the low layer's bottom and top, and the cirrus layer's. weather_offset is the camera
// relative to the weather map's origin, less the wind's carry, reduced modulo the map's size, and noise_offset the
// same reduced modulo CLOUD_NOISE_PERIOD, so a lookup adds them to a point relative to the camera. cirrus_offset is
// the same in the wind's frame, along it and across it, reduced modulo the cirrus's stretched period and its period.
// wind_direction is the unit vector toward which the wind blows. shadow_center is the shadow map's center relative to
// the camera, and shadow_extent its side. base_variation is how far each cloud's base may rise, 0 to 1.
struct Cloud_Constants {
	float4 right;
	float4 up;
	float4 forward;
	float4x4 previous;
	float4 sun_direction;
	float4 sun_illuminance;
	float4 cirrus_illuminance;
	float4 ambient[4];
	float camera_height;
	float bottom;
	float top;
	float cirrus_height;
	float planet_radius;
	float inv_weather_size;
	float far_distance;
	float far_coverage;
	float2 weather_offset;
	float2 noise_offset;
	float2 wind_direction;
	float2 screen_size;
	float coverage;
	float precipitation;
	float cloud_type;
	float cirrus;
	float density;
	float history_blend;
	float shadow_extent;
	float near;
	float2 shadow_center;
	uint shadow_size;
	uint shadow_steps;
	uint steps;
	uint light_steps;
	uint divisor;
	uint frame;
	uint2 size;
	uint use_map;
	uint shape;
	uint detail;
	uint curl;
	uint noise_sampler;
	uint weather;
	uint blue_noise;
	uint clamp_sampler;
	float2 cirrus_offset;
	float base_variation;
	float3 padding;
};
CN_PASS_CONSTANTS(Cloud_Constants, clouds);

// Matches Cloud_Push in lib/engine/render/clouds.odin: one pass's textures, which exist only once the frame records.
// kind is the noise pass's texture: 0 the shape, 1 the detail, 2 the curl. valid is whether the history holds last
// frame's clouds. aerial is the composite's aerial perspective volume, 0 without one.
struct Cloud_Push {
	uint depth;
	uint current;
	uint distance;
	uint history;
	uint output;
	uint kind;
	uint valid;
	uint exposure;
	uint aerial;
};
CN_PUSH_CONSTANTS(Cloud_Push, push);

static const float CLOUD_PI = 3.14159265;
// The extinction of a meter of cloud at a density of 1, and the Clouds' density of 1.
static const float CLOUD_EXTINCTION = 0.05;
// The noise textures' periods in the world, in meters. The low layer's match CLOUD_NOISE_PERIOD in clouds.odin, their
// least common multiple, which noise_offset is reduced by. The cirrus reads the shape stretched CIRRUS_STRETCH times
// along the wind, through cirrus_offset, which is reduced in the wind's frame (cirrus_offset in clouds.odin).
static const float CLOUD_SHAPE_PERIOD = 8000;
static const float CLOUD_DETAIL_PERIOD = 600;
static const float CLOUD_CURL_PERIOD = 4000;
static const float CIRRUS_PERIOD = 8000;
static const float CIRRUS_STRETCH = 3;
// The period of the slow noise that lifts each cloud's base, which divides CLOUD_NOISE_PERIOD, and the most of the
// layer's thickness that a base rises at a base_variation of 1.
static const float CLOUD_LIFT_PERIOD = 12000;
static const float CLOUD_LIFT_MAX = 0.7;
// How far the curl moves the detail noise at the layer's base, in meters, tapering to 0 at its top.
static const float CLOUD_CURL_STRENGTH = 150;
// The march ends here, and the clouds fade out from CLOUD_FADE_START.
static const float CLOUD_MAX_DISTANCE = 40000;
static const float CLOUD_FADE_START = 25000;
// The light march toward the sun reaches at most this far.
static const float LIGHT_REACH_MAX = 4000;
// The cirrus layer's optical depth at a coverage of 1.
static const float CIRRUS_OPTICAL_DEPTH = 0.8;
// Keeps the scene within its format, as sky.hlsl does.
static const float CLOUD_MAX_SCENE = 60000;
// The multiple scattering octaves (Wrenninge): each takes this share of the light, the extinction and the phase's
// eccentricity of the one before.
static const uint SCATTER_OCTAVES = 3;
static const float SCATTER_ATTENUATION = 0.5;

float remap(float v, float lo, float hi, float a, float b) {
	return a + (v - lo) / max(hi - lo, 1e-4) * (b - a);
}

// Henyey and Greenstein's phase function.
float hg_phase(float mu, float g) {
	float g2 = g * g;
	return (1 - g2) / (4 * CLOUD_PI * pow(max(1 + g2 - 2 * g * mu, 1e-4), 1.5));
}

// cloud_phase is the clouds' phase: a forward lobe and a weaker back lobe, each scaled by an octave's eccentricity.
float cloud_phase(float mu, float k) {
	return lerp(hg_phase(mu, -0.3 * k), hg_phase(mu, 0.8 * k), 0.5);
}

// The geometry: a ray from a point at height h0 above the ground with mu, the cosine of its angle from the zenith, and
// a sphere at height H around a planet of radius R. b and c are the quadratic's halves, so disc = b * b - c.

// sphere_above is the distance to a sphere above the point, which the ray always reaches.
float sphere_above(float h0, float mu, float H, float R) {
	float r = R + h0;
	float b = r * mu;
	float c = (h0 - H) * (2 * R + h0 + H);
	float disc = b * b - c;
	return -c / (b + sqrt(max(disc, 0)));
}

// sphere_below is whether the ray reaches a sphere below the point, at the near and the far roots.
bool sphere_below(float h0, float mu, float H, float R, out float near_t, out float far_t) {
	near_t = 0;
	far_t = 0;
	float r = R + h0;
	float b = r * mu;
	float c = (h0 - H) * (2 * R + h0 + H);
	float disc = b * b - c;
	if (b >= 0 || disc < 0) {
		return false;
	}
	float s = sqrt(disc);
	near_t = c / (-b + s);
	far_t = -b + s;
	return true;
}

// cloud_shell is the segment of the ray through the layer between bottom and top: from below it, inside it, or from
// above it. Matches cloud_shell in clouds.odin.
bool cloud_shell(float h0, float mu, float bottom, float top, float R, out float t0, out float t1) {
	t0 = 0;
	t1 = 0;
	float near_t, far_t;
	if (h0 < bottom) {
		t0 = sphere_above(h0, mu, bottom, R);
		t1 = sphere_above(h0, mu, top, R);
		return true;
	}
	if (h0 < top) {
		t1 = sphere_above(h0, mu, top, R);
		if (sphere_below(h0, mu, bottom, R, near_t, far_t)) {
			t1 = min(t1, near_t);
		}
		return true;
	}
	if (!sphere_below(h0, mu, top, R, near_t, far_t)) {
		return false;
	}
	t0 = near_t;
	t1 = far_t;
	float bottom_near, bottom_far;
	if (sphere_below(h0, mu, bottom, R, bottom_near, bottom_far)) {
		t1 = bottom_near;
	}
	return true;
}

// cloud_ground is whether the ray meets the ground, and where. Matches cloud_ground in clouds.odin.
bool cloud_ground(float h0, float mu, float R, out float t) {
	t = 0;
	float r = R + h0;
	float b = r * mu;
	float c = h0 * (2 * R + h0);
	float disc = b * b - c;
	if (mu >= 0 || disc < 0) {
		return false;
	}
	t = c / (-b + sqrt(disc));
	return true;
}

// height_at is the height above the ground at a distance along the ray, from a difference that keeps its precision.
// Matches cloud_height_at in clouds.odin.
float height_at(float h0, float mu, float t, float R) {
	float r = R + h0;
	float rise = 2 * r * mu * t + t * t;
	return h0 + rise / (sqrt(max(r * r + rise, 0)) + r);
}

// The weather at a point: how much of the sky the clouds cover, how much it rains, the cloud type from stratus (0)
// through cumulus (0.5) to cumulonimbus (1), and how far the point is into the far clouds, which blend the authored
// weather over to a cumulus at far_coverage.
struct Cloud_Weather {
	float coverage;
	float precipitation;
	float type;
	float far;
};

// weather_at is the weather at a point relative to the camera, at a distance along the ray.
Cloud_Weather weather_at(float3 p, float t) {
	Cloud_Weather w;
	if (clouds.use_map != 0) {
		float2 uv = (p.xz + clouds.weather_offset) * clouds.inv_weather_size + 0.5;
		float3 m = cn_texture(clouds.weather).SampleLevel(cn_sampler(clouds.noise_sampler), uv, 0).rgb;
		w.coverage = m.r;
		w.precipitation = m.g;
		w.type = m.b;
	} else {
		w.coverage = clouds.coverage;
		w.precipitation = clouds.precipitation;
		w.type = clouds.cloud_type;
	}
	// Rain comes with thick, tall clouds.
	w.coverage = max(w.coverage, 0.7 * w.precipitation);
	w.type = max(w.type, w.precipitation);
	w.far = saturate((t - clouds.far_distance) / max(clouds.far_distance, 1));
	w.coverage = lerp(w.coverage, clouds.far_coverage, w.far);
	w.type = lerp(w.type, 0.5, w.far);
	w.precipitation *= 1 - w.far;
	return w;
}

// cloud_gradient is how dense a cloud type is at a height fraction of the layer, from four knots: where it starts,
// where it is whole, where it starts to thin, and where it ends. Matches cloud_gradient in clouds.odin.
float cloud_gradient(float hf, float type) {
	const float4 stratus = float4(0, 0.1, 0.2, 0.3);
	const float4 cumulus = float4(0, 0.2, 0.4, 0.6);
	const float4 cumulonimbus = float4(0, 0.1, 0.7, 1.0);
	float4 k = type < 0.5 ? lerp(stratus, cumulus, type * 2) : lerp(cumulus, cumulonimbus, (type - 0.5) * 2);
	return saturate(remap(hf, k.x, k.y, 0, 1)) * saturate(remap(hf, k.z, k.w, 1, 0));
}

// anvil_coverage spreads a cumulonimbus's top into an anvil: its coverage grows toward the top of the layer.
float anvil_coverage(float coverage, float hf, float type) {
	float cb = saturate((type - 0.5) * 2);
	return pow(max(coverage, 0), lerp(1, clamp(remap(hf, 0.7, 0.8, 1, 0.5), 0.5, 1), cb));
}

// noise_position is where a point relative to the camera, at a height above the ground, is in the noise: anchored to
// the world, and blown by the wind.
float3 noise_position(float3 p, float h) {
	return float3(p.x + clouds.noise_offset.x, h, p.z + clouds.noise_offset.y);
}

// The share of the shape's Worley octaves that the remap cuts from its R's low end. The R's values sit about 0.7, so
// cutting SHAPE_EROSION of the octaves' sum (about 0.4) leaves a base about 0.55 with a wide spread, and a coverage
// then covers about its share of the sky.
static const float SHAPE_EROSION = 0.75;

// base_lift is how far up the layer a cloud's base is at a point of the noise, as a share of the thickness: the
// shape's R at one slice over CLOUD_LIFT_PERIOD, so neighbouring clouds sit at different heights, scaled by
// base_variation, and less for a cumulonimbus, whose anvil must still reach the top.
float base_lift(float3 q, float type) {
	float n = cn_texture3d(clouds.shape).SampleLevel(cn_sampler(clouds.noise_sampler), float3(q.x / CLOUD_LIFT_PERIOD, 0.73, q.z / CLOUD_LIFT_PERIOD), 0).r;
	return clouds.base_variation * CLOUD_LIFT_MAX * saturate(remap(n, 0.45, 0.95, 0, 1)) * (1 - saturate((type - 0.5) * 2));
}

// cloud_base is the cheap density at a point of the noise: the shape noise, eroded by its Worley octaves, shaped by the
// type's height gradient, which each cloud's base lift moves up, and the coverage.
float cloud_base(float3 q, float hf, float coverage, float type) {
	float4 s = cn_texture3d(clouds.shape).SampleLevel(cn_sampler(clouds.noise_sampler), q / CLOUD_SHAPE_PERIOD, 0);
	float fbm = s.g * 0.625 + s.b * 0.25 + s.a * 0.125;
	float base = saturate(remap(s.r, SHAPE_EROSION * fbm, 1, 0, 1)) * cloud_gradient(hf - base_lift(q, type), type);
	return saturate(remap(base, 1 - coverage, 1, 0, 1)) * coverage;
}

// cloud_detail is the full density: the base eroded by the detail noise, which the curl noise swirls at the base of the
// layer, with wispy edges at the bottom and billows above. The far clouds keep the base alone.
float cloud_detail(float3 q, float hf, float base, float far) {
	float2 curl = (cn_texture(clouds.curl).SampleLevel(cn_sampler(clouds.noise_sampler), q.xz / CLOUD_CURL_PERIOD, 0).rg * 2 - 1) * CLOUD_CURL_STRENGTH * (1 - hf);
	float3 dn = cn_texture3d(clouds.detail).SampleLevel(cn_sampler(clouds.noise_sampler), (q + float3(curl.x, 0, curl.y)) / CLOUD_DETAIL_PERIOD, 0).rgb;
	float dfbm = dn.r * 0.625 + dn.g * 0.25 + dn.b * 0.125;
	float dmod = lerp(dfbm, 1 - dfbm, saturate(hf * 10));
	return saturate(remap(base, dmod * 0.35 * (1 - far), 1, 0, 1));
}

// cloud_sigma is the extinction of a meter of cloud at a density, thicker in rain, fading out with the distance so
// the march ends cleanly at CLOUD_MAX_DISTANCE.
float cloud_sigma(float density, float precipitation, float t) {
	return density * CLOUD_EXTINCTION * clouds.density * lerp(1, 2, precipitation) * (1 - smoothstep(CLOUD_FADE_START, CLOUD_MAX_DISTANCE, t));
}

// cheap_sigma is the extinction of the cheap density at a point relative to the camera, at a height above the ground,
// for the light march and the shadow map, with the weather's far blend by a distance.
float cheap_sigma(float3 p, float h, float t) {
	float hf = saturate((h - clouds.bottom) / max(clouds.top - clouds.bottom, 1));
	if (hf <= 0 || hf >= 1) {
		return 0;
	}
	Cloud_Weather w = weather_at(p, t);
	if (w.coverage <= 0.005) {
		return 0;
	}
	float coverage = anvil_coverage(w.coverage, hf, w.type);
	float base = cloud_base(noise_position(p, h), hf, coverage, w.type);
	return cloud_sigma(base, w.precipitation, t);
}

// cloud_direction is the direction of a texel of the cloud buffer, from its block's center on the screen.
float3 cloud_direction(uint2 texel) {
	float2 pixel = (float2(texel) + 0.5) * float(clouds.divisor);
	float2 ndc = pixel / clouds.screen_size * float2(2, -2) + float2(-1, 1);
	return normalize(clouds.right.xyz * (ndc.x / clouds.right.w) + clouds.up.xyz * (ndc.y / clouds.up.w) + clouds.forward.xyz);
}

// pixel_direction is the direction of a pixel of the screen.
float3 pixel_direction(uint2 pixel) {
	float2 ndc = (float2(pixel) + 0.5) / clouds.screen_size * float2(2, -2) + float2(-1, 1);
	return normalize(clouds.right.xyz * (ndc.x / clouds.right.w) + clouds.up.xyz * (ndc.y / clouds.up.w) + clouds.forward.xyz);
}

#endif
