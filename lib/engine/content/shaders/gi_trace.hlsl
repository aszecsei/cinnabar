// The radiance cascades' rays (see docs/rendering.md#global-illumination): a thread for each texel of every cascade,
// a probe and a direction. It marches its cascade's interval through the depth buffer from the probe's surface. Where
// the ray passes behind a surface, it takes that surface's light in last frame's lit scene, and nothing from beyond;
// otherwise everything from beyond gets through, which the merge adds.
#include "gi_common.hlsli"

static const uint STEPS = 8;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint k = id.z;
	uint directions = cascade_directions(k);
	uint2 probe = id.xy / directions;
	uint2 direction_texel = id.xy % directions;
	if (any(id.xy >= constants.region) || any(probe >= cascade_probes(k))) {
		return;
	}
	uint2 texel = cascade_texel(k, probe, direction_texel);
	RWTexture2D<float4> cascades = cn_rw_texture(constants.cascades);
	float3 origin;
	float z;
	int2 pixel = probe_pixel(k, probe);
	if (!surface_at(pixel, origin, z)) {
		cascades[texel] = float4(0, 0, 0, 1);
		return;
	}
	float2 noise = float2(interleaved_noise(float2(id.xy) + 5.588238 * float(constants.frame % 64)), interleaved_noise(float2(id.yx) + 17 + 3.7 * float(constants.frame % 64)));
	float3 direction = direction_of(direction_texel, directions, noise);
	float3 normal = octahedral_normal(pixel);
	origin += normal * pixel_meters(z) * 2;
	float start = interval_start(k, z);
	float end = interval_start(k + 1, z);
	float step = (end - start) / STEPS;

	Texture2D<float4> depth = cn_texture(constants.depth);
	float4 result = float4(0, 0, 0, 1);
	for (uint s = 0; s < STEPS; s++) {
		float3 p = origin + direction * (start + (s + noise.x) * step);
		float3 view = float3(dot(p, constants.right.xyz), dot(p, constants.up.xyz), dot(p, constants.forward.xyz));
		if (view.z <= constants.projection.z) {
			break;
		}
		float2 ndc = view.xy * constants.projection.xy / view.z;
		// A ray that leaves the screen sees what lies beyond its interval: the screen cannot say what blocks it.
		if (any(abs(ndc) >= 1)) {
			break;
		}
		int2 at = int2((ndc * float2(0.5, -0.5) + 0.5) * float2(constants.size));
		float surface_depth = depth.Load(int3(at, 0)).r;
		bool view_model = (cn_stencil_texture(constants.stencil).Load(int3(at, 0)).g & VIEW_MODEL_STENCIL) != 0;
		if (surface_depth <= 0 || view_model) {
			continue;
		}
		float surface_z = constants.projection.z / surface_depth;
		float thickness = max(step * 2, 0.05 * view.z);
		if (view.z > surface_z && view.z - surface_z < thickness) {
			result = float4(0, 0, 0, 0);
			// The surface's light in last frame's lit scene, where it was then.
			float4 clip = mul(constants.previous, float4(p, 1));
			float2 uv = clip.xy / clip.w * float2(0.5, -0.5) + 0.5;
			if (constants.lit_valid != 0 && clip.w > 0 && all(uv == saturate(uv))) {
				result.rgb = cn_texture(constants.lit).SampleLevel(cn_sampler(constants.sampler_index), uv, 0).rgb;
			}
			break;
		}
	}
	cascades[texel] = result;
}
