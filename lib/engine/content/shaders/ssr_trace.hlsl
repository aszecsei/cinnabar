// The screen-space reflections' rays (see docs/rendering/lighting-and-shadows.md#screen-space-reflections): a thread for
// each pixel, or for one pixel of each block of stride, which changes from frame to frame. Each of its rays reflects
// the view direction by a normal from GGX's distribution of visible normals, at the pixel's roughness, from the blue
// noise, and marches the depth pyramid on the screen (see ssr_march.hlsli). The ray keeps its direction, its distance to
// the hit, 0 for a miss, and its pdf, which the resolve weighs it by, 0 where the pixel takes no reflections.
#include "ssr_march.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.trace_size)) {
		return;
	}
	int2 pixel = trace_pixel(id.xy);
	float3 position;
	bool surface = surface_at(pixel, position);
	float roughness = roughness_at(pixel);
	float exposure = cn_buffer(constants.exposure).Load<float>(0);
	for (uint r = 0; r < constants.ray_count; r++) {
		RWTexture2D<float4> rays = cn_rw_texture(constants.rays[r]);
		RWTexture2D<float4> radiance = cn_rw_texture(constants.rays[2 + r]);
		float3 normal;
		float3 direction;
		float4 ray;
		if (!surface || roughness > constants.cutoff || !sample_ray(pixel, position, roughness, r, normal, direction, ray)) {
			rays[id.xy] = 0;
			radiance[id.xy] = 0;
			continue;
		}
		float4 light = 0;
		if (dot(direction, normal) > 0) {
			float distance;
			screen_ray(position, normal, direction, constants.steps, exposure, distance, light);
			ray.z = distance;
		}
		rays[id.xy] = ray;
		radiance[id.xy] = light;
	}
}
