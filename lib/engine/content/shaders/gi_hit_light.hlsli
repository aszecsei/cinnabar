// The light that a traced ray's hit sends back along the ray (see docs/rendering/global-illumination.md#world-probes):
// its emission, the direct light of every directional light and of a list of punctual lights, each shadowed by a ray
// toward it, and the world probes' light at the hit, so light bounces once more each time. A ray that hit nothing sees
// the ambient light. A back face of a one-sided surface is black, and its distance is negative, which tells the world
// probes that a probe may be inside geometry. A pass includes it after material_lighting.hlsli, whose lights it reads,
// with the camera's frame constants set.
#ifndef GI_HIT_LIGHT_HLSLI
#define GI_HIT_LIGHT_HLSLI

#include "ray_scene.hlsli"
#include "gi_probes.hlsli"

// Directional lights' shadow rays stop this far away, in meters.
static const float HIT_SHADOW_DISTANCE = 1000;

// Hit_Lights are what a hit's light needs beyond the frame constants: the ray scene that the shadow rays trace, and the
// punctual lights that the hits see, after the directional ones.
struct Hit_Lights {
	uint accel;
	uint lights;
	uint lights_offset;
	uint light_count;
};

// hit_shadow is whether a light reaches a point relative to the camera, along a direction toward it, within a distance.
float hit_shadow(uint accel, float3 p, float3 direction, float distance) {
	RayDesc ray;
	ray.Origin = p + frame.camera_offset.xyz;
	ray.Direction = direction;
	ray.TMin = 0;
	ray.TMax = distance;
	RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES | RAY_FLAG_FORCE_OPAQUE> query;
	query.TraceRayInline(cn_accel(accel), 0, RAY_MASK_SHADOWS, ray);
	query.Proceed();
	return query.CommittedStatus() == COMMITTED_NOTHING ? 1 : 0;
}

float3 hit_direct(uint accel, Light_Record l, float3 p, float3 normal) {
	Light light = light_falloff(l, p);
	float cosine = saturate(dot(normal, light.direction));
	if (cosine <= 0 || all(light.color <= 0)) {
		return 0;
	}
	float distance = l.type == LIGHT_DIRECTIONAL ? HIT_SHADOW_DISTANCE : length(l.position - p);
	return light.color * cosine * hit_shadow(accel, p, light.direction, distance);
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
			direct += hit_direct(lights.accel, load_light(i), origin, normal);
		}
		for (uint k = 0; k < lights.light_count; k++) {
			uint index = cn_buffer(lights.lights).Load(lights.lights_offset + k * 4);
			direct += hit_direct(lights.accel, load_light(index), origin, normal);
		}
		float3 bounce;
		if (!sample_probes(grid, p, normal, normal, false, bounce)) {
			bounce = ambient_light(frame.ambient, normal);
		}
		light += albedo / PI * direct + albedo * bounce;
	}
	return float4(light, hit.t);
}

#endif
