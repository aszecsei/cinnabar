// What every material's shaders share (see docs/rendering.md#materials): the frame's constants, the GPU scene's
// records, the inputs that a material's evaluate reads, and what a shading model is given.
#ifndef MATERIAL_COMMON_HLSLI
#define MATERIAL_COMMON_HLSLI

#include "cinnabar.hlsli"

// Matches Frame_Constants in lib/engine/render/scene.odin. Positions in the GPU scene are relative to the render
// origin, and the view's are relative to the camera, which is camera_offset from the origin.
struct Frame_Constants {
	float4x4 view_projection;
	float4 camera_offset;
	// Toward the sun, in the world, and its light.
	float4 sun_direction;
	float4 sun_color;
	// The ambient light from above and from below.
	float4 sky_color;
	float4 ground_color;
	// Bindless indices: the GPU scene's instances, this frame's draw records, the mesh records and the material table.
	uint instances;
	uint draws;
	uint meshes;
	uint materials;
	uint sampler_index;
	float time;
	uint2 padding;
};
CN_PASS_CONSTANTS(Frame_Constants, frame);

// Matches Draw_Record in lib/engine/render/scene.odin: one indirect draw, by its draw ID. material is the byte offset
// of the draw's parameter block in the material table.
struct Draw_Record {
	uint instance;
	uint mesh;
	uint first_index;
	uint material;
};

// Matches Mesh_Record in lib/engine/render/scene.odin.
static const uint MESH_INDEX32 = 1;
static const uint MESH_UV1 = 2;
static const uint MESH_COLOR = 4;
struct Mesh_Record {
	uint positions;
	uint attributes;
	uint indices;
	uint attribute_stride;
	uint flags;
	uint3 padding;
};

// Matches Instance_Record in lib/engine/render/scene.odin: the pose relative to the render origin as the rows of a
// 3x4 matrix, last frame's, and the entity's value in the editor's ID buffer.
struct Instance_Record {
	float4 rows[3];
	float4 previous_rows[3];
	uint id;
	uint flags;
	uint2 padding;
};

// What a material's evaluate reads. position is relative to the camera, and the directions are in the world.
struct Material_Inputs {
	float3 position;
	float3 normal;
	// The bitangent is cross(normal, tangent.xyz) * tangent.w.
	float4 tangent;
	float2 uv0;
	float2 uv1;
	float4 color;
	// Toward the camera.
	float3 view;
	bool front_facing;
};

// What a shading model shades: the point, its normal after the material's normal map, and the direction to the camera.
struct Shading_Point {
	float3 position;
	float3 normal;
	float3 view;
};

// A light that reaches the point: the direction toward it, and its light there.
struct Light {
	float3 direction;
	float3 color;
};

// The light from everything else: diffuse, and along the reflection.
struct Indirect {
	float3 diffuse;
	float3 specular;
};

static const float PI = 3.14159265;

// cn_sample samples a material's texture with the frame's sampler. A material samples through it, so a later path that
// shades without derivatives (a visibility buffer) can give its own.
float4 cn_sample(uint texture_index, float2 uv) {
	return cn_texture(texture_index).Sample(cn_sampler(frame.sampler_index), uv);
}

// cn_normal_map reads a tangent-space normal from a two-channel normal map (BC5), which keeps x and y.
float3 cn_normal_map(uint texture_index, float2 uv) {
	float2 xy = cn_sample(texture_index, uv).xy * 2 - 1;
	return float3(xy, sqrt(saturate(1 - dot(xy, xy))));
}

// octahedral unfolds a unit vector from the square [-1, 1]², as the cooker folded it.
float3 octahedral(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

float2 snorm16(uint word) {
	int2 v = int2(int(word << 16) >> 16, int(word) >> 16);
	return max(float2(v) / 32767.0, -1.0);
}

float2 unorm16(uint word) {
	return float2(word & 0xffff, word >> 16) / 65535.0;
}

float4 unpack_unorm8(uint c) {
	return float4(c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, c >> 24) / 255.0;
}

#endif
