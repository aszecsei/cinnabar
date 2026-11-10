// The sun's contact shadows (see docs/rendering/lighting-and-shadows.md#shadows): in a frame whose sun has a shadow map
// and no channel of the traced mask, each pixel marches a short way toward the sun on the screen, through gtao_depth.hlsl's
// depth levels, and is in shadow where a step is behind a surface by less than a thickness. The shadow map's texels are
// too coarse for a foot on a floor or a cup on a table; the march finds those. 1 is lit, 0 in shadow.
#include "cinnabar.hlsli"
#include "view_projection.hlsli"
#include "blue_noise.hlsli"

// Matches Contact_Constants in lib/engine/render/shadows.odin. to_light is the direction toward the sun in view space.
// levels and level4 are the ambient occlusion's depth levels, where the view model's depth is negated. jitter is the
// camera's, which the depth was drawn with. noise and noise_slice are the ambient occlusion's blue noise and its slice.
struct Contact_Constants {
	float4 projection;
	float4 to_light;
	uint4 levels;
	uint level4;
	uint output;
	uint noise;
	uint noise_slice;
	uint2 size;
	float2 jitter;
};
CN_PASS_CONSTANTS(Contact_Constants, constants);

static const uint LEVELS = 5;
// The march's length, in meters, and its steps.
static const float CONTACT_LENGTH = 0.3;
static const uint CONTACT_STEPS = 16;
// A step occludes behind a surface by at most this much, in meters, or two steps' length if that is more, so a step
// that passes behind an object does not shadow from its back.
static const float CONTACT_THICKNESS = 0.05;
// A surface occludes only if it is above the pixel's plane by this share of the pixel's depth, against the depth's
// precision, plus this slope times its distance along the plane, so that the gentle curve of a surface, such as the
// facets of a coarse mesh that its normals shade smooth, does not shadow itself; an object that the surface touches
// rises far more steeply.
static const float CONTACT_BIAS = 0.002;
static const float CONTACT_SLOPE = 1.0;
// The occlusion fades out over this last share of the length, so the shadow does not end in a hard line.
static const float CONTACT_FADE = 0.25;
// The march starts this many pixels at the point's depth off its plane, so its first steps are not on its own surface.
static const float START_PIXELS = 1.5;
// A march shorter than this many pixels finds nothing a shadow map does not.
static const float MIN_PIXELS = 1.3;
// Matches LEVEL_OFFSET in ao_common.hlsli: a step this many pixels out reads level log2(pixels) - LEVEL_OFFSET, where a
// texel stands for the area around it and a thin object in front of a far surface has been filtered out.
static const float LEVEL_OFFSET = 3.3;

// level_depth is a pixel's view depth from a depth level, negative for the view model.
float level_depth(int2 pixel, uint level) {
	uint index = level < 4 ? constants.levels[level] : constants.level4;
	return cn_texture(NonUniformResourceIndex(index)).Load(int3(pixel >> level, 0)).r;
}

// pixel_ndc is the normalized device x and y of a point on the screen, in pixels, where the unjittered projection has
// what the jittered one drew there: the depth is the surface's there.
float2 pixel_ndc(float2 point_pixels) {
	return float2(point_pixels.x / constants.size.x * 2 - 1, 1 - point_pixels.y / constants.size.y * 2) - constants.jitter;
}

// screen_pixels is where a position in view space is on the screen, in pixels: pixel_ndc's inverse.
float2 screen_pixels(float3 position) {
	float2 ndc = view_ndc(constants.projection, position) + constants.jitter;
	return float2((ndc.x + 1) * 0.5 * constants.size.x, (1 - ndc.y) * 0.5 * constants.size.y);
}

// surface_at is the position in view space of the world's surface at a pixel, from level 0. It is false off the
// screen, on the view model and on the background.
bool surface_at(int2 pixel, out float3 position) {
	position = 0;
	if (any(pixel < 0) || any(pixel >= int2(constants.size))) {
		return false;
	}
	float z = level_depth(pixel, 0);
	float4 projection = constants.projection;
	// The background is at the depth of a cleared pixel, near / 1e-7 or an orthographic view's far plane.
	if (z < 0 || (is_orthographic(projection) ? z >= projection.w * 0.9999 : z >= projection.z * 1e7 * 0.5)) {
		return false;
	}
	position = view_position(projection, pixel_ndc(float2(pixel) + 0.5), z);
	return true;
}

// neighbor_delta is the step from a pixel's position to its neighbor's on one axis, toward whichever side is nearer
// the pixel's depth, so an edge does not bend the plane. It is false if neither side has the world's surface.
bool neighbor_delta(int2 pixel, int2 axis, float3 center, out float3 delta) {
	float3 a, b;
	bool has_a = surface_at(pixel + axis, a);
	bool has_b = surface_at(pixel - axis, b);
	delta = 0;
	if (!has_a && !has_b) {
		return false;
	}
	bool use_a = has_a && (!has_b || abs(a.z - center.z) <= abs(b.z - center.z));
	delta = use_a ? a - center : center - b;
	return true;
}

float march(int2 pixel) {
	float3 position;
	// The view model neither casts nor takes contact shadows: its depth is not where it seems to be.
	if (!surface_at(pixel, position)) {
		return 1;
	}
	// The pixel's plane, from its neighbors' depths rather than the prepass's normal, which a normal map tilts.
	float3 dx, dy;
	if (!neighbor_delta(pixel, int2(1, 0), position, dx) || !neighbor_delta(pixel, int2(0, 1), position, dy)) {
		return 1;
	}
	// The screen's y goes down, so dx x dy faces away from the camera.
	float3 normal = normalize(cross(dy, dx));
	float3 to_camera = view_to_camera(constants.projection, position);
	normal = dot(normal, to_camera) < 0 ? -normal : normal;
	float3 to_light = constants.to_light.xyz;
	// A surface that faces away from the sun is in its own shadow, which the light loop gives it.
	if (dot(normal, to_light) <= 0) {
		return 1;
	}
	float pixel_meters = view_pixel_meters(constants.projection, position.z, constants.size.y);
	if (CONTACT_LENGTH < MIN_PIXELS * pixel_meters) {
		return 1;
	}
	float3 origin = position + normal * (pixel_meters * START_PIXELS);
	float2 origin_pixels = float2(pixel) + 0.5;
	float step = CONTACT_LENGTH / CONTACT_STEPS;
	float thickness = max(CONTACT_THICKNESS, 2 * step);
	float offset = blue_noise(constants.noise, uint2(pixel), constants.noise_slice).x;
	float occlusion = 0;
	[loop] for (uint i = 0; i < CONTACT_STEPS; i++) {
		float t = (i + offset) * step;
		float3 p = origin + to_light * t;
		// A step behind the camera's near plane has left the view.
		if (!is_orthographic(constants.projection) && p.z <= constants.projection.z) {
			break;
		}
		float2 at = screen_pixels(p);
		if (any(at < 0) || any(at >= float2(constants.size))) {
			break;
		}
		int2 sample_pixel = int2(at);
		uint level = uint(clamp(round(log2(max(length(at - origin_pixels), 1)) - LEVEL_OFFSET), 0, LEVELS - 1));
		float surface = level_depth(sample_pixel, level);
		// The view model casts no shadow on the world.
		if (surface < 0) {
			continue;
		}
		// The step must be behind the surface by less than the thickness, and the surface above the pixel's plane. A
		// depth bias alone would not do: at a grazing angle one pixel spans far more depth than any bias, while the
		// pixel's own surface stays in its plane.
		float behind = p.z - surface;
		float3 d = view_position(constants.projection, pixel_ndc(float2(sample_pixel) + 0.5), surface) - position;
		float height = dot(d, normal);
		float across = length(d - normal * height);
		if (behind > 0 && behind < thickness && height > across * CONTACT_SLOPE + CONTACT_BIAS * position.z) {
			occlusion = max(occlusion, saturate((CONTACT_LENGTH - t) / (CONTACT_FADE * CONTACT_LENGTH)));
			if (occlusion >= 1) {
				break;
			}
		}
	}
	return 1 - occlusion;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	cn_rw_texture(constants.output)[id.xy] = march(int2(id.xy));
}
