// The depth of field (see docs/rendering/post-processing.md#depth-of-field), in four modes: the setup halves the scene
// with each pixel's circle of confusion, the tiles take the largest near circle in each tile, the gather blurs the
// half-size scene by its taps' circles, and the composite blends the blur into the scene.
//
// A tap counts where its own circle reaches the pixel, so a sharp surface in front of a blurred background does not
// spread over it, and a tap behind the pixel reaches no further than the pixel's own circle, so a blurred background
// does not spread over a sharp surface in front of it: neither leaves a halo. A blurred surface in front spreads over
// what is behind it, which the near tiles let the gather reach.
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
	uint padding;
};
CN_PASS_CONSTANTS(Constants, constants);

static const uint DOF_SETUP = 0;
static const uint DOF_TILES = 1;
static const uint DOF_GATHER = 2;
static const uint DOF_COMPOSITE = 3;

// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;
static const float PI = 3.14159265;
static const float GOLDEN_ANGLE = 2.39996323;

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

// gather blurs a half-size pixel: rgb is the blur, and a the share of it that a blurrier surface in front spreads over
// the pixel, which the composite takes whatever the pixel's own circle.
void gather(uint2 id) {
	Texture2D<float4> half_scene = cn_texture(constants.half_scene);
	Texture2D<float4> half_depth = cn_texture(constants.half_depth);
	Texture2D<float4> near_tiles = cn_texture(constants.tiles);
	float4 center = half_scene.Load(int3(id, 0));
	float center_coc = abs(center.a);
	float center_z = half_depth.Load(int3(id, 0)).r;
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
		cn_rw_texture(constants.blur)[id] = float4(center.rgb, 0);
		return;
	}
	float center_weight = highlight(center.rgb);
	float3 sum = center.rgb * center_weight;
	float total = center_weight;
	float spread = 0;
	for (uint i = 0; i < constants.taps; i++) {
		float2 offset = tap_offset(i) * radius;
		int2 pixel = clamp(int2(floor(float2(id) + offset + 0.5)), 0, int2(constants.half_size) - 1);
		float4 tap = half_scene.Load(int3(pixel, 0));
		float tap_z = half_depth.Load(int3(pixel, 0)).r;
		float reach = abs(tap.a);
		bool behind = tap_z > center_z;
		if (behind) {
			reach = min(reach, center_coc);
		}
		float w = saturate(reach - length(offset) + 1) * highlight(tap.rgb);
		sum += tap.rgb * w;
		total += w;
		if (!behind && reach > center_coc + 1) {
			spread += w;
		}
	}
	cn_rw_texture(constants.blur)[id] = float4(sum / total, spread / total);
}

// composite blends a scene pixel toward the blur, read with a 3x3 tent of bilinear taps, by its own circle and by the
// near blur that spreads over it.
void composite(uint2 id) {
	float3 color = cn_texture(constants.scene).Load(int3(id, 0)).rgb;
	float z;
	float c = abs(pixel_coc(int2(id), z));
	Texture2D<float4> blur = cn_texture(constants.blur);
	SamplerState s = cn_sampler(constants.sampler_index);
	float2 uv = (float2(id) + 0.5) / float2(constants.size);
	float2 t = 0.5 / float2(constants.half_size);
	float4 blurred = 0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float w = (x == 0 ? 2 : 1) * (y == 0 ? 2 : 1);
			blurred += blur.SampleLevel(s, uv + t * float2(x, y), 0) * w;
		}
	}
	blurred /= 16;
	float amount = max(smoothstep(1, 3, c), saturate(blurred.a));
	cn_rw_texture(constants.output)[id] = float4(lerp(color, blurred.rgb, amount), 1);
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
	default:
		if (all(id.xy < constants.size)) {
			composite(id.xy);
		}
		break;
	}
}
