#include "cinnabar.hlsli"
#include "pass.hlsli"
#include "shadows.hlsli"

// Matches Shadow_Constants in game.odin.
struct Push {
	uint accel;
	uint output;
	uint2 size;
};
CN_PUSH_CONSTANTS(Push, push);


// The distance to the hit, or -1 for a miss.
struct Payload {
	float distance;
};

// The ray tracing pipeline version of shadows.hlsl: the same rays, traced with TraceRay. The shadow ray skips the
// closest hit shader, so its payload keeps 0 when it hits anything and the miss shader sets -1.
[shader("raygeneration")]
void ray_generation() {
	uint2 pixel = DispatchRaysIndex().xy;
	RaytracingAccelerationStructure scene = cn_accel(push.accel);
	float3 direction = view_ray(pixel, push.size);

	RayDesc primary = primary_ray(direction);
	Payload surface = {-1};
	TraceRay(scene, RAY_FLAG_FORCE_OPAQUE, 0xff, 0, 1, 0, primary, surface);
	float distance = surface.distance >= 0 ? surface.distance : primary.TMax;

	Payload occluder = {0};
	uint flags = RAY_FLAG_FORCE_OPAQUE | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER;
	TraceRay(scene, flags, 0xff, 0, 1, 0, shadow_ray(direction * distance), occluder);
	float light = occluder.distance >= 0 ? SHADOWED : 1.0;
	cn_rw_texture(push.output)[pixel] = float4(light, light, light, 1);
}

[shader("miss")]
void miss(inout Payload payload) {
	payload.distance = -1;
}

[shader("closesthit")]
void closest_hit(inout Payload payload, BuiltInTriangleIntersectionAttributes attributes) {
	payload.distance = RayTCurrent();
}
