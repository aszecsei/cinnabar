// Traces the shadow mask (see docs/rendering/lighting-and-shadows.md#shadows): for each pixel of the prepass, one ray toward each of up to
// four lights, against the GPU scene's acceleration structure. Each channel holds one light's result: 1 lit, 0 in
// shadow. Pixels with no surface are lit.
//
// A light with a size (see light_size) is soft: its ray goes toward a point on its shape that the blue noise picks, a
// new one each frame, and the denoiser averages them (see shadow_denoise_temporal.hlsl). A soft channel also writes
// the radius of the penumbra that its ray's blocker would cast, which the denoiser blurs by (see
// docs/rendering/lighting-and-shadows.md#the-traced-mask).
#include "cinnabar.hlsli"
#include "view_projection.hlsli"
#include "ray_scene.hlsli"
#include "light_record.hlsli"
#include "blue_noise.hlsli"

// Matches Mask_Constants in lib/engine/render/shadows.odin. The view's axes and its projection rebuild each pixel's
// position relative to the camera from its depth; camera_offset moves it into the acceleration structure's space, which
// is the render origin's. A pixel with the view model's stencil bit uses the view model's projection. light_index holds
// the light of each channel, or ~0. jitter is the camera's, which the prepass drew with, in normalized device
// coordinates. soft has bit c set when channel c's light has a size; then output is the raw visibility for the
// denoiser, penumbra its RGBA16_Float penumbra radii in meters, and noise the blue noise at noise_slice, 0 without it.
struct Mask_Constants {
	float4 right;
	float4 up;
	float4 forward;
	// The camera's projection, and the view model's (see view_projection.hlsli).
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
	uint soft;
	uint penumbra;
	uint noise;
	uint noise_slice;
	uint padding;
};
CN_PASS_CONSTANTS(Mask_Constants, constants);

// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;
// Directional rays stop this far away, in meters.
static const float DIRECTIONAL_DISTANCE = 10000;

// Each channel reads the noise this far from the pixel, so the channels' points do not move together.
static const int2 CHANNEL_NOISE_OFFSETS[4] = {int2(0, 0), int2(61, 37), int2(29, 83), int2(97, 13)};

// basis_of is two directions at right angles to a direction and to each other.
void basis_of(float3 d, out float3 t1, out float3 t2) {
	t1 = normalize(cross(abs(d.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0), d));
	t2 = cross(d, t1);
}

// light_point is a point on a light's shape, relative to the camera, as a point o sees it, for two numbers in [0, 1):
// a uniform point of a quad or of a disk, a point along a line, or a uniform point of the disk of a sphere's radius
// that faces o. A directional light's is a point of its disk 1 m from o, toward the light.
float3 light_point(Light_Record l, float3 o, float size, float2 u) {
	float2 d = sqrt(u.x) * float2(cos(6.28318531 * u.y), sin(6.28318531 * u.y));
	float3 t1, t2;
	switch (l.type) {
	case LIGHT_DIRECTIONAL:
		basis_of(-l.direction, t1, t2);
		return o - l.direction + (t1 * d.x + t2 * d.y) * size;
	case LIGHT_QUAD:
	case LIGHT_DISK: {
		float3 axis_y = cross(l.direction, l.extent / max(length(l.extent), 1e-7)) * l.extent_y;
		float2 q = l.type == LIGHT_QUAD ? u * 2 - 1 : d;
		return l.position + l.extent * q.x + axis_y * q.y;
	}
	case LIGHT_LINE:
		return l.position + l.extent * (u.x * 2 - 1);
	default:
		basis_of(normalize(l.position - o), t1, t2);
		return l.position + (t1 * d.x + t2 * d.y) * size;
	}
}

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
	float4 penumbra = 0;
	if (depth > 0) {
		// The pixel's position relative to the camera, from its view depth.
		bool view_model = (cn_stencil_texture(constants.stencil).Load(int3(id.xy, 0)).g & VIEW_MODEL_STENCIL) != 0;
		float4 projection = view_model ? constants.view_model_projection : constants.projection;
		float z = view_z(projection, depth);
		// The depth is the surface's where the jittered projection put the pixel's center, so the position is rebuilt
		// there. At the unjittered center, a sloped surface's point would be off its plane by the jitter times the
		// slope, far more than the hair below.
		float2 ndc = float2((id.x + 0.5) / constants.size.x * 2 - 1, 1 - (id.y + 0.5) / constants.size.y * 2) - constants.jitter;
		float2 xy = view_position(projection, ndc, z).xy;
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
			bool soft = (constants.soft & (1u << c)) != 0;
			float size = soft ? light_size(l) : 0;
			float3 target = l.position;
			if (soft) {
				float2 u = constants.noise != 0 ? blue_noise(constants.noise, id.xy + CHANNEL_NOISE_OFFSETS[c], constants.noise_slice) : 0.5;
				target = light_point(l, origin, size, u);
			}
			RayDesc ray;
			ray.Origin = origin + constants.camera_offset.xyz;
			ray.TMin = epsilon;
			if (l.type == LIGHT_DIRECTIONAL) {
				ray.Direction = soft ? normalize(target - origin) : -l.direction;
				ray.TMax = DIRECTIONAL_DISTANCE;
			} else {
				if (length(l.position - origin) >= l.range) {
					continue;
				}
				float3 d = target - origin;
				float distance = length(d);
				if (distance <= 0) {
					continue;
				}
				ray.Direction = d / distance;
				ray.TMax = distance;
			}
			if (dot(ray.Direction, normal) <= 0) {
				// A surface that faces away from an area light's middle can still see some of it, which its shading
				// clips to the horizon, so it is left lit. So is a ray toward a point of a soft light that is behind the
				// surface: the shading says how much of the light is above the horizon, and the mask only what blocks it.
				result[c] = l.type >= LIGHT_QUAD || soft ? 1 : 0;
				continue;
			}
			RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES | RAY_FLAG_FORCE_OPAQUE> query;
			query.TraceRayInline(accel, 0, RAY_MASK_SHADOWS, ray);
			query.Proceed();
			bool hit = query.CommittedStatus() != COMMITTED_NOTHING;
			result[c] = hit ? 0 : 1;
			if (soft && hit) {
				// A blocker t from the point, under a light whose point is the ray's end, casts a penumbra of the light's
				// radius times t over the blocker's distance from the light; under the sun, t times its radius 1 m away.
				float t = query.CommittedRayT();
				penumbra[c] = l.type == LIGHT_DIRECTIONAL ? t * size : size * t / max(ray.TMax - t, 1e-3);
			}
		}
	}
	cn_rw_texture(constants.output)[id.xy] = result;
	if (constants.soft != 0) {
		cn_rw_texture(constants.penumbra)[id.xy] = min(penumbra, 1000);
	}
}
