// The sky over the background (see docs/rendering/sky.md#sky): where nothing drew, the light from the sky view table,
// and above the horizon the sun's and the moon's discs and the stars, dimmed by the air in front of them, pre-exposed.
#include "sky_common.hlsli"

// The stars are at most one in each cell of a grid over each face of a cube around the camera.
static const float STAR_CELLS = 128;
// Keeps the brightest disc within the scene's format.
static const float MAX_SCENE = 60000;

uint hash(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352d;
	x ^= x >> 15;
	x *= 0x846ca68b;
	x ^= x >> 16;
	return x;
}

float random(inout uint seed) {
	seed = hash(seed);
	return (seed >> 8) * (1.0 / 16777216.0);
}

// The share of a pixel that a disc of an angular radius covers, at an angle from its middle.
float coverage(float angle, float radius, float pixel) {
	return saturate((radius - angle) / pixel + 0.5);
}

float3 sun_disc(float3 d, float pixel) {
	float radius = sky.sun_illuminance.w;
	float cos_angle = dot(d, sky.sun_direction.xyz);
	if (radius <= 0 || cos_angle < cos(radius + pixel)) {
		return 0;
	}
	float angle = acos(saturate(cos_angle));
	// Limb darkening: the disc's edge is the sun's air seen at a slant.
	float x = saturate(angle / radius);
	float limb = 1 - 0.6 * (1 - sqrt(1 - x * x));
	return sky.sun_illuminance.rgb / (SKY_PI * radius * radius) * limb * coverage(angle, radius, pixel);
}

float value_noise(float3 p) {
	float3 cell = floor(p);
	float3 f = p - cell;
	f = f * f * (3 - 2 * f);
	float result = 0;
	for (uint i = 0; i < 8; i++) {
		float3 corner = float3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
		int3 c = int3(cell + corner);
		uint seed = hash(uint(c.x) * 73856093u ^ uint(c.y) * 19349663u ^ uint(c.z) * 83492791u);
		float3 w = lerp(1 - f, f, corner);
		result += random(seed) * w.x * w.y * w.z;
	}
	return result;
}

// The moon is a sphere that the sun lights, so its phase follows the angle between them, with darker seas.
float3 moon_disc(float3 d, float pixel) {
	float radius = sky.moon_illuminance.w;
	float3 m = sky.moon_direction.xyz;
	float cos_angle = dot(d, m);
	if (radius <= 0 || all(sky.moon_illuminance.rgb <= 0) || cos_angle < cos(radius + pixel)) {
		return 0;
	}
	float angle = acos(saturate(cos_angle));
	float3 side = normalize(abs(m.y) < 0.99 ? cross(float3(0, 1, 0), m) : cross(float3(1, 0, 0), m));
	float3 top = cross(m, side);
	float3 offset = d - m * cos_angle;
	float2 xy = float2(dot(offset, side), dot(offset, top)) / max(sin(radius), 1e-6);
	float3 normal = side * xy.x + top * xy.y - m * sqrt(saturate(1 - dot(xy, xy)));
	float lit = saturate(dot(normal, sky.sun_direction.xyz));
	float seas = 0.7 + 0.3 * value_noise(normal * 4 + 11.3);
	// A lit sphere's light averages two thirds of its middle's over its disc.
	return sky.moon_illuminance.rgb / (SKY_PI * radius * radius) * 1.5 * lit * seas * coverage(angle, radius, pixel);
}

float3 stars(float3 d, float pixel) {
	float intensity = sky.ground_albedo.w;
	if (intensity <= 0 || sky.star_density <= 0) {
		return 0;
	}
	float3 a = abs(d);
	float2 face_uv;
	uint face;
	if (a.x >= a.y && a.x >= a.z) {
		face_uv = d.yz / a.x;
		face = d.x > 0 ? 0 : 1;
	} else if (a.y >= a.z) {
		face_uv = d.xz / a.y;
		face = d.y > 0 ? 2 : 3;
	} else {
		face_uv = d.xy / a.z;
		face = d.z > 0 ? 4 : 5;
	}
	float2 grid = (face_uv * 0.5 + 0.5) * STAR_CELLS;
	uint2 cell = uint2(min(grid, STAR_CELLS - 1));
	uint seed = hash(cell.x + hash(cell.y + hash(face)));
	if (random(seed) > sky.star_density) {
		return 0;
	}
	float2 middle = float2(cell) + 0.2 + 0.6 * float2(random(seed), random(seed));
	float brightness = pow(random(seed), 6);
	float warmth = random(seed);
	// A face's grid spans about two radians, so a cell is about 2 / STAR_CELLS of one, and a star a pixel wide.
	float width = max(pixel * STAR_CELLS * 0.5, 0.05);
	float2 offset = (grid - middle) / width;
	float3 tint = lerp(float3(0.75, 0.85, 1), float3(1, 0.85, 0.65), warmth);
	return intensity * brightness * tint * exp(-2 * dot(offset, offset));
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= sky.size) || cn_texture(push.depth).Load(int3(id.xy, 0)).r > 0) {
		return;
	}
	float2 ndc = (float2(id.xy) + 0.5) / float2(sky.size) * float2(2, -2) + float2(-1, 1);
	float3 d = normalize(sky.right.xyz * (ndc.x / sky.right.w) + sky.up.xyz * (ndc.y / sky.up.w) + sky.forward.xyz);
	float h = sky.heights.x;
	float3 light = cn_texture(push.view).SampleLevel(cn_sampler(push.sampler_index), sky_view_uv(d, h), 0).rgb;
	if (!hits_ground(h, d.y)) {
		// The angle that a pixel spans.
		float pixel = 2 / (sky.up.w * sky.size.y);
		light += transmittance_at(h, d.y) * (sun_disc(d, pixel) + moon_disc(d, pixel) + stars(d, pixel));
	}
	float exposure = cn_buffer(push.exposure).Load<float>(0);
	cn_rw_texture(push.output)[id.xy] = float4(min(light * exposure, MAX_SCENE), 1);
}
