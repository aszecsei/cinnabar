// The evaluate of the preview_surface materials, which a USD stage's UsdPreviewSurface materials are instances of (see
// docs/content/kinds/stages.md#materials). A connected texture replaces its input's value, as UsdPreviewSurface defines
// it; the switches say which inputs are textures. The cooker writes each mask that a material reads into red, whatever
// channel the stage reads it from.

Surface evaluate(Material_Inputs inputs) {
	Surface s = default_surface();
	float2 uv = inputs.uv0;
#if use_uv1
	uv = inputs.uv1;
#endif
#if use_uv_transform
	uv = uv * params.uv_transform.xy + params.uv_transform.zw;
#endif
	float4 base = float4(params.base_color.rgb, 1);
#if has_base_color_tex
	base = cn_sample(params.base_color_tex, uv);
#endif
	s.base_color = base.rgb;
	s.metallic = params.metallic;
#if has_metallic_tex
	s.metallic = cn_sample(params.metallic_tex, uv).r;
#endif
	s.roughness = params.roughness;
#if has_roughness_tex
	s.roughness = cn_sample(params.roughness_tex, uv).r;
#endif
#if has_normal_tex
	s.normal = cn_normal_map(params.normal_tex, uv);
#endif
	s.emission = params.emissive.rgb;
#if has_emissive_tex
	s.emission = cn_sample(params.emissive_tex, uv).rgb;
#endif
	float opacity = params.opacity;
#if opacity_from_base_alpha
	opacity = base.a;
#elif has_opacity_tex
	opacity = cn_sample(params.opacity_tex, uv).r;
#endif
#if MATERIAL_MASKED
	// UsdPreviewSurface cuts at its own opacityThreshold, and the material at its cutoff.
	opacity = opacity >= params.opacity_threshold ? 1 : 0;
#endif
	s.opacity = opacity;
	return s;
}
