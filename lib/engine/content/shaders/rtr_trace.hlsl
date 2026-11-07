// The traced reflections' rays (see docs/rendering/lighting-and-shadows.md#ray-traced-reflections): a thread for each
// trace texel, whose ray starts from one pixel of its block, which changes from frame to frame. The ray reflects the
// view direction by a normal from GGX's distribution of visible normals, at the pixel's roughness, from the blue noise,
// as the screen-space reflections' rays do. With steps, it first marches the screen (see ssr_march.hlsli): a hit there
// with its whole weight takes last frame's lit scene, and the ray traces nothing. Otherwise the ray traces the ray
// scene's surfaces from the pixel's surface, moved off it, with a cone as wide as the pixel or the lobe, so a rough
// reflection samples coarser textures, and stores its hit for hit shading. A hit past the reach is stored as a miss, so
// hit shading skips it, and the light pass gives it no weight. The ray texture keeps the ray's direction and pdf, and
// the radiance texture waits for the light pass with RTR_PENDING.
#include "ssr_march.hlsli"
#include "ray_scene.hlsli"
#include "rtr_common.hlsli"

CN_PUSH_CONSTANTS(Rtr_Trace_Push, push);

// skip stores a miss of no length for a ray that hit shading has nothing to shade for.
void skip(uint ray) {
	Hit_Record miss;
	miss.instance = HIT_MISS;
	miss.primitive = 0;
	miss.barycentrics = 0;
	miss.direction = hit_pack_unit(float3(0, 0, 1));
	miss.t = 0;
	miss.cone_width = 0;
	miss.bin = 0;
	miss.entry = 0;
	store_hit(push.hits, ray, miss);
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.trace_size)) {
		return;
	}
	uint index = id.y * constants.trace_size.x + id.x;
	RWTexture2D<float4> rays = cn_rw_texture(constants.rays[0]);
	RWTexture2D<float4> radiance = cn_rw_texture(constants.rays[2]);
	int2 pixel = trace_pixel(id.xy);
	float3 position;
	bool surface = surface_at(pixel, position);
	float roughness = roughness_at(pixel);
	float3 normal;
	float3 direction;
	float4 ray;
	if (!surface || roughness > constants.cutoff || !sample_ray(pixel, position, roughness, 0, normal, direction, ray)) {
		rays[id.xy] = 0;
		radiance[id.xy] = 0;
		skip(index);
		return;
	}
	// Below the surface, the ray has no weight.
	if (dot(direction, normal) <= 0) {
		rays[id.xy] = ray;
		radiance[id.xy] = 0;
		skip(index);
		return;
	}
	float pixel_meters = pixel_meters_at(position);
	if (constants.steps > 0 && constants.lit_valid != 0) {
		float exposure = cn_buffer(constants.exposure).Load<float>(0);
		float distance;
		float4 light;
		if (screen_ray(position, normal, direction, constants.steps, exposure, distance, light) && light.a >= 1) {
			ray.z = distance;
			rays[id.xy] = ray;
			radiance[id.xy] = light;
			skip(index);
			return;
		}
	}
	RayDesc desc;
	desc.Origin = position + normal * pixel_meters * START_PIXELS + push.camera_offset.xyz;
	desc.Direction = direction;
	desc.TMin = 0;
	desc.TMax = RTR_FAR;
	// The cone widens by a pixel's angle, or by the lobe's, about the GGX alpha in radians.
	float spread = max(pixel_meters / max(view_of(position).z, 1e-4), ggx_alpha(roughness));
	Hit_Record hit = trace_hit(cn_accel(push.accel), desc, RAY_MASK_SURFACES, spread);
	if (!hit_missed(hit) && hit.t > constants.reach) {
		ray.z = RTR_PAST_REACH;
		skip(index);
	} else {
		store_hit(push.hits, index, hit);
	}
	rays[id.xy] = ray;
	radiance[id.xy] = float4(0, 0, 0, RTR_PENDING);
}
