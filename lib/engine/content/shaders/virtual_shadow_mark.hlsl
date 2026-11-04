// Marks the virtual shadow map's pages (see docs/rendering/lighting-and-shadows.md#virtual-shadow-maps): each level's
// bits of the pages that the frame reads. One phase rebuilds each pixel of the prepass from its depth, and marks the
// pages of its lookup's block. The other marks through the view's frustum, from a coarse grid of points, at levels
// coarser than their footprints, for what has no prepass: the fog, the transparent surfaces and the sprites.
#define MATERIAL_PUSH Virtual_Mark_Push
// Matches Virtual_Mark_Push in lib/engine/render/virtual_shadows.odin. forward is the view's axis, and the projections
// are the x and y scales and the near plane of the camera's and of the view model's.
struct Virtual_Mark_Push {
	float4 forward;
	float4 projection;
	float4 view_model_projection;
	uint depth;
	uint stencil;
	uint requests;
	uint phase;
	uint2 size;
	float reach;
	uint padding;
};
#include "virtual_shadow.hlsli"

static const uint MARK_PIXELS = 0;
static const uint MARK_VOLUME = 1;
// Match VIRTUAL_VOLUME_GRID and VIRTUAL_VOLUME_LEVELS in lib/engine/render/virtual_shadows.odin.
static const uint3 VOLUME_GRID = uint3(64, 40, 32);
static const uint VOLUME_LEVELS = 3;
// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;
// The lookups' offsets move a point by at most this many texels (see virtual_find).
static const int MARK_MARGIN = 1;

// mark_page sets a page's bit. Most of a pixel's pages are set already, and the read is much cheaper than the atomic.
void mark_page(RWByteAddressBuffer requests, uint level, uint2 page) {
	uint index = level * VIRTUAL_LEVEL_PAGES + page.y * VIRTUAL_PAGES + page.x;
	uint word = (index >> 5) * 4;
	uint bit = 1u << (index & 31);
	if ((requests.Load(word) & bit) == 0) {
		uint previous;
		requests.InterlockedOr(word, bit, previous);
	}
}

// mark marks a lookup's pages at the first level from level on whose valid rectangle holds its block. Matches
// virtual_mark in virtual_shadows.odin.
void mark(float3 p, uint level) {
	RWByteAddressBuffer requests = cn_rw_buffer(push.requests);
	for (; level < frame.virtual_levels; level++) {
		Shadow_View view = virtual_view(level);
		Virtual_Block block = virtual_block(virtual_project(view, p).xy);
		int2 low = block.base - MARK_MARGIN;
		int2 high = block.base + block.size - 1 + MARK_MARGIN;
		if (!virtual_in_rect(view, low, high)) {
			continue;
		}
		uint2 low_page = uint2(low) >> VIRTUAL_PAGE_SHIFT;
		uint2 high_page = uint2(high) >> VIRTUAL_PAGE_SHIFT;
		mark_page(requests, level, low_page);
		if (high_page.x != low_page.x) {
			mark_page(requests, level, uint2(high_page.x, low_page.y));
		}
		if (high_page.y != low_page.y) {
			mark_page(requests, level, uint2(low_page.x, high_page.y));
			if (high_page.x != low_page.x) {
				mark_page(requests, level, high_page);
			}
		}
		return;
	}
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	float3 right = frame.camera_right.xyz;
	float3 up = frame.camera_up.xyz;
	if (push.phase == MARK_VOLUME) {
		// A point in each cell of the grid, exponentially in depth.
		float2 ndc = (float2(id.xy) + 0.5) / float2(VOLUME_GRID.xy) * float2(2, -2) + float2(-1, 1);
		float z = push.projection.z * pow(push.reach / push.projection.z, (float(id.z) + 0.5) / float(VOLUME_GRID.z));
		float2 xy = ndc / push.projection.xy * z;
		float3 p = right * xy.x + up * xy.y + push.forward.xyz * z;
		mark(p, min(virtual_footprint_level(length(p)) + VOLUME_LEVELS, frame.virtual_levels - 1));
		return;
	}
	if (any(id.xy >= push.size)) {
		return;
	}
	float depth = cn_texture(push.depth).Load(int3(id.xy, 0)).r;
	if (depth <= 0) {
		return;
	}
	// The pixel's position relative to the camera, as the shadow mask rebuilds it (see shadow_mask.hlsl).
	bool view_model = (cn_stencil_texture(push.stencil).Load(int3(id.xy, 0)).g & VIEW_MODEL_STENCIL) != 0;
	float3 projection = view_model ? push.view_model_projection.xyz : push.projection.xyz;
	float z = projection.z / depth;
	float2 ndc = float2((id.x + 0.5) / push.size.x * 2 - 1, 1 - (id.y + 0.5) / push.size.y * 2) - frame.jitter;
	float2 xy = ndc / projection.xy * z;
	float3 p = right * xy.x + up * xy.y + push.forward.xyz * z;
	mark(p, virtual_footprint_level(length(p)));
}
