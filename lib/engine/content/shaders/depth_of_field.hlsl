// The depth of field (see docs/rendering/post-processing.md#depth-of-field), in five modes: the setup halves the scene
// with each pixel's circle of confusion, the tiles take the largest near circle in each tile, the gather blurs the
// half-size scene into a near layer and a background, the median filters both, and the composite blends them into the
// scene.
//
// A background tap counts where its own circle reaches the pixel, so a sharp surface in front of a blurred background
// does not spread over it, and a tap behind the pixel reaches no further than the pixel's own circle, so a blurred
// background does not spread over a sharp surface in front of it: neither leaves a halo. A blurred surface in front is
// a layer of its own, over its circle on both sides of its edge, which the near tiles let the gather reach.
#include "cinnabar.hlsli"
#include "view_projection.hlsli"
#include "dof.hlsli"

// Matches Dof_Constants in lib/engine/render/depth_of_field.odin. max_radius is in the scene's pixels; the other sizes
// and radii are in the half size's.
struct Constants {
	float4 projection;
	uint2 size;
	uint2 half_size;
	uint2 tiles_size;
	uint mode;
	uint scene;
	uint depth;
	uint stencil;
	uint half_scene;
	uint half_depth;
	uint tiles;
	uint blur;
	uint output;
	uint sampler_index;
	float coc_scale;
	float focus;
	float max_radius;
	uint taps;
	uint blades;
	float highlights;
	uint tile;
	uint near_layer;
	// The median's results: the background, then the near layer.
	uint2 filtered;
	uint2 padding;
};
CN_PASS_CONSTANTS(Constants, constants);

static const uint DOF_SETUP = 0;
static const uint DOF_TILES = 1;
static const uint DOF_GATHER = 2;
static const uint DOF_COMPOSITE = 3;
static const uint DOF_POSTFILTER = 4;

// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;
static const float PI = 3.14159265;
static const float GOLDEN_ANGLE = 2.39996323;
// A half-size pixel whose circle is this many pixels in front of the focus is in the near layer.
static const float NEAR_MIN = 0.5;

float sqr(float x) {
	return x * x;
}

float luma(float3 c) {
	return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// pixel_coc is a scene pixel's circle of confusion in the scene's pixels, and its view-space z. The view model is
// sharp, and in front of the world.
float pixel_coc(int2 pixel, out float z) {
	pixel = clamp(pixel, 0, int2(constants.size) - 1);
	float depth = cn_texture(constants.depth).Load(int3(pixel, 0)).r;
	z = view_z(constants.projection, depth);
	if ((cn_stencil_texture(constants.stencil).Load(int3(pixel, 0)).g & VIEW_MODEL_STENCIL) != 0) {
		z = constants.projection.z;
		return 0;
	}
	return clamp(coc(constants.coc_scale, constants.focus, z), -constants.max_radius, constants.max_radius);
}

// tap_offset is a gather tap's offset in a unit disk: a Vogel spiral, which spreads any count of taps evenly, pushed
// out to the aperture's polygon when it has blades. The taps are the same every frame, so the blur does not crawl
// without temporal AA.
float2 tap_offset(uint i) {
	float r = sqrt((float(i) + 0.5) / float(constants.taps));
	float angle = float(i) * GOLDEN_ANGLE;
	if (constants.blades >= 3) {
		float sector = 2 * PI / float(constants.blades);
		float within = angle - sector * floor(angle / sector) - sector * 0.5;
		r *= cos(sector * 0.5) / cos(within);
	}
	return r * float2(cos(angle), sin(angle));
}

// highlight is how much a color weighs in the gather: a highlight over white weighs more, so it opens into the
// aperture's shape.
float highlight(float3 color) {
	return 1 + constants.highlights * saturate(luma(color) - 1);
}

// setup writes a half-size pixel from its 2x2 block: the color weighed by each pixel's circle, so a sharp pixel at the
// edge of a blurred surface does not enter the blur, and the circle and the depth of that color, in half-size pixels.
void setup(uint2 id) {
	Texture2D<float4> scene = cn_texture(constants.scene);
	float4 sum = 0;
	float coc_sum = 0;
	float z_sum = 0;
	for (uint k = 0; k < 4; k++) {
		int2 pixel = min(int2(id * 2 + uint2(k & 1, k >> 1)), int2(constants.size) - 1);
		float z;
		float c = pixel_coc(pixel, z) * 0.5;
		float w = abs(c) + 1e-3;
		sum += float4(max(scene.Load(int3(pixel, 0)).rgb, 0), 1) * w;
		coc_sum += c * w;
		z_sum += z * w;
	}
	cn_rw_texture(constants.half_scene)[id] = float4(sum.rgb / sum.w, coc_sum / sum.w);
	cn_rw_texture(constants.half_depth)[id] = z_sum / sum.w;
}

// tiles writes the largest near circle in a tile, in half-size pixels.
void tiles(uint2 id) {
	Texture2D<float4> half_scene = cn_texture(constants.half_scene);
	uint2 first = id * constants.tile;
	uint2 last = min(first + constants.tile, constants.half_size);
	float largest = 0;
	for (uint y = first.y; y < last.y; y++) {
		for (uint x = first.x; x < last.x; x++) {
			largest = max(largest, -half_scene.Load(int3(x, y, 0)).a);
		}
	}
	cn_rw_texture(constants.tiles)[id] = largest;
}

// gather blurs a half-size pixel into two layers. The near layer is the blur of the surfaces in front of the focus,
// with its coverage: each tap stands for its share of the disk, and a near tap spreads its color over its own circle's
// area, so a blurred surface's coverage is a half at its edge, and goes to 1 inside it and to 0 outside it over its
// circle. The background is the blur of the rest, without the near taps: of a far pixel, the taps whose circle reaches
// it, and behind it no further than its own circle; of a near pixel, which hides what is behind it, the background
// that shows around it. blur's a is 1 where the background has a tap, and near's a is the coverage.
void gather(uint2 id) {
	Texture2D<float4> half_scene = cn_texture(constants.half_scene);
	Texture2D<float4> half_depth = cn_texture(constants.half_depth);
	Texture2D<float4> near_tiles = cn_texture(constants.tiles);
	float4 center = half_scene.Load(int3(id, 0));
	float center_coc = abs(center.a);
	float center_z = half_depth.Load(int3(id, 0)).r;
	bool center_near = center.a < -NEAR_MIN;
	int2 tile = int2(id / constants.tile);
	float near = 0;
	for (int ty = -1; ty <= 1; ty++) {
		for (int tx = -1; tx <= 1; tx++) {
			int2 t = clamp(tile + int2(tx, ty), 0, int2(constants.tiles_size) - 1);
			near = max(near, near_tiles.Load(int3(t, 0)).r);
		}
	}
	float radius = min(max(center_coc, near), constants.max_radius * 0.5);
	if (radius < 0.5) {
		cn_rw_texture(constants.blur)[id] = float4(center.rgb, 1);
		cn_rw_texture(constants.near_layer)[id] = 0;
		return;
	}
	float3 far_sum = 0;
	float far_total = 0;
	float3 near_sum = 0;
	float near_total = 0;
	float coverage = 0;
	// The center is a tap at no offset, which reaches it whatever its circle.
	for (uint i = 0; i <= constants.taps; i++) {
		float2 offset = i < constants.taps ? tap_offset(i) * radius : 0;
		float distance = length(offset);
		int2 pixel = clamp(int2(floor(float2(id) + offset + 0.5)), 0, int2(constants.half_size) - 1);
		float4 tap = i < constants.taps ? half_scene.Load(int3(pixel, 0)) : center;
		float tap_z = i < constants.taps ? half_depth.Load(int3(pixel, 0)).r : center_z;
		float reach = abs(tap.a);
		float weight = highlight(tap.rgb);
		if (tap.a < -NEAR_MIN) {
			// A near tap's light is spread over its circle, which the taps cover radius² / reach² times.
			float share = saturate(max(reach, 1) - distance + 1) * min(sqr(radius / max(reach, 1)), float(constants.taps + 1));
			near_sum += tap.rgb * share * weight;
			near_total += share * weight;
			coverage += share;
			continue;
		}
		float w = weight;
		if (!center_near) {
			if (tap_z > center_z) {
				reach = min(reach, center_coc);
			}
			w *= saturate(reach - distance + 1);
		}
		far_sum += tap.rgb * w;
		far_total += w;
	}
	bool background = far_total > 0;
	cn_rw_texture(constants.blur)[id] = float4(background ? far_sum / far_total : center.rgb, background ? 1 : 0);
	float alpha = saturate(coverage / float(constants.taps + 1));
	cn_rw_texture(constants.near_layer)[id] = float4(near_total > 0 ? near_sum / near_total : 0, alpha);
}

// The median of nine values in 20 compare-swaps (McGuire, "A fast, small-radius GPU median filter", ShaderX6), each
// channel on its own.
#define S2(a, b) { float4 t_ = a; a = min(t_, b); b = max(t_, b); }
#define MN3(a, b, c) S2(a, b); S2(a, c);
#define MX3(a, b, c) S2(b, c); S2(a, c);
#define MNMX3(a, b, c) MX3(a, b, c); S2(a, b);
#define MNMX4(a, b, c, d) S2(a, b); S2(c, d); S2(a, c); S2(b, d);
#define MNMX5(a, b, c, d, e) S2(a, b); S2(c, d); MN3(a, c, e); MX3(b, d, e);
#define MNMX6(a, b, c, d, e, f) S2(a, d); S2(b, e); S2(c, f); MN3(a, b, c); MX3(d, e, f);

// median3x3 is the median of a half-size pixel's 3x3 block, which takes out a lone tap's color that the gather's taps
// leave between them, and keeps edges where a blur lowpass would soften them.
float4 median3x3(Texture2D<float4> source, int2 id) {
	int2 last = int2(constants.half_size) - 1;
	float4 v0 = source.Load(int3(clamp(id + int2(-1, -1), 0, last), 0));
	float4 v1 = source.Load(int3(clamp(id + int2(0, -1), 0, last), 0));
	float4 v2 = source.Load(int3(clamp(id + int2(1, -1), 0, last), 0));
	float4 v3 = source.Load(int3(clamp(id + int2(-1, 0), 0, last), 0));
	float4 v4 = source.Load(int3(id, 0));
	float4 v5 = source.Load(int3(clamp(id + int2(1, 0), 0, last), 0));
	float4 v6 = source.Load(int3(clamp(id + int2(-1, 1), 0, last), 0));
	float4 v7 = source.Load(int3(clamp(id + int2(0, 1), 0, last), 0));
	float4 v8 = source.Load(int3(clamp(id + int2(1, 1), 0, last), 0));
	MNMX6(v0, v1, v2, v3, v4, v5);
	MNMX5(v1, v2, v3, v4, v6);
	MNMX4(v2, v3, v4, v7);
	MNMX3(v3, v4, v8);
	return v4;
}

// postfilter writes the median of the background and of the near layer.
void postfilter(uint2 id) {
	cn_rw_texture(constants.filtered.x)[id] = median3x3(cn_texture(constants.blur), int2(id));
	cn_rw_texture(constants.filtered.y)[id] = median3x3(cn_texture(constants.near_layer), int2(id));
}

// tent reads a half-size texture at a scene pixel with a 3x3 tent of bilinear taps.
float4 tent(Texture2D<float4> source, SamplerState s, float2 uv) {
	float2 t = 0.5 / float2(constants.half_size);
	float4 sum = 0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float w = (x == 0 ? 2 : 1) * (y == 0 ? 2 : 1);
			sum += source.SampleLevel(s, uv + t * float2(x, y), 0) * w;
		}
	}
	return sum / 16;
}

// composite blends a scene pixel toward the background's blur by its own circle behind the focus, or takes the
// background that shows around a pixel in front of it, then puts the near layer over that by its coverage.
void composite(uint2 id) {
	float3 color = cn_texture(constants.scene).Load(int3(id, 0)).rgb;
	float z;
	float c = pixel_coc(int2(id), z);
	SamplerState s = cn_sampler(constants.sampler_index);
	float2 uv = (float2(id) + 0.5) / float2(constants.size);
	float4 background = tent(cn_texture(constants.blur), s, uv);
	float4 near_layer = tent(cn_texture(constants.near_layer), s, uv);
	float3 base = c < -2 * NEAR_MIN ? lerp(color, background.rgb, background.a) : lerp(color, background.rgb, smoothstep(1, 3, c));
	cn_rw_texture(constants.output)[id] = float4(lerp(base, near_layer.rgb, saturate(near_layer.a)), 1);
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	switch (constants.mode) {
	case DOF_SETUP:
		if (all(id.xy < constants.half_size)) {
			setup(id.xy);
		}
		break;
	case DOF_TILES:
		if (all(id.xy < constants.tiles_size)) {
			tiles(id.xy);
		}
		break;
	case DOF_GATHER:
		if (all(id.xy < constants.half_size)) {
			gather(id.xy);
		}
		break;
	case DOF_POSTFILTER:
		if (all(id.xy < constants.half_size)) {
			postfilter(id.xy);
		}
		break;
	default:
		if (all(id.xy < constants.size)) {
			composite(id.xy);
		}
		break;
	}
}
