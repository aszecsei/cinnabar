// The sprites' light (see docs/rendering/transparency.md#sprites): a group for each sprite, whose threads light an 8x8
// grid of points on it, as the paper's particle lightmap does. Each point takes every directional light and its
// cluster's punctual lights with their shadow maps, as a surface lit from every side would, the global illumination at
// the opaque surface behind it or the ambient light, and the fog between it and the camera. light holds the light,
// dimmed by the fog, in rgb and the share of light that the fog lets through in a; fog_light holds the fog's own light.
#define MATERIAL_PUSH Light_Push
// Matches Light_Push in lib/engine/render/sprites.odin. It starts with Material_Push's shadow textures, which the light
// loop reads, and has the fog volume in fog, as fog_at reads it.
struct Light_Push {
	uint shadow_atlas;
	uint shadow_mask;
	uint fog;
	uint gi_diffuse;
	uint records;
	uint records_offset;
	uint count;
	uint light;
	uint fog_light;
};
#define SHADING_NO_LIGHTING 1
#include "material_lighting.hlsli"
#include "fog_at.hlsli"
#include "sprites.hlsli"

// A sprite's point scatters a light toward the camera as a Lambert surface does at this cosine: the mean over the two
// sides of a sprite, which is lit from wherever its light comes.
static const float SPRITE_COSINE = 0.5;

// sprite_shadow is how lit a point of a sprite is by a light, from its shadow maps. A light with a channel of the shadow
// mask has none, so it does not shadow sprites, as it does not shadow other transparent surfaces.
float sprite_shadow(Light_Record light, Light reaching, float3 p, float depth) {
	if (light.mask >= 0) {
		return 1;
	}
	int view = shadow_view(light, p, depth);
	return view < 0 ? 1 : shadow_map(uint(view), p, 0, reaching.direction);
}

[numthreads(SPRITE_LIGHT_TEXELS, SPRITE_LIGHT_TEXELS, 1)]
void cs_main(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
	uint index = group.y * SPRITE_LIGHT_COLUMNS + group.x;
	if (index >= push.count) {
		return;
	}
	Sprite_Record r = load_sprite(push.records, push.records_offset, index);
	float2 q = (float2(thread.xy) + 0.5) / SPRITE_LIGHT_TEXELS * 2 - 1;
	float2 rotation = float2(cos(r.rotation), sin(r.rotation));
	float3 right = rotation.x * frame.camera_right.xyz + rotation.y * frame.camera_up.xyz;
	float3 up = rotation.x * frame.camera_up.xyz - rotation.y * frame.camera_right.xyz;
	float3 p = r.position + r.size * (q.x * right + q.y * up);
	float4 clip = mul(frame.cluster_view_projection, float4(p, 1));
	float depth = max(clip.w, frame.near);

	float3 light = 0;
	for (uint i = 0; i < frame.directional_count; i++) {
		Light_Record l = load_light(i);
		Light reaching = light_falloff(l, p);
		light += reaching.color * sprite_shadow(l, reaching, p, depth);
	}
	if (frame.clustered != 0) {
		uint2 range = cn_buffer(frame.clusters).Load2(cluster_at(p, depth) * 8);
		ByteAddressBuffer indices = cn_buffer(frame.cluster_indices);
		for (uint j = 0; j < range.y; j++) {
			Light_Record l = load_light(indices.Load((range.x + j) * 4));
			Light reaching = light_falloff(l, p);
			if (any(reaching.color > 0)) {
				light += reaching.color * sprite_shadow(l, reaching, p, depth);
			}
		}
	}
	light *= SPRITE_COSINE / PI;
	if (frame.gi != 0) {
		float2 pixel = (clip.xy / depth * float2(0.5, -0.5) + 0.5) * frame.screen_size;
		light += load_screen(push.gi_diffuse, clamp(pixel, 0, frame.screen_size - 1)).rgb;
	} else {
		light += 0.5 * (frame.sky_color.rgb + frame.ground_color.rgb);
	}
	float4 fog = frame.fog != 0 ? fog_at(p) : float4(0, 0, 0, 1);
	uint2 texel = group.xy * SPRITE_LIGHT_TEXELS + thread.xy;
	cn_rw_texture(push.light)[texel] = float4(light * fog.a, fog.a);
	cn_rw_texture(push.fog_light)[texel] = float4(fog.rgb, 1);
}
