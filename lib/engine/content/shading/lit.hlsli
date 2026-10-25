// The Lit shading model (lit.shading): metallic and roughness, GGX specular with Smith visibility and Schlick's
// Fresnel, and Lambert diffuse. See docs/rendering.md#shading-models.

float3 lit_f0(Surface s) {
	return lerp(0.04, s.base_color, s.metallic);
}

float3 shade_direct(Surface s, Shading_Point p, Light light) {
	float3 n = p.normal;
	float3 v = p.view;
	float3 l = light.direction;
	float nl = saturate(dot(n, l));
	if (nl <= 0) {
		return 0;
	}
	float3 h = normalize(v + l);
	float nv = max(dot(n, v), 1e-4);
	float nh = saturate(dot(n, h));
	float vh = saturate(dot(v, h));
	float a = max(s.roughness * s.roughness, 2e-3);
	float a2 = a * a;
	float denominator = nh * nh * (a2 - 1) + 1;
	float distribution = a2 / (PI * denominator * denominator);
	float k = a * 0.5;
	float visibility = 0.25 / ((nv * (1 - k) + k) * (nl * (1 - k) + k));
	float3 fresnel = lit_f0(s) + (1 - lit_f0(s)) * pow(1 - vh, 5);
	float3 specular = distribution * visibility * fresnel;
	float3 diffuse = (1 - fresnel) * (1 - s.metallic) * s.base_color / PI;
	return (diffuse + specular) * light.color * nl;
}

// An area light, by linearly transformed cosines: the specular lobe's, fitted to shade_direct's GGX (see ltc.hlsli),
// and Lambert's for the diffuse, which takes the Fresnel at the light's middle as shade_direct does.
float3 shade_area(Surface s, Shading_Point p, Area_Light light) {
	float3 n = p.normal;
	float3 v = p.view;
	Ltc_Ggx ggx = ltc_ggx(s.roughness, dot(n, v));
	float3 f0 = lit_f0(s);
	float3 specular = (f0 * ggx.magnitude + (1 - f0) * ggx.fresnel) * ltc_integral(light, n, v, ggx.inverse);
	float vh = saturate(dot(v, normalize(v + normalize(light.center))));
	float3 fresnel = f0 + (1 - f0) * pow(1 - vh, 5);
	float3 diffuse = (1 - fresnel) * (1 - s.metallic) * s.base_color * ltc_integral(light, n, v, float3x3(1, 0, 0, 0, 1, 0, 0, 0, 1));
	return (diffuse + specular) * light.color;
}

// The indirect light, with Karis's analytic fit of the environment BRDF for the specular part.
float3 shade_indirect(Surface s, Shading_Point p, Indirect indirect) {
	float nv = saturate(dot(p.normal, p.view));
	const float4 c0 = float4(-1, -0.0275, -0.572, 0.022);
	const float4 c1 = float4(1, 0.0425, 1.04, -0.04);
	float4 r = s.roughness * c0 + c1;
	float a004 = min(r.x * r.x, exp2(-9.28 * nv)) * r.x + r.y;
	float2 environment = float2(-1.04, 1.04) * a004 + r.zw;
	float3 specular = indirect.specular * (lit_f0(s) * environment.x + environment.y);
	float3 diffuse = indirect.diffuse * s.base_color * (1 - s.metallic);
	return diffuse + specular;
}

float3 shade_emission(Surface s) {
	return s.emission;
}

float shade_opacity(Surface s) {
	return s.opacity;
}
