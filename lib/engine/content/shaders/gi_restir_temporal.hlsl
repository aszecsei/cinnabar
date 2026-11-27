// ReSTIR GI's temporal pass (see docs/rendering/global-illumination.md#restir-gi): a thread for each reservoir makes
// this frame's sample from its ray, then merges it with last frame's reservoir at the place that the velocity gives.
// A hit is the hit's point, with its light from the hit light passes; a ray past the reach is a sample at infinity
// along it, with the world probes' light from that direction, or the ambient light without them; a back face is a
// sample of no light. The sample's weight is its target over its cosine-weighted pdf. Last frame's reservoir counts
// while the surface that it was for is this one, by its depth, and while its sample is younger than the grid's
// max_age, and counts as at most temporal_max_m samples, so the light follows a change within a few frames. Its sample
// point moves back by the camera's motion, as the points are relative to the camera.
#include "gi_restir.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Restir_Grid g = restir_grid();
	if (any(id.xy >= g.reservoirs)) {
		return;
	}
	int2 texel = int2(id.xy);
	float3 p;
	float3 normal;
	float z;
	if (!restir_surface(g, texel, p, normal, z)) {
		restir_store(push.sample_out, push.light_out, push.normal_out, texel, restir_empty());
		return;
	}
	uint ray = uint(texel.y) * g.reservoirs.x + uint(texel.x);
	uint state = restir_seed(g, texel, 1);
	float exposure = cn_buffer(push.exposure).Load<float>(0);

	// This frame's sample.
	Hit_Record hit = load_hit(push.hits, ray);
	float4 light = cn_buffer(push.rays).Load<float4>(ray * 16);
	float3 direction = hit_unpack_unit(hit.direction);
	Restir_Reservoir s = restir_empty();
	s.depth = z;
	if (hit_missed(hit)) {
		s.infinite = true;
		s.position = direction;
		s.light = beyond_light(p, normal, direction) * load_transmittance(push.transmit, ray);
	} else {
		s.infinite = false;
		if (light.a < 0) {
			s.position = p + direction * abs(light.a);
			s.normal = -direction;
			s.light = 0;
		} else {
			Hit_Surface surface = load_hit_surface(push.surfaces, ray);
			s.position = surface.position - g.camera_offset.xyz;
			s.normal = hit_unpack_unit(surface.normal);
			s.light = light.rgb;
		}
	}
	s.light = clamp_hit_light(max(s.light, 0), exposure, g.radiance_max);
	// The target over the cosine-weighted pdf: the cosines cancel.
	float cosine = saturate(dot(normal, direction));
	float weight = cosine > 0 ? restir_luminance(s.light) * RESTIR_PI : 0;

	Restir_Reservoir r = restir_empty();
	r.depth = z;
	// A back face this near the pixel means that the ray started inside geometry, as where two meshes meet, and the
	// sample counts for nothing, as the split cascades' deposit does.
	bool inside = !hit_missed(hit) && light.a < 0 && abs(light.a) < 4 * g.bias * pixel_meters(z);
	if (!inside) {
		restir_merge(r, s, weight, 1, state);
	}

	// Last frame's reservoir.
	if (g.history_valid != 0) {
		int2 pixel = restir_pixel(g, texel);
		float2 uv = (float2(pixel) + 0.5) / float2(constants.size);
		float2 previous_uv = uv - cn_texture(constants.velocity).Load(int3(pixel, 0)).rg;
		if (all(previous_uv == saturate(previous_uv))) {
			int2 previous_pixel = min(int2(previous_uv * float2(constants.size)), int2(constants.size) - 1);
			int2 previous_texel = min(previous_pixel / int2(g.tile), int2(g.reservoirs) - 1);
			Restir_Reservoir previous = restir_load(push.sample_in, push.light_in, push.normal_in, previous_texel);
			float expected = mul(constants.previous, float4(p, 1)).w;
			previous.age += 1;
			if (previous.M > 0 && previous.age < g.max_age && abs(previous.depth - expected) <= g.depth_tolerance * expected) {
				if (!previous.infinite) {
					previous.position -= g.camera_motion.xyz;
				}
				float M = min(previous.M, g.temporal_max_m);
				restir_merge(r, previous, restir_target(previous, p, normal) * previous.W * M, M, state);
			}
		}
	}
	restir_finish(r, p, normal);
	restir_store(push.sample_out, push.light_out, push.normal_out, texel, r);
}
