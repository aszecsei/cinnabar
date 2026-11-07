// What the screen-space reflections' shaders share (see docs/rendering/lighting-and-shadows.md#screen-space-reflections):
// their constants, the positions on the screen and in the world, and GGX's distribution of visible normals, which the
// rays sample and the resolve weighs them by.
#ifndef SSR_COMMON_HLSLI
#define SSR_COMMON_HLSLI

#include "cinnabar.hlsli"

// Matches Ssr_Constants in lib/engine/render/screen_reflections.odin. previous maps a position relative to the camera to
// last frame's clip space, the camera's motion included. right, up and forward are the view's axes in the world, and
// projection holds the camera's x and y scales and its near plane. levels are the depth pyramid's, written by the
// depth pass and read by the trace. rays are the trace's ray textures, then its radiance textures, a pair for each ray.
struct Ssr_Constants {
	float4x4 previous;
	float4 right;
	float4 up;
	float4 forward;
	float4 projection;
	uint depth;
	uint stencil;
	uint normals;
	uint roughness;
	uint velocity;
	uint lit;
	uint lit_valid;
	uint sampler_index;
	uint noise;
	uint frame;
	uint exposure;
	uint scene;
	uint2 size;
	uint2 trace_size;
	uint2 lit_size;
	uint2 offset;
	uint ray_count;
	uint steps;
	float cutoff;
	uint level_count;
	uint4 levels[3];
	uint4 rays;
	uint resolved;
	uint distance;
	uint history;
	uint output;
	float2 jitter;
	uint history_valid;
	uint first;
	uint source;
	float min_frames;
	float max_frames;
	uint padding;
};
CN_PASS_CONSTANTS(Ssr_Constants, constants);

static const float PI = 3.14159265;
// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;
// Lit's smallest GGX alpha (see shade_direct in lit.hlsli), so a mirror's distribution stays finite.
static const float MIN_ALPHA = 2e-3;
// A ray's pdf is stored as a half float, so a mirror's is clamped below its largest.
static const float MAX_PDF = 60000;
// The roughness over which a surface's reflection fades out below the cutoff.
static const float CUTOFF_FADE = 0.1;
// The noise texture's size and slices: tools/stbn's.
static const uint NOISE_SIZE = 128;
static const uint NOISE_SLICES = 32;

uint level_index(uint i) {
	return constants.levels[i / 4][i % 4];
}

uint2 level_size(uint i) {
	return (constants.size + (1u << i) - 1) >> i;
}

// noise is the spatiotemporal blue noise at a pixel this frame, offset for each ray and each use, so they are not
// correlated.
float2 noise(int2 pixel, uint offset) {
	uint2 texel = (uint2(pixel) + uint2(offset * 64, offset * 37)) % NOISE_SIZE;
	return cn_texture_array(constants.noise).Load(int4(texel, (constants.frame + offset * 11) % NOISE_SLICES, 0)).rg;
}

// view_of is a position relative to the camera in view space: x right, y up, z forward.
float3 view_of(float3 p) {
	return float3(dot(p, constants.right.xyz), dot(p, constants.up.xyz), dot(p, constants.forward.xyz));
}

float3 world_of(float3 v) {
	return constants.right.xyz * v.x + constants.up.xyz * v.y + constants.forward.xyz * v.z;
}

// screen_of is where a position in view space is on the screen, in [0, 1], and its depth, as the jittered prepass
// drew it: the depth is near / z, which is linear on the screen.
float3 screen_of(float3 v) {
	float2 ndc = v.xy * constants.projection.xy / v.z + constants.jitter;
	return float3(ndc * float2(0.5, -0.5) + 0.5, constants.projection.z / v.z);
}

// position_at is the position relative to the camera of a point on the screen, in [0, 1], at a depth: screen_of's inverse.
float3 position_at(float2 uv, float depth) {
	float z = constants.projection.z / max(depth, 1e-7);
	float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2) - constants.jitter;
	return world_of(float3(ndc / constants.projection.xy * z, z));
}

// surface_at is a pixel's surface: its depth and its position relative to the camera. There is none where nothing drew,
// and none on the view model, which is not where it seems to be in the world.
bool surface_at(int2 pixel, out float3 position) {
	float depth = cn_texture(constants.depth).Load(int3(pixel, 0)).r;
	bool view_model = (cn_stencil_texture(constants.stencil).Load(int3(pixel, 0)).g & VIEW_MODEL_STENCIL) != 0;
	position = position_at((float2(pixel) + 0.5) / float2(constants.size), depth);
	return depth > 0 && !view_model;
}

float3 octahedral_decode(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

float2 octahedral_encode(float3 n) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	float2 p = n.xy;
	if (n.z < 0) {
		float2 sign_xy = float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
		p = (1 - abs(p.yx)) * sign_xy;
	}
	return p;
}

float3 normal_at(int2 pixel) {
	return octahedral_decode(cn_texture(constants.normals).Load(int3(pixel, 0)).xy);
}

float roughness_at(int2 pixel) {
	return cn_texture(constants.roughness).Load(int3(pixel, 0)).r;
}

float ggx_alpha(float roughness) {
	return max(roughness * roughness, MIN_ALPHA);
}

// basis is an orthonormal frame around a normal (Duff et al., "Building an Orthonormal Basis, Revisited", 2017).
void basis(float3 n, out float3 t, out float3 b) {
	float s = n.z >= 0 ? 1 : -1;
	float a = -1 / (s + n.z);
	float c = n.x * n.y * a;
	t = float3(1 + s * n.x * n.x * a, s * c, -s * n.x);
	b = float3(c, s + n.y * n.y * a, -n.y);
}

float ggx_d(float n_h, float alpha) {
	float a2 = alpha * alpha;
	float d = n_h * n_h * (a2 - 1) + 1;
	return a2 / (PI * d * d);
}

// smith_lambda_term is sqrt(α² + (1 - α²) cos²θ), which the Smith masking terms share.
float smith_term(float n_x, float alpha) {
	float a2 = alpha * alpha;
	return sqrt(a2 + (1 - a2) * n_x * n_x);
}

float smith_g1(float n_v, float alpha) {
	return 2 * n_v / (n_v + smith_term(n_v, alpha));
}

// vndf_pdf is the probability of reflecting the view direction into l by a normal sampled from GGX's distribution of
// visible normals: G1(v) D(h) / (4 n·v) (Heitz, "Sampling the GGX Distribution of Visible Normals", JCGT 2018).
float vndf_pdf(float n_v, float n_h, float alpha) {
	return smith_g1(n_v, alpha) * ggx_d(n_h, alpha) / (4 * max(n_v, 1e-4));
}

// specular_weight is GGX's specular times the cosine, without Fresnel, which shade_indirect applies after: D G2 / (4 n·v),
// with the height-correlated G2.
float specular_weight(float n_v, float n_l, float n_h, float alpha) {
	if (n_l <= 0 || n_v <= 0) {
		return 0;
	}
	float g2 = 2 * n_l * n_v / (n_l * smith_term(n_v, alpha) + n_v * smith_term(n_l, alpha));
	return ggx_d(n_h, alpha) * g2 / (4 * n_v);
}

// sample_vndf is a normal from GGX's distribution of visible normals, for a view direction in the frame where the
// normal is +z (Heitz 2018, listing 1).
float3 sample_vndf(float3 v, float alpha, float2 u) {
	float3 vh = normalize(float3(alpha * v.x, alpha * v.y, v.z));
	float lensq = vh.x * vh.x + vh.y * vh.y;
	float3 t1 = lensq > 0 ? float3(-vh.y, vh.x, 0) * rsqrt(lensq) : float3(1, 0, 0);
	float3 t2 = cross(vh, t1);
	float r = sqrt(u.x);
	float phi = 2 * PI * u.y;
	float p1 = r * cos(phi);
	float p2 = r * sin(phi);
	float s = 0.5 * (1 + vh.z);
	p2 = (1 - s) * sqrt(max(1 - p1 * p1, 0)) + s * p2;
	float3 nh = p1 * t1 + p2 * t2 + sqrt(max(0, 1 - p1 * p1 - p2 * p2)) * vh;
	return normalize(float3(alpha * nh.x, alpha * nh.y, max(nh.z, 0)));
}

// The weight that fades a point out near the screen's edges, over this share of the screen.
static const float EDGE_FADE = 0.1;

float edge_weight(float2 uv) {
	float2 edge = min(uv, 1 - uv) / EDGE_FADE;
	return saturate(min(edge.x, edge.y));
}

#endif
