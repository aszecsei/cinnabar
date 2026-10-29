// What the sky's shaders share (see docs/rendering/sky.md#sky): their constants, the atmosphere's model and the lookup
// tables' layouts, after Hillaire's "A Scalable and Production Ready Sky and Atmosphere Rendering Technique" (2020).
// Distances are in kilometers. A point is its height above the ground and the cosine of a ray's angle from its zenith,
// mu, rather than a position from the planet's center: a radius of thousands of kilometers in a float keeps only about
// a meter, which is the camera's whole height above the ground, so the heights are found from differences that keep it.
#ifndef SKY_COMMON_HLSLI
#define SKY_COMMON_HLSLI

#include "cinnabar.hlsli"

// Matches Sky_Constants in lib/engine/render/sky.odin. right and up have the projection's scales in w. Directions
// point toward the sun and the moon, with the cosines of their discs' radii in w; their illuminances have the radii.
// moon_light is the moon's light on the sky at its phase. rayleigh has its height in w, and mie its scattering,
// absorption, anisotropy and height. ground_albedo has the stars' intensity in w. heights holds the camera's height
// above the ground, the atmosphere's height and the planet's radius.
struct Sky_Constants {
	float4 right;
	float4 up;
	float4 forward;
	float4 sun_direction;
	float4 sun_illuminance;
	float4 moon_direction;
	float4 moon_illuminance;
	float4 moon_light;
	float4 rayleigh;
	float4 mie;
	float4 ozone;
	float4 ground_albedo;
	float4 heights;
	float star_density;
	uint padding;
	uint2 size;
};
CN_PASS_CONSTANTS(Sky_Constants, sky);

// Matches Sky_Push in lib/engine/render/sky.odin.
struct Sky_Push {
	uint transmittance;
	uint multiscatter;
	uint view;
	uint output;
	uint depth;
	uint exposure;
	uint sampler_index;
	uint padding;
};
CN_PUSH_CONSTANTS(Sky_Push, push);

static const float SKY_PI = 3.14159265;
// Match SKY_TRANSMITTANCE_SIZE, SKY_MULTISCATTER_SIZE and SKY_VIEW_SIZE in sky.odin.
static const uint2 TRANSMITTANCE_SIZE = uint2(256, 64);
static const uint2 MULTISCATTER_SIZE = uint2(32, 32);
static const uint2 SKY_VIEW_SIZE = uint2(256, 128);
// Match OZONE_CENTER and OZONE_HALF_WIDTH in sky.odin.
static const float OZONE_CENTER = 25;
static const float OZONE_HALF_WIDTH = 15;

float planet_radius() {
	return sky.heights.z;
}

float atmosphere_height() {
	return sky.heights.y;
}

// Medium is the air at a height: what scatters, per kilometer, and what scatters or absorbs.
struct Medium {
	float3 rayleigh;
	float mie;
	float3 extinction;
};

Medium medium_at(float h) {
	h = max(h, 0);
	float rayleigh = exp(-h / sky.rayleigh.w);
	float mie = exp(-h / sky.mie.w);
	float ozone = max(0, 1 - abs(h - OZONE_CENTER) / OZONE_HALF_WIDTH);
	Medium m;
	m.rayleigh = sky.rayleigh.rgb * rayleigh;
	m.mie = sky.mie.x * mie;
	m.extinction = m.rayleigh + (sky.mie.x + sky.mie.y) * mie + sky.ozone.rgb * ozone;
	return m;
}

// height_along is the height of the point at a distance along a ray from a height with mu.
float height_along(float h, float mu, float t) {
	float r = planet_radius() + h;
	float rise = 2 * r * mu * t + t * t;
	return h + rise / (sqrt(r * r + rise) + r);
}

// mu_along is the cosine from the zenith, at that point, of a direction whose cosine with the ray is cos_ray and whose
// y is toward_y.
float mu_along(float h, float t, float toward_y, float cos_ray, float h_at) {
	float b = planet_radius();
	return clamp(((b + h) * toward_y + t * cos_ray) / (b + h_at), -1, 1);
}

// horizon_mu is mu of the horizon from a height: rays below it meet the ground.
float horizon_mu(float h) {
	float b = planet_radius();
	return -sqrt(max(h * (2 * b + h), 0)) / (b + h);
}

bool hits_ground(float h, float mu) {
	return mu < horizon_mu(h);
}

float distance_to_ground(float h, float mu) {
	float b = planet_radius();
	float r = b + h;
	return max(-r * mu - sqrt(max(r * r * mu * mu - h * (2 * b + h), 0)), 0);
}

float distance_to_top(float h, float mu) {
	float b = planet_radius();
	float a = atmosphere_height();
	float r = b + h;
	return max(-r * mu + sqrt(max(r * r * mu * mu + (a - h) * (2 * b + a + h), 0)), 0);
}

// The transmittance table holds the share of light that reaches a height from the top of the atmosphere along mu,
// laid out as Bruneton's: by the distance to the top within its range at that height, and the distance to the
// horizon.
float2 transmittance_uv(float h, float mu) {
	float b = planet_radius();
	float a = atmosphere_height();
	float horizon = sqrt(a * (2 * b + a));
	float rho = sqrt(max(h * (2 * b + h), 0));
	float d = distance_to_top(h, mu);
	float d_min = a - h;
	float d_max = rho + horizon;
	float2 x = float2((d - d_min) / max(d_max - d_min, 1e-6), rho / horizon);
	return x * (1 - 1.0 / float2(TRANSMITTANCE_SIZE)) + 0.5 / float2(TRANSMITTANCE_SIZE);
}

// transmittance_params is the height and mu of a texel of the transmittance table, from 0 to 1 across its centers.
void transmittance_params(float2 x, out float h, out float mu) {
	float b = planet_radius();
	float a = atmosphere_height();
	float horizon = sqrt(a * (2 * b + a));
	float rho = horizon * x.y;
	h = rho * rho / (sqrt(rho * rho + b * b) + b);
	float d_min = a - h;
	float d = d_min + x.x * (rho + horizon - d_min);
	mu = d <= 0 ? 1 : clamp((horizon * horizon - rho * rho - d * d) / (2 * (b + h) * d), -1, 1);
}

float3 transmittance_at(float h, float mu) {
	return cn_texture(push.transmittance).SampleLevel(cn_sampler(push.sampler_index), transmittance_uv(h, mu), 0).rgb;
}

// The light that reaches a height along mu from a light at the top of the atmosphere: none from below the horizon.
float3 light_at(float h, float mu) {
	return hits_ground(h, mu) ? 0 : transmittance_at(h, mu);
}

// The multiple scattering table holds the light scattered more than once at a height, from a light along mu, per
// unit of scattering and of illuminance.
float3 multiscatter_at(float h, float mu) {
	float2 x = saturate(float2(mu * 0.5 + 0.5, h / atmosphere_height()));
	float2 uv = x * (1 - 1.0 / float2(MULTISCATTER_SIZE)) + 0.5 / float2(MULTISCATTER_SIZE);
	return cn_texture(push.multiscatter).SampleLevel(cn_sampler(push.sampler_index), uv, 0).rgb;
}

float rayleigh_phase(float cos_theta) {
	return 3 / (16 * SKY_PI) * (1 + cos_theta * cos_theta);
}

// Cornette and Shanks's phase function.
float mie_phase(float cos_theta, float g) {
	float g2 = g * g;
	return 3 / (8 * SKY_PI) * (1 - g2) * (1 + cos_theta * cos_theta) / ((2 + g2) * pow(max(1 + g2 - 2 * g * cos_theta, 1e-4), 1.5));
}

// The sky view table holds the light from every direction at the camera: the azimuth from +z toward +x across, and
// the elevation down, from the zenith to the horizon in the top half and from the horizon to the nadir in the
// bottom. Each half is squeezed toward the horizon, where the light changes fastest.
float2 sky_view_uv(float3 d, float h) {
	float horizon = asin(horizon_mu(h));
	float elevation = asin(clamp(d.y, -1, 1));
	float v;
	if (elevation >= horizon) {
		v = 0.5 - 0.5 * sqrt(saturate((elevation - horizon) / (SKY_PI * 0.5 - horizon)));
	} else {
		v = 0.5 + 0.5 * sqrt(saturate((horizon - elevation) / (SKY_PI * 0.5 + horizon)));
	}
	float u = frac(atan2(d.x, d.z) / (2 * SKY_PI));
	return float2(u, v);
}

float3 sky_view_direction(float2 uv, float h) {
	float horizon = asin(horizon_mu(h));
	float elevation;
	if (uv.y < 0.5) {
		float x = 1 - 2 * uv.y;
		elevation = horizon + x * x * (SKY_PI * 0.5 - horizon);
	} else {
		float x = 2 * uv.y - 1;
		elevation = horizon - x * x * (SKY_PI * 0.5 + horizon);
	}
	float azimuth = uv.x * 2 * SKY_PI;
	return float3(cos(elevation) * sin(azimuth), sin(elevation), cos(elevation) * cos(azimuth));
}

#endif
