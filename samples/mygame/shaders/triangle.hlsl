#include "cinnabar.hlsli"

// Matches Vertex in game.odin.
struct Vertex {
	float2 position;
	float2 uv;
	float4 color;
};

// Matches Triangle_Constants in game.odin.
struct Push {
	uint vertices;
	uint texture;
	uint sampler_index;
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

Varyings vs_main(uint vertex_id : SV_VertexID) {
	Vertex v = cn_buffer(push.vertices).Load<Vertex>(vertex_id * sizeof(Vertex));
	float s, c;
	sincos(pass.time, s, c);
	float2 p = float2(v.position.x * c - v.position.y * s, v.position.x * s + v.position.y * c);

	Varyings o;
	o.position = float4(p.x / pass.aspect, p.y, 0, 1);
	o.uv = v.uv;
	o.color = v.color;
	return o;
}

float4 ps_main(Varyings i) : SV_Target {
	return cn_texture(push.texture).Sample(cn_sampler(push.sampler_index), i.uv) * i.color;
}
