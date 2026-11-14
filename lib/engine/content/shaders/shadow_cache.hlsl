// The shadow atlas's cache (see docs/rendering/lighting-and-shadows.md#cached-shadow-maps): a triangle over a slot that
// writes its depth with no test. A cache view's piece clears its slot of the cache to the far plane, 0 with the depth
// reversed, before it draws its baked casters there. A cached view's piece copies its slot of the cache into the frame's
// atlas, at the same texels, since the cache has the atlas's layout, before it draws its live casters over it.
#include "cinnabar.hlsli"

// Matches Shadow_Cache_Push in lib/engine/render/shadow_cache.odin: the cache's read index, and whether the piece copies
// it or clears.
struct Push {
	uint cache;
	uint copy;
};
CN_PUSH_CONSTANTS(Push, push);

struct Varyings {
	float4 position : SV_Position;
};

// Three vertices make one triangle that covers the viewport, which is the slot.
Varyings vs_main(uint vertex_id : SV_VertexID) {
	float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
	Varyings o;
	o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
	return o;
}

float ps_main(Varyings i) : SV_Depth {
	if (push.copy == 0) {
		return 0;
	}
	return cn_texture(push.cache).Load(int3(i.position.xy, 0)).r;
}
