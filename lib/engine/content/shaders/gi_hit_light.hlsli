// The light that a traced ray's hit sends back along the ray (see docs/rendering/global-illumination.md#world-probes):
// its emission, the direct light of every directional light, each shadowed by a ray toward it, and of one punctual
// light that it picks from the frame's light grid by resampled importance sampling (gi_light_sampling.hlsli), shadowed
// by one ray, and the world probes' light at the hit, so light bounces once more each time, for its diffuse part and its
// specular part alike, or the sky's along the hit's reflection for the specular part where no probe counts. A ray that hit nothing sees
// the ambient light. A back face of a one-sided surface is black, and its distance is negative, which tells the world
// probes that a probe may be inside geometry. A pass includes it after material_lighting.hlsli, whose lights it reads,
// with the camera's frame constants set.
#ifndef GI_HIT_LIGHT_HLSLI
#define GI_HIT_LIGHT_HLSLI

#include "ray_scene.hlsli"
#include "gi_probes.hlsli"
#include "gi_light_sampling.hlsli"

// Directional lights' shadow rays stop this far away, in meters.
static const float HIT_SHADOW_DISTANCE = 1000;
// A shadow ray that meets more translucent triangles than this counts as shadowed, so its loop is bounded.
static const uint HIT_SHADOW_MAX_CANDIDATES = 8;
// A slot's submeshes. Match MAX_SUBMESHES in lib/engine/render/residency.odin.
static const uint HIT_MAX_SUBMESHES = 16;

// Hit_Lights are what a hit's light needs beyond the frame constants: the ray scene that the shadow rays trace, with
// its hit table, whose translucent submeshes they pass through; the light grid in a buffer at an offset, whose punctual
// lights the hits pick from after the directional ones, with the emitters' samples, which hold emitter_count triangles,
// or none for 0, the lights that each hit weighs, and the seed of its choices.
struct Hit_Lights {
	uint accel;
	uint hit_instances;
	uint hit_instances_offset;
	uint hit_submeshes;
	uint hit_submeshes_offset;
	uint light_grid;
	uint light_grid_offset;
	uint candidates;
	uint seed;
	uint emitters;
	uint emitter_count;
};

// hit_translucent is whether a primitive of a slot is a translucent submesh's, by the hit table.
bool hit_translucent(Hit_Lights lights, uint slot, uint primitive) {
	Hit_Instance instance = cn_buffer(lights.hit_instances).Load<Hit_Instance>(lights.hit_instances_offset + slot * sizeof(Hit_Instance));
	if ((instance.flags & HIT_INSTANCE_TRANSLUCENT) == 0) {
		return false;
	}
	for (uint k = 0; k < min(instance.count, HIT_MAX_SUBMESHES); k++) {
		Hit_Submesh submesh = cn_buffer(lights.hit_submeshes).Load<Hit_Submesh>(lights.hit_submeshes_offset + (instance.first + k) * sizeof(Hit_Submesh));
		if (primitive - submesh.first_primitive < submesh.primitive_count) {
			return (submesh.bin & HIT_TRANSLUCENT) != 0;
		}
	}
	return false;
}

// hit_shadow is whether a light reaches a point relative to the camera, along a direction toward it, within a distance.
// Only an instance with a translucent submesh is not opaque, and the ray passes through that submesh's triangles: a
// lantern's glass does not hide its flame, and a window lets the sun in.
float hit_shadow(Hit_Lights lights, float3 p, float3 direction, float distance) {
	RayDesc ray;
	ray.Origin = p + frame.camera_offset.xyz;
	ray.Direction = direction;
	ray.TMin = 0;
	ray.TMax = distance;
	RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES> query;
	query.TraceRayInline(cn_accel(lights.accel), 0, RAY_MASK_SHADOWS, ray);
	uint candidates = 0;
	while (query.Proceed()) {
		if (query.CandidateType() != CANDIDATE_NON_OPAQUE_TRIANGLE) {
			continue;
		}
		candidates++;
		if (candidates > HIT_SHADOW_MAX_CANDIDATES || !hit_translucent(lights, query.CandidateInstanceID(), query.CandidatePrimitiveIndex())) {
			query.CommitNonOpaqueTriangleHit();
		}
	}
	return query.CommittedStatus() == COMMITTED_NOTHING ? 1 : 0;
}

float3 hit_direct(Hit_Lights lights, Light_Record l, float3 p, float3 normal) {
	Light light = light_falloff(l, p);
	float cosine = saturate(dot(normal, light.direction));
	if (cosine <= 0 || all(light.color <= 0)) {
		return 0;
	}
	float distance = l.type == LIGHT_DIRECTIONAL ? HIT_SHADOW_DISTANCE : length(l.position - p);
	return light.color * cosine * hit_shadow(lights, p, light.direction, distance);
}

// hit_light is the light that a ray's hit sends back along it, and the ray's distance: the hit's, negative for a back
// face, or for a miss the ray's whole length, which trace_hit gives it.
float4 hit_light(Hit_Record hit, uint surfaces, uint ray, Hit_Lights lights, Probe_Grid grid) {
	float3 direction = hit_unpack_unit(hit.direction);
	if (hit_missed(hit)) {
		return float4(ambient_light(frame.ambient, direction), hit.t);
	}
	Hit_Surface s = load_hit_surface(surfaces, ray);
	uint flags = hit_flags(s);
	if ((flags & HIT_SURFACE_BACK) != 0) {
		return float4(0, 0, 0, -hit.t);
	}
	float3 p = s.position - frame.camera_offset.xyz;
	float3 normal = hit_unpack_unit(s.normal);
	float3 geometric = hit_unpack_unit(s.geometric);
	float3 light = hit_emission(s);
	if ((flags & HIT_SURFACE_NO_LIGHTING) == 0) {
		float3 albedo = hit_albedo(s);
		// The shadow rays start a hair off the surface, as the shadow mask's do.
		float3 world = s.position;
		float epsilon = 1e-4 * max(1, hit.t) + 2e-6 * max(abs(world.x), max(abs(world.y), abs(world.z)));
		float3 origin = p + geometric * epsilon * 4;
		float3 direct = 0;
		for (uint i = 0; i < frame.directional_count; i++) {
			direct += hit_direct(lights, load_light(i), origin, normal);
		}
		uint state = lowbias32(lights.seed ^ lowbias32(ray));
		Hit_Choice choice = pick_hit_light(lights.light_grid, lights.light_grid_offset, lights.candidates, lights.emitters, lights.emitter_count, origin, normal, state);
		if (choice.weight > 0) {
			direct += choice.light * choice.weight * hit_shadow(lights, origin, choice.direction, choice.distance);
		}
		float3 bounce;
		bool probes = sample_probes(grid, p, normal, normal, false, bounce);
		if (!probes) {
			bounce = ambient_light(frame.ambient, normal);
		}
		light += albedo / PI * direct + albedo * bounce;
		// The specular part, so a metal is not black: where the probes count, the light that they give around the normal,
		// and elsewhere the sky's cubemap along the reflection, at the hit's roughness. A second probe lookup along the
		// reflection hung the GPU on an RTX 5090, as the screen light did here (see gi_hit_screen.hlsli).
		float3 specular = hit_specular(s);
		if (any(specular > 0)) {
			light += specular * (probes ? bounce : frame_sky_specular(reflect(direction, normal), hit_roughness(s)));
		}
	}
	return float4(light, hit.t);
}

#endif
