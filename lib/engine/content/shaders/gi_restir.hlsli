// What ReSTIR GI's shaders share (see docs/rendering/global-illumination.md#restir-gi): their push constants, the
// grid in the upload ring, and the reservoirs. Each tile of the screen traces one ray a frame from one of its pixels,
// the same pixel of every tile, and keeps one reservoir: the sample point that its ray found and the light that it sends
// back toward the tile's surface, the sample's weight W, and M, how many samples the reservoir chose it from. A sample
// is a point relative to the camera, or a direction for a ray that went past the grid's reach, a sample at infinity.
// The target of the resampling at a surface is the luminance of a sample's light times the cosine toward it, so the
// diffuse light that a reservoir gives is its light times the cosine times W, over pi. The pass constants are the
// global illumination's (gi_common.hlsli), for the pixels' surfaces, the world probes' light and the sky's cubemap.
#ifndef GI_RESTIR_HLSLI
#define GI_RESTIR_HLSLI

#include "gi_common.hlsli"
#include "ray_scene.hlsli"
#include "hash.hlsli"
#include "hit_clamp.hlsli"
#include "gi_translucency.hlsli"

// Match lib/engine/render/gi_restir.odin.
static const uint RESTIR_GROUP = 64;
static const float RESTIR_PI = 3.14159265;

// Matches Restir_Push in lib/engine/render/gi_restir.odin.
struct Restir_Push {
	uint grid;
	uint grid_offset;
	uint pass_index;
	uint step;
	uint hits;
	uint surfaces;
	uint rays;
	uint accel;
	// What the rays pass through glass by.
	Translucency translucency;
	uint transmit;
	uint exposure;
	uint sample_in;
	uint light_in;
	uint normal_in;
	uint sample_out;
	uint light_out;
	uint normal_out;
	uint filter_in;
	uint filter_out;
	// The ray guide's Restir_Guide in the upload ring (see gi_restir_guide.hlsli), each ray's pdf, and the Gi_Probes
	// debug view's texture.
	uint guide_grid;
	uint guide_offset;
	uint pdfs;
	uint view_out;
};
CN_PUSH_CONSTANTS(Restir_Push, push);

// Matches Restir_Grid in lib/engine/render/gi_restir.odin.
struct Restir_Grid {
	float4 camera_motion;
	float4 camera_offset;
	uint2 reservoirs;
	uint2 tile;
	uint2 rotation;
	uint ray_count;
	uint frame;
	float reach;
	float bias;
	float temporal_max_m;
	float max_age;
	uint spatial_samples;
	float spatial_radius;
	float spatial_max_m;
	uint visibility;
	float jacobian_max;
	float depth_tolerance;
	float normal_cos;
	float radiance_max;
	uint history_valid;
	uint padding0;
	uint padding1;
	uint padding2;
};

Restir_Grid restir_grid() {
	return cn_buffer(push.grid).Load<Restir_Grid>(push.grid_offset);
}

// Restir_Reservoir is one reservoir. position is the sample point relative to the camera, or the direction toward a
// sample at infinity. depth is the view depth of the surface that the reservoir is for, which tells a reused
// reservoir from one of another surface.
struct Restir_Reservoir {
	float3 position;
	float W;
	float3 light;
	float M;
	float3 normal;
	bool infinite;
	float depth;
	float age;
	float weight_sum;
};

Restir_Reservoir restir_empty() {
	Restir_Reservoir r;
	r.position = float3(0, 0, 1);
	r.W = 0;
	r.light = 0;
	r.M = 0;
	r.normal = float3(0, 0, 1);
	r.infinite = true;
	r.depth = 0;
	r.age = 0;
	r.weight_sum = 0;
	return r;
}

// A reservoir in its three textures: the sample with W, the light with M, and the sample's normal, octahedral, with
// the surface's depth and the sample's age, negative for a sample at infinity.
Restir_Reservoir restir_load(uint sample_texture, uint light_texture, uint normal_texture, int2 texel) {
	float4 s = cn_texture(sample_texture).Load(int3(texel, 0));
	float4 l = cn_texture(light_texture).Load(int3(texel, 0));
	float4 n = cn_texture(normal_texture).Load(int3(texel, 0));
	Restir_Reservoir r;
	r.position = s.xyz;
	r.W = s.w;
	r.light = l.rgb;
	r.M = l.a;
	r.normal = octahedral(n.xy);
	r.infinite = n.w < 0;
	r.depth = n.z;
	r.age = abs(n.w) - 1;
	r.weight_sum = 0;
	return r;
}

void restir_store(uint sample_texture, uint light_texture, uint normal_texture, int2 texel, Restir_Reservoir r) {
	bool finite = all(isfinite(r.light)) && isfinite(r.W) && all(isfinite(r.position));
	if (!finite) {
		r = restir_empty();
	}
	cn_rw_texture(sample_texture)[texel] = float4(r.position, r.W);
	cn_rw_texture(light_texture)[texel] = float4(r.light, r.M);
	float age = r.age + 1;
	cn_rw_texture(normal_texture)[texel] = float4(octahedral_encode(r.normal), r.depth, r.infinite ? -age : age);
}

float restir_luminance(float3 c) {
	return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// restir_direction is the direction from a surface toward a reservoir's sample.
float3 restir_direction(Restir_Reservoir r, float3 p) {
	if (r.infinite) {
		return r.position;
	}
	float3 d = r.position - p;
	float l = length(d);
	return l > 1e-6 ? d / l : float3(0, 0, 1);
}

// restir_target is the target of the resampling for a reservoir's sample at a surface: its light's luminance times the
// cosine toward it.
float restir_target(Restir_Reservoir r, float3 p, float3 normal) {
	return restir_luminance(r.light) * saturate(dot(normal, restir_direction(r, p)));
}

// restir_merge streams a sample with a weight into a reservoir: it takes the sample's place with its share of the
// weights so far, and counts its samples.
bool restir_merge(inout Restir_Reservoir r, Restir_Reservoir s, float weight, float M, inout uint state) {
	r.weight_sum += weight;
	r.M += M;
	if (weight > 0 && random_unit(state) * r.weight_sum < weight) {
		float weight_sum = r.weight_sum;
		float total = r.M;
		float depth = r.depth;
		r = s;
		r.weight_sum = weight_sum;
		r.M = total;
		r.depth = depth;
		return true;
	}
	return false;
}

// restir_finish gives a reservoir its weight W at a surface, once its samples are merged.
void restir_finish(inout Restir_Reservoir r, float3 p, float3 normal) {
	float target = restir_target(r, p, normal);
	r.W = target > 0 && r.M > 0 ? r.weight_sum / (r.M * target) : 0;
}

// restir_jacobian is how much the solid angle of a sample point changes when a neighbour's sample is reused at a
// receiver: the cosine at the sample toward the receiver over the one toward the neighbour, times the neighbour's
// squared distance over the receiver's. A sample at infinity keeps its solid angle. Matches restir_jacobian in
// lib/engine/render/gi_restir.odin.
float restir_jacobian(float3 receiver, float3 neighbour, Restir_Reservoir s) {
	if (s.infinite) {
		return 1;
	}
	float3 to_receiver = receiver - s.position;
	float3 to_neighbour = neighbour - s.position;
	float d_r = max(dot(to_receiver, to_receiver), 1e-8);
	float d_q = max(dot(to_neighbour, to_neighbour), 1e-8);
	float cos_r = abs(dot(s.normal, to_receiver)) * rsqrt(d_r);
	float cos_q = max(abs(dot(s.normal, to_neighbour)) * rsqrt(d_q), 1e-6);
	return cos_r / cos_q * (d_q / d_r);
}

// restir_pixel is the pixel of a reservoir's tile that the frame traces.
int2 restir_pixel(Restir_Grid g, int2 texel) {
	return texel * int2(g.tile) + int2(g.rotation);
}

// restir_surface is a reservoir's surface this frame: its pixel's position relative to the camera, normal and view
// depth. It is false off the screen and where the pixel has no surface.
bool restir_surface(Restir_Grid g, int2 texel, out float3 p, out float3 normal, out float z) {
	int2 pixel = restir_pixel(g, texel);
	p = 0;
	normal = float3(0, 0, 1);
	z = 0;
	if (any(texel < 0) || any(texel >= int2(g.reservoirs)) || any(pixel >= int2(constants.size))) {
		return false;
	}
	if (!surface_at(pixel, p, z)) {
		return false;
	}
	normal = octahedral_normal(pixel);
	return true;
}

// restir_seed is a random sequence's state for a reservoir, a pass and the frame.
uint restir_seed(Restir_Grid g, int2 texel, uint salt) {
	return lowbias32(uint(texel.x) * 0x8da6b343u ^ uint(texel.y) * 0xd8163841u ^ lowbias32(g.frame * 0x9e3779b9u + salt));
}

// restir_cosine_direction is a direction around a normal, cosine-weighted, from two numbers in [0, 1), in a frame of
// the normal's that has no seam (Duff et al., "Building an Orthonormal Basis, Revisited").
float3 restir_cosine_direction(float3 n, float2 u) {
	float s = n.z >= 0 ? 1 : -1;
	float a = -1 / (s + n.z);
	float b = n.x * n.y * a;
	float3 t = float3(1 + s * n.x * n.x * a, s * b, -s * n.x);
	float3 bt = float3(b, s + n.y * n.y * a, -n.y);
	float r = sqrt(u.x);
	float phi = 2 * RESTIR_PI * u.y;
	return normalize(t * (r * cos(phi)) + bt * (r * sin(phi)) + n * sqrt(saturate(1 - u.x)));
}

// restir_visible is whether nothing opaque lies between a surface and a sample, by a shadow ray through the ray scene,
// which passes through glass, as the rays that found the samples did. The ray to a sample at infinity goes as far as
// the grid's reach.
bool restir_visible(Restir_Grid g, float3 p, float3 normal, float z, Restir_Reservoir s) {
	float3 origin = p + normal * g.bias * pixel_meters(z);
	float3 d = restir_direction(s, origin);
	float distance = s.infinite ? g.reach : length(s.position - origin) * 0.98;
	if (distance <= 0) {
		return true;
	}
	RayDesc ray;
	ray.Origin = origin + g.camera_offset.xyz;
	ray.Direction = d;
	ray.TMin = 0;
	ray.TMax = distance;
	RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES> query;
	query.TraceRayInline(cn_accel(push.accel), 0, RAY_MASK_SURFACES, ray);
	uint candidates = 0;
	while (query.Proceed()) {
		if (query.CandidateType() != CANDIDATE_NON_OPAQUE_TRIANGLE) {
			continue;
		}
		candidates++;
		float3 transmittance;
		if (candidates > TRACE_MAX_CROSSINGS || !hit_translucent(push.translucency, query.CandidateInstanceID(), query.CandidatePrimitiveIndex(), transmittance)) {
			query.CommitNonOpaqueTriangleHit();
		}
	}
	return query.CommittedStatus() == COMMITTED_NOTHING;
}

#endif
