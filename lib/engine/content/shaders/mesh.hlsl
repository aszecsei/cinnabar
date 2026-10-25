// The engine's mesh shader until materials exist (see docs/rendering.md#components): it draws a Mesh_Renderer's mesh
// with its normal under a fixed light, into the scene's HDR colors and the editor's entity IDs.
#include "cinnabar.hlsli"

// Matches Mesh_Instance in lib/engine/render/meshes.odin: the pose relative to the camera, as the rows of a 3x4
// matrix, and the entity's value in the editor's ID buffer.
struct Instance {
	float4 rows[3];
	uint id;
	uint3 padding;
};

// Matches Mesh_Push in lib/engine/render/meshes.odin.
struct Push {
	float4x4 view_projection;
	uint positions;
	uint attributes;
	uint attribute_stride;
	uint instances;
	uint instance_offset;
	uint instance;
};
CN_PUSH_CONSTANTS(Push, push);

// Toward the light, in the world, and the light's strength in the HDR scene.
static const float3 TO_LIGHT = float3(-0.4, 0.7, -0.6);
static const float LIGHT = 2.5;
static const float AMBIENT = 0.25;
static const float3 ALBEDO = float3(0.8, 0.78, 0.75);

struct Varyings {
	float4 position : SV_Position;
	float3 normal : NORMAL;
	nointerpolation uint id : ENTITY;
};

struct Targets {
	float4 color : SV_Target0;
	uint id : SV_Target1;
};

// octahedral unfolds a unit vector from the square [-1, 1]², as the cooker folded it.
float3 octahedral(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

// snorm16 decodes the two signed 16-bit halves of a word.
float2 snorm16(uint word) {
	int2 v = int2(int(word << 16) >> 16, int(word) >> 16);
	return max(float2(v) / 32767.0, -1.0);
}

Varyings vs_main(uint vertex_id : SV_VertexID) {
	Instance instance = cn_buffer(push.instances).Load<Instance>(push.instance_offset + push.instance * sizeof(Instance));
	float3 local = cn_buffer(push.positions).Load<float3>(vertex_id * 12);
	uint normal_word = cn_buffer(push.attributes).Load(vertex_id * push.attribute_stride);
	float3 normal = octahedral(snorm16(normal_word));

	float4 l = float4(local, 1);
	float3 p = float3(dot(instance.rows[0], l), dot(instance.rows[1], l), dot(instance.rows[2], l));
	// The rows' rotation and scale turn the normal; a scale that is not uniform bends it a little, which this shader
	// does not correct.
	float3 n = float3(dot(instance.rows[0].xyz, normal), dot(instance.rows[1].xyz, normal), dot(instance.rows[2].xyz, normal));

	Varyings o;
	o.position = mul(push.view_projection, float4(p, 1));
	o.normal = n;
	o.id = instance.id;
	return o;
}

Targets ps_main(Varyings i) {
	float3 n = normalize(i.normal);
	float diffuse = saturate(dot(n, normalize(TO_LIGHT)));
	Targets o;
	o.color = float4(ALBEDO * (AMBIENT + diffuse * LIGHT), 1);
	o.id = i.id;
	return o;
}
