#include "cinnabar.hlsli"

// Matches Vertex in game.odin.
struct Vertex {
	float2 position;
	float2 uv;
	float4 color;
};

// Matches Scene_Constants in game.odin.
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

// Instance 0 is a bright triangle in front. Instance 1 is a larger, dimmer triangle behind it that turns the
// other way, so the depth test hides the part of it that the first one covers.
Varyings vs_main(uint vertex_id : SV_VertexID, uint instance : SV_InstanceID) {
	Vertex v = cn_buffer(push.vertices).Load<Vertex>(vertex_id * sizeof(Vertex));
	bool front = instance == 0;
	float s, c;
	sincos(front ? pass.time : -0.7 * pass.time, s, c);
	float2 p = float2(v.position.x * c - v.position.y * s, v.position.x * s + v.position.y * c) * (front ? 1.0 : 1.5);

	Varyings o;
	o.position = float4(p.x / pass.aspect, p.y, front ? 0.4 : 0.6, 1);
	o.uv = v.uv;
	// The scene is HDR. The composite pass tone maps it.
	o.color = v.color * (front ? 3.0 : 0.6);
	return o;
}

float4 ps_main(Varyings i) : SV_Target {
	return cn_texture(push.texture).Sample(cn_sampler(push.sampler_index), i.uv) * i.color;
}
