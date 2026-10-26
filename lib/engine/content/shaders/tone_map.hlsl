// The tone map pass (see docs/rendering/anti-aliasing.md#anti-aliasing): the output pass's tone mapping on its own, into
// a texture of the display's sRGB-encoded colors, which FXAA and SMAA read. The output pass then blends the UI over
// their result and encodes it.
#include "output.hlsli"

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	cn_rw_texture(push.output)[id.xy] = float4(tone_map(id.xy + 0.5), 1);
}
