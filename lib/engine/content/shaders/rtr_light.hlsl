// The traced reflections' light (see docs/rendering/lighting-and-shadows.md#ray-traced-reflections): a thread for each
// trace texel whose ray traced the ray scene, after hit shading and the hits' light (see gi_hit_light.hlsli and
// gi_hit_screen.hlsli). A ray that found nothing sees the sky's cubemap along it, and keeps RTR_FAR as its distance. A
// ray that hit past the reach, or a back face, has no weight, and the probes fill in. A hit takes its light. The light
// is pre-exposed by this frame's exposure, into the radiance texture that the screen-space reflections' resolve reads.
#include "rtr_common.hlsli"

// Matches Rtr_Light_Push in lib/engine/render/traced_reflections.odin. It starts with Material_Push's shadow textures,
// so the light loop's lookups compile. light holds a float4 for each ray from the hits' light: its light, and its
// distance, negative for a back face. Without shaded, hit shading did not run, and a hit has no weight.
struct Rtr_Light_Push {
	uint shadow_atlas;
	uint shadow_mask;
	uint hits;
	uint light;
	uint rays;
	uint radiance;
	uint exposure;
	uint width;
	uint height;
	uint shaded;
};
#define MATERIAL_PUSH Rtr_Light_Push
#define SHADING_NO_LIGHTING 1
#include "material_lighting.hlsli"
#include "ray_scene.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (id.x >= push.width || id.y >= push.height) {
		return;
	}
	RWTexture2D<float4> radiance = cn_rw_texture(push.radiance);
	if (radiance[id.xy].a != RTR_PENDING) {
		return;
	}
	RWTexture2D<float4> rays = cn_rw_texture(push.rays);
	float4 ray = rays[id.xy];
	uint index = id.y * push.width + id.x;
	float4 light = 0;
	if (ray.z != RTR_PAST_REACH) {
		Hit_Record hit = load_hit(push.hits, index);
		float exposure = cn_buffer(push.exposure).Load<float>(0);
		if (hit_missed(hit)) {
			light = float4(frame_sky_specular(hit_unpack_unit(hit.direction), 0) * exposure, 1);
			ray.z = RTR_FAR;
		} else if (push.shaded != 0) {
			float4 lit = cn_buffer(push.light).Load<float4>(index * 16);
			if (lit.w > 0) {
				light = float4(lit.rgb * exposure, 1);
				ray.z = lit.w;
			}
		}
	}
	if (light.a <= 0) {
		ray.z = 0;
	}
	rays[id.xy] = ray;
	radiance[id.xy] = light;
}
