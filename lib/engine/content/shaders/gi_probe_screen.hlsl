// The world probes' screen light (see docs/rendering/global-illumination.md#world-probes): a thread for each ray, after
// the hits' light. A hit of a front face that the screen shows takes its light from last frame's lit scene instead, as
// the cascades' rays do, so the probes see what the screen sees: the light of small emissive surfaces that few rays
// hit, and of everything that the cascades lit. It is a pass of its own, after the light, so the light's shader stays
// as it is.
#include "gi_probe_pass.hlsli"

// A point is the surface that a pixel shows when its view depth is within this share of the pixel's, plus a few
// centimeters.
static const float SCREEN_TOLERANCE = 0.05;
static const float SCREEN_SLACK = 0.05;

// screen_light is the light of a point relative to the camera in last frame's lit scene, where it was then, when this
// frame's depth shows it.
bool screen_light(float3 p, out float3 light) {
	light = 0;
	if (push.lit_valid == 0) {
		return false;
	}
	float4 clip = mul(frame.view_projection, float4(p, 1));
	if (clip.w <= frame.near) {
		return false;
	}
	float2 ndc = clip.xy / clip.w;
	if (any(abs(ndc) >= 1)) {
		return false;
	}
	uint2 pixel = min(uint2((ndc * float2(0.5, -0.5) + 0.5) * frame.screen_size), uint2(frame.screen_size) - 1);
	float depth = cn_texture(push.depth).Load(int3(pixel, 0)).r;
	if (depth <= 0 || abs(clip.w - frame.near / depth) > SCREEN_TOLERANCE * clip.w + SCREEN_SLACK) {
		return false;
	}
	float4 previous = mul(frame.previous_view_projection, float4(p + frame.camera_offset.xyz - frame.previous_camera_offset.xyz, 1));
	float2 uv = previous.xy / previous.w * float2(0.5, -0.5) + 0.5;
	if (previous.w <= 0 || any(uv != saturate(uv))) {
		return false;
	}
	light = cn_texture(push.lit).SampleLevel(cn_sampler(frame_probe_grid().sampler_index), uv, 0).rgb;
	return true;
}

[numthreads(HIT_GROUP_SIZE, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint ray = id.x;
	if (ray >= push.ray_count) {
		return;
	}
	Hit_Record hit = load_hit(push.hits, ray);
	if (hit_missed(hit)) {
		return;
	}
	Hit_Surface s = load_hit_surface(push.surfaces, ray);
	float3 seen;
	if ((hit_flags(s) & HIT_SURFACE_BACK) == 0 && screen_light(s.position - frame.camera_offset.xyz, seen)) {
		cn_rw_buffer(push.rays).Store<float4>(ray * 16, float4(seen, hit.t));
	}
}
