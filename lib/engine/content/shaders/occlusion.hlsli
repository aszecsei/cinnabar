// Two-phase occlusion culling (see docs/rendering/gpu-scene.md#occlusion-culling): the camera's early view draws what
// was visible last frame, a depth pyramid is built from its depth, and the late view tests everything else against
// the pyramid, draws what it shows, and keeps what is visible for next frame.
#ifndef OCCLUSION_HLSLI
#define OCCLUSION_HLSLI

#include "cinnabar.hlsli"

// Match MAX_HZB_LEVELS, VIEW_EARLY and VIEW_LATE in lib/engine/render/occlusion.odin.
#define MAX_HZB_LEVELS 16
static const uint VIEW_EARLY = 4;
static const uint VIEW_LATE = 8;

// Matches Occlusion_Constants in lib/engine/render/occlusion.odin. view_projection is the camera's, without its
// jitter, for positions relative to it. hzb are the pyramid's levels, the first half the depth's size, each the
// farthest depth under it. The bins below opaque_bins are the opaque ones, which alone are culled by occlusion. A
// slot's bit is set in slot_seen when its items were visible last frame, and the late view sets it in slot_seen_next
// for this frame; cell_seen has an instance set's cell's 256 bits, which the late view writes.
struct Occlusion_Constants {
	float4x4 view_projection;
	uint hzb[MAX_HZB_LEVELS];
	uint2 hzb_size;
	uint hzb_levels;
	uint opaque_bins;
	uint slot_seen;
	uint slot_seen_next;
	uint cell_seen;
	float near;
};

Occlusion_Constants load_occlusion(uint buffer, uint offset) {
	return cn_buffer(buffer).Load<Occlusion_Constants>(offset);
}

// slot_was_seen is whether a slot's items were visible last frame.
bool slot_was_seen(Occlusion_Constants o, uint slot) {
	return (cn_buffer(o.slot_seen).Load((slot / 32) * 4) & (1u << (slot % 32))) != 0;
}

// mark_slot_seen keeps a slot's items for next frame's early view.
void mark_slot_seen(Occlusion_Constants o, uint slot) {
	cn_rw_buffer(o.slot_seen_next).InterlockedOr((slot / 32) * 4, 1u << (slot % 32));
}

// sphere_occluded is whether a sphere, relative to the camera, is behind the pyramid's depth everywhere that it
// covers: its box's nearest depth is farther than the farthest depth under it, at the level where the box covers at
// most two texels across. A sphere that reaches behind the near plane is not occluded.
bool sphere_occluded(Occlusion_Constants o, float3 center, float radius) {
	float2 lo = float2(1e30, 1e30);
	float2 hi = float2(-1e30, -1e30);
	float nearest = 0;
	for (uint k = 0; k < 8; k++) {
		float3 corner = center + radius * float3((k & 1) != 0 ? 1 : -1, (k & 2) != 0 ? 1 : -1, (k & 4) != 0 ? 1 : -1);
		float4 clip = mul(o.view_projection, float4(corner, 1));
		if (clip.w <= o.near) {
			return false;
		}
		float3 ndc = clip.xyz / clip.w;
		lo = min(lo, ndc.xy);
		hi = max(hi, ndc.xy);
		// The depth is reversed: nearer is larger.
		nearest = max(nearest, ndc.z);
	}
	// In the pyramid's first level's texels, y down.
	float2 size = float2(o.hzb_size);
	float2 p0 = clamp(float2(lo.x * 0.5 + 0.5, 0.5 - hi.y * 0.5) * size, 0, size);
	float2 p1 = clamp(float2(hi.x * 0.5 + 0.5, 0.5 - lo.y * 0.5) * size, 0, size);
	if (any(p1 <= p0)) {
		return false;
	}
	float extent = max(p1.x - p0.x, p1.y - p0.y);
	uint level = min(uint(max(ceil(log2(max(extent, 1))), 0)), o.hzb_levels - 1);
	int2 first = int2(p0) >> level;
	int2 last = int2(min(p1, size - 1)) >> level;
	uint2 level_size = max(o.hzb_size >> level, 1);
	Texture2D<float4> pyramid = cn_texture(o.hzb[level]);
	float farthest = 1;
	for (int y = first.y; y <= min(last.y, first.y + 1); y++) {
		for (int x = first.x; x <= min(last.x, first.x + 1); x++) {
			farthest = min(farthest, pyramid.Load(int3(min(uint2(x, y), level_size - 1), 0)).r);
		}
	}
	return nearest < farthest;
}

#endif
