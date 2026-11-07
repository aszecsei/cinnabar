// The march of a reflection's ray on the screen (see docs/rendering/lighting-and-shadows.md#screen-space-reflections),
// which the screen-space reflections' trace takes for each of its rays, and the traced reflections' for each ray before
// it traces the ray scene. The ray marches the depth pyramid on the screen, where the depth is linear: in front of a
// level's texel, the ray skips to the texel's edge or to the depth that it holds and climbs a level, and behind it the
// ray descends, until it is behind a texel of level 0. It hits there if it is within a thickness of the surface that
// scales with the surface's depth; further behind, it has passed behind the surface, and finds nothing. A hit takes the
// light in last frame's lit scene where the hit point was then, pre-exposed by this frame's exposure, with a weight that
// fades near the screen's edges and is 0 on a surface that faces away.
#ifndef SSR_MARCH_HLSLI
#define SSR_MARCH_HLSLI

#include "ssr_common.hlsli"

// The surface's thickness, as a share of its view depth.
static const float THICKNESS = 0.03;
// How far rays start from their surface, in pixels at its depth, so they do not hit it.
static const float START_PIXELS = 1.5;
// A ray leaves a texel this far past its edge, in pixels, so it lands in the next.
static const float CROSS_PIXELS = 0.01;
// How far past a texel's depth, as a share of the ray, a ray that reaches it moves.
static const float T_PAST = 1e-5;

struct Hit {
	float3 screen;
	bool found;
};

// march follows a ray on the screen, in pixels and depth, from start for t in [0, 1] toward start + delta, for at most
// steps steps.
Hit march(float3 start, float3 delta, uint steps) {
	Hit hit;
	hit.found = false;
	hit.screen = 0;
	uint top = constants.level_count - 1;
	float2 inverse = float2(delta.x != 0 ? 1 / delta.x : 1e30, delta.y != 0 ? 1 / delta.y : 1e30);
	float2 side = float2(delta.x >= 0 ? 1 : 0, delta.y >= 0 ? 1 : 0);
	float2 cross_offset = float2(delta.x >= 0 ? CROSS_PIXELS : -CROSS_PIXELS, delta.y >= 0 ? CROSS_PIXELS : -CROSS_PIXELS);
	// Out of the start's own pixel first.
	float2 first = (floor(start.xy) + side) + cross_offset;
	float t = min((first.x - start.x) * inverse.x, (first.y - start.y) * inverse.y);
	uint level = 0;
	for (uint i = 0; i < steps; i++) {
		if (t >= 1) {
			return hit;
		}
		float3 p = start + delta * t;
		float cell_size = float(1u << level);
		float2 cell = floor(p.xy / cell_size);
		float nearest = cn_texture(level_index(level)).Load(int3(cell, 0)).r;
		float2 edge = (cell + side) * cell_size + cross_offset;
		float2 exits = (edge - start.xy) * inverse;
		float t_cell = min(exits.x, exits.y);
		if (p.z > nearest) {
			// In front of everything under the texel: the ray reaches the nearest depth in the texel, and descends, or
			// leaves it, and climbs.
			float t_depth = delta.z < 0 ? (nearest - start.z) / delta.z : 1e30;
			if (t_depth < t_cell) {
				// Just past the depth, so rounding cannot leave the ray in front of it at the same place.
				t = max(t_depth + T_PAST, t);
				level = level > 0 ? level - 1 : 0;
			} else {
				t = t_cell;
				level = min(level + 1, top);
			}
		} else if (level > 0) {
			level--;
		} else {
			float surface_z = constants.projection.z / max(nearest, 1e-7);
			float ray_z = constants.projection.z / max(p.z, 1e-7);
			hit.found = ray_z - surface_z <= THICKNESS * surface_z;
			hit.screen = p;
			return hit;
		}
	}
	return hit;
}

// pixel_meters is how wide a pixel is at a position relative to the camera, in meters.
float pixel_meters_at(float3 position) {
	return 2 * view_of(position).z / (constants.size.y * constants.projection.y);
}

// screen_ray marches a ray from a pixel's surface at a position, with its normal, along a direction above the surface,
// for steps steps. It gives whether the ray hit a surface on the screen, its distance to the hit, and the hit's light,
// pre-exposed by exposure, with its weight in alpha.
bool screen_ray(float3 position, float3 normal, float3 direction, uint steps, float exposure, out float distance, out float4 light) {
	distance = 0;
	light = 0;
	float3 origin = position + normal * pixel_meters_at(position) * START_PIXELS;
	float3 o = view_of(origin);
	float3 d = view_of(direction);
	// The ray's end, short of the near plane, or far enough that it reaches its vanishing point.
	float reach = d.z < 0 ? 0.99 * (constants.projection.z - o.z) / d.z : 1e4 * o.z;
	float3 start = screen_of(o);
	float3 end = screen_of(o + d * max(reach, 0));
	start.xy *= float2(constants.size);
	end.xy *= float2(constants.size);
	float3 delta = end - start;
	// Only as far as the screen's edge.
	float limit = 1;
	float2 bounds = float2(constants.size);
	if (delta.x != 0) {
		limit = min(limit, ((delta.x > 0 ? bounds.x : 0) - start.x) / delta.x);
	}
	if (delta.y != 0) {
		limit = min(limit, ((delta.y > 0 ? bounds.y : 0) - start.y) / delta.y);
	}
	Hit hit = march(start, delta * max(limit, 0), steps);
	if (!hit.found) {
		return false;
	}
	int2 at = clamp(int2(hit.screen.xy), 0, int2(constants.size) - 1);
	float2 uv = hit.screen.xy / float2(constants.size);
	float3 hit_position = position_at(uv, hit.screen.z);
	distance = length(hit_position - position);
	float weight = edge_weight(uv);
	// A surface that faces away from the ray shows its back, which the lit scene does not have.
	if (dot(normal_at(at), direction) > 0) {
		weight = 0;
	}
	float4 clip = mul(constants.previous, float4(hit_position, 1));
	float2 previous = clip.xy / clip.w * float2(0.5, -0.5) + 0.5;
	if (constants.lit_valid == 0 || clip.w <= 0 || any(previous != saturate(previous))) {
		weight = 0;
	}
	float3 lit = cn_texture(constants.lit).SampleLevel(cn_sampler(constants.sampler_index), previous, 0).rgb;
	light = float4(lit * exposure, weight);
	return true;
}

#endif
