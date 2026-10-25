#include "cinnabar.hlsli"
#include "pass.hlsli"

// Matches Vertex in game.odin.
struct Vertex {
	float2 position;
	float2 uv;
	float4 color;
};

// Matches Triangle_Instance in game.odin: a camera-relative transform, as the rows of a 3x4 matrix, an HDR
// brightness, and the entity's value in the editor's ID buffer. The ray tracing instances use the same rows.
struct Instance {
	float4 rows[3];
	float brightness;
	uint id;
	float2 padding;
};

// Matches Scene_Constants in game.odin.
struct Push {
	uint vertices;
	uint texture;
	uint sampler_index;
	uint instances;
	uint instance_offset;
};
CN_PUSH_CONSTANTS(Push, push);


struct Varyings {
	float4 position : SV_Position;
	float2 uv : TEXCOORD0;
	float4 color : COLOR0;
	nointerpolation uint id : ENTITY;
};

// The scene's colors, and the entity IDs that the editor picks from (see editor.ID_FORMAT).
struct Targets {
	float4 color : SV_Target0;
	uint id : SV_Target1;
};

// The world places the triangles, relative to the camera.
Varyings vs_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
	Vertex v = cn_buffer(push.vertices).Load<Vertex>(vertex_id * sizeof(Vertex));
	Instance instance = cn_buffer(push.instances).Load<Instance>(push.instance_offset + instance_id * sizeof(Instance));
	float4 local = float4(v.position, 0, 1);
	float3 p = float3(dot(instance.rows[0], local), dot(instance.rows[1], local), dot(instance.rows[2], local));

	Varyings o;
	o.position = mul(pass.view_projection, float4(p, 1));
	o.uv = v.uv;
	// The scene is HDR. The output pass tone maps it.
	o.color = v.color * instance.brightness;
	o.id = instance.id;
	return o;
}

Targets ps_main(Varyings i) {
	Targets o;
	o.color = cn_texture(push.texture).Sample(cn_sampler(push.sampler_index), i.uv) * i.color;
	o.color.rgb *= exposure();
	o.id = i.id;
	return o;
}
