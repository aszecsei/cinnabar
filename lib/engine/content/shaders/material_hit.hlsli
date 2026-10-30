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
	// The diffuse albedo is the shading model's indirect light from a white surrounding, without its specular part.
#if SHADING_NO_LIGHTING
	float3 albedo = 0;
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
#endif
#if SHADING_HAS_ROUGHNESS
	float roughness = s.roughness;
#else
	float roughness = 1;
#endif
	float3 emission = min(shade_emission(s), 65000);
	store_hit_surface(ray, pack_hit_surface(tri.position, normal, tri.facing, albedo, emission, roughness, flags));
}
