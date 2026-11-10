// The voxel cones' gather (see docs/rendering/global-illumination.md#voxel-cones): each pixel traces the level's diffuse
// cones around its normal through the clipmap's light, each cone's light weighted by its cosine, and one narrow cone
// along its reflection, each with the sky beyond what blocks it: the ambient light for the diffuse cones, and the
// sky's cubemap at the pixel's roughness for the reflection's. The cones turn about the normal by a noise
// of the pixel's that stays from frame to frame: a turn that moved each frame flickered, as the histories hold too few
// frames to average it. Both lights blend into their histories, found by the velocity, as the screen cascades' gather's
// do. The view model's pixels take the light around the camera. With the Gi_Probes debug view, it draws the
// voxels that each pixel's view ray meets first, in their albedo. A reflection probe capture's face gathers the same
// way at its own pixels, from the probe.
#include "gi_common.hlsli"
#include "gi_voxel.hlsli"

// Matches Voxel_Push in lib/engine/render/gi_voxel.odin.
struct Voxel_Push {
	uint shadow_atlas;
	uint shadow_mask;
	uint grid;
	uint grid_offset;
	uint level;
	uint view_output;
	uint padding[2];
};
CN_PUSH_CONSTANTS(Voxel_Push, push);

// A history counts while its depth is within this share of the pixel's.
static const float HISTORY_TOLERANCE = 0.05;
// Where the cones go: far past the last level, where they stop.
static const float CONE_END = 1e6;

// cone_light is the light that a cone brings to a point, with the sky's light past what blocks it.
float3 cone_light(Voxel_Grid g, float3 origin, float3 direction, float aperture, float start, float3 sky) {
	float4 c = cone_trace(g, origin, direction, aperture, start, CONE_END, 0);
	return c.rgb + (1 - c.a) * sky;
}

// gather_cones gives a point's diffuse light, the cosine-weighted mean of its cones' light, and its specular light along
// a reflection at its roughness. The cones start a voxel and a half of the point's level off its surface, past the trilinear reach of its
// own voxel.
void gather_cones(Voxel_Grid g, float3 p, float3 normal, float3 reflected, float roughness, float turn, out float3 diffuse, out float3 specular) {
	uint k = min(voxel_level_of(g, 0, p, 1), g.level_count - 1);
	float size = voxel_size(g.levels[k]);
	float3 origin = p + normal * size * 1.5;
	float3 t, b;
	cone_basis(normal, t, b);
	float c = cos(turn), s = sin(turn);
	diffuse = 0;
	for (uint i = 0; i < g.cone_count; i++) {
		float4 cone = g.cones[i];
		float2 xy = float2(cone.x * c - cone.y * s, cone.x * s + cone.y * c);
		float3 direction = normalize(t * xy.x + b * xy.y + normal * cone.z);
		diffuse += cone.w * cone_light(g, origin, direction, g.cone_aperture, size, sky_light(direction));
	}
	specular = cone_light(g, origin, reflected, g.specular_aperture, size, sky_cube_light(reflected, roughness));
}

// voxel_view is the albedo of the first voxel that a view ray from the camera meets, black past the last level.
float3 voxel_view(Voxel_Grid g, float3 direction) {
	float t = voxel_size(g.levels[0]);
	for (uint i = 0; i < 512; i++) {
		float3 p = direction * t;
		uint k = voxel_level_of(g, 0, p, 0);
		if (k >= g.level_count) {
			break;
		}
		Voxel_Level l = g.levels[k];
		uint3 texel = voxel_texel(g, k, int3(floor(voxel_local(l, p))));
		if (cn_uint_texture3d(NonUniformResourceIndex(l.mask.x)).Load(int4(texel, 0)) != 0) {
			return voxel_albedo(cn_uint_texture3d(NonUniformResourceIndex(l.reads.x)).Load(int4(texel, 0)));
		}
		t += voxel_size(l) * 0.5;
	}
	return 0;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	RWTexture2D<float4> out_diffuse = cn_rw_texture(constants.out_diffuse);
	RWTexture2D<float4> out_specular = cn_rw_texture(constants.out_specular);
	Voxel_Grid g = load_voxel_grid(push.grid, push.grid_offset);
	float depth = cn_texture(constants.depth).Load(int3(pixel, 0)).r;
	float3 position;
	float z;
	bool surface = surface_at(pixel, position, z);
	if (push.view_output != 0) {
		cn_rw_texture(push.view_output)[pixel] = float4(voxel_view(g, from_camera(position)), 1);
	}
	if (depth <= 0) {
		out_diffuse[pixel] = 0;
		out_specular[pixel] = 0;
		return;
	}
	float3 normal = octahedral_normal(pixel);
	float3 reflected = reflect(from_camera(position), normal);
	float turn = 6.28318531 * interleaved_noise(float2(pixel));
	float roughness = gather_roughness(pixel);
	float3 diffuse, specular;
	// A reflection probe capture's face (see docs/rendering/lighting-and-shadows.md#reflection-probes): its positions are
	// relative to the probe, it keeps no history, and a point outside every level takes the light that a capture takes
	// without the cones, the ambient light along its normal and the sky's cubemap along its reflection.
	if (constants.capture != 0) {
		float3 p = position + constants.origin.xyz;
		if (voxel_level_of(g, 0, p, 1) >= g.level_count) {
			diffuse = sky_light(normal);
			specular = sky_cube_light(reflected, roughness);
		} else {
			gather_cones(g, p, normal, reflected, roughness, turn, diffuse, specular);
		}
		out_diffuse[pixel] = float4(diffuse, z);
		out_specular[pixel] = float4(specular, 1);
		return;
	}
	if (!surface) {
		gather_cones(g, 0, normal, reflected, roughness, turn, diffuse, specular);
		out_diffuse[pixel] = float4(diffuse, 0);
		out_specular[pixel] = float4(specular, 0);
		return;
	}
	gather_cones(g, position, normal, reflected, roughness, turn, diffuse, specular);

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
