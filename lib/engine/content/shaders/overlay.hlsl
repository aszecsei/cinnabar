#include "cinnabar.hlsli"

// The editor's overlay on the frame: the selection outline, then the gizmo. Matches Overlay_Constants in viewport.odin.
struct Push {
	float4x4 view_projection;
	uint ids;
	// The selection: a bit for each entity slot, in an upload.
	uint selection;
	uint selection_offset;
	uint slots;
	// The gizmo's vertices, in an upload.
	uint vertices;
	uint vertex_offset;
	// 0 draws the outline, 1 the gizmo.
	uint mode;
	// The scene's depth, which tells the selection's own edges from the edges of what is in front of it, and its
	// stencil, whose view model bit puts a pixel in front of every pixel of the world.
	uint depth;
	uint stencil;
};
CN_PUSH_CONSTANTS(Push, push);

// Matches Gizmo_Vertex in viewport.odin: a position relative to the view, and a color.
struct Vertex {
	float3 position;
	uint color;
};

// The outline's color: cinnabar, as the editor's accent.
static const float4 OUTLINE = float4(0.77, 0.06, 0.04, 1);
// The outline reaches this many pixels from the selection's edge.
static const int OUTLINE_RADIUS = 2;
// Matches render.VIEW_MODEL_STENCIL.
static const uint VIEW_MODEL_STENCIL = 1;

struct Varyings {
	float4 position : SV_Position;
	float4 color : COLOR0;
};

float4 unpack_color(uint c) {
	return float4(c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, c >> 24) / 255.0;
}

Varyings vs_main(uint vertex_id : SV_VertexID) {
	Varyings o;
	if (push.mode == 0) {
		// Three vertices make one triangle that covers the screen.
		float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
		o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
		o.color = OUTLINE;
		return o;
	}
	Vertex v = cn_buffer(push.vertices).Load<Vertex>(push.vertex_offset + vertex_id * 16);
	o.position = mul(push.view_projection, float4(v.position, 1));
	// The gizmo is drawn over everything, so its depth does not matter.
	o.position.z = 0;
	o.color = unpack_color(v.color);
	return o;
}

bool selected(int2 pixel) {
	uint entity = cn_uint_texture(push.ids).Load(int3(pixel, 0));
	if (entity == 0 || entity > push.slots) {
		return false;
	}
	uint slot = entity - 1;
	return (cn_buffer(push.selection).Load(push.selection_offset + slot / 32 * 4) >> (slot % 32)) & 1;
}

float depth_at(int2 pixel) {
	return cn_texture(push.depth).Load(int3(pixel, 0)).r;
}

bool view_model_at(int2 pixel) {
	return (cn_stencil_texture(push.stencil).Load(int3(pixel, 0)).g & VIEW_MODEL_STENCIL) != 0;
}

// in_front is whether pixel a shows something in front of what pixel b shows. The view model draws over the world, so
// it is in front of every world pixel, whatever their depths; otherwise the nearer depth is in front. Depth is
// reversed: it shrinks with distance, and the background is 0.
bool in_front(int2 a, int2 b) {
	bool model_a = view_model_at(a), model_b = view_model_at(b);
	if (model_a != model_b) {
		return model_a;
	}
	return depth_at(a) > depth_at(b);
}

float4 ps_main(Varyings i) : SV_Target {
	if (push.mode != 0) {
		return i.color;
	}
	// A pixel is on the outline where the selection's edge is near: some pixel within the radius differs from it. The
	// edge must be the selection's silhouette, where the other side is behind it or is the background. Where the other
	// side is in front, the edge is an occluder's, which would look selected.
	int2 pixel = int2(i.position.xy);
	uint2 size;
	cn_uint_texture(push.ids).GetDimensions(size.x, size.y);
	bool inside = selected(pixel);
	for (int y = -OUTLINE_RADIUS; y <= OUTLINE_RADIUS; y++) {
		for (int x = -OUTLINE_RADIUS; x <= OUTLINE_RADIUS; x++) {
			int2 other = clamp(pixel + int2(x, y), 0, int2(size) - 1);
			if (x * x + y * y > OUTLINE_RADIUS * OUTLINE_RADIUS || selected(other) == inside) {
				continue;
			}
			int2 selection = inside ? pixel : other;
			int2 rest = inside ? other : pixel;
			if (!in_front(rest, selection)) {
				return OUTLINE;
			}
		}
	}
	discard;
	return 0;
}
