// An instance set's instances (see docs/rendering/gpu-scene.md#instanced-meshes): each one a pose relative to its
// Instanced_Mesh_Renderer's entity, which cull_instances.hlsl culls and the vertex paths draw a mesh at.
#ifndef INSTANCED_HLSLI
#define INSTANCED_HLSLI

#include "cinnabar.hlsli"

// The size of format.Instance in lib/engine/asset/format/instances.odin: a position as three floats, a unit quaternion
// x, y, z, w as snorm16, a scale as three halves and a half of padding, then the point's index.
static const uint INSTANCE_SIZE = 32;

// instance_rows is an instance's pose as the rows of a 3x4 matrix, as pose_rows in lib/engine/render/extract.odin
// gives an entity's: the rotation's columns scaled by the scale's axes, then the position.
void instance_rows(ByteAddressBuffer instances, uint index, out float4 rows[3]) {
	uint base = index * INSTANCE_SIZE;
	float3 p = asfloat(instances.Load3(base));
	uint4 packed = instances.Load4(base + 12);
	int4 r = int4(packed.x << 16, packed.x, packed.y << 16, packed.y) >> 16;
	float4 q = normalize(float4(r) / 32767.0);
	float3 s = float3(f16tof32(packed.z), f16tof32(packed.z >> 16), f16tof32(packed.w));
	float3 m0 = float3(1 - 2 * (q.y * q.y + q.z * q.z), 2 * (q.x * q.y - q.w * q.z), 2 * (q.x * q.z + q.w * q.y));
	float3 m1 = float3(2 * (q.x * q.y + q.w * q.z), 1 - 2 * (q.x * q.x + q.z * q.z), 2 * (q.y * q.z - q.w * q.x));
	float3 m2 = float3(2 * (q.x * q.z - q.w * q.y), 2 * (q.y * q.z + q.w * q.x), 1 - 2 * (q.x * q.x + q.y * q.y));
	rows[0] = float4(m0 * s, p.x);
	rows[1] = float4(m1 * s, p.y);
	rows[2] = float4(m2 * s, p.z);
}

// compose_rows is a pose relative to an entity, placed by the entity's rows.
void compose_rows(float4 entity[3], float4 local[3], out float4 rows[3]) {
	for (uint k = 0; k < 3; k++) {
		float4 e = entity[k];
		rows[k] = e.x * local[0] + e.y * local[1] + e.z * local[2] + float4(0, 0, 0, e.w);
	}
}

// max_axis_scale is the largest scale of the rows' axes: the length of their longest column.
float max_axis_scale(float4 rows[3]) {
	float3 scales = rows[0].xyz * rows[0].xyz + rows[1].xyz * rows[1].xyz + rows[2].xyz * rows[2].xyz;
	return sqrt(max(scales.x, max(scales.y, scales.z)));
}

#endif
