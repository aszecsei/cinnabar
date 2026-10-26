// What the ambient occlusion's searches share (see docs/rendering/ambient-occlusion.md#ambient-occlusion): gtao.hlsl, hbao.hlsl
// and ssao.hlsl each read gtao_depth.hlsl's depth levels and the prepass's normals, find a pixel's occlusion within
// the radius, and write it with the edges between surfaces for gtao_denoise.hlsl. Only the search between ao_begin
// and ao_end differs. After XeGTAO's XeGTAO_MainPass and XeGTAO_CalculateEdges (Copyright (C) 2016-2021, Intel
// Corporation; SPDX-License-Identifier: MIT).
#ifndef AO_COMMON_HLSLI
#define AO_COMMON_HLSLI

#include "cinnabar.hlsli"

// Matches Ao_Constants in lib/engine/render/ambient_occlusion.odin. The view's axes in the world turn the normals into
// view space. projection holds the camera's x and y scales and its near plane, and view_model the view model's, which
// a pixel whose depth level 0 holds negated uses. levels and level4 are the depth levels. jitter is the camera's, which
// the depth was drawn with. noise_index moves the noise from frame to frame, and is 0 without temporal AA, which would
// average it. samples and steps are the level's search (see Ao_Params): GTAO's slices, HBAO's directions or SSAO's
// samples, and the steps of each slice or direction, which SSAO does not use.
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
	uint samples;
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

// level_at is the depth level that a step this many pixels out reads.
uint level_at(float pixels) {
	return uint(clamp(round(log2(pixels) - LEVEL_OFFSET), 0, LEVELS - 1));
}

// view_position is the position in view space (x right, y up, z forward) of a point on the screen, in pixels, from its
// view depth and the projection that drew it.
float3 view_position(float2 point_pixels, float z, bool view_model) {
	float2 scale = view_model ? constants.view_model.xy : constants.projection.xy;
	// The depth is the surface's at the point moved by the jitter, so a slope does not seem to bend.
	float2 ndc = float2(point_pixels.x / constants.size.x * 2 - 1, 1 - point_pixels.y / constants.size.y * 2) - constants.jitter;
	return float3(ndc / scale * z, z);
}

// screen_pixels is where a position in view space is on the screen, in pixels: view_position's inverse.
float2 screen_pixels(float3 position, bool view_model) {
	float2 scale = view_model ? constants.view_model.xy : constants.projection.xy;
	float2 ndc = position.xy * scale / position.z + constants.jitter;
	return float2((ndc.x + 1) * 0.5 * constants.size.x, (1 - ndc.y) * 0.5 * constants.size.y);
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

// Ao_Pixel is what a search knows of its pixel, in view space.
struct Ao_Pixel {
	int2 pixel;
	bool view_model;
	float3 position;
	float3 normal;
	// Toward the camera.
	float3 view;
	// The search's reach in pixels, at most MAX_PIXELS, and the radius in meters, which shrinks with it: where
	// MAX_PIXELS cuts the search short, the occluders still fade out by the search's end, and the occlusion does not
	// stop at a hard edge.
	float pixels;
	float radius;
	// One point of the R2 sequence, at the pixel's place along the Hilbert curve, so its two dimensions are independent
	// and spread evenly over the screen. With temporal AA, every frame moves it 288 places, which temporal AA averages.
	float2 noise;
};

// ao_begin writes a pixel's edges, and readies its search. Where nothing can occlude it, the background or a surface
// so far that the radius is under MIN_PIXELS, it writes no occlusion and returns false.
bool ao_begin(uint3 id, out Ao_Pixel p) {
	p = (Ao_Pixel)0;
	if (any(id.xy >= constants.size)) {
		return false;
	}
	p.pixel = int2(id.xy);
	float center = level_depth(p.pixel, 0);
	cn_rw_texture(constants.edges)[p.pixel] = pack_edges(edges(p.pixel, center));
	p.view_model = center < 0;
	float z = abs(center);
	float near = p.view_model ? constants.view_model.z : constants.projection.z;
	// The background is at the depth of a cleared pixel, near / 1e-7, and nothing occludes it.
	if (z >= near * 1e7 * 0.5) {
		cn_rw_texture(constants.output)[p.pixel] = 1;
		return false;
	}
	p.position = view_position(float2(p.pixel) + 0.5, z, p.view_model);
	float3 world_normal = octahedral(cn_texture(constants.normals).Load(int3(p.pixel, 0)).xy);
	p.normal = normalize(float3(dot(world_normal, constants.right.xyz), dot(world_normal, constants.up.xyz), dot(world_normal, constants.forward.xyz)));
	p.view = normalize(-p.position);

	// The radius in pixels at this depth: a pixel spans 2 z / (height * scale.y) meters.
	float scale = p.view_model ? constants.view_model.y : constants.projection.y;
	float full_pixels = constants.radius * constants.size.y * scale / (2 * z);
	p.pixels = min(full_pixels, MAX_PIXELS);
	if (p.pixels < MIN_PIXELS) {
		cn_rw_texture(constants.output)[p.pixel] = 1;
		return false;
	}
	p.radius = constants.radius * p.pixels / full_pixels;
	uint noise = hilbert_index(uint2(p.pixel) % HILBERT_WIDTH) + 288 * constants.noise_index;
	p.noise = frac(0.5 + float(noise) * float2(0.7548777, 0.5698403));
	return true;
}

// ao_falloff is how much an occluder at a distance counts: whole within the radius's first share, falling to none at
// its end.
float ao_falloff(Ao_Pixel p, float distance) {
	return saturate((p.radius - distance) / (FALLOFF_SHARE * p.radius));
}

// ao_sample is the surface at a pixel that a step reads, at a level, in view space. It is false off the screen, and
// from the world onto the view model or back: the view model is not where it seems to be, so it occludes only itself.
bool ao_sample(Ao_Pixel p, int2 pixel, uint level, out float3 position) {
	position = 0;
	if (any(pixel < 0) || any(pixel > int2(constants.size) - 1)) {
		return false;
	}
	float z = level_depth(pixel, level);
	if ((z < 0) != p.view_model) {
		return false;
	}
	position = view_position(float2(pixel) + 0.5, abs(z), p.view_model);
	return true;
}

// ao_end writes a pixel's visibility, raised to the power. A pixel's estimate is noisy around the true value, above 1
// too, so it is not clamped until the forward pass reads the denoised result; clamping each one first would darken
// every open surface.
void ao_end(Ao_Pixel p, float visibility) {
	cn_rw_texture(constants.output)[p.pixel] = max(pow(max(visibility, 0), constants.power), 0.03);
}

#endif
