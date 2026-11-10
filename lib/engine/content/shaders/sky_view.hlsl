// The sky view table (see sky_common.hlsli): the light that reaches the camera from every direction, which the air
// scatters toward it from the sun and the moon, once from the transmittance table and more from the multiple
// scattering table, and the ground's where the ray meets it.
#include "sky_common.hlsli"

static const uint STEPS = 32;

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
		sky_step(h, mu, d, (s + 0.5) * dt, dt, light, transmittance);
	}
	if (ground) {
		light += transmittance * (ground_light(h, length, d, sky.sun_direction, sky.sun_illuminance.rgb) +
			ground_light(h, length, d, sky.moon_direction, sky.moon_light.rgb));
	}
	cn_rw_texture(push.output)[id.xy] = float4(light, 1);
}
