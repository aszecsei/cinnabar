// Debug lines (see docs/rendering/layers-and-output.md#debug): each line is a quad a few pixels wide, in exact colors, into the debug
// layer. The renderer draws tested lines twice, faintly where the scene hides them and fully where it does not, and
// overlay lines over everything.
#include "cinnabar.hlsli"

// Matches Debug_Vertex_Line in lib/engine/render/renderer.odin: the ends relative to the camera, and the linear color
// in RGBA8.
struct Line {
	float3 a;
	uint color;
	float3 b;
	uint padding;
};

// Matches Debug_Push in lib/engine/render/renderer.odin.
struct Push {
	float4x4 view_projection;
	uint lines;
	uint lines_offset;
	uint first_line;
	float alpha;
	float2 viewport;
	float width;
};
CN_PUSH_CONSTANTS(Push, push);

// How close to the camera, in clip-space w, a line's end may come. A line that passes behind the camera ends here.
static const float NEAR_W = 1e-3;

struct Varyings {
	float4 position : SV_Position;
	float4 color : COLOR0;
};

float4 unpack_color(uint c) {
	return float4(c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, c >> 24) / 255.0;
}

// Six vertices make the quad of a line: two triangles along it.
Varyings vs_main(uint vertex_id : SV_VertexID) {
	Line l = cn_buffer(push.lines).Load<Line>(push.lines_offset + (push.first_line + vertex_id / 6) * sizeof(Line));
	float4 a = mul(push.view_projection, float4(l.a, 1));
	float4 b = mul(push.view_projection, float4(l.b, 1));
	// Clip the line where it passes behind the camera, so its ends stay in front.
	if (a.w < NEAR_W) {
		a = lerp(a, b, (NEAR_W - a.w) / (b.w - a.w));
	} else if (b.w < NEAR_W) {
		b = lerp(b, a, (NEAR_W - b.w) / (a.w - b.w));
	}
	float2 screen_a = a.xy / a.w * push.viewport * 0.5;
	float2 screen_b = b.xy / b.w * push.viewport * 0.5;
	float2 along = screen_b - screen_a;
	along = dot(along, along) > 1e-8 ? normalize(along) : float2(1, 0);
	float2 across = float2(-along.y, along.x);

	uint corner = vertex_id % 6;
	// Corners 0, 1, 2 and 3, 4, 5: the ends, each on one side or the other.
	bool at_b = corner == 1 || corner == 2 || corner == 4;
	float side = (corner == 2 || corner == 4 || corner == 5) ? 1 : -1;
	float4 p = at_b ? b : a;
	p.xy += across * side * push.width / push.viewport * p.w;

	Varyings o;
	o.position = p;
	o.color = unpack_color(l.color);
	o.color.a *= push.alpha;
	return o;
}

float4 ps_main(Varyings i) : SV_Target {
	return i.color;
}
