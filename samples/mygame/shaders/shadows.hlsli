// The shadow rays, shared by shadows.hlsl (inline ray tracing) and shadows_rt.hlsl (a ray tracing pipeline), so both
// trace the same rays.
#ifndef SHADOWS_HLSLI
#define SHADOWS_HLSLI

#include "pass.hlsli"

// The rays start at the camera, and the acceleration structure holds the triangles relative to it, as the scene pass
// draws them. Where a ray hits nothing, it ends on a background plane this far ahead of the camera, in meters, which
// catches the triangles' shadows.
static const float BACKGROUND_DEPTH = 2.0;
// Toward the light, in the world: up, left and toward -z, so shadows fall down and right onto what is behind.
static const float3 TO_LIGHT = float3(-0.4, 0.5, -1.0);
// The light that reaches a shadowed surface.
static const float SHADOWED = 0.35;

// view_ray is the direction through a pixel's center, in the world.
float3 view_ray(uint2 pixel, uint2 size) {
	float2 ndc = (pixel + 0.5) / float2(size) * 2 - 1;
	float2 slope = float2(ndc.x * pass.aspect, -ndc.y) * pass.tan_half_fov;
	return normalize(pass.forward.xyz + pass.right.xyz * slope.x + pass.up.xyz * slope.y);
}

// background_distance is how far a view ray goes to reach the background plane.
float background_distance(float3 direction) {
	return BACKGROUND_DEPTH / max(dot(direction, pass.forward.xyz), 1e-3);
}

// primary_ray finds the nearest surface along a view ray, as far as the background.
RayDesc primary_ray(float3 direction) {
	RayDesc ray;
	ray.Origin = 0;
	ray.Direction = direction;
	ray.TMin = pass.near;
	ray.TMax = background_distance(direction);
	return ray;
}

// shadow_ray starts a little off the surface, so the surface does not shadow itself.
RayDesc shadow_ray(float3 surface) {
	RayDesc ray;
	ray.Origin = surface;
	ray.Direction = normalize(TO_LIGHT);
	ray.TMin = 0.001;
	ray.TMax = 10;
	return ray;
}

#endif
