// The voxel cones' injection (see docs/rendering/global-illumination.md#voxel-cones): a thread for each voxel of a
// level, which sends out the light that its surfaces reflect and emit, premultiplied by their opacity. Each light's
// shadow is a narrow cone toward it through the voxels' opacity, so a voxel off the screen is shadowed as one on it,
// with no shadow map or ray. The light that bounces is a wide cone along the normal through the next level's light,
// which this frame's injection has not reached yet, so it is last frame's: light bounces once more each frame. A voxel
// that a finer level covers is left to the filter, which averages the finer one's.
#include "gi_voxel_pass.hlsli"

// The bounce's cone is 90 degrees wide.
static const float BOUNCE_APERTURE = 1;

// voxel_shadow is how much of a light gets through the voxels from a point toward it, within a distance: a narrow cone
// through the levels' opacity, from those that the voxelization wrote, never finer than the voxel's level.
float voxel_shadow(Voxel_Grid g, uint k, float3 p, float3 direction, float distance) {
	float finest = voxel_size(g.levels[0]);
	float size = voxel_size(g.levels[k]);
	float t = size;
	float visible = 1;
	for (uint i = 0; i < VOXEL_MAX_STEPS && visible > 0.01 && t < distance; i++) {
		float3 q = p + direction * t;
		float width = max(2 * g.shadow_aperture * t, size);
		uint level = voxel_level_of(g, clamp(uint(log2(width / finest)), k, g.level_count - 1), q, 0);
		if (level >= g.level_count) {
			break;
		}
		Voxel_Level l = g.levels[level];
		int3 cell = int3(floor(voxel_local(l, q)));
		uint mask = cn_uint_texture3d(NonUniformResourceIndex(l.mask.x)).Load(int4(voxel_texel(g, level, cell), 0));
		float s = voxel_size(l);
		float step = max(width, s) * VOXEL_STEP;
		visible *= pow(saturate(1 - voxel_opacity(mask)), step / s);
		t += step;
	}
	return visible;
}

// voxel_direct is one light's light on a voxel's surface, which falls off with the cosine to its normal.
float3 voxel_direct(Voxel_Grid g, uint k, Light_Record l, float3 p, float3 normal) {
	Light light = light_falloff(l, p);
	float cosine = saturate(dot(normal, light.direction));
	if (cosine <= 0 || all(light.color <= 0)) {
		return 0;
	}
	float distance = l.type == LIGHT_DIRECTIONAL ? 1e6 : length(l.position - p);
	return light.color * cosine * voxel_shadow(g, k, p, light.direction, distance);
}

[numthreads(VOXEL_GROUP, VOXEL_GROUP, VOXEL_GROUP)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Voxel_Grid g = frame_voxel_grid();
	if (any(id >= g.res)) {
		return;
	}
	uint k = push.level;
	Voxel_Level l = g.levels[k];
	float3 p = voxel_cell_center(l, int3(id));
	if (k > 0 && voxel_inside(g, k - 1, p, 0)) {
		return;
	}
	uint3 texel = voxel_texel(g, k, int3(id));
	RWTexture3D<float4> radiance = cn_rw_texture3d(l.writes.w);
	float opacity = voxel_opacity(cn_uint_texture3d(l.mask.x).Load(int4(texel, 0)));
	float3 light = 0;
	if (opacity > 0) {
		float3 albedo = voxel_albedo(cn_uint_texture3d(l.reads.x).Load(int4(texel, 0)));
		float3 normal = voxel_normal(cn_uint_texture3d(l.reads.y).Load(int4(texel, 0)));
		float size = voxel_size(l);
		light = voxel_emission(cn_uint_texture3d(l.reads.z).Load(int4(texel, 0)));
		if (any(albedo > 0)) {
			// The shadows and the bounce start off the surfaces, so the voxel and its neighbours on them do not block them.
			float3 origin = p + normal * size;
			float3 direct = 0;
			for (uint i = 0; i < frame.directional_count; i++) {
				direct += voxel_direct(g, k, load_light(i), origin, normal);
			}
			for (uint n = 0; n < g.light_count; n++) {
				uint index = cn_buffer(g.lights).Load(g.lights_offset + n * 4);
				direct += voxel_direct(g, k, load_light(index), origin, normal);
			}
			float3 bounce = ambient_light(frame.ambient, normal);
			if (k + 1 < g.level_count) {
				float next = voxel_size(g.levels[k + 1]);
				float4 c = cone_trace(g, origin, normal, BOUNCE_APERTURE, next, 1e6, k + 1);
				bounce = c.rgb + (1 - c.a) * bounce;
			}
			light += albedo / PI * direct + albedo * bounce;
		}
	}
	float4 result = float4(light * opacity, opacity);
	radiance[texel] = result;
}
