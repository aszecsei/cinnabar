// The composite of moment-based transparency (see docs/rendering.md#transparency): the scene behind the transparent
// surfaces is dimmed by all of them, e^-b0, and their light, which the transparent pass added up premultiplied by its
// opacity, is normalized by the opacity that it added up and fills the rest. The colors are pre-exposed already.
#include "cinnabar.hlsli"
#include "moments.hlsli"

// Matches Composite_Push in lib/engine/render/transparency.odin.
struct Push {
	uint moments_zeroth;
	uint accumulated;
	uint scene;
	uint padding;
	uint2 size;
};
CN_PUSH_CONSTANTS(Push, push);

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	int3 pixel = int3(id.xy, 0);
	float b0 = cn_texture(push.moments_zeroth).Load(pixel).r;
	if (b0 < MOMENT_MIN_DEPTH) {
		return;
	}
	float4 accumulated = cn_texture(push.accumulated).Load(pixel);
	float transmittance = exp(-b0);
	float3 color = accumulated.a > 1e-6 ? accumulated.rgb / accumulated.a : 0;
	RWTexture2D<float4> scene = cn_rw_texture(push.scene);
	scene[id.xy] = float4(scene[id.xy].rgb * transmittance + color * (1 - transmittance), 1);
}
