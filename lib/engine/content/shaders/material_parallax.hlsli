// Parallax occlusion mapping (see docs/rendering/materials.md#parallax-occlusion-mapping): a height map marched along the view
// in tangent space, so a flat surface shows relief where its texture is seen from the side. The Parallax Occlusion
// node calls cn_parallax. material_common.hlsli includes this file.
#ifndef MATERIAL_PARALLAX_HLSLI
#define MATERIAL_PARALLAX_HLSLI

// The most layers a march takes, whatever the node asks for.
static const float PARALLAX_MAX_STEPS = 64;
// How edge on the view may be: below this, the offset per layer would run away.
static const float PARALLAX_MIN_VIEW_Z = 0.05;

// cn_parallax is the UV where the view ray through the surface's point meets the height map, and the height there. The
// map's red channel is the height: 1 at the surface, 0 at scale below it, where scale is in UV units. It marches from
// the surface down in equal layers, more of them the more edge on the view is, and interpolates between the last two
// layers for where the ray crossed the surface. The samples take the pixel's derivatives of the UV before the march,
// since the march's steps differ between neighbouring pixels. The depth is not moved: the forward pass's Equal depth
// test and early depth stay, and silhouettes do not change. At a ray's hit, which has no derivatives, it gives the UV
// as it is.
float3 cn_parallax(uint height_texture, float2 uv, float scale, float steps, Material_Inputs inputs) {
#if MATERIAL_HIT
	return float3(uv, 1);
#else
	float3 n = inputs.normal;
	float3 t = normalize(inputs.tangent.xyz - n * dot(inputs.tangent.xyz, n));
	float3 b = cross(n, t) * inputs.tangent.w;
	float3 view = float3(dot(inputs.view, t), dot(inputs.view, b), dot(inputs.view, n));
	float count = clamp(lerp(steps, steps * 0.25, saturate(view.z)), 1, PARALLAX_MAX_STEPS);
	float2 uv_dx = ddx(uv);
	float2 uv_dy = ddy(uv);
	// Each layer is deeper by 1 / count of the map's range, and a point that deep on the ray away from the camera is
	// seen at the UV moved against the view's tangent-space direction.
	float layer = 1 / count;
	float2 delta = -view.xy / max(view.z, PARALLAX_MIN_VIEW_Z) * scale * layer;
	float2 current = uv;
	float depth = 0;
	float height = cn_sample_grad(height_texture, current, uv_dx, uv_dy).r;
	float previous_height = height;
	[loop]
	for (float i = 0; i < count && depth < 1 - height; i += 1) {
		current += delta;
		depth += layer;
		previous_height = height;
		height = cn_sample_grad(height_texture, current, uv_dx, uv_dy).r;
	}
	// The ray is below the surface at this layer and was above it at the last: the crossing is between them, by how
	// far each is from the surface. A ray that reached the bottom without crossing takes its last layer.
	float after = depth - (1 - height);
	float before = (1 - previous_height) - (depth - layer);
	float w = after > 0 ? saturate(after / max(after + before, 1e-5)) : 0;
	return float3(lerp(current, current - delta, w), lerp(height, previous_height, w));
#endif
}

#endif
