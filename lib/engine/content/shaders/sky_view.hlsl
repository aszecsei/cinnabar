// The sky view table (see sky_common.hlsli): the light that reaches the camera from every direction, which the air
// scatters toward it from the sun and the moon, once from the transmittance table and more from the multiple
// scattering table, and the ground's where the ray meets it.
#include "sky_common.hlsli"

static const uint STEPS = 32;

// The light that the air at a point along the ray scatters toward the camera from one light.
float3 scattered(Medium m, float h, float t, float h_at, float3 d, float4 toward, float3 illuminance) {
	if (all(illuminance <= 0)) {
		return 0;
	}
	float cos_ray = dot(d, toward.xyz);
	float mu = mu_along(h, t, toward.y, cos_ray, h_at);
	float3 phase = m.rayleigh * rayleigh_phase(cos_ray) + m.mie * mie_phase(cos_ray, sky.mie.z);
	float3 multi = multiscatter_at(h_at, mu) * (m.rayleigh + m.mie);
	return illuminance * (light_at(h_at, mu) * phase + multi);
}

// The light of the ground where the ray meets it, from one light.
float3 ground_light(float h, float length, float3 d, float4 toward, float3 illuminance) {
	float mu = mu_along(h, length, toward.y, dot(d, toward.xyz), 0);
	return illuminance * transmittance_at(0, mu) * saturate(mu) * sky.ground_albedo.rgb / SKY_PI;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= SKY_VIEW_SIZE)) {
		return;
	}
	float h = sky.heights.x;
	float3 d = sky_view_direction((float2(id.xy) + 0.5) / float2(SKY_VIEW_SIZE), h);
	float mu = d.y;
	bool ground = hits_ground(h, mu);
	float length = ground ? distance_to_ground(h, mu) : distance_to_top(h, mu);
	float dt = length / STEPS;
	float3 transmittance = 1;
	float3 light = 0;
	for (uint s = 0; s < STEPS; s++) {
		float t = (s + 0.5) * dt;
		float h_at = height_along(h, mu, t);
		Medium m = medium_at(h_at);
		float3 source = scattered(m, h, t, h_at, d, sky.sun_direction, sky.sun_illuminance.rgb) +
			scattered(m, h, t, h_at, d, sky.moon_direction, sky.moon_light.rgb);
		float3 step = exp(-m.extinction * dt);
		light += transmittance * source * (1 - step) / max(m.extinction, 1e-6);
		transmittance *= step;
	}
	if (ground) {
		light += transmittance * (ground_light(h, length, d, sky.sun_direction, sky.sun_illuminance.rgb) +
			ground_light(h, length, d, sky.moon_direction, sky.moon_light.rgb));
	}
	cn_rw_texture(push.output)[id.xy] = float4(light, 1);
}
