// Traces the shadow mask (see docs/rendering/lighting-and-shadows.md#shadows): for each pixel of the prepass, one ray toward each of up to
// four lights, against the GPU scene's acceleration structure. Each channel holds one light's result: 1 lit, 0 in
// shadow. Pixels with no surface are lit.
#include "cinnabar.hlsli"
#include "ray_scene.hlsli"

// Matches Mask_Constants in lib/engine/render/shadows.odin. The view's axes and its projection rebuild each pixel's
// position relative to the camera from its depth; camera_offset moves it into the acceleration structure's space, which
// is the render origin's. A pixel with the view model's stencil bit uses the view model's projection. light_index holds
// the light of each channel, or ~0. jitter is the camera's, which the prepass drew with, in normalized device
// coordinates.
struct Mask_Constants {
	float4 right;
	float4 up;
	float4 forward;
	// The x and y scales and the near plane of the camera's projection, and of the view model's.
	float4 projection;
	float4 view_model_projection;
	float4 camera_offset;
	uint4 light_index;
	uint depth;
	uint normals;
	uint output;
	uint accel;
	uint lights;
	uint lights_offset;
	uint2 size;
	uint stencil;
	float2 jitter;
	uint padding;
};
CN_PASS_CONSTANTS(Mask_Constants, constants);

// Matches Light_Record in lib/engine/render/lights.odin.
struct Light_Record {
	float3 position;
	float range;
	float3 color;
	uint type;
	float3 direction;
	float spot_scale;
	float spot_offset;
	int shadow;
	int mask;
	uint flags;
	float3 extent;
	float extent_y;
};

static const uint LIGHT_DIRECTIONAL = 0;
// The first area light type; the others follow it.
static const uint LIGHT_QUAD = 3;
// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;
// Directional rays stop this far away, in meters.
static const float DIRECTIONAL_DISTANCE = 10000;

float3 octahedral(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	float depth = cn_texture(constants.depth).Load(int3(id.xy, 0)).r;
	float4 result = 1;
	if (depth > 0) {
		// The pixel's position relative to the camera, from its view depth.
		bool view_model = (cn_stencil_texture(constants.stencil).Load(int3(id.xy, 0)).g & VIEW_MODEL_STENCIL) != 0;
		float3 projection = view_model ? constants.view_model_projection.xyz : constants.projection.xyz;
		float z = projection.z / depth;
		// The depth is the surface's where the jittered projection put the pixel's center, so the position is rebuilt
		// there. At the unjittered center, a sloped surface's point would be off its plane by the jitter times the
		// slope, far more than the hair below.
		float2 ndc = float2((id.x + 0.5) / constants.size.x * 2 - 1, 1 - (id.y + 0.5) / constants.size.y * 2) - constants.jitter;
		float2 xy = ndc / projection.xy * z;
		float3 p = constants.right.xyz * xy.x + constants.up.xyz * xy.y + constants.forward.xyz * z;
		float3 normal = octahedral(cn_texture(constants.normals).Load(int3(id.xy, 0)).xy);
		// The ray starts off the surface along the normal by a hair: enough for the precision of the depth, of the
		// position rebuilt from it and of the acceleration structure's space, and no more. An offset along the normal
		// moves the shadow's edge across the surface by the offset over the tangent of the light's angle to the
		// normal, so two surfaces that meet at a crease disagree on where the shadow crosses their seam by as much.
		// The ray skips the same hair along itself instead, which moves no edge.
		// The render origin is a corner of a 1024 m grid, so the position in the structure's space is hundreds of
		// meters in a small scene, where a float's unit is a twentieth of a millimeter: that term is a few units.
		float3 world = p + constants.camera_offset.xyz;
		float epsilon = 1e-4 * max(1, z) + 2e-6 * max(abs(world.x), max(abs(world.y), abs(world.z)));
		float3 origin = p + normal * epsilon;
		RaytracingAccelerationStructure accel = cn_accel(constants.accel);
		[unroll] for (uint c = 0; c < 4; c++) {
			if (constants.light_index[c] == ~0u) {
				continue;
			}
			Light_Record l = cn_buffer(constants.lights).Load<Light_Record>(constants.lights_offset + constants.light_index[c] * sizeof(Light_Record));
			RayDesc ray;
			ray.Origin = origin + constants.camera_offset.xyz;
			ray.TMin = epsilon;
			if (l.type == LIGHT_DIRECTIONAL) {
				ray.Direction = -l.direction;
				ray.TMax = DIRECTIONAL_DISTANCE;
			} else {
				float3 d = l.position - origin;
				float distance = length(d);
				if (distance >= l.range || distance <= 0) {
					continue;
				}
				ray.Direction = d / distance;
				ray.TMax = distance;
			}
			if (dot(ray.Direction, normal) <= 0) {
				// A surface that faces away from an area light's middle can still see some of it, which its shading
				// clips to the horizon, so it is left lit.
				result[c] = l.type >= LIGHT_QUAD ? 1 : 0;
				continue;
			}
			RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES | RAY_FLAG_FORCE_OPAQUE> query;
			query.TraceRayInline(accel, 0, RAY_MASK_SHADOWS, ray);
			query.Proceed();
			result[c] = query.CommittedStatus() == COMMITTED_NOTHING ? 1 : 0;
		}
	}
	cn_rw_texture(constants.output)[id.xy] = result;
}
