// Hit shading's fallback bin (see docs/rendering/ray-scene.md#hit-shading): the hits whose material was not evaluated,
// a translucent one's or one whose hit pipeline is not ready, are a grey surface with the triangle's normal.
#define MATERIAL_HIT 1
#include "material_common.hlsli"
#include "material_hit_common.hlsli"

static const float3 FALLBACK_ALBEDO = 0.5;

[numthreads(HIT_GROUP_SIZE, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint ray;
	if (!hit_ray(id.x, ray)) {
		return;
	}
	Hit_Triangle tri = load_hit_triangle(ray);
	uint flags = HIT_SURFACE_FALLBACK | (tri.front ? 0 : HIT_SURFACE_BACK);
	store_hit_surface(ray, pack_hit_surface(tri.position, tri.facing, tri.facing, FALLBACK_ALBEDO, 0, 1, flags));
}
