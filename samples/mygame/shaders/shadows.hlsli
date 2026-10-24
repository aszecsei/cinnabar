// The shadow rays, shared by shadows.hlsl (inline ray tracing) and shadows_rt.hlsl (a ray tracing pipeline), so both
// trace the same rays.
#ifndef SHADOWS_HLSLI
#define SHADOWS_HLSLI

// The world matches the scene: the screen spans -aspect to aspect horizontally and -1 to 1 vertically, the large
// triangles are at depths 0.4 and 0.6, and a background plane is at depth 1.
static const float BACKGROUND_DEPTH = 1.0;
// Toward the light: up, left and toward the viewer, so shadows fall down and right onto what is behind.
static const float3 TO_LIGHT = float3(-0.4, 0.5, -1.0);
// The light that reaches a shadowed surface.
static const float SHADOWED = 0.35;

// world_xy is a pixel's position in the world.
float2 world_xy(uint2 pixel, uint2 size, float aspect) {
	float2 ndc = (pixel + 0.5) / float2(size) * 2 - 1;
	return float2(ndc.x * aspect, -ndc.y);
}

// primary_ray looks straight into the screen from in front of everything, as far as the background.
RayDesc primary_ray(float2 xy) {
	RayDesc ray;
	ray.Origin = float3(xy, -1);
	ray.Direction = float3(0, 0, 1);
	ray.TMin = 0;
	ray.TMax = BACKGROUND_DEPTH + 1;
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
