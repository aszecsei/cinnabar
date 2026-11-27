// ReSTIR GI's resolve (see docs/rendering/global-illumination.md#restir-gi): each pixel takes its diffuse light from
// the reservoirs around it, each evaluated at the pixel's own surface, its light times the cosine toward its sample
// times its weight, over pi. With a tile of one pixel, that is the pixel's own reservoir; with larger tiles, the four
// nearest reservoirs blend by how near they are and whether their surfaces are the pixel's, and a pixel that none
// matches, or whose reservoirs have no samples, takes the world probes' light around it. A reservoir has none where
// every ray and every neighbour's sample was lost, as behind a masked decal just off a wall, which the rays take as
// opaque. The reconnection to the pixel's surface leaves out the Jacobian
// there, which the tiles are too small for it to matter in. The specular light is the world probes' radiance along the
// reflection, or the sky's cubemap at the pixel's roughness; the traced reflections, where they run, are in front of
// it. Then both blend into their histories, found by the velocity, as the screen cascades' gather does, and a history
// whose depth is not where this frame's point was last frame starts over. The view model's pixels take the light
// around the camera.
#include "gi_restir.hlsli"

// A history counts while its depth is within this share of the pixel's.
static const float HISTORY_TOLERANCE = 0.05;

// restir_contribution is a reservoir's diffuse light at a surface.
float3 restir_contribution(Restir_Reservoir r, float3 p, float3 normal) {
	if (r.M <= 0 || r.W <= 0) {
		return 0;
	}
	return r.light * saturate(dot(normal, restir_direction(r, p))) * r.W / RESTIR_PI;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	RWTexture2D<float4> out_diffuse = cn_rw_texture(constants.out_diffuse);
	RWTexture2D<float4> out_specular = cn_rw_texture(constants.out_specular);
	float depth = cn_texture(constants.depth).Load(int3(pixel, 0)).r;
	if (depth <= 0) {
		out_diffuse[pixel] = 0;
		out_specular[pixel] = 0;
		return;
	}
	float3 normal = octahedral_normal(pixel);
	float3 position;
	float z;
	if (!surface_at(pixel, position, z)) {
		float3 reflected = reflect(from_camera(position), normal);
		out_diffuse[pixel] = float4(surrounding_light(0, normal), 0);
		out_specular[pixel] = float4(beyond_specular(0, normal, reflected, gather_roughness(pixel)), 0);
		return;
	}
	Restir_Grid g = restir_grid();
	float3 reflected = reflect(from_camera(position), normal);

	float3 diffuse = 0;
	float total = 0;
	if (all(g.tile == 1)) {
		Restir_Reservoir r = restir_load(push.sample_in, push.light_in, push.normal_in, pixel);
		diffuse = restir_contribution(r, position, normal);
		total = r.M > 0 ? 1 : 0;
	} else {
		// A reservoir's ray is from the pixel at its tile's rotation.
		float2 grid = float2(pixel - int2(g.rotation)) / float2(g.tile);
		int2 base = int2(floor(grid));
		float2 f = grid - float2(base);
		[unroll] for (uint n = 0; n < 4; n++) {
			int2 offset = int2(n & 1, n >> 1);
			int2 q = base + offset;
			float3 pq;
			float3 nq;
			float zq;
			if (!restir_surface(g, q, pq, nq, zq)) {
				continue;
			}
			float2 w2 = lerp(1 - f, f, float2(offset));
			float alike = pow(saturate(dot(nq, normal)), 8);
			float near = abs(dot(pq - position, normal)) <= PLANE_TOLERANCE * z ? 1 : 1e-3;
			float w = max(w2.x * w2.y, 1e-3) * alike * near;
			if (w <= 0) {
				continue;
			}
			Restir_Reservoir r = restir_load(push.sample_in, push.light_in, push.normal_in, q);
			if (r.M <= 0) {
				continue;
			}
			diffuse += restir_contribution(r, position, normal) * w;
			total += w;
		}
		diffuse = total > 1e-4 ? diffuse / total : 0;
	}
	if (total <= 1e-4) {
		diffuse = surrounding_light(position, normal);
	}
	float exposure = cn_buffer(push.exposure).Load<float>(0);
	diffuse = clamp_hit_light(diffuse, exposure, g.radiance_max);
	float3 specular = beyond_specular(position, normal, reflected, gather_roughness(pixel));

	float4 diffuse_result = float4(diffuse, z);
	float4 specular_result = float4(specular, 1);
	if (constants.valid != 0) {
		float2 uv = (float2(pixel) + 0.5) / float2(constants.size);
		float2 previous_uv = uv - cn_texture(constants.velocity).Load(int3(pixel, 0)).rg;
		float expected = mul(constants.previous, float4(position, 1)).w;
		if (all(previous_uv == saturate(previous_uv))) {
			int2 previous_pixel = min(int2(previous_uv * float2(constants.size)), int2(constants.size) - 1);
			float4 history_diffuse = cn_texture(constants.history_diffuse).Load(int3(previous_pixel, 0));
			float4 history_specular = cn_texture(constants.history_specular).Load(int3(previous_pixel, 0));
			if (abs(history_diffuse.a - expected) <= HISTORY_TOLERANCE * expected) {
				float frames = min(history_specular.a + 1, constants.max_frames);
				diffuse_result.rgb = lerp(history_diffuse.rgb, diffuse, 1 / frames);
				specular_result = float4(lerp(history_specular.rgb, specular, 1 / frames), frames);
			}
		}
	}
	out_diffuse[pixel] = diffuse_result;
	out_specular[pixel] = specular_result;
}
