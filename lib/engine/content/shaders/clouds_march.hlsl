// The clouds' ray march (see docs/rendering/clouds.md#lighting): a thread for each texel of the cloud buffer, a block
// of divisor x divisor pixels. It marches the block's center ray through the low layer's shell between the camera and
// the block's farthest surface, lights each sample by the sun, through a light march toward it, and by the sky's
// ambient light, adds the cirrus layer's thin sheet, and writes the light scattered toward the camera, not
// pre-exposed, with the transmittance in a, and the mean distance of what it hit with the block's depth.
#include "blue_noise.hlsli"
#include "clouds_common.hlsli"

// The march's step is at least the layer's thickness over this, so a short segment is not oversampled; a long one is
// the segment over the level's steps, so the budget always reaches its end.
static const float FINE_STEPS = 64;
// After this many empty samples in a row the march doubles its step, until it finds cloud again.
static const uint EMPTY_SAMPLES = 3;
// The march stops behind this much cloud.
static const float MIN_TRANSMITTANCE = 0.01;

uint hash(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352d;
	x ^= x >> 15;
	x *= 0x846ca68b;
	x ^= x >> 16;
	return x;
}

// jitter is where in its first step the march starts: the blue noise's value at the texel in the frame's slice, or a
// hash of them until the noise is resident.
float jitter(uint2 texel) {
	if (clouds.blue_noise != 0) {
		return blue_noise(clouds.blue_noise, texel, clouds.frame).x;
	}
	return (hash(texel.x + hash(texel.y + hash(clouds.frame))) >> 8) * (1.0 / 16777216.0);
}

// block_depth is the block's scene depth: the farthest of its pixels', or 0 when any pixel shows the sky.
float block_depth(uint2 texel) {
	Texture2D<float4> depth = cn_texture(push.depth);
	uint2 first = texel * clouds.divisor;
	uint2 last = min(first + clouds.divisor, uint2(clouds.screen_size)) ;
	float result = 1;
	for (uint y = first.y; y < last.y; y++) {
		for (uint x = first.x; x < last.x; x++) {
			float z = depth.Load(int3(x, y, 0)).r;
			if (z <= 0) {
				return 0;
			}
			result = min(result, z);
		}
	}
	return result;
}

// albedo is the share of the light that a cloud scatters: rain darkens it.
float albedo(float precipitation) {
	return lerp(0.95, 0.8, precipitation);
}

// sun_light is the sun's light scattered toward the camera at a sample: a light march toward the sun through the cheap
// density in steps that double, then the multiple scattering octaves of its optical depth, each with its own phase, and
// the powder effect, which darkens the creases of a front-lit cloud.
float3 sun_light(float3 p, float h, float t, float mu_sun) {
	float3 to_sun = clouds.sun_direction.xyz;
	float reach = min((clouds.top - h) / max(to_sun.y, 0.1), LIGHT_REACH_MAX);
	float step_l = reach / (exp2(float(clouds.light_steps)) - 1);
	float od = 0;
	float s = 0;
	for (uint i = 0; i < clouds.light_steps; i++) {
		float ds = step_l * exp2(float(i));
		float middle = s + ds * 0.5;
		od += cheap_sigma(p + to_sun * middle, h + to_sun.y * middle, t) * ds;
		s += ds;
	}
	float3 sun = 0;
	float a = 1;
	[unroll] for (uint o = 0; o < SCATTER_OCTAVES; o++) {
		sun += a * cloud_phase(mu_sun, a) * exp(-a * od);
		a *= SCATTER_ATTENUATION;
	}
	float front_lit = saturate(-mu_sun * 0.5 + 0.5);
	float powder = lerp(1, 1 - exp(-2 * od), front_lit);
	return sun * powder * clouds.sun_illuminance.rgb;
}

// The share of the sky's ambient light at the bottom of the layer, and the height fraction from which it is whole.
static const float AMBIENT_BOTTOM = 0.35;
static const float AMBIENT_WHOLE = 0.3;

// ambient_light_at is the sky's light at a sample: AMBIENT_BOTTOM of it at the bottom of the layer, whole from
// AMBIENT_WHOLE of its height, and darker in rain.
float3 ambient_light_at(float hf, float precipitation) {
	return ambient_average(clouds.ambient) * lerp(AMBIENT_BOTTOM, 1, pow(saturate(hf / AMBIENT_WHOLE), 0.8)) * lerp(1, 0.6, precipitation);
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= clouds.size)) {
		return;
	}
	RWTexture2D<float4> current = cn_rw_texture(push.current);
	RWTexture2D<float4> distances = cn_rw_texture(push.distance);
	float3 d = cloud_direction(id.xy);
	float mu = d.y;
	float h0 = clouds.camera_height;
	float R = clouds.planet_radius;
	float depth = block_depth(id.xy);
	float scene_distance = depth > 0 ? (clouds.near / depth) / max(dot(d, clouds.forward.xyz), 1e-3) : CLOUD_MAX_DISTANCE * 10;
	float reach = min(scene_distance, CLOUD_MAX_DISTANCE);
	float ground;
	bool hits_ground = cloud_ground(h0, mu, R, ground);
	if (hits_ground) {
		reach = min(reach, ground);
	}
	bool has_sun = clouds.sun_direction.w != 0;
	float mu_sun = dot(d, clouds.sun_direction.xyz);

	float3 scattering = 0;
	float T = 1;
	float mean_t = 0;
	float mean = reach;
	bool hit = false;
	float t0, t1;
	if (cloud_shell(h0, mu, clouds.bottom, clouds.top, R, t0, t1) && t0 < reach) {
		t1 = min(t1, reach);
		float thickness = clouds.top - clouds.bottom;
		float step = max((t1 - t0) / float(clouds.steps), thickness / FINE_STEPS);
		float t = t0 + jitter(id.xy) * step;
		uint empty = 0;
		bool coarse = false;
		for (uint i = 0; i < clouds.steps && t <= t1; i++) {
			float dt = coarse ? 2 * step : step;
			float3 p = d * t;
			float h = height_at(h0, mu, t, R);
			float hf = saturate((h - clouds.bottom) / thickness);
			Cloud_Weather w = weather_at(p, t);
			float base = 0;
			float3 q = noise_position(p, h);
			if (w.coverage > 0.005) {
				base = cloud_base(q, hf, anvil_coverage(w.coverage, hf, w.type), w.type);
			}
			if (base <= 0.01) {
				empty++;
				if (empty >= EMPTY_SAMPLES) {
					coarse = true;
				}
				t += dt;
				continue;
			}
			if (coarse) {
				// Back to the fine step, from the sample before this one.
				coarse = false;
				empty = 0;
				t -= step;
				continue;
			}
			empty = 0;
			float density = w.far < 1 ? cloud_detail(q, hf, base, w.far) : base;
			float sigma = cloud_sigma(density, w.precipitation, t);
			if (sigma > 0) {
				float3 light = ambient_light_at(hf, w.precipitation);
				if (has_sun) {
					light += sun_light(p, h, t, mu_sun);
				}
				light *= albedo(w.precipitation);
				float T_step = exp(-sigma * dt);
				float share = T * (1 - T_step);
				scattering += light * share;
				mean_t += t * share;
				T *= T_step;
				hit = true;
				if (T < MIN_TRANSMITTANCE) {
					break;
				}
			}
			t += dt;
		}
		if (hit && T < 1) {
			mean = mean_t / (1 - T);
		} else {
			mean = t1;
		}
	}

	// The cirrus: a thin sheet at its height, stretched along the wind.
	if (clouds.cirrus > 0) {
		float tc = 0;
		bool reaches = false;
		if (h0 < clouds.cirrus_height) {
			tc = sphere_above(h0, mu, clouds.cirrus_height, R);
			reaches = true;
		} else {
			float far_t;
			reaches = sphere_below(h0, mu, clouds.cirrus_height, R, tc, far_t);
		}
		if (reaches && tc >= 0 && tc <= reach) {
			float3 pc = d * tc;
			float3 qc = noise_position(pc, clouds.cirrus_height);
			// In the wind's frame, with the offset reduced there, so a wrap moves the lookup by whole periods.
			float2 along_axis = clouds.wind_direction;
			float2 across_axis = float2(-along_axis.y, along_axis.x);
			float along = (dot(pc.xz, along_axis) + clouds.cirrus_offset.x) / CIRRUS_STRETCH;
			float across = dot(pc.xz, across_axis) + clouds.cirrus_offset.y;
			float2 curl = (cn_texture(clouds.curl).SampleLevel(cn_sampler(clouds.noise_sampler), qc.xz / CLOUD_CURL_PERIOD, 0).rg * 2 - 1) * CLOUD_CURL_STRENGTH;
			float n = cn_texture3d(clouds.shape).SampleLevel(cn_sampler(clouds.noise_sampler), float3((along + curl.x) / CIRRUS_PERIOD, 0.37, (across + curl.y) / CIRRUS_PERIOD), 0).r;
			float od_c = clouds.cirrus * CIRRUS_OPTICAL_DEPTH * saturate(remap(n, 1 - clouds.cirrus, 1, 0, 1)) * clouds.density * (1 - smoothstep(CLOUD_FADE_START, CLOUD_MAX_DISTANCE, tc));
			float T_c = exp(-od_c);
			float3 L_c = (clouds.cirrus_illuminance.rgb * hg_phase(mu_sun, 0.7) * 2 + ambient_average(clouds.ambient) * 0.5) * (1 - T_c) * 0.9;
			scattering += T * L_c;
			T *= T_c;
			if (!hit && od_c > 0) {
				mean = tc;
			}
		}
	}
	current[id.xy] = float4(scattering, T);
	distances[id.xy] = float4(mean, depth, 0, 0);
}
