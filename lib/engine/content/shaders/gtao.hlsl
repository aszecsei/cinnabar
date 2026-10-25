// Ambient occlusion (see docs/rendering.md#ambient-occlusion): ground-truth ambient occlusion (GTAO, after Jimenez et
// al. and Intel's XeGTAO) from the prepass's depth and normals. Each pixel searches a few slices around the view
// direction for the highest horizon on each side, and integrates the cosine-weighted visible arc between them. The
// slices' angles and the steps' offsets change from pixel to pixel and from frame to frame, so gtao_denoise.hlsl
// averages them over space and time.
#include "cinnabar.hlsli"

// Matches Ao_Push in lib/engine/render/ambient_occlusion.odin. The view's axes in the world turn the normals into view
// space. projection holds the camera's x and y scales and its near plane, and view_model the view model's, which a
// pixel with the view model's stencil bit uses. jitter is the camera's, which the depth was drawn with.
struct Push {
	float4 right;
	float4 up;
	float4 forward;
	float4 projection;
	float4 view_model;
	uint depth;
	uint stencil;
	uint normals;
	uint output;
	uint2 size;
	float radius;
	float power;
	uint frame;
	float2 jitter;
};
CN_PUSH_CONSTANTS(Push, push);

// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;
static const uint SLICES = 2;
static const uint STEPS = 4;
static const float PI = 3.14159265;
static const float HALF_PI = 1.5707963;
// The occluders' weight falls off over this share of the radius, toward its end.
static const float FALLOFF_SHARE = 0.615;
// The search starts this many pixels out, past the pixel's own surface.
static const float MIN_PIXELS = 1.3;
// The search reaches at most this many pixels, so a surface right at the camera does not read the whole screen.
static const float MAX_PIXELS = 256;

float3 octahedral(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

// interleaved_noise is Jimenez's interleaved gradient noise, in [0, 1).
float interleaved_noise(float2 pixel) {
	return frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715))));
}

// view_position is a pixel's position in view space (x right, y up, z forward), from its depth and the projection
// that drew it, and whether the view model drew it.
float3 view_position(int2 pixel, out bool view_model) {
	float depth = cn_texture(push.depth).Load(int3(pixel, 0)).r;
	view_model = (cn_stencil_texture(push.stencil).Load(int3(pixel, 0)).g & VIEW_MODEL_STENCIL) != 0;
	float3 projection = view_model ? push.view_model.xyz : push.projection.xyz;
	float z = projection.z / max(depth, 1e-7);
	// The depth is the surface's at the pixel's center moved by the jitter, so a slope does not seem to bend.
	float2 ndc = float2((pixel.x + 0.5) / push.size.x * 2 - 1, 1 - (pixel.y + 0.5) / push.size.y * 2) - push.jitter;
	return float3(ndc / projection.xy * z, z);
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	float depth = cn_texture(push.depth).Load(int3(pixel, 0)).r;
	if (depth <= 0) {
		cn_rw_texture(push.output)[pixel] = 1;
		return;
	}
	bool view_model;
	float3 position = view_position(pixel, view_model);
	float z = position.z;
	float3 world_normal = octahedral(cn_texture(push.normals).Load(int3(pixel, 0)).xy);
	float3 normal = normalize(float3(dot(world_normal, push.right.xyz), dot(world_normal, push.up.xyz), dot(world_normal, push.forward.xyz)));
	float3 view = normalize(-position);

	// The radius in pixels at this depth: a pixel spans 2 z / (height * scale.y) meters.
	float scale = view_model ? push.view_model.y : push.projection.y;
	float pixels = min(push.radius * push.size.y * scale / (2 * z), MAX_PIXELS);
	if (pixels < MIN_PIXELS) {
		cn_rw_texture(push.output)[pixel] = 1;
		return;
	}
	float falloff_range = FALLOFF_SHARE * push.radius;
	float falloff_mul = -1 / falloff_range;
	float falloff_add = (push.radius - falloff_range) / falloff_range + 1;
	float min_step = MIN_PIXELS / pixels;

	float2 temporal = 5.588238 * float(push.frame % 64);
	float slice_noise = interleaved_noise(float2(pixel) + temporal);
	float step_noise = interleaved_noise(float2(pixel) + float2(17, 23) + temporal);
	int2 last = int2(push.size) - 1;
	float visibility = 0;
	// The slices turn evenly around the view direction, not around the screen's axis, which off the screen's center
	// would weigh some directions more and make an open plane look occluded or brighter than open.
	float3 across = normalize(cross(float3(0, 1, 0), view));
	float3 along = cross(view, across);
	float2 projection_scale = view_model ? push.view_model.xy : push.projection.xy;
	[unroll] for (uint slice = 0; slice < SLICES; slice++) {
		float phi = (slice + slice_noise) / SLICES * PI;
		float3 ortho = cos(phi) * across + sin(phi) * along;
		// The slice's direction on the screen: how its direction moves the point's projection. The screen's y goes
		// down, view space's up.
		float2 moved = projection_scale * (ortho.xy * position.z - position.xy * ortho.z);
		float2 omega = normalize(float2(moved.x * push.size.x, -moved.y * push.size.y)) * pixels;
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
		[unroll] for (uint step = 0; step < STEPS; step++) {
			float s = (step + frac(step_noise + (slice + step * STEPS) * 0.618034)) / STEPS;
			s = s * s + min_step;
			int2 offset = int2(round(omega * s));
			int2 pixel0 = pixel + offset;
			int2 pixel1 = pixel - offset;
			// A step off the screen sees nothing, and neither does a step from the world onto the view model or back:
			// the view model is not where it seems to be, so it occludes only itself.
			bool other;
			if (all(pixel0 >= 0) && all(pixel0 <= last)) {
				float3 delta = view_position(pixel0, other) - position;
				float distance = length(delta);
				float weight = saturate(distance * falloff_mul + falloff_add);
				weight = other == view_model ? weight : 0;
				horizon0 = max(horizon0, lerp(low0, dot(delta / distance, view), weight));
			}
			if (all(pixel1 >= 0) && all(pixel1 <= last)) {
				float3 delta = view_position(pixel1, other) - position;
				float distance = length(delta);
				float weight = saturate(distance * falloff_mul + falloff_add);
				weight = other == view_model ? weight : 0;
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
	visibility = max(pow(max(visibility / SLICES, 0), push.power), 0.03);
	cn_rw_texture(push.output)[pixel] = visibility;
}
