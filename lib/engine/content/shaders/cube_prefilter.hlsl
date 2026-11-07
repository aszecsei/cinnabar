// A cube's prefilter by roughness (see docs/rendering/sky.md#specular-light): one mip of the output cube is the source
// cube's light convolved with a GGX lobe of the mip's roughness around each texel's direction, the split sum's first
// term as Karis gives it, with the normal, the view and the reflection all along that direction. The lobe is importance
// sampled at Hammersley points, each weighted by its cosine, and each sample reads the source's mip whose texels cover
// about the solid angle that the sample stands for (Krivanek and Colbert's filtered importance sampling), so a small
// bright light, such as the glow around the sun, does not leave fireflies. Roughness 0 is the source's mip 0 as it is.
// The source is any sampled cube with its mip chain. A group's z is the face, which the output takes at first_layer
// and the five layers after it, so the output may be one cube of a cube array.
#include "cinnabar.hlsli"
#include "sky_directions.hlsli"

// Matches Cube_Prefilter_Push in lib/engine/render/sky_cube.odin. face is the output mip's size, and source_face the
// source's mip 0's.
struct Cube_Prefilter_Push {
	uint source;
	uint output;
	uint face;
	uint source_face;
	uint source_mips;
	uint samples;
	uint sampler_index;
	float roughness;
	uint first_layer;
};
CN_PUSH_CONSTANTS(Cube_Prefilter_Push, push);

static const float PI = 3.14159265;

float2 hammersley(uint i, uint count) {
	return float2((i + 0.5) / count, reversebits(i) * 2.3283064365386963e-10);
}

// ggx_half is the half vector of a point of the square, in the GGX distribution of a squared alpha, about +z.
float3 ggx_half(float2 xi, float a2) {
	float phi = 2 * PI * xi.x;
	float cos_theta = sqrt((1 - xi.y) / (1 + (a2 - 1) * xi.y));
	float sin_theta = sqrt(1 - cos_theta * cos_theta);
	return float3(sin_theta * cos(phi), sin_theta * sin(phi), cos_theta);
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.face)) {
		return;
	}
	TextureCube<float4> source = cn_texture_cube(push.source);
	SamplerState s = cn_sampler(push.sampler_index);
	float3 n = cube_texel_direction(id.z, id.xy, push.face, 0.5);
	uint3 out_texel = uint3(id.xy, push.first_layer + id.z);
	if (push.roughness <= 0) {
		cn_rw_texture_array(push.output)[out_texel] = float4(source.SampleLevel(s, n, 0).rgb, 1);
		return;
	}
	float a = max(push.roughness * push.roughness, 2e-3);
	float a2 = a * a;
	float3 up = abs(n.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
	float3 t = normalize(cross(up, n));
	float3 b = cross(n, t);
	// A texel of the source's mip 0 covers about this solid angle.
	float texel_angle = 4 * PI / (6.0 * push.source_face * push.source_face);
	float max_lod = push.source_mips - 1;
	float3 light = 0;
	float total = 0;
	for (uint i = 0; i < push.samples; i++) {
		float3 h_local = ggx_half(hammersley(i, push.samples), a2);
		float3 h = t * h_local.x + b * h_local.y + n * h_local.z;
		float nh = h_local.z;
		float3 l = 2 * nh * h - n;
		float nl = dot(n, l);
		if (nl <= 0) {
			continue;
		}
		// With the view along the normal, the reflection's pdf is D / 4.
		float denominator = nh * nh * (a2 - 1) + 1;
		float pdf = a2 / (PI * denominator * denominator) * 0.25;
		float sample_angle = 1 / (push.samples * pdf + 1e-6);
		float lod = clamp(0.5 * log2(sample_angle / texel_angle) + 1, 0, max_lod);
		light += source.SampleLevel(s, l, lod).rgb * nl;
		total += nl;
	}
	cn_rw_texture_array(push.output)[out_texel] = float4(light / max(total, 1e-6), 1);
}
