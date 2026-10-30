// The world probes' hit lighting (see docs/rendering/global-illumination.md#world-probes): a thread for each ray. A ray
// that hit nothing sees the ambient light. A hit's light is its emission, the direct light of every directional light
// and of the frame's listed punctual lights, each shadowed by a ray toward it, and the probes' light from last frame
// at the hit, so light bounces once more each update. gi_probe_screen.hlsl then gives the hits that the screen shows
// their light there. A back face of a one-sided surface is black, and its distance is negative, which tells the update
// that the probe may be inside geometry.
#include "gi_probe_pass.hlsli"

// Directional lights' shadow rays stop this far away, in meters.
static const float PROBE_SHADOW_DISTANCE = 1000;

// probe_shadow is whether a light reaches a point relative to the camera, along a direction toward it, within a
// distance.
float probe_shadow(float3 p, float3 direction, float distance) {
	RayDesc ray;
	ray.Origin = p + frame.camera_offset.xyz;
	ray.Direction = direction;
	ray.TMin = 0;
	ray.TMax = distance;
	RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES | RAY_FLAG_FORCE_OPAQUE> query;
	query.TraceRayInline(cn_accel(push.accel), 0, RAY_MASK_SHADOWS, ray);
	query.Proceed();
	return query.CommittedStatus() == COMMITTED_NOTHING ? 1 : 0;
}

float3 probe_direct(Light_Record l, float3 p, float3 normal) {
	Light light = light_falloff(l, p);
	float cosine = saturate(dot(normal, light.direction));
	if (cosine <= 0 || all(light.color <= 0)) {
		return 0;
	}
	float distance = l.type == LIGHT_DIRECTIONAL ? PROBE_SHADOW_DISTANCE : length(l.position - p);
	return light.color * cosine * probe_shadow(p, light.direction, distance);
}

[numthreads(HIT_GROUP_SIZE, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint ray = id.x;
	if (ray >= push.ray_count) {
		return;
	}
	Probe_Grid grid = frame_probe_grid();
	Probe probe = job_probe(grid, ray / grid.rays);
	Hit_Record hit = load_hit(push.hits, ray);
	float3 direction = hit_unpack_unit(hit.direction);
	float4 result;
	if (hit_missed(hit)) {
		result = float4(ambient_light(frame.ambient, direction), probe.distance);
	} else {
		Hit_Surface s = load_hit_surface(push.surfaces, ray);
		uint flags = hit_flags(s);
		if ((flags & HIT_SURFACE_BACK) != 0) {
			result = float4(0, 0, 0, -hit.t);
		} else {
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
					direct += probe_direct(load_light(i), origin, normal);
				}
				for (uint k = 0; k < push.light_count; k++) {
					uint index = cn_buffer(push.lights).Load(push.lights_offset + k * 4);
					direct += probe_direct(load_light(index), origin, normal);
				}
				float3 bounce;
				if (!sample_probes(grid, p, normal, normal, false, bounce)) {
					bounce = ambient_light(frame.ambient, normal);
				}
				light += albedo / PI * direct + albedo * bounce;
			}
			result = float4(light, hit.t);
		}
	}
	cn_rw_buffer(push.rays).Store<float4>(ray * 16, result);
}
