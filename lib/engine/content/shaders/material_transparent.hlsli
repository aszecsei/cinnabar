// The passes of a transparent or additive material (see docs/rendering/transparency.md#transparency). They draw after the opaque
// surfaces, test their depth and do not write it. The cooker includes this after material_forward.hlsli for a material
// with MATERIAL_TRANSPARENT, and MATERIAL_ADDITIVE for an additive one. Each pass draws with vs_forward.
//   ps_moments: a Transparent material's optical depth and moments, which moment-based transparency adds up.
//   ps_transparent: the surface's color times its opacity, and its opacity, both premultiplied by the light that gets
//     through the surfaces in front of it when push.transmittance is set. Moment-based transparency adds them up and
//     normalizes them; a sorted draw blends them over the scene as premultiplied alpha, and an additive one adds them.
//   ps_transparent_ids: the entity ID wherever the surface shows, for the editor.
#ifndef MATERIAL_TRANSPARENT_HLSLI
#define MATERIAL_TRANSPARENT_HLSLI

#include "moments.hlsli"

// The opacity from which ps_transparent_ids writes a surface's ID and depth. A glass of low opacity is picked wherever
// it shows; only where a surface does not show at all, such as a texture's cut-out texels, does the editor pick what is
// behind.
static const float TRANSPARENT_ID_CUTOFF = 1.0 / 255.0;

struct Moment_Targets {
	float b0 : SV_Target0;
	float4 moments : SV_Target1;
};

// view_depth is a pixel's depth from the view, from its reversed depth with the far plane at infinity.
float view_depth(Varyings i) {
	return frame.near / max(i.position.z, 1e-7);
}

Moment_Targets ps_moments(Varyings i, bool front : SV_IsFrontFace) {
	Material_Inputs inputs = material_inputs(i, front);
	Surface s = evaluate(inputs);
	Moment_Targets o;
	// The overdraw view counts the layers instead (see docs/rendering/post-processing.md#debug-views).
	if (frame.debug_view == DEBUG_TRANSPARENT_OVERDRAW) {
		o.b0 = 1;
		o.moments = 0;
		return o;
	}
	float depth = optical_depth(saturate(shade_opacity(s)));
	o.b0 = depth;
	o.moments = depth_moments(warp_depth(view_depth(i), frame.near), depth);
	return o;
}

float4 ps_transparent(Varyings i, bool front : SV_IsFrontFace) : SV_Target0 {
	Material_Inputs inputs = material_inputs(i, front);
	Surface s = evaluate(inputs);
	float alpha = saturate(shade_opacity(s));
#if MATERIAL_ADDITIVE
	// Light that adds to what is behind: it covers nothing.
	return float4(forward_color(i, inputs, s, 0) * alpha, 0);
#else
	float3 color = forward_color(i, inputs, s, 1);
	float transmittance = 1;
	if (push.transmittance != 0) {
		int3 pixel = int3(i.position.xy, 0);
		float b0 = cn_texture(push.moments_zeroth).Load(pixel).r;
		float4 moments = cn_texture(push.moments).Load(pixel);
		transmittance = transmittance_at(b0, moments, warp_depth(view_depth(i), frame.near));
	}
	return float4(color, 1) * alpha * transmittance;
#endif
}

uint ps_transparent_ids(Varyings i, bool front : SV_IsFrontFace) : SV_Target0 {
	Material_Inputs inputs = material_inputs(i, front);
	Surface s = evaluate(inputs);
	clip(shade_opacity(s) - TRANSPARENT_ID_CUTOFF);
	return i.id;
}

#endif
