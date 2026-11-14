// The forward pass's light loop (see docs/rendering/lighting-and-shadows.md#lights-and-clusters): every directional light, then the
// punctual and area lights of the pixel's cluster, each with its shadow from the shadow mask or the shadow maps. The
// shading model shades each light; this file only finds the lights and how much of each reaches the point.
#ifndef MATERIAL_LIGHTING_HLSLI
#define MATERIAL_LIGHTING_HLSLI

#include "material_common.hlsli"
#include "cloud_shadow.hlsli"
#include "sky_cube.hlsli"
#include "blue_noise.hlsli"
#include "virtual_shadow.hlsli"

// frame_sky_specular is the sky's light along a reflection, from the frame's cubemap at a roughness.
float3 frame_sky_specular(float3 d, float roughness) {
	Sky_Cube c;
	c.current = frame.sky_cube_current;
	c.previous = frame.sky_cube_previous;
	c.blend = frame.sky_cube_blend;
	c.mips = frame.sky_cube_mips;
	c.sampler_index = frame.sky_cube_sampler;
	return sky_specular(c, frame.ambient, d, roughness);
}

// Match CLUSTER_TILE and CLUSTER_SLICES in lib/engine/render/lights.odin.
static const uint CLUSTER_TILE = 64;
static const uint CLUSTER_SLICES = 32;

Light_Record load_light(uint index) {
	return cn_buffer(frame.lights).Load<Light_Record>(frame.lights_offset + index * sizeof(Light_Record));
}

// cluster_at is the cluster of a point at a view depth.
uint cluster_at(float3 p, float depth) {
	float4 clip = mul(frame.cluster_view_projection, float4(p, 1));
	float2 pixel = (clip.xy / max(clip.w, 1e-7) * float2(0.5, -0.5) + 0.5) * frame.screen_size;
	uint2 tile = min(uint2(max(pixel, 0)) / CLUSTER_TILE, uint2(frame.cluster_columns, frame.cluster_rows) - 1);
	uint slice = uint(clamp(slice_of(frame.projection, depth, frame.slice_scale, frame.slice_bias), 0, CLUSTER_SLICES - 1));
	return (slice * frame.cluster_rows + tile.y) * frame.cluster_columns + tile.x;
}

// cluster_of is the cluster of a point: its tile of the screen as the camera's projection places it, and the depth
// slice of its view depth (see slice_of). The view model's pixels are elsewhere on the
// screen than the camera's projection would place their points, so the tile comes from the point, not the pixel.
uint cluster_of(float3 p, float4 position) {
	return cluster_at(p, view_z(frame.projection, position.z));
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

// shadow_map is how lit a point is in one shadow view: the fraction of a texel neighbourhood that is nearer the light
// than the point, from frame.shadow_filter bilinear comparisons, a render.Shadow_Filter: 1 for 2x2 texels, 4 for 3x3,
// 9 for 4x4. Every pixel takes the same branch. Outside the view, it is lit.
//
// The point moves half a texel toward the light first, so the map's own depth precision does not shadow the surface
// that wrote it; that moves no shadow edge. It also moves along its normal by half a texel times the sine of the
// light's angle to the normal, against the taps' spread on a surface the light grazes. An offset along the normal
// moves the shadow's edge across the surface by the offset over the tangent of that angle, so two surfaces that meet
// at a crease disagree on where the shadow crosses their seam by as much; the sine keeps that under half a texel,
// and at nothing where the surface faces the light. The casters' slope bias (SHADOW_SLOPE_BIAS) covers the rest.
float shadow_map(uint view_index, float3 p, float3 normal, float3 to_light) {
	Shadow_View view = cn_buffer(frame.shadow_views).Load<Shadow_View>(frame.shadow_views_offset + view_index * sizeof(Shadow_View));
	float4 clip = shadow_clip(view, p);
	float texel = view.texel * (view.perspective != 0 ? clip.w : 1);
	float cos_light = dot(normal, to_light);
	float sin_light = sqrt(saturate(1 - cos_light * cos_light));
	clip = shadow_clip(view, p + to_light * (texel * 0.5) + normal * (texel * 0.5 * sin_light));
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
	if (frame.shadow_filter == 1) {
		return atlas.SampleCmpLevelZero(s, clamp(center, low, high), ndc.z);
	}
	if (frame.shadow_filter == 9) {
		[unroll] for (uint i = 0; i < 9; i++) {
			float2 offset = float2(float(i % 3) - 1, float(i / 3) - 1) * texel_uv;
			lit += atlas.SampleCmpLevelZero(s, clamp(center + offset, low, high), ndc.z);
		}
		return lit / 9;
	}
	[unroll] for (uint i = 0; i < 4; i++) {
		float2 offset = float2((i & 1) != 0 ? 0.5 : -0.5, (i & 2) != 0 ? 0.5 : -0.5) * texel_uv;
		lit += atlas.SampleCmpLevelZero(s, clamp(center + offset, low, high), ndc.z);
	}
	return lit * 0.25;
}

#if MATERIAL_SCREEN_SHADOWS && !MATERIAL_TRANSPARENT
// vogel is the ith of count points of a disk of radius 1, on a spiral of the golden angle, turned by a rotation's cosine
// and sine. Its points cover the disk evenly for any count.
float2 vogel(uint i, uint count, float2 turn) {
	float r = sqrt((i + 0.5) / count);
	float a = i * 2.39996323;
	float2 d = float2(cos(a), sin(a)) * r;
	return float2(d.x * turn.x - d.y * turn.y, d.x * turn.y + d.y * turn.x);
}

// soft_shadow_map is how lit a point is in a spot or a point light's view of the atlas, with percentage-closer soft
// shadows (see docs/rendering/lighting-and-shadows.md#soft-shadows), for a light of a size in meters: a search for the
// blockers between the point and the light, and a filter as wide as the penumbra that their mean depth gives. The
// point moves as shadow_map moves it. Outside the view, it is lit.
//
// The view's depth is reversed and perspective: a texel holds SHADOW_NEAR over its distance from the light, so the
// ratio of two distances is the inverse ratio of their depths, and the near plane cancels out. The light is size /
// (z * texel) texels wide at the point's distance z. The search reaches as far as a blocker at the near plane could
// stand from the point, which is that times (z / near - 1), and the penumbra is that times (z / z_blocker - 1), each at
// most frame.shadow_soft_radius. The view's guard band (see render.soft_guard) holds what lies past the view's edge out
// to that reach, so the taps never reach a neighbouring view.
//
// A wide filter's taps on a sloped surface compare against the surface's own depth there, not the point's, or the
// surface would shadow itself: each tap's reference is the point's depth plus the receiver plane's slope in the map
// times the tap's offset. The blue noise turns the search's and the filter's taps for each pixel, and temporal AA
// averages them.
float soft_shadow_map(uint view_index, float3 p, float3 normal, float3 to_light, float size, float2 pixel) {
	Shadow_View view = cn_buffer(frame.shadow_views).Load<Shadow_View>(frame.shadow_views_offset + view_index * sizeof(Shadow_View));
	float4 clip = shadow_clip(view, p);
	float texel = view.texel * clip.w;
	float cos_light = dot(normal, to_light);
	float sin_light = sqrt(saturate(1 - cos_light * cos_light));
	float3 q = p + to_light * (texel * 0.5) + normal * (texel * 0.5 * sin_light);
	clip = shadow_clip(view, q);
	float3 ndc = clip.xyz / clip.w;
	float2 uv = ndc.xy * float2(0.5, -0.5) + 0.5;
	if (clip.w <= 0 || any(uv < 0) || any(uv > 1) || ndc.z <= 0) {
		return 1;
	}
	float2 atlas_size;
	Texture2D<float4> atlas = cn_texture(push.shadow_atlas);
	atlas.GetDimensions(atlas_size.x, atlas_size.y);
	float2 texel_uv = 1 / atlas_size;
	float2 low = view.rect.xy + texel_uv * 1.5;
	float2 high = view.rect.xy + view.rect.zw - texel_uv * 1.5;
	float2 center = view.rect.xy + uv * view.rect.zw;

	// The receiver plane's depth per texel of the map: two steps along the surface, projected, give the depth's change
	// and the texels' change, whose inverse gives the slope. At a grazing angle the steps' texels barely change, so
	// the slope is held to where the surface is 85 degrees from the light.
	float3 t1 = normalize(cross(normal, abs(normal.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0)));
	float3 t2 = cross(normal, t1);
	float4 c1 = shadow_clip(view, q + t1 * texel);
	float4 c2 = shadow_clip(view, q + t2 * texel);
	float2 to_texels = float2(0.5, -0.5) * view.rect.zw * atlas_size;
	float3 a = c1.xyz / c1.w - ndc;
	float3 b = c2.xyz / c2.w - ndc;
	float2 ua = a.xy * to_texels;
	float2 ub = b.xy * to_texels;
	float det = ua.x * ub.y - ua.y * ub.x;
	float2 slope = abs(det) > 1e-8 ? float2(ub.y * a.z - ua.y * b.z, ua.x * b.z - ub.x * a.z) / det : 0;
	// A step of a texel along a surface at 85 degrees changes the depth by ndc.z * view.texel * tan(85).
	float max_slope = ndc.z * view.texel * 11.4;
	float slope_length = length(slope);
	slope *= slope_length > max_slope ? max_slope / slope_length : 1;

	float2 noise = frame.shadow_noise != 0 ? blue_noise(frame.shadow_noise, uint2(pixel), frame.shadow_noise_slice) : 0;
	float angle = noise.x * 6.28318531;
	float2 turn = float2(cos(angle), sin(angle));
	float light_texels = size / max(clip.w * view.texel, 1e-7);

	// The blockers: the texels nearer the light than the receiver plane, whose depths are larger.
	float search = min(light_texels * (1 / ndc.z - 1), frame.shadow_soft_radius);
	SamplerState gather_sampler = cn_sampler(frame.shadow_depth_sampler);
	float blockers = 0;
	float inverse_depths = 0;
	for (uint i = 0; i < frame.shadow_soft_search; i++) {
		float2 offset = vogel(i, frame.shadow_soft_search, turn) * search;
		float4 depths = atlas.GatherRed(gather_sampler, clamp(center + offset * texel_uv, low, high));
		float reference = ndc.z + dot(slope, offset);
		[unroll] for (uint k = 0; k < 4; k++) {
			if (depths[k] > reference) {
				blockers += 1;
				inverse_depths += 1 / depths[k];
			}
		}
	}
	// With every texel a blocker the point is likely in the umbra, but the filter still runs: the noise turns the search,
	// so a shortcut to 0 would flicker along the umbra's edge.
	if (blockers == 0) {
		return 1;
	}
	// The blockers' mean distance over the receiver's is the mean of their inverse depths times the receiver's depth.
	float distance_ratio = ndc.z * inverse_depths / blockers;
	float radius = clamp(light_texels * (1 / distance_ratio - 1), 1, frame.shadow_soft_radius);

	SamplerComparisonState s = cn_comparison_sampler(frame.shadow_sampler);
	float lit = 0;
	for (uint j = 0; j < frame.shadow_soft_taps; j++) {
		float2 offset = vogel(j, frame.shadow_soft_taps, turn) * radius;
		lit += atlas.SampleCmpLevelZero(s, clamp(center + offset * texel_uv, low, high), ndc.z + dot(slope, offset));
	}
	return lit / frame.shadow_soft_taps;
}

// virtual_depth_at is the virtual shadow map's depth over a point relative to the camera, from the first level from
// level on that has the point's page, with the point's own depth there, and that level's meters per unit of depth and
// its texel. It is false with no page in any level.
bool virtual_depth_at(float3 p, uint level, out float stored, out float z, out float meters, out float texel) {
	ByteAddressBuffer table = cn_buffer(frame.virtual_table);
	stored = 0;
	z = 0;
	meters = 0;
	texel = 0;
	for (; level < frame.virtual_levels; level++) {
		Shadow_View view = virtual_view(level);
		float3 at = virtual_project(view, p);
		int2 t = int2(floor(at.xy));
		if (!virtual_in_rect(view, t, t)) {
			continue;
		}
		uint page = virtual_block_page(table, level, view.page_origin, t >> VIRTUAL_PAGE_SHIFT);
		if (page == VIRTUAL_NO_PAGE) {
			continue;
		}
		int2 local = t & int(VIRTUAL_PAGE_TEXELS - 1);
		stored = asfloat(cn_uint_texture(frame.virtual_pool).Load(int3(int2(virtual_physical(page)) + local, 0)));
		z = at.z;
		meters = 1 / max(length(view.rows[2].xyz), 1e-9);
		texel = view.texel;
		return true;
	}
	return false;
}

// virtual_soft_shadow is how lit a point is by the light of the virtual shadow map, by shadow map ray tracing (SMRT; see
// docs/rendering/lighting-and-shadows.md#the-virtual-shadow-map), for a light whose angular radius has a tangent of
// size: frame.virtual_rays rays from the point toward points of the light's disk, each marching frame.virtual_steps
// steps through the map's depth out to frame.virtual_ray_length meters, the steps nearer together near the point. A
// step is in shadow when it is behind the map's depth by more than a thickness of two texels and 2% of its distance,
// against the map's texels and the surfaces' own slopes. Behind the map's depth is solid, which is how the map is
// extrapolated behind a blocker: a ray that passes behind a thin caster is blocked, whatever its steps' spacing. The
// last step is at the ray's end, so a caster farther than the rays reach still casts, with the penumbra of one at
// their reach. The point moves as virtual_find moves it, and the steps read the level that it found, or a coarser one
// where the page is missing. The blue noise turns the rays' disk and moves their steps for each pixel.
float virtual_soft_shadow(float3 p, float3 normal, float3 to_light, float size, float2 pixel) {
	Virtual_Hit hit;
	if (!virtual_find(p, normal, to_light, hit)) {
		return 1;
	}
	Shadow_View view = virtual_view(hit.level);
	float cos_light = dot(normal, to_light);
	float sin_light = sqrt(saturate(1 - cos_light * cos_light));
	float3 q = p + to_light * (view.texel * 0.5) + normal * (view.texel * 0.5 * sin_light);
	float3 t1 = normalize(cross(abs(to_light.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0), to_light));
	float3 t2 = cross(to_light, t1);
	float2 noise = frame.shadow_noise != 0 ? blue_noise(frame.shadow_noise, uint2(pixel), frame.shadow_noise_slice) : 0.5;
	float angle = noise.x * 6.28318531;
	float2 turn = float2(cos(angle), sin(angle));
	float lit = 0;
	for (uint r = 0; r < frame.virtual_rays; r++) {
		float2 d = vogel(r, frame.virtual_rays, turn) * size;
		float3 direction = normalize(to_light + t1 * d.x + t2 * d.y);
		bool blocked = false;
		for (uint s = 0; s < frame.virtual_steps && !blocked; s++) {
			float u = (s + (s + 1 == frame.virtual_steps ? 1 : noise.y)) / frame.virtual_steps;
			float t = frame.virtual_ray_length * u * u;
			float stored, z, meters, texel;
			if (!virtual_depth_at(q + direction * t, hit.level, stored, z, meters, texel)) {
				continue;
			}
			blocked = (stored - z) * meters > 2 * texel + 0.02 * t;
		}
		lit += blocked ? 0 : 1;
	}
	return lit / frame.virtual_rays;
}
#endif

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

// map_shadow is how lit a point at a view depth is by one light, from its virtual shadow map or its shadow maps, or 1
// without any.
float map_shadow(Light_Record light, float3 p, float3 normal, float3 to_light, float depth) {
	if ((light.flags & LIGHT_VIRTUAL_SHADOW) != 0) {
		return virtual_shadow(p, normal, to_light);
	}
	int view = shadow_view(light, p, depth);
	return view < 0 ? 1 : shadow_map(uint(view), p, normal, to_light);
}

// light_shadow is how lit a point is by one light: its channel of the shadow mask, or its shadow maps, or 1. The mask is
// the opaque surfaces', from the prepass's depth, so a transparent surface is lit by the lights that have a channel.
// The sun's contact shadows (see contact_shadows.hlsl) are the opaque surfaces' too, so only the forward pass's opaque
// surfaces take them, on top of the shadow map; the fog, the sprites and the transparent surfaces have the map alone.
// to_light is the direction toward the light, which the shadow maps' lookup offsets along.
float light_shadow(Light_Record light, float3 p, float3 normal, float3 to_light, float4 position) {
	if (light.mask >= 0) {
#if MATERIAL_TRANSPARENT
		return 1;
#else
		return load_screen(push.shadow_mask, position.xy)[light.mask];
#endif
	}
#if MATERIAL_SCREEN_SHADOWS && !MATERIAL_TRANSPARENT
	// The opaque surfaces take a spot, a point or an area light's map with soft shadows, as wide as its size, and the
	// virtual shadow map's light by ray tracing the map.
	float size = light_size(light);
	if (frame.virtual_rays != 0 && size > 0 && (light.flags & LIGHT_VIRTUAL_SHADOW) != 0) {
		float soft = virtual_soft_shadow(p, normal, to_light, size, position.xy);
		if ((light.flags & LIGHT_CONTACT_SHADOW) != 0) {
			soft *= load_screen(push.shadow_mask, position.xy).r;
		}
		return soft;
	}
	if (frame.shadow_soft_taps != 0 && size > 0 && light.type != LIGHT_DIRECTIONAL) {
		int soft_view = shadow_view(light, p, 0);
		return soft_view < 0 ? 1 : soft_shadow_map(uint(soft_view), p, normal, to_light, size, position.xy);
	}
#endif
	float shadow = map_shadow(light, p, normal, to_light, view_z(frame.projection, position.z));
#if MATERIAL_SCREEN_SHADOWS && !MATERIAL_TRANSPARENT
	if ((light.flags & LIGHT_CONTACT_SHADOW) != 0) {
		shadow *= load_screen(push.shadow_mask, position.xy).r;
	}
#endif
	return shadow;
}

// range_window is 1 near a light and 0 at its range: saturate(1 - (d / range)^4)^2.
float range_window(float distance2, float range) {
	float window = saturate(1 - distance2 * distance2 / (range * range * range * range));
	return window * window;
}

// light_falloff is one light as it reaches a point, before its shadow: the direction toward it, and its light there.
// A punctual light falls off with the square of the distance, windowed to 0 at its range. The fog sees an area light as
// a point light at its middle, whose light a quad or a disk sends out with the cosine of its face. The clouds shadow
// the directional light that casts their shadow (see cloud_shadow.hlsli), so every pass that includes this file takes
// it.
Light light_falloff(Light_Record l, float3 p) {
	Light light;
	if (l.type == LIGHT_DIRECTIONAL) {
		light.direction = -l.direction;
		light.color = l.color;
		if ((l.flags & LIGHT_CLOUD_SHADOW) != 0) {
			light.color *= cloud_shadow(p, light.direction);
		}
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
	if (any(light.color > 0)) {
		// A surface that faces away from the light is in its own shadow. Its shading would not clip that to nothing,
		// because a normal map can tilt the shading normal toward the light.
		light.color *= dot(normal, light.direction) > 0 ? light_shadow(l, p, normal, light.direction, position) : 0;
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
		light.color *= light_shadow(l, p, normal, normalize(light.center), position);
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
