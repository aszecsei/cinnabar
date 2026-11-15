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
// After this many empty samples in a row the march doubles its step at each empty sample, up to EMPTY_MAX_STEPS fine
// steps, until it finds cloud again.
static const uint EMPTY_SAMPLES = 3;
static const float EMPTY_MAX_STEPS = 8;
// The probe away from the sun takes this many samples, whose lengths double, out to at most BACK_REACH meters.
static const uint BACK_STEPS = 4;
static const float BACK_REACH = 1000;
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

// sun_light is the sun's light scattered toward the camera at a sample, before the albedo: a light march toward the sun
// through the expected density (cheap_sigma) in steps that double, a shorter probe away from the sun, and the sun term
// of the two optical depths (cloud_sun_scattering).
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
	// The probe away from the sun, down to the layer's bottom or BACK_REACH.
	float back_reach = min((h - clouds.bottom) / max(to_sun.y, 0.1), BACK_REACH);
	float step_b = back_reach / (exp2(float(BACK_STEPS)) - 1);
	float od_back = 0;
	s = 0;
	[unroll] for (uint j = 0; j < BACK_STEPS; j++) {
		float ds = step_b * exp2(float(j));
		float middle = s + ds * 0.5;
		od_back += cheap_sigma(p - to_sun * middle, h - to_sun.y * middle, t) * ds;
		s += ds;
	}
	return cloud_sun_scattering(od, od_back, mu_sun, to_sun.y) * clouds.sun_illuminance.rgb;
}

// At the bottom of the layer, the share of the upper hemisphere's light that comes down through the cloud, and the
// share of the lower hemisphere's, the ground's; the height fraction from which the light is the upper hemisphere's.
static const float AMBIENT_BOTTOM_SKY = 0.25;
static const float AMBIENT_BOTTOM_GROUND = 0.15;
static const float AMBIENT_WHOLE = 0.3;
// The local coverage from which the light from above turns grey, wholly grey at 1 and at the bottom of the layer.
static const float OVERCAST_START = 0.5;
static const float3 LUMINANCE = float3(0.2126, 0.7152, 0.0722);

// ambient_light_at is the sky's light at a sample. From AMBIENT_WHOLE of the layer's height up, a sample sees the sky
// above it. At the bottom, it sees the ground below it and the sky's light that comes down through the cloud. The
// ambient light leaves the clouds out, so under a high coverage the light from above is more cloud's, not the clear
// sky's, and is grey, the more so the more of the layer is above the sample. Rain darkens it.
float3 ambient_light_at(float hf, float coverage, float precipitation) {
	float3 up = ambient_hemisphere(clouds.ambient, float3(0, 1, 0));
	float3 down = ambient_hemisphere(clouds.ambient, float3(0, -1, 0));
	float3 above = lerp(up, dot(up, LUMINANCE).xxx, smoothstep(OVERCAST_START, 1, coverage) * (1 - hf));
	float3 bottom = AMBIENT_BOTTOM_SKY * above + AMBIENT_BOTTOM_GROUND * down;
	return lerp(bottom, above, pow(saturate(hf / AMBIENT_WHOLE), 0.8)) * lerp(1, 0.6, precipitation);
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
		// The last empty sample, which the march steps back to when a coarse step finds cloud, and where that step found
		// it: the march keeps the fine step until it is past there.
		float last_empty = t;
		float found = -1;
		uint empty = 0;
		bool coarse = false;
		for (uint i = 0; i < clouds.steps && t <= t1; i++) {
			float3 p = d * t;
			float h = height_at(h0, mu, t, R);
			float hf = saturate((h - clouds.bottom) / thickness);
			Cloud_Weather w = weather_at(p, t);
			float base = 0;
			float3 q = noise_position(p, h);
			float coverage = anvil_coverage(w.coverage, hf, w.type);
			if (w.coverage > 0.005) {
				base = cloud_base(q, hf, coverage, w.type);
			}
			if (base <= 0.01) {
				empty++;
				last_empty = t;
				// A whole number of fine steps, so the march stays on the fine steps' grid.
				float grow = empty >= EMPTY_SAMPLES && t > found + 0.5 * step ? min(exp2(float(empty - EMPTY_SAMPLES + 1)), EMPTY_MAX_STEPS) : 1;
				coarse = grow > 1;
				t += step * grow;
				continue;
			}
			if (coarse) {
				// A coarse step found cloud: back to the fine step after the last empty sample.
				coarse = false;
				found = t;
				empty = 0;
				t = last_empty + step;
				continue;
			}
			empty = 0;
			float dt = step;
			float density = w.far < 1 ? cloud_detail(q, hf, base, w.far, coverage) : base;
			float sigma = cloud_sigma(density, w.precipitation, t);
			if (sigma > 0) {
				float3 light = ambient_light_at(hf, w.coverage, w.precipitation);
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
			float3 L_c = (clouds.cirrus_illuminance.rgb * hg_phase(mu_sun, 0.7) * 2 + ambient_hemisphere(clouds.ambient, float3(0, -1, 0)) * 0.5) * (1 - T_c) * 0.9;
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
