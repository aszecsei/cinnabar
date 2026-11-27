// A material's hit pass (see docs/rendering/ray-scene.md#hit-shading): cs_hit evaluates the material at the hits of
// its bin, a thread each, and writes each ray's Hit_Surface. The inputs are the hit triangle's, interpolated by the
// ray's barycentrics: the mesh as authored, without a displacement or a billboard's turn. The view is back along the
// ray, and the textures sample the level of the ray's cone (see cn_sample).
#include "material_vertex.hlsli"
#include "material_hit_common.hlsli"

[numthreads(HIT_GROUP_SIZE, 1, 1)]
void cs_hit(uint3 id : SV_DispatchThreadID) {
	uint ray;
	if (!hit_ray(id.x, ray)) {
		return;
	}
	Hit_Triangle tri = load_hit_triangle(ray);
	params = cn_buffer(frame.materials).Load<Params>(frame.materials_offset + tri.submesh.block);
	cn_hit_lod = tri.lod;
	Material_Inputs inputs;
	inputs.position = tri.position - frame.camera_offset.xyz;
	inputs.object_position = tri.local;
	inputs.normal = tri.normal;
	inputs.tangent = tri.tangent;
	inputs.uv0 = tri.uv0;
	inputs.uv1 = tri.uv1;
	inputs.color = tri.color;
	inputs.view = -tri.direction;
	inputs.front_facing = tri.front;
	inputs.time = frame.time;
#if MATERIAL_TWO_SIDED
	// A back face shades as the other side of the surface.
	if (!tri.front) {
		inputs.normal = -inputs.normal;
	}
#endif
	Surface s = evaluate(inputs);
	// A two-sided surface has no back: its back faces are its other side.
	uint flags = tri.front || MATERIAL_TWO_SIDED ? 0 : HIT_SURFACE_BACK;
#if MATERIAL_MASKED
	if (shade_opacity(s) < MATERIAL_CUTOFF) {
		flags |= HIT_SURFACE_CUTOUT;
	}
#endif
	float3 normal = shading_normal(inputs, s);
	// The diffuse albedo is the shading model's indirect light from a white surrounding, without its specular part, and
	// the specular albedo its specular part alone, along the ray: a metal's color, or a dielectric's Fresnel.
#if SHADING_NO_LIGHTING
	float3 albedo = 0;
	float3 specular = 0;
	flags |= HIT_SURFACE_NO_LIGHTING;
#else
	Shading_Point p;
	p.position = inputs.position;
	p.normal = normal;
	p.view = inputs.view;
	Indirect white;
	white.diffuse = 1;
	white.specular = 0;
	float3 albedo = shade_indirect(s, p, white);
	white.diffuse = 0;
	white.specular = 1;
	float3 specular = shade_indirect(s, p, white);
#endif
	float3 emission = shade_emission(s);
#if MATERIAL_TRANSPARENT
	// A translucent surface gives the light that passes through it in place of its emission: what alpha blending lets
	// through, 1 - opacity, tinted toward its albedo by its opacity, or all of it for an additive one, which only adds
	// its own light.
	flags |= HIT_SURFACE_TRANSLUCENT;
#if MATERIAL_ADDITIVE
	emission = 1;
#else
	float opacity = saturate(shade_opacity(s));
#if SHADING_NO_LIGHTING
	emission = 1 - opacity;
#else
	emission = (1 - opacity) * lerp(1, saturate(albedo), opacity);
#endif
#endif
#endif
	store_hit_surface(ray, pack_hit_surface(tri.position, normal, tri.facing, albedo, specular, emission, shading_roughness(s), flags));
}
