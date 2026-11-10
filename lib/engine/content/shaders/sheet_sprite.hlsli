// What the sprite renderers' two shaders share (see docs/rendering/2d.md#drawing): the records, the quad's vertex, the
// color and the ID. sheet_sprite.hlsl and sheet_sprite_ids.hlsl include it, each with its own entry points, since the
// cooker finds a shader's stages by their entry points in its own file.
#ifndef SHEET_SPRITE_HLSLI
#define SHEET_SPRITE_HLSLI

#define MATERIAL_PUSH Sheet_Sprite_Push
// Matches Sheet_Sprite_Push in lib/engine/render/sheet_sprites.odin. It starts with Material_Push's shadow textures,
// which the light loop reads, and has the fog volume in fog, as fog_at reads it.
struct Sheet_Sprite_Push {
	uint shadow_atlas;
	uint shadow_mask;
	uint fog;
	uint records;
	uint records_offset;
	uint padding;
};
#define SHADING_NO_LIGHTING 1
#include "material_lighting.hlsli"
#include "fog_at.hlsli"

// Matches Sheet_Sprite_Record in lib/engine/render/sheet_sprites.odin. center is the pivot's place relative to the
// camera, and right and up are the frame's whole width and height in the world. uv_rect is the frame's corner and size
// in the texture, and pivot the share of the frame that is left of and below the center.
struct Sheet_Sprite_Record {
	float3 center;
	uint texture;
	float3 right;
	uint sampler_index;
	float3 up;
	uint id;
	float4 uv_rect;
	float4 color;
	float2 pivot;
	uint flags;
	uint padding;
};

// Match SHEET_SPRITE_LIT and SHEET_SPRITE_SNAP in lib/engine/render/sheet_sprites.odin.
static const uint SHEET_SPRITE_LIT = 1;
static const uint SHEET_SPRITE_SNAP = 2;

// A sprite scatters a light toward the camera as a Lambert surface does at this cosine, from whichever side the light
// is: a 2D scene's lights are in the plane of its sprites.
static const float SHEET_SPRITE_COSINE = 0.5;
// A texel more clear than this has no ID.
static const float SHEET_SPRITE_ID_CUTOFF = 0.1;

struct Varyings {
	float4 position : SV_Position;
	float2 uv : TEXCOORD0;
	// Relative to the camera.
	float3 world : WORLD;
	nointerpolation uint index : INDEX;
};

static const float2 CORNERS[6] = {float2(0, 0), float2(1, 0), float2(1, 1), float2(0, 0), float2(1, 1), float2(0, 1)};

Sheet_Sprite_Record load_sheet_sprite(uint index) {
	return cn_buffer(push.records).Load<Sheet_Sprite_Record>(push.records_offset + index * sizeof(Sheet_Sprite_Record));
}

// sheet_sprite_vertex places a corner of a sprite's quad.
Varyings sheet_sprite_vertex(uint vertex_id) {
	uint index = vertex_id / 6;
	Sheet_Sprite_Record r = load_sheet_sprite(index);
	float2 corner = CORNERS[vertex_id % 6];
	Varyings o;
	o.world = r.center + r.right * (corner.x - r.pivot.x) + r.up * (corner.y - r.pivot.y);
	bool snap = (r.flags & SHEET_SPRITE_SNAP) != 0;
	// A snapped sprite draws without the camera's jitter, which would move its texels within their pixels, and with its
	// pivot on a corner of the screen's pixels, so its texels fall on whole pixels when they are a whole count of pixels wide.
	if (snap) {
		o.position = mul(frame.cluster_view_projection, float4(o.world, 1));
		float4 center = mul(frame.cluster_view_projection, float4(r.center, 1));
		float2 pixel = (center.xy / max(center.w, 1e-7) * 0.5 + 0.5) * frame.screen_size;
		float2 moved = (round(pixel) - pixel) / frame.screen_size * 2;
		o.position.xy += moved * o.position.w;
	} else {
		o.position = mul(frame.view_projection, float4(o.world, 1));
	}
	// The texture's v goes down, and the quad's y up.
	o.uv = r.uv_rect.xy + float2(corner.x, 1 - corner.y) * r.uv_rect.zw;
	o.index = index;
	return o;
}

float4 sheet_sprite_texel(Sheet_Sprite_Record r, float2 uv) {
	return cn_texture(r.texture).Sample(cn_sampler(r.sampler_index), uv);
}

float sheet_sprite_shadow(Light_Record light, Light reaching, float3 p, float depth) {
	// A light with a channel of the shadow mask has no shadow maps, so it does not shadow sprites, as it does not shadow
	// other transparent surfaces.
	if (light.mask >= 0) {
		return 1;
	}
	return map_shadow(light, p, 0, reaching.direction, depth);
}

// sheet_sprite_color is a sprite's color at a pixel, premultiplied by its opacity.
float4 sheet_sprite_color(Varyings i) {
	Sheet_Sprite_Record r = load_sheet_sprite(i.index);
	float4 texel = sheet_sprite_texel(r, i.uv) * r.color;
	if (texel.a <= 0) {
		discard;
	}
	float3 p = i.world;
	float3 light = 1;
	if ((r.flags & SHEET_SPRITE_LIT) != 0) {
		float depth = max(view_z(frame.projection, i.position.z), frame.projection.z);
		light = 0;
		for (uint k = 0; k < frame.directional_count; k++) {
			Light_Record l = load_light(k);
			Light reaching = light_falloff(l, p);
			light += reaching.color * sheet_sprite_shadow(l, reaching, p, depth);
		}
		if (frame.clustered != 0) {
			uint2 range = cn_buffer(frame.clusters).Load2(cluster_at(p, depth) * 8);
			ByteAddressBuffer indices = cn_buffer(frame.cluster_indices);
			for (uint j = 0; j < range.y; j++) {
				Light_Record l = load_light(indices.Load((range.x + j) * 4));
				Light reaching = light_falloff(l, p);
				if (any(reaching.color > 0)) {
					light += reaching.color * sheet_sprite_shadow(l, reaching, p, depth);
				}
			}
		}
		light = light * (SHEET_SPRITE_COSINE / PI) + ambient_average(frame.ambient);
	}
	float4 fog = frame.fog != 0 ? fog_at(p) : float4(0, 0, 0, 1);
	float3 color = (texel.rgb * light * fog.a + fog.rgb) * frame_exposure();
	// Premultiplied, so the blend adds it over what is behind.
	return float4(color * texel.a, texel.a);
}

// sheet_sprite_id is a sprite's entity ID at a pixel, where the sprite is not clear.
uint sheet_sprite_id(Varyings i) {
	Sheet_Sprite_Record r = load_sheet_sprite(i.index);
	if (sheet_sprite_texel(r, i.uv).a * r.color.a < SHEET_SPRITE_ID_CUTOFF) {
		discard;
	}
	return r.id;
}

#endif
