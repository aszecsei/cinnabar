// A reflection probe's capture of one face (see docs/rendering/lighting-and-shadows.md#reflection-probes): the face's scene, which
// the face's view drew linear, not pre-exposed, goes into the probe's source cube at the face's layer of mip 0, and where
// the view drew nothing, the sky's cubemap's light along the texel's direction, or the ambient light without one.
#include "ambient.hlsli"
#include "cinnabar.hlsli"
#include "sky_directions.hlsli"

// Matches Reflection_Probe_Face_Push in lib/engine/render/reflection_probes.odin.
struct Reflection_Probe_Face_Push {
	float4 ambient[4];
	uint scene;
	uint depth;
	uint output;
	uint face;
	uint size;
	uint sky;
	float sky_mips;
	uint sampler_index;
};
CN_PUSH_CONSTANTS(Reflection_Probe_Face_Push, push);

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	float depth = cn_texture(push.depth).Load(int3(id.xy, 0)).r;
	float3 light;
	if (depth > 0) {
		light = cn_texture(push.scene).Load(int3(id.xy, 0)).rgb;
	} else {
		float3 d = cube_texel_direction(push.face, id.xy, push.size, 0.5);
		light = push.sky_mips > 0 ? cn_texture_cube(push.sky).SampleLevel(cn_sampler(push.sampler_index), d, 0).rgb : ambient_light(push.ambient, d);
	}
	cn_rw_texture_array(push.output)[uint3(id.xy, push.face)] = float4(light, 1);
}
