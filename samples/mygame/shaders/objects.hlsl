#include "cinnabar.hlsli"
#include "objects.hlsli"

// Matches Vertex in game.odin.
struct Vertex {
	float2 position;
	float2 uv;
	float4 color;
};

// Matches Object_Constants in game.odin.
struct Push {
	uint vertices;
	uint visible;
	uint texture;
	uint sampler_index;
	uint2 grid;
};
CN_PUSH_CONSTANTS(Push, push);

// Matches Pass_Constants in game.odin.
struct Pass {
	float time;
	float aspect;
};
CN_PASS_CONSTANTS(Pass, pass);

struct Varyings {
	float4 position : SV_Position;
	float2 uv : TEXCOORD0;
	float4 color : COLOR0;
};

// Each indirect draw is one visible object. The draw ID indexes the visible list that the cull pass wrote.
Varyings vs_main(uint vertex_id : SV_VertexID) {
	Vertex v = cn_buffer(push.vertices).Load<Vertex>(vertex_id * sizeof(Vertex));
	uint object = cn_buffer(push.visible).Load(CN_DRAW_ID * 4);
	float s, c;
	sincos(1.5 * pass.time + 0.37 * object, s, c);
	float2 p = object_center(object, push.grid, pass.time, pass.aspect);
	p += float2(v.position.x * c - v.position.y * s, v.position.x * s + v.position.y * c) * (OBJECT_RADIUS / 0.6);

	Varyings o;
	o.position = float4(p.x / pass.aspect, p.y, 0.8, 1);
	o.uv = v.uv;
	o.color = v.color * 0.8;
	return o;
}

float4 ps_main(Varyings i) : SV_Target {
	return cn_texture(push.texture).Sample(cn_sampler(push.sampler_index), i.uv) * i.color;
}
