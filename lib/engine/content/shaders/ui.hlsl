#include "cinnabar.hlsli"

// The UI's one batch (see docs/ui/design.md#drawing): each instance is a rounded rectangle with a border and a fill or a
// gradient, an image, or a glyph of a font's multi-channel distance field, cut to its clip rectangle. The UI layer is
// premultiplied and sRGB-encoded, so colors blend as encoded values, as a designer's tools blend them (see
// docs/rendering/layers-and-output.md#ui).

// Matches Instance in lib/engine/ui/batch.odin.
struct Instance {
	float4 rect;
	float4 clip;
	float4 radii;
	float4 uv;
	uint fill;
	uint fill_end;
	uint border;
	uint kind;
	uint texture;
	float width;
	float2 gradient;
};

// Matches Push in lib/engine/ui/render.odin.
struct Push {
	uint instances;
	uint instances_offset;
	uint sampler;
	uint padding;
	float2 viewport;
};
CN_PUSH_CONSTANTS(Push, push);

static const uint KIND_RECT = 0;
static const uint KIND_IMAGE = 1;
static const uint KIND_GLYPH = 2;
static const uint KIND_GRADIENT = 0x100;

Instance load_instance(uint index) {
	return cn_buffer(push.instances).Load<Instance>(push.instances_offset + index * 96);
}

float4 unpack_color(uint c) {
	return float4(c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, c >> 24) / 255.0;
}

float3 linear_to_srgb(float3 c) {
	return select(c <= 0.0031308, c * 12.92, 1.055 * pow(abs(c), 1.0 / 2.4) - 0.055);
}

struct Varyings {
	float4 position : SV_Position;
	float2 uv : TEXCOORD0;
	nointerpolation uint instance : INSTANCE;
};

// Six vertices make each instance's quad. A rectangle's grows by a pixel for its antialiased edge, and every quad is cut
// to its clip; the UV follows the rectangle as it was, so a cut never stretches it.
Varyings vs_main(uint vertex_id : SV_VertexID) {
	uint index = vertex_id / 6;
	uint corner = vertex_id % 6;
	static const float2 CORNERS[6] = {float2(0, 0), float2(1, 0), float2(0, 1), float2(0, 1), float2(1, 0), float2(1, 1)};
	Instance i = load_instance(index);
	float grow = (i.kind & 0xff) == KIND_GLYPH ? 0 : 1;
	float4 r = i.rect + float4(-grow, -grow, grow, grow);
	float2 p = lerp(r.xy, r.zw, CORNERS[corner]);
	p = clamp(p, i.clip.xy, i.clip.zw);
	float2 t = (p - i.rect.xy) / max(i.rect.zw - i.rect.xy, 1e-6);
	Varyings o;
	o.position = float4(p / push.viewport * float2(2, -2) + float2(-1, 1), 0, 1);
	o.uv = lerp(i.uv.xy, i.uv.zw, t);
	o.instance = index;
	return o;
}

// rounded_box is the signed distance from a point to a box of a half size about its middle, with each corner's own
// radius: top left, top right, bottom right and bottom left, y down.
float rounded_box(float2 p, float2 half_size, float4 radii) {
	float r = p.x < 0 ? (p.y < 0 ? radii.x : radii.w) : (p.y < 0 ? radii.y : radii.z);
	r = min(r, min(half_size.x, half_size.y));
	float2 q = abs(p) - half_size + r;
	return min(max(q.x, q.y), 0) + length(max(q, 0)) - r;
}

float median(float3 v) {
	return max(min(v.r, v.g), min(max(v.r, v.g), v.b));
}

float4 ps_main(Varyings v) : SV_Target {
	Instance i = load_instance(v.instance);
	float2 p = v.position.xy;
	if (any(p < i.clip.xy) || any(p >= i.clip.zw)) {
		discard;
	}
	uint kind = i.kind & 0xff;
	float4 color;
	if (kind == KIND_GLYPH) {
		Texture2D<float4> atlas = ResourceDescriptorHeap[NonUniformResourceIndex(i.texture)];
		float3 m = atlas.SampleLevel(cn_sampler(push.sampler), v.uv, 0).rgb;
		// The field's distance in screen pixels: its range in the atlas, as many pixels as the glyph is drawn at.
		float coverage = saturate(i.width * (median(m) - 0.5) + 0.5);
		color = unpack_color(i.fill);
		color.a *= coverage;
	} else {
		float2 half_size = (i.rect.zw - i.rect.xy) * 0.5;
		float d = rounded_box(p - (i.rect.xy + half_size), half_size, i.radii);
		float coverage = saturate(0.5 - d);
		float4 fill = unpack_color(i.fill);
		if (kind == KIND_IMAGE) {
			Texture2D<float4> image = ResourceDescriptorHeap[NonUniformResourceIndex(i.texture)];
			float4 texel = image.SampleLevel(cn_sampler(push.sampler), v.uv, 0);
			// A color texture samples as linear light, and the UI layer is encoded.
			fill = float4(linear_to_srgb(texel.rgb), texel.a) * fill;
		} else if ((i.kind & KIND_GRADIENT) != 0) {
			float t = saturate(0.5 + dot(p - (i.rect.xy + half_size), i.gradient));
			fill = lerp(fill, unpack_color(i.fill_end), t);
		}
		// The border is the band within width of the edge; the fill is inside it. They blend premultiplied, so a clear
		// fill shows nothing of the border's color through it.
		float inner = i.width > 0 ? saturate(0.5 - (d + i.width)) : 1;
		float4 border = unpack_color(i.border);
		float3 rgb = border.rgb * border.a * (1 - inner) + fill.rgb * fill.a * inner;
		float a = border.a * (1 - inner) + fill.a * inner;
		return float4(rgb, a) * coverage;
	}
	return float4(color.rgb * color.a, color.a);
}
