#include "cinnabar.hlsli"
#include "shadows.hlsli"

// Matches Shadow_Constants in game.odin.
struct Push {
	uint accel;
	uint output;
	uint2 size;
};
CN_PUSH_CONSTANTS(Push, push);

// Matches Pass_Constants in game.odin.
struct Pass {
	float time;
	float aspect;
};
CN_PASS_CONSTANTS(Pass, pass);

// The geometry is opaque, so the queries need no candidate loop: Proceed finds the committed hit.
typedef RayQuery<RAY_FLAG_FORCE_OPAQUE> Opaque_Query;
typedef RayQuery<RAY_FLAG_FORCE_OPAQUE | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> Any_Hit_Query;

// Inline ray tracing: for each pixel, find the nearest surface, then test whether anything is between it and the light.
[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	RaytracingAccelerationStructure scene = cn_accel(push.accel);
	float2 xy = world_xy(id.xy, push.size, pass.aspect);

	RayDesc primary = primary_ray(xy);
	Opaque_Query surface;
	surface.TraceRayInline(scene, RAY_FLAG_NONE, 0xff, primary);
	while (surface.Proceed()) {
	}
	float depth = BACKGROUND_DEPTH;
	if (surface.CommittedStatus() == COMMITTED_TRIANGLE_HIT) {
		depth = primary.Origin.z + surface.CommittedRayT();
	}

	Any_Hit_Query occluder;
	occluder.TraceRayInline(scene, RAY_FLAG_NONE, 0xff, shadow_ray(float3(xy, depth)));
	while (occluder.Proceed()) {
	}
	float light = occluder.CommittedStatus() == COMMITTED_TRIANGLE_HIT ? SHADOWED : 1.0;
	cn_rw_texture(push.output)[id.xy] = float4(light, light, light, 1);
}
