// The debug views that come from the frame's textures (see docs/rendering.md#debug-views): it writes the view into a
// new scene color, before post-processing. The shaded views are pre-exposed, as the scene is, and the others are
// colors as they are, which the output pass only encodes.
#include "cinnabar.hlsli"

// Matches Debug_View_Push in lib/engine/render/debug_views.odin.
struct Push {
	uint view;
	uint source;
	uint output;
	uint exposure;
	uint2 size;
	float near;
	// The shadow mask's channels that hold a light.
	uint mask_channels;
};
CN_PUSH_CONSTANTS(Push, push);

// Match render.Debug_View.
static const uint DEBUG_NORMALS = 8;
static const uint DEBUG_DEPTH = 9;
static const uint DEBUG_VELOCITY = 10;
static const uint DEBUG_AMBIENT_OCCLUSION = 11;
static const uint DEBUG_GI_DIFFUSE = 12;
static const uint DEBUG_GI_SPECULAR = 13;
static const uint DEBUG_SHADOW_MASK = 14;
static const uint DEBUG_ENTITY_IDS = 15;
static const uint DEBUG_LUMINANCE = 16;

// The prepass clears the velocity to render.VELOCITY_NONE where it draws nothing; anything this large is that.
static const float VELOCITY_NONE = 1000;
// The depth view's far end, in meters, on a log scale from the near plane.
static const float DEPTH_FAR = 1000;
// The luminance view's range of EV100, which its heat colors span.
static const float EV_LOW = -4;
static const float EV_HIGH = 16;

float3 octahedral(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

float3 heat(float t) {
	t = saturate(t);
	return saturate(float3(1.5 - abs(4 * t - 3), 1.5 - abs(4 * t - 2), 1.5 - abs(4 * t - 1)));
}

// hash_color is a bright color for an ID, so neighbouring entities differ.
float3 hash_color(uint id) {
	uint h = id * 2654435761u;
	h ^= h >> 15;
	h *= 2246822519u;
	h ^= h >> 13;
	return float3(h & 0xff, (h >> 8) & 0xff, (h >> 16) & 0xff) / 255.0 * 0.75 + 0.25;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= push.size)) {
		return;
	}
	int3 pixel = int3(id.xy, 0);
	float exposure = asfloat(cn_buffer(push.exposure).Load(0));
	float3 color = 0;
	switch (push.view) {
	case DEBUG_NORMALS: {
		float2 encoded = cn_texture(push.source).Load(pixel).xy;
		color = all(encoded == 0) ? 0 : octahedral(encoded) * 0.5 + 0.5;
		break;
	}
	case DEBUG_DEPTH: {
		// Reversed depth with the far plane at infinity: the view depth is near / depth, so log2(view depth / near) is
		// -log2(depth).
		float depth = cn_texture(push.source).Load(pixel).r;
		color = depth > 0 ? 1 - saturate(-log2(depth) / log2(DEPTH_FAR / push.near)) : 0;
		break;
	}
	case DEBUG_VELOCITY: {
		float2 velocity = cn_texture(push.source).Load(pixel).rg;
		color = velocity.x >= VELOCITY_NONE ? 0.25 : float3(saturate(0.5 + velocity * float2(10, -10)), 0.5);
		break;
	}
	case DEBUG_AMBIENT_OCCLUSION:
		color = saturate(cn_texture(push.source).Load(pixel).r);
		break;
	case DEBUG_GI_DIFFUSE:
	case DEBUG_GI_SPECULAR:
		color = cn_texture(push.source).Load(pixel).rgb * exposure;
		break;
	case DEBUG_SHADOW_MASK: {
		// Each light's channel in its own color: red, green, blue and yellow. A channel without a light is black.
		float4 mask = cn_texture(push.source).Load(pixel) * float4(push.mask_channels > 0, push.mask_channels > 1, push.mask_channels > 2, push.mask_channels > 3);
		color = saturate(mask.r * float3(1, 0, 0) + mask.g * float3(0, 1, 0) + mask.b * float3(0, 0, 1) + mask.a * float3(1, 1, 0));
		break;
	}
	case DEBUG_ENTITY_IDS: {
		Texture2D<uint> ids = ResourceDescriptorHeap[push.source];
		uint entity = ids.Load(pixel);
		color = entity == 0 ? 0 : hash_color(entity);
		break;
	}
	case DEBUG_LUMINANCE: {
		// The scene is pre-exposed. EV100 is log2 of the luminance times 100 / 12.5.
		float3 scene = max(cn_texture(push.source).Load(pixel).rgb, 0) / max(exposure, 1e-12);
		float luminance = dot(scene, float3(0.2126, 0.7152, 0.0722));
		color = luminance > 0 ? heat((log2(luminance * 8) - EV_LOW) / (EV_HIGH - EV_LOW)) : 0;
		break;
	}
	}
	cn_rw_texture(push.output)[id.xy] = float4(color, 1);
}
