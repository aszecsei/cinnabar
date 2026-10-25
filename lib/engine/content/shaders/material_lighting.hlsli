// The forward pass's light loop (see docs/rendering.md#lights-and-clusters): every directional light, then the
// punctual and area lights of the pixel's cluster, each with its shadow from the shadow mask or the shadow maps. The
// shading model shades each light; this file only finds the lights and how much of each reaches the point.
#ifndef MATERIAL_LIGHTING_HLSLI
#define MATERIAL_LIGHTING_HLSLI

#include "material_common.hlsli"

// Match CLUSTER_TILE and CLUSTER_SLICES in lib/engine/render/lights.odin.
static const uint CLUSTER_TILE = 64;
static const uint CLUSTER_SLICES = 32;
// Matches FOG_SLICES in lib/engine/render/fog.odin: the fog volume halves each of the clusters' depth slices.
static const uint FOG_SLICES = CLUSTER_SLICES * 2;

Light_Record load_light(uint index) {
	return cn_buffer(frame.lights).Load<Light_Record>(frame.lights_offset + index * sizeof(Light_Record));
}

// cluster_at is the cluster of a point at a view depth.
uint cluster_at(float3 p, float depth) {
	float4 clip = mul(frame.cluster_view_projection, float4(p, 1));
	float2 pixel = (clip.xy / max(clip.w, 1e-7) * float2(0.5, -0.5) + 0.5) * frame.screen_size;
	uint2 tile = min(uint2(max(pixel, 0)) / CLUSTER_TILE, uint2(frame.cluster_columns, frame.cluster_rows) - 1);
	uint slice = uint(clamp(log2(depth) * frame.slice_scale + frame.slice_bias, 0, CLUSTER_SLICES - 1));
	return (slice * frame.cluster_rows + tile.y) * frame.cluster_columns + tile.x;
}

// cluster_of is the cluster of a point: its tile of the screen as the camera's projection places it, and the depth
// slice of its view depth, which slices exponentially from the near plane. The view model's pixels are elsewhere on the
// screen than the camera's projection would place their points, so the tile comes from the point, not the pixel.
uint cluster_of(float3 p, float4 position) {
	return cluster_at(p, frame.near / max(position.z, 1e-7));
}

// light_count is how many lights shade a point: every directional light, and its cluster's.
uint light_count(float3 p, float4 position) {
	uint count = frame.directional_count;
	if (frame.clustered != 0) {
		count += cn_buffer(frame.clusters).Load2(cluster_of(p, position) * 8).y;
	}
	return count;
}

// cascade_at is the index of the directional lights' cascade that reaches a view depth, or 4 beyond the last.
uint cascade_at(float depth) {
	uint cascade = 0;
	[unroll] for (uint c = 0; c < 4; c++) {
		cascade += depth > frame.cascade_splits[c] ? 1 : 0;
	}
	return cascade;
}

float4 shadow_clip(Shadow_View view, float3 p) {
	float4 v = float4(p, 1);
	return float4(dot(view.rows[0], v), dot(view.rows[1], v), dot(view.rows[2], v), dot(view.rows[3], v));
}

// shadow_map is how lit a point is in one shadow view: the fraction of a 3x3 texel neighbourhood that is nearer the
// light than the point, from four bilinear comparisons. The point moves along its normal by a texel's size first, so a
// surface does not shadow itself. Outside the view, it is lit.
float shadow_map(uint view_index, float3 p, float3 normal) {
	Shadow_View view = cn_buffer(frame.shadow_views).Load<Shadow_View>(frame.shadow_views_offset + view_index * sizeof(Shadow_View));
	float4 clip = shadow_clip(view, p);
	float texel = view.texel * (view.perspective != 0 ? clip.w : 1);
	clip = shadow_clip(view, p + normal * texel * 1.5);
	float3 ndc = clip.xyz / clip.w;
	float2 uv = ndc.xy * float2(0.5, -0.5) + 0.5;
	if (clip.w <= 0 || any(uv < 0) || any(uv > 1) || ndc.z < 0) {
		return 1;
	}
	float2 atlas_size;
	Texture2D<float4> atlas = cn_texture(push.shadow_atlas);
	atlas.GetDimensions(atlas_size.x, atlas_size.y);
	float2 texel_uv = 1 / atlas_size;
	// The taps stay a texel inside the view's rectangle, so they never read a neighbouring view.
	float2 low = view.rect.xy + texel_uv * 1.5;
	float2 high = view.rect.xy + view.rect.zw - texel_uv * 1.5;
	float2 center = view.rect.xy + uv * view.rect.zw;
	SamplerComparisonState s = cn_comparison_sampler(frame.shadow_sampler);
	float lit = 0;
	[unroll] for (uint i = 0; i < 4; i++) {
		float2 offset = float2((i & 1) != 0 ? 0.5 : -0.5, (i & 2) != 0 ? 0.5 : -0.5) * texel_uv;
		lit += atlas.SampleCmpLevelZero(s, clamp(center + offset, low, high), ndc.z);
	}
	return lit * 0.25;
}

// shadow_view is the shadow map view of a light at a point at a view depth, or -1 for none: a directional light's first
// cascade that reaches the depth, none beyond the last, or a point light's cube face.
int shadow_view(Light_Record light, float3 p, float depth) {
	if (light.shadow < 0) {
		return -1;
	}
	int view = light.shadow;
	switch (light.type) {
	case LIGHT_DIRECTIONAL: {
		int cascade = int(cascade_at(depth));
		if (cascade >= 4) {
			return -1;
		}
		view += cascade;
		break;
	}
	case LIGHT_POINT:
	case LIGHT_QUAD:
	case LIGHT_DISK:
	case LIGHT_LINE: {
		// The cube face of the direction from the light: +x, -x, +y, -y, +z, -z. An area light's cube is at its middle.
		float3 d = p - light.position;
		float3 a = abs(d);
		int face = a.x >= a.y && a.x >= a.z ? (d.x >= 0 ? 0 : 1) : (a.y >= a.z ? (d.y >= 0 ? 2 : 3) : (d.z >= 0 ? 4 : 5));
		view += face;
		break;
	}
	}
	return view;
}

// light_shadow is how lit a point is by one light: its channel of the shadow mask, or its shadow maps, or 1.
float light_shadow(Light_Record light, float3 p, float3 normal, float4 position) {
	if (light.mask >= 0) {
		return cn_texture(push.shadow_mask).Load(int3(position.xy, 0))[light.mask];
	}
	int view = shadow_view(light, p, frame.near / max(position.z, 1e-7));
	return view < 0 ? 1 : shadow_map(uint(view), p, normal);
}

// range_window is 1 near a light and 0 at its range: saturate(1 - (d / range)^4)^2.
float range_window(float distance2, float range) {
	float window = saturate(1 - distance2 * distance2 / (range * range * range * range));
	return window * window;
}

// light_falloff is one light as it reaches a point, before its shadow: the direction toward it, and its light there.
// A punctual light falls off with the square of the distance, windowed to 0 at its range. The fog sees an area light as
// a point light at its middle, whose light a quad or a disk sends out with the cosine of its face.
Light light_falloff(Light_Record l, float3 p) {
	Light light;
	if (l.type == LIGHT_DIRECTIONAL) {
		light.direction = -l.direction;
		light.color = l.color;
	} else {
		float3 d = l.position - p;
		float distance2 = max(dot(d, d), 1e-4);
		light.direction = d * rsqrt(distance2);
		float falloff = range_window(distance2, l.range) / distance2;
		if (l.type == LIGHT_SPOT) {
			float cone = saturate(dot(-light.direction, l.direction) * l.spot_scale + l.spot_offset);
			falloff *= cone * cone;
		} else if (l.type == LIGHT_QUAD || l.type == LIGHT_DISK) {
			float face = dot(-light.direction, l.direction);
			falloff *= (l.flags & LIGHT_TWO_SIDED) != 0 ? abs(face) : saturate(face);
		}
		light.color = l.color * falloff;
	}
	return light;
}

// light_at is one light as it reaches a point, after its falloff and its shadow.
Light light_at(Light_Record l, float3 p, float3 normal, float4 position) {
	Light light = light_falloff(l, p);
	if (any(light.color > 0) && dot(normal, light.direction) > 0) {
		light.color *= light_shadow(l, p, normal, position);
	}
	return light;
}

// area_light_at is an area light as it reaches a point: its shape relative to the point, and its radiance, which is
// its color over the area that it shows along its normal (an ideal line's over its length), after its range's window,
// from its middle, and its shadow. A surface that faces away from its middle can still see some of it, so its shadow
// is looked up whatever the normal.
Area_Light area_light_at(Light_Record l, float3 p, float3 normal, float4 position) {
	Area_Light light;
	light.shape = l.type;
	light.center = l.position - p;
	light.axis_x = l.extent;
	float half_x = length(l.extent);
	light.axis_y = cross(l.direction, l.extent / max(half_x, 1e-7)) * l.extent_y;
	light.normal = l.direction;
	light.radius = l.extent_y;
	light.two_sided = (l.flags & LIGHT_TWO_SIDED) != 0;
	float area;
	switch (l.type) {
	case LIGHT_QUAD:
		area = 4 * half_x * l.extent_y;
		break;
	case LIGHT_DISK:
		area = PI * half_x * l.extent_y;
		break;
	default:
		area = l.extent_y > 0 ? 4 * half_x * l.extent_y + PI * l.extent_y * l.extent_y : 2 * half_x;
		break;
	}
	light.color = l.color / max(area, 1e-7) * range_window(dot(light.center, light.center), l.range);
	if (any(light.color > 0)) {
		light.color *= light_shadow(l, p, normal, position);
	}
	return light;
}

#if !SHADING_NO_LIGHTING
// shade_light is one light's shading at a point, by the shading model's shade_area for an area light and its
// shade_direct for the others.
float3 shade_light(Surface s, Shading_Point p, Light_Record l, float3 normal, float4 position) {
	if (l.type >= LIGHT_QUAD) {
		return shade_area(s, p, area_light_at(l, p.position, normal, position));
	}
	return shade_direct(s, p, light_at(l, p.position, normal, position));
}

// direct_light adds every light's shading at a point. normal is the geometric normal, which the shadows offset along.
float3 direct_light(Surface s, Shading_Point p, float3 normal, float4 position) {
	float3 color = 0;
	for (uint i = 0; i < frame.directional_count; i++) {
		color += shade_direct(s, p, light_at(load_light(i), p.position, normal, position));
	}
	if (frame.clustered == 0) {
		return color;
	}
	uint2 range = cn_buffer(frame.clusters).Load2(cluster_of(p.position, position) * 8);
	ByteAddressBuffer indices = cn_buffer(frame.cluster_indices);
	for (uint j = 0; j < range.y; j++) {
		uint index = indices.Load((range.x + j) * 4);
		color += shade_light(s, p, load_light(index), normal, position);
	}
	return color;
}

#endif

#endif
