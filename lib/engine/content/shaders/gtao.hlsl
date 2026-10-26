// Ambient occlusion (see docs/rendering/ambient-occlusion.md#ambient-occlusion): ground-truth ambient occlusion (GTAO, after Jimenez et
// al.) from gtao_depth.hlsl's depth levels and the prepass's normals. Each pixel searches a few slices around the view
// direction for the highest horizon on each side, and integrates the cosine-weighted visible arc between them. It also
// writes how much each of its four neighbors is on its surface, for gtao_denoise.hlsl. After XeGTAO's XeGTAO_MainPass
// and XeGTAO_CalculateEdges (Copyright (C) 2016-2021, Intel Corporation; SPDX-License-Identifier: MIT).
#include "cinnabar.hlsli"

// Matches Ao_Constants in lib/engine/render/ambient_occlusion.odin. The view's axes in the world turn the normals into
// view space. projection holds the camera's x and y scales and its near plane, and view_model the view model's, which
// a pixel whose depth level 0 holds negated uses. levels and level4 are the depth levels. jitter is the camera's, which
// the depth was drawn with. noise_index moves the noise from frame to frame, and is 0 without temporal AA, which would
// average it. slices and steps are the level's search (see GTAO_PARAMS).
struct Constants {
	float4 right;
	float4 up;
	float4 forward;
	float4 projection;
	float4 view_model;
	uint4 levels;
	uint level4;
	uint normals;
	uint output;
	uint edges;
	uint2 size;
	float2 jitter;
	float radius;
	float power;
	uint noise_index;
	uint slices;
	uint steps;
	uint padding0;
	uint padding1;
	uint padding2;
};
CN_PASS_CONSTANTS(Constants, constants);

static const uint LEVELS = 5;
static const float PI = 3.14159265;
static const float HALF_PI = 1.5707963;
// The occluders' weight falls off over this share of the radius, toward its end.
static const float FALLOFF_SHARE = 0.615;
// The search starts this many pixels out, past the pixel's own surface.
static const float MIN_PIXELS = 1.3;
// The search reaches at most this many pixels, so a surface right at the camera does not read the whole screen.
static const float MAX_PIXELS = 256;
// A step this many pixels out reads level log2(pixels) - LEVEL_OFFSET, so each level's texel is a few times smaller
// than the gap between steps.
static const float LEVEL_OFFSET = 3.3;
// The noise's tile, in pixels: a power of two.
static const uint HILBERT_WIDTH = 64;

float3 octahedral(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

// hilbert_index is a pixel's place along a Hilbert curve through its tile. The R2 sequence along the curve spreads the
// noise evenly over the screen.
uint hilbert_index(uint2 p) {
	uint index = 0;
	for (uint level = HILBERT_WIDTH / 2; level > 0; level /= 2) {
		uint region_x = (p.x & level) > 0 ? 1 : 0;
		uint region_y = (p.y & level) > 0 ? 1 : 0;
		index += level * level * ((3 * region_x) ^ region_y);
		if (region_y == 0) {
			if (region_x == 1) {
				p = HILBERT_WIDTH - 1 - p;
			}
			p = p.yx;
		}
	}
	return index;
}

uint level_index(uint level) {
	return level < 4 ? constants.levels[level] : constants.level4;
}

// level_depth is a pixel's view depth from a depth level, negative for the view model. The level differs between the
// threads of a wave.
float level_depth(int2 pixel, uint level) {
	return cn_texture(NonUniformResourceIndex(level_index(level))).Load(int3(pixel >> level, 0)).r;
}

// view_position is the position in view space (x right, y up, z forward) of a point on the screen, in pixels, from its
// view depth and the projection that drew it.
float3 view_position(float2 point_pixels, float z, bool view_model) {
	float2 scale = view_model ? constants.view_model.xy : constants.projection.xy;
	// The depth is the surface's at the point moved by the jitter, so a slope does not seem to bend.
	float2 ndc = float2(point_pixels.x / constants.size.x * 2 - 1, 1 - point_pixels.y / constants.size.y * 2) - constants.jitter;
	return float3(ndc / scale * z, z);
}

// edges is how much each neighbor, left, right, top and bottom, is on the pixel's surface, from 0 to 1. A neighbor
// counts by its depth's difference from the pixel's, or from the plane through the pixel and the opposite neighbor if
// that is smaller, so a slope is not an edge. The view model and the world are never on one surface.
float4 edges(int2 pixel, float center) {
	int2 last = int2(constants.size) - 1;
	float4 z = float4(
		level_depth(clamp(pixel + int2(-1, 0), 0, last), 0),
		level_depth(clamp(pixel + int2(1, 0), 0, last), 0),
		level_depth(clamp(pixel + int2(0, -1), 0, last), 0),
		level_depth(clamp(pixel + int2(0, 1), 0, last), 0));
	bool4 other = (z < 0) != (center < 0);
	float c = abs(center);
	float4 difference = abs(z) - c;
	float slope_x = (difference.y - difference.x) * 0.5;
	float slope_y = (difference.w - difference.z) * 0.5;
	float4 along_slope = difference + float4(slope_x, -slope_x, slope_y, -slope_y);
	float4 e = saturate(1.25 - min(abs(difference), abs(along_slope)) / (c * 0.011));
	return select(other, float4(0, 0, 0, 0), e);
}

// pack_edges matches unpack_edges in gtao_denoise.hlsl: two bits for each, in an R8_Unorm.
float pack_edges(float4 e) {
	uint4 q = uint4(round(saturate(e) * 2.9));
	return float((q.x << 6) | (q.y << 4) | (q.z << 2) | q.w) / 255.0;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	float center = level_depth(pixel, 0);
	cn_rw_texture(constants.edges)[pixel] = pack_edges(edges(pixel, center));
	bool view_model = center < 0;
	float z = abs(center);
	float near = view_model ? constants.view_model.z : constants.projection.z;
	// The background is at the depth of a cleared pixel, near / 1e-7, and nothing occludes it.
	if (z >= near * 1e7 * 0.5) {
		cn_rw_texture(constants.output)[pixel] = 1;
		return;
	}
	float3 position = view_position(float2(pixel) + 0.5, z, view_model);
	float3 world_normal = octahedral(cn_texture(constants.normals).Load(int3(pixel, 0)).xy);
	float3 normal = normalize(float3(dot(world_normal, constants.right.xyz), dot(world_normal, constants.up.xyz), dot(world_normal, constants.forward.xyz)));
	float3 view = normalize(-position);

	// The radius in pixels at this depth: a pixel spans 2 z / (height * scale.y) meters.
	float scale = view_model ? constants.view_model.y : constants.projection.y;
	float full_pixels = constants.radius * constants.size.y * scale / (2 * z);
	float pixels = min(full_pixels, MAX_PIXELS);
	if (pixels < MIN_PIXELS) {
		cn_rw_texture(constants.output)[pixel] = 1;
		return;
	}
	// Where MAX_PIXELS cuts the search short, the radius shrinks with it, so the occluders still fade out by the
	// search's end and the occlusion does not stop at a hard edge.
	float radius = constants.radius * pixels / full_pixels;
	float falloff_range = FALLOFF_SHARE * radius;
	float falloff_mul = -1 / falloff_range;
	float falloff_add = (radius - falloff_range) / falloff_range + 1;
	float min_step = MIN_PIXELS / pixels;

	// One point of the R2 sequence gives the slices' angle and the steps' offset, at the pixel's place along the
	// Hilbert curve, so the two are independent and spread evenly over the screen. With temporal AA, every frame moves
	// it 288 places, which temporal AA averages.
	uint noise = hilbert_index(uint2(pixel) % HILBERT_WIDTH) + 288 * constants.noise_index;
	float2 noise_sample = frac(0.5 + float(noise) * float2(0.7548777, 0.5698403));
	float slice_noise = noise_sample.x;
	float step_noise = noise_sample.y;

	int2 last = int2(constants.size) - 1;
	float visibility = 0;
	// The slices turn evenly around the view direction, not around the screen's axis, which off the screen's center
	// would weigh some directions more and make an open plane look occluded or brighter than open.
	float3 across = normalize(cross(float3(0, 1, 0), view));
	float3 along = cross(view, across);
	float2 projection_scale = view_model ? constants.view_model.xy : constants.projection.xy;
	uint slices = constants.slices;
	uint steps = constants.steps;
	[loop] for (uint slice = 0; slice < slices; slice++) {
		float phi = (slice + slice_noise) / slices * PI;
		float3 ortho = cos(phi) * across + sin(phi) * along;
		// The slice's direction on the screen: how its direction moves the point's projection. The screen's y goes
		// down, view space's up.
		float2 moved = projection_scale * (ortho.xy * position.z - position.xy * ortho.z);
		float2 omega = normalize(float2(moved.x * constants.size.x, -moved.y * constants.size.y)) * pixels;
		float3 axis = normalize(cross(ortho, view));
		float3 projected = normal - axis * dot(normal, axis);
		float projected_length = length(projected);
		float sign_n = dot(ortho, projected) >= 0 ? 1 : -1;
		float cos_n = saturate(dot(projected, view) / max(projected_length, 1e-5));
		float n = sign_n * acos(cos_n);
		float low0 = cos(n + HALF_PI);
		float low1 = cos(n - HALF_PI);
		float horizon0 = low0;
		float horizon1 = low1;
		[loop] for (uint step = 0; step < steps; step++) {
			float s = (step + frac(step_noise + (slice + step * steps) * 0.618034)) / steps;
			s = s * s + min_step;
			int2 offset = int2(round(omega * s));
			uint level = uint(clamp(round(log2(length(float2(offset))) - LEVEL_OFFSET), 0, LEVELS - 1));
			int2 pixel0 = pixel + offset;
			int2 pixel1 = pixel - offset;
			// A step off the screen sees nothing, and neither does a step from the world onto the view model or back:
			// the view model is not where it seems to be, so it occludes only itself.
			if (all(pixel0 >= 0) && all(pixel0 <= last)) {
				float sample_z = level_depth(pixel0, level);
				float3 delta = view_position(float2(pixel0) + 0.5, abs(sample_z), sample_z < 0) - position;
				float distance = length(delta);
				float weight = saturate(distance * falloff_mul + falloff_add);
				weight = (sample_z < 0) == view_model ? weight : 0;
				horizon0 = max(horizon0, lerp(low0, dot(delta / distance, view), weight));
			}
			if (all(pixel1 >= 0) && all(pixel1 <= last)) {
				float sample_z = level_depth(pixel1, level);
				float3 delta = view_position(float2(pixel1) + 0.5, abs(sample_z), sample_z < 0) - position;
				float distance = length(delta);
				float weight = saturate(distance * falloff_mul + falloff_add);
				weight = (sample_z < 0) == view_model ? weight : 0;
				horizon1 = max(horizon1, lerp(low1, dot(delta / distance, view), weight));
			}
		}
		// The visible arc between the two horizons, each at most a quarter turn from the normal, cosine-weighted.
		projected_length = lerp(projected_length, 1, 0.05);
		float h0 = -acos(clamp(horizon1, -1, 1));
		float h1 = acos(clamp(horizon0, -1, 1));
		h0 = n + clamp(h0 - n, -HALF_PI, HALF_PI);
		h1 = n + clamp(h1 - n, -HALF_PI, HALF_PI);
		float arc0 = (cos_n + 2 * h0 * sin(n) - cos(2 * h0 - n)) / 4;
		float arc1 = (cos_n + 2 * h1 * sin(n) - cos(2 * h1 - n)) / 4;
		visibility += projected_length * (arc0 + arc1);
	}
	// A pixel's estimate is noisy around the true value, above 1 too, so it is not clamped until the forward pass reads
	// the denoised result; clamping each one first would darken every open surface.
	visibility = max(pow(max(visibility / slices, 0), constants.power), 0.03);
	cn_rw_texture(constants.output)[pixel] = visibility;
}
