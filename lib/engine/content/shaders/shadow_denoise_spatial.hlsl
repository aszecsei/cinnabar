// The traced mask's spatial pass (see docs/rendering/lighting-and-shadows.md#the-traced-mask): each soft channel's
// average over time blurs over a disk as wide as half its penumbra, among the pixels on the same surface, into the mask
// that the forward pass reads. The penumbra comes from the rays that a blocker stopped, the widest within a few pixels,
// since a lit ray says nothing of it; a channel with none near is not blurred. The blue noise turns each pixel's disk,
// and temporal AA averages the turns. A hard channel's visibility passes through.
#include "cinnabar.hlsli"
#include "view_projection.hlsli"
#include "blue_noise.hlsli"

// Matches Denoise_Spatial_Constants in lib/engine/render/shadows.odin. The view's axes and its projections rebuild the
// pixels' positions relative to the camera, as the trace does; a pixel with the view model's stencil bit uses the view
// model's projection. accumulated is the temporal pass's average, raw this frame's visibility, penumbra the trace's
// radii in meters, and max_radius the widest disk in pixels.
struct Denoise_Spatial_Constants {
	float4 right;
	float4 up;
	float4 forward;
	float4 projection;
	float4 view_model_projection;
	uint2 size;
	uint accumulated;
	uint raw;
	uint penumbra;
	uint depth;
	uint normals;
	uint stencil;
	uint output;
	uint noise;
	uint noise_slice;
	uint soft;
	float max_radius;
	float2 jitter;
	uint padding;
};
CN_PASS_CONSTANTS(Denoise_Spatial_Constants, constants);

// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;
// The disk's taps, and how far apart the penumbra's search looks, in pixels.
static const uint TAPS = 12;
static const int SEARCH_STEP = 3;
// A tap farther from the pixel's plane than this share of their distance apart is on another surface.
static const float PLANE_TOLERANCE = 0.1;

float3 octahedral(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

// position_at is a pixel's position relative to the camera, from its depth, where the jittered projection put its
// center, and whether it has a surface.
bool position_at(int2 pixel, out float3 p, out float z) {
	float depth = cn_texture(constants.depth).Load(int3(pixel, 0)).r;
	p = 0;
	z = 0;
	if (depth <= 0) {
		return false;
	}
	bool view_model = (cn_stencil_texture(constants.stencil).Load(int3(pixel, 0)).g & VIEW_MODEL_STENCIL) != 0;
	float4 projection = view_model ? constants.view_model_projection : constants.projection;
	z = view_z(projection, depth);
	float2 ndc = float2((pixel.x + 0.5) / constants.size.x * 2 - 1, 1 - (pixel.y + 0.5) / constants.size.y * 2) - constants.jitter;
	float2 xy = view_position(projection, ndc, z).xy;
	p = constants.right.xyz * xy.x + constants.up.xyz * xy.y + constants.forward.xyz * z;
	return true;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	int2 last = int2(constants.size) - 1;
	Texture2D<float4> accumulated = cn_texture(constants.accumulated);
	float4 result = accumulated.Load(int3(pixel, 0));
	float4 raw = cn_texture(constants.raw).Load(int3(pixel, 0));
	float3 p;
	float z;
	if (!position_at(pixel, p, z)) {
		cn_rw_texture(constants.output)[pixel] = raw;
		return;
	}
	Texture2D<float4> normals = cn_texture(constants.normals);
	float3 normal = octahedral(normals.Load(int3(pixel, 0)).xy);
	bool view_model = (cn_stencil_texture(constants.stencil).Load(int3(pixel, 0)).g & VIEW_MODEL_STENCIL) != 0;
	float pixel_meters = view_pixel_meters(view_model ? constants.view_model_projection : constants.projection, z, constants.size.y);

	// The widest penumbra that a ray near the pixel found.
	Texture2D<float4> penumbra_texture = cn_texture(constants.penumbra);
	float4 penumbra = 0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			penumbra = max(penumbra, penumbra_texture.Load(int3(clamp(pixel + int2(x, y) * SEARCH_STEP, 0, last), 0)));
		}
	}
	float2 noise = constants.noise != 0 ? blue_noise(constants.noise, id.xy, constants.noise_slice) : 0;
	float angle = noise.x * 6.28318531;
	float2 turn = float2(cos(angle), sin(angle));

	[unroll] for (uint c = 0; c < 4; c++) {
		if ((constants.soft & (1u << c)) == 0) {
			result[c] = raw[c];
			continue;
		}
		float radius = min(0.5 * penumbra[c] / max(pixel_meters, 1e-7), constants.max_radius);
		if (radius < 1) {
			continue;
		}
		float sum = result[c];
		float weights = 1;
		for (uint i = 0; i < TAPS; i++) {
			float r = sqrt((i + 0.5) / TAPS) * radius;
			float a = i * 2.39996323;
			float2 d = float2(cos(a), sin(a));
			d = float2(d.x * turn.x - d.y * turn.y, d.x * turn.y + d.y * turn.x);
			int2 q = clamp(pixel + int2(round(d * r)), 0, last);
			float3 pq;
			float zq;
			if (!position_at(q, pq, zq)) {
				continue;
			}
			// The tap counts when it is on the pixel's plane and faces as the pixel does.
			float3 offset = pq - p;
			float apart = length(offset);
			float plane = abs(dot(offset, normal)) / max(apart, 1e-6);
			float facing = saturate(dot(octahedral(normals.Load(int3(q, 0)).xy), normal));
			float w = (plane < PLANE_TOLERANCE ? 1 : 0) * facing * facing * facing * facing;
			sum += accumulated.Load(int3(q, 0))[c] * w;
			weights += w;
		}
		result[c] = sum / weights;
	}
	cn_rw_texture(constants.output)[pixel] = result;
}
