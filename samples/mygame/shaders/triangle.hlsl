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
	// SV_InstanceID starts at 0 in each draw on D3D12, but not on Vulkan, so each draw passes its first instance here.
	uint first_instance;
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

float2 rotate(float2 p, float angle) {
	float s, c;
	sincos(angle, s, c);
	return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// Instance 0 is a bright triangle in front. Instance 1 is a larger, dimmer triangle behind it that turns the
// other way, so the depth test hides the part of it that the first one covers. The other instances are a grid of
// small triangles behind both.
Varyings vs_main(uint vertex_id : SV_VertexID, uint draw_instance : SV_InstanceID) {
	Vertex v = cn_buffer(push.vertices).Load<Vertex>(vertex_id * sizeof(Vertex));
	uint instance = push.first_instance + draw_instance;

	Varyings o;
	o.uv = v.uv;
	if (instance < 2) {
		bool front = instance == 0;
		float2 p = rotate(v.position, front ? pass.time : -0.7 * pass.time) * (front ? 1.0 : 1.5);
		o.position = float4(p.x / pass.aspect, p.y, front ? 0.4 : 0.6, 1);
		// The scene is HDR. The composite pass tone maps it.
		o.color = v.color * (front ? 3.0 : 0.6);
		return o;
	}
	uint cell = instance - 2;
	float2 center = (float2(cell % push.grid.x, cell / push.grid.x) + 0.5) / float2(push.grid) * 2 - 1;
	float2 p = rotate(v.position, 1.5 * pass.time + 0.37 * cell) * 0.035;
	o.position = float4(center.x + p.x / pass.aspect, center.y + p.y, 0.9, 1);
	o.color = v.color * 0.35;
	return o;
}

float4 ps_main(Varyings i) : SV_Target {
	return cn_texture(push.texture).Sample(cn_sampler(push.sampler_index), i.uv) * i.color;
}
