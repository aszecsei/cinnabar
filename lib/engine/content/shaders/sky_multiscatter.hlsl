// The sky's multiple scattering table (see sky_common.hlsli), after Hillaire: at each height and mu of the light, the
// light scattered twice toward the point from every direction, with the phase taken as even, and the share of light
// that the air around it scatters back. Each further order scatters that share again, so the orders sum to the second
// over one minus the share.
#include "sky_common.hlsli"

static const uint SQRT_DIRECTIONS = 8;
static const uint STEPS = 20;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= MULTISCATTER_SIZE)) {
		return;
	}
	float2 x = float2(id.xy) / float2(MULTISCATTER_SIZE - 1);
	float mu_light = x.x * 2 - 1;
	float h = max(x.y * atmosphere_height(), 0.001);
	float3 toward = float3(sqrt(saturate(1 - mu_light * mu_light)), mu_light, 0);
	float isotropic = 1 / (4 * SKY_PI);

	float3 second = 0;
	float3 share = 0;
	for (uint i = 0; i < SQRT_DIRECTIONS; i++) {
		for (uint j = 0; j < SQRT_DIRECTIONS; j++) {
			float cos_theta = 1 - 2 * (j + 0.5) / SQRT_DIRECTIONS;
			float sin_theta = sqrt(saturate(1 - cos_theta * cos_theta));
			float phi = 2 * SKY_PI * (i + 0.5) / SQRT_DIRECTIONS;
			float3 d = float3(cos(phi) * sin_theta, cos_theta, sin(phi) * sin_theta);
			float mu = d.y;
			bool ground = hits_ground(h, mu);
			float length = ground ? distance_to_ground(h, mu) : distance_to_top(h, mu);
			float dt = length / STEPS;
			float cos_ray = dot(d, toward);
			float3 transmittance = 1;
			float3 light = 0;
			float3 scattered = 0;
			for (uint s = 0; s < STEPS; s++) {
				float t = (s + 0.5) * dt;
				float h_at = height_along(h, mu, t);
				Medium m = medium_at(h_at);
				float3 scattering = m.rayleigh + m.mie;
				float3 step = exp(-m.extinction * dt);
				float3 integral = (1 - step) / max(m.extinction, 1e-6);
				float3 reaching = light_at(h_at, mu_along(h, t, toward.y, cos_ray, h_at));
				light += transmittance * scattering * reaching * isotropic * integral;
				scattered += transmittance * scattering * integral;
				transmittance *= step;
			}
			if (ground) {
				float mu_ground = mu_along(h, length, toward.y, cos_ray, 0);
				light += transmittance * transmittance_at(0, mu_ground) * saturate(mu_ground) * sky.ground_albedo.rgb / SKY_PI;
			}
			second += light;
			share += scattered;
		}
	}
	float directions = SQRT_DIRECTIONS * SQRT_DIRECTIONS;
	second /= directions;
	share /= directions;
	cn_rw_texture(push.output)[id.xy] = float4(second / max(1 - share, 1e-3), 1);
}
