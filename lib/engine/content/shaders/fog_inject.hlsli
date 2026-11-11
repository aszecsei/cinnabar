// The fog volume's injection (see docs/rendering/fog.md#volumetric-fog): a thread for each froxel, a screen tile of
// tile pixels in one of grid.z depth slices, which divide the clusters' slices. Each froxel takes the fog's
// density at a point in it, which moves within its slice from frame to frame, and the light that reaches that point:
// every directional light, the punctual lights of its cluster with their shadow maps, and the sky's light. Then it
// blends with last frame's value where the point was then. fog_inject.hlsl and fog_inject_traced.hlsl include this;
// the traced one defines FOG_TRACE, and traces the lights that have a channel of the shadow mask with RayQuery.
#ifndef FOG_INJECT_HLSLI
#define FOG_INJECT_HLSLI

// Matches Fog_Push in lib/engine/render/fog.odin. It starts with Material_Push's shadow textures, which the light loop
// reads. right, up and forward are the view's axes in the world. base_height is the fog's height relative to the camera. jitter is where the point is in its slice, in [0, 1). tile is the froxels' tile in pixels, the level's FOG_LEVEL_TILE.
struct Fog_Push {
	uint shadow_atlas;
	uint shadow_mask;
	uint history;
	uint output;
	float4 right;
	float4 up;
	float4 forward;
	float3 albedo;
	float density;
	float height_falloff;
	float base_height;
	float anisotropy;
	float jitter;
	uint3 grid;
	uint valid;
	uint accel;
	float blend;
	float tile;
};
#define MATERIAL_PUSH Fog_Push
// No shading model: the fog needs only the light loop's lookups.
#define SHADING_NO_LIGHTING 1
#include "material_lighting.hlsli"
#include "ray_scene.hlsli"

// Directional rays stop this far away, in meters.
static const float FOG_RAY_DISTANCE = 10000;

// fog_depth is the view depth at a slice coordinate of the fog volume, in the clusters' slices (see slice_z).
float fog_depth(float slice) {
	return slice_z(frame.projection, slice * CLUSTER_SLICES / float(push.grid.z), frame.slice_scale, frame.slice_bias);
}

// fog_point is the point relative to the camera at a normalized device x and y and a view depth.
float3 fog_point(float2 ndc, float depth) {
	float3 v = view_position(frame.projection, ndc, depth);
	return push.right.xyz * v.x + push.up.xyz * v.y + push.forward.xyz * v.z;
}

// henyey_greenstein is the share of light that scatters by an angle, per steradian.
float henyey_greenstein(float g, float cos_theta) {
	float g2 = g * g;
	return (1 - g2) / (4 * PI * pow(max(1 + g2 - 2 * g * cos_theta, 1e-4), 1.5));
}

// fog_shadow is how lit a point in the fog is by a light. A light with a channel of the shadow mask has no shadow maps,
// so the traced shader traces it, and the other one leaves it lit.
float fog_shadow(Light_Record light, Light reaching, float3 p, float depth) {
	if (light.mask >= 0) {
#if FOG_TRACE
		RayDesc ray;
		ray.Origin = p + frame.camera_offset.xyz;
		ray.Direction = reaching.direction;
		ray.TMin = 0;
		ray.TMax = light.type == LIGHT_DIRECTIONAL ? FOG_RAY_DISTANCE : length(light.position - p);
		RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES | RAY_FLAG_FORCE_OPAQUE> query;
		query.TraceRayInline(cn_accel(push.accel), 0, RAY_MASK_SHADOWS, ray);
		query.Proceed();
		return query.CommittedStatus() == COMMITTED_NOTHING ? 1 : 0;
#else
		return 1;
#endif
	}
	return map_shadow(light, p, 0, reaching.direction, depth);
}

// fog_light is the light that a point in the fog scatters toward the camera, per unit of scattering.
float3 fog_light(float3 p, float depth) {
	float3 toward_camera = to_camera(p);
	float3 result = 0;
	for (uint i = 0; i < frame.directional_count; i++) {
		Light_Record l = load_light(i);
		Light reaching = light_falloff(l, p);
		float phase = henyey_greenstein(push.anisotropy, dot(-reaching.direction, toward_camera));
		result += reaching.color * phase * fog_shadow(l, reaching, p, depth);
	}
	if (frame.clustered != 0) {
		uint2 range = cn_buffer(frame.clusters).Load2(cluster_at(p, depth) * 8);
		ByteAddressBuffer indices = cn_buffer(frame.cluster_indices);
		for (uint j = 0; j < range.y; j++) {
			Light_Record l = load_light(indices.Load((range.x + j) * 4));
			Light reaching = light_falloff(l, p);
			if (any(reaching.color > 0)) {
				float phase = henyey_greenstein(push.anisotropy, dot(-reaching.direction, toward_camera));
				result += reaching.color * phase * fog_shadow(l, reaching, p, depth);
			}
		}
	}
	// The sky's light is the ambient light, through the phase: with anisotropy above 0, more of it comes from the side of
	// the sky behind the point as the camera sees it.
	return result + ambient_scattered(frame.ambient, push.anisotropy, toward_camera);
}

// fog_inject fills one froxel. Each shader that includes this file calls it from its cs_main, with 4x4x4 threads,
// since the cooker finds a shader's stages by their entry points in its own file.
void fog_inject(uint3 id) {
	if (any(id >= push.grid)) {
		return;
	}
	// The point: the froxel's tile center, at its jittered place in its slice.
	float2 pixel = (float2(id.xy) + 0.5) * push.tile;
	float2 ndc = float2(pixel.x / frame.screen_size.x * 2 - 1, 1 - pixel.y / frame.screen_size.y * 2);
	float depth = fog_depth(id.z + push.jitter);
	float3 p = fog_point(ndc, depth);

	float density = push.density * exp(-push.height_falloff * max(p.y - push.base_height, 0));
	float4 current = float4(push.albedo * density * fog_light(p, depth), density);

	float4 result = current;
	if (push.valid != 0) {
		// Where the froxel's middle was in last frame's volume. The history holds each froxel's mean over the jitter, so a
		// still camera reads its own texel; from the jittered point it would read between slices, by a different amount
		// each frame, and smear them.
		float middle = fog_depth(id.z + 0.5);
		float3 previous = fog_point(ndc, middle) + frame.camera_offset.xyz - frame.previous_camera_offset.xyz;
		float4 clip = mul(frame.previous_view_projection, float4(previous, 1));
		float previous_depth = clip_view_z(frame.projection, clip);
		if (clip.w > 0 && (previous_depth > 0 || is_orthographic(frame.projection))) {
			float2 uv = (clip.xy / clip.w * float2(0.5, -0.5) + 0.5) * frame.fog_scale;
			float slices = float(push.grid.z);
			float slice = slice_of(frame.projection, previous_depth, frame.slice_scale, frame.slice_bias) * (slices / CLUSTER_SLICES);
			float3 coordinates = float3(uv, slice / slices);
			if (all(coordinates == saturate(coordinates))) {
				float4 history = cn_texture3d(push.history).SampleLevel(cn_sampler(frame.fog_sampler), coordinates, 0);
				result = lerp(history, current, push.blend);
			}
		}
	}
	cn_rw_texture3d(push.output)[id] = result;
}

#endif
