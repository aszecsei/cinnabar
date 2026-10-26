// The vertex side of every material pass (see docs/rendering/materials.md#materials): the draw's vertex, pulled through its
// draw record, so one indirect draw draws a whole bin, and the inputs that a material's evaluate reads. The prepass
// and the forward pass place vertices with the same code, so their depths are equal.
#ifndef MATERIAL_VERTEX_HLSLI
#define MATERIAL_VERTEX_HLSLI

#include "material_common.hlsli"

// A vertex as a material pass sees it. world is relative to the camera, and previous is the same point last frame,
// relative to last frame's camera.
struct Material_Vertex {
	float3 world;
	float3 previous;
	// In the mesh's own space, before the instance's pose.
	float3 local;
	float3 normal;
	float4 tangent;
	float2 uv0;
	float2 uv1;
	float4 color;
	uint material;
	uint id;
};

// What every pass but an opaque depth pass interpolates.
struct Varyings {
	float4 position : SV_Position;
	float3 world : POSITION1;
	float3 local : POSITION2;
	float3 normal : NORMAL;
	float4 tangent : TANGENT;
	float2 uv0 : TEXCOORD0;
	float2 uv1 : TEXCOORD1;
	float4 color : COLOR0;
	nointerpolation uint material : MATERIAL;
	nointerpolation uint id : ENTITY;
};

float3 transform_point(float4 rows[3], float3 p) {
	float4 v = float4(p, 1);
	return float3(dot(rows[0], v), dot(rows[1], v), dot(rows[2], v));
}

// The rows' rotation and scale turn a direction. A scale that is not uniform bends normals a little, which the passes
// do not correct.
float3 transform_direction(float4 rows[3], float3 d) {
	return float3(dot(rows[0].xyz, d), dot(rows[1].xyz, d), dot(rows[2].xyz, d));
}

Material_Vertex load_vertex(uint vertex_id) {
	Draw_Record d = cn_buffer(frame.draws).Load<Draw_Record>(CN_DRAW_ID * sizeof(Draw_Record));
	Mesh_Record m = cn_buffer(frame.meshes).Load<Mesh_Record>(frame.meshes_offset + (d.mesh & ID_ENTITY_MASK) * sizeof(Mesh_Record));
	uint corner = d.first_index + vertex_id;
	uint index;
	if (m.flags & MESH_INDEX32) {
		index = cn_buffer(m.indices).Load(corner * 4);
	} else {
		uint word = cn_buffer(m.indices).Load((corner * 2) & ~3u);
		index = (corner & 1) != 0 ? word >> 16 : word & 0xffff;
	}
	float3 local = cn_buffer(m.positions).Load<float3>(index * 12);
	ByteAddressBuffer attributes = cn_buffer(m.attributes);
	uint base = index * m.attribute_stride;
	float3 normal = octahedral(snorm16(attributes.Load(base)));
	uint tangent_word = attributes.Load(base + 4);
	float3 tangent = octahedral(unorm16(tangent_word) * 2 - 1);
	// The lowest bit of the tangent's second half is the bitangent's sign.
	float bitangent_sign = (tangent_word & 0x10000) != 0 ? -1 : 1;
	float2 uv0 = attributes.Load<float2>(base + 8);
	uint offset = base + 16;
	float2 uv1 = 0;
	if (m.flags & MESH_UV1) {
		uv1 = attributes.Load<float2>(offset);
		offset += 8;
	}
	float4 color = 1;
	if (m.flags & MESH_COLOR) {
		color = unpack_unorm8(attributes.Load(offset));
	}

	Instance_Record instance = cn_buffer(frame.instances).Load<Instance_Record>(d.instance * sizeof(Instance_Record));
	Material_Vertex v;
	v.world = transform_point(instance.rows, local) - frame.camera_offset.xyz;
	v.previous = transform_point(instance.previous_rows, local) - frame.previous_camera_offset.xyz;
	v.local = local;
	v.normal = transform_direction(instance.rows, normal);
	v.tangent = float4(transform_direction(instance.rows, tangent), bitangent_sign);
	v.uv0 = uv0;
	v.uv1 = uv1;
	v.color = color;
	v.material = d.material;
	v.id = instance.id | (d.mesh & ~ID_ENTITY_MASK);
	return v;
}

// clip_position is where every pass places a vertex. It is precise, so each pass computes the same depth.
float4 clip_position(float3 world) {
	precise float4 position = mul(frame.view_projection, float4(world, 1));
	return position;
}

Varyings vertex_varyings(Material_Vertex v) {
	Varyings o;
	o.position = clip_position(v.world);
	o.world = v.world;
	o.local = v.local;
	o.normal = v.normal;
	o.tangent = v.tangent;
	o.uv0 = v.uv0;
	o.uv1 = v.uv1;
	o.color = v.color;
	o.material = v.material;
	o.id = v.id;
	return o;
}

// material_inputs loads the draw's parameters, and gives what evaluate reads.
Material_Inputs material_inputs(Varyings i, bool front) {
	params = cn_buffer(frame.materials).Load<Params>(frame.materials_offset + i.material);
	Material_Inputs inputs;
	inputs.position = i.world;
	inputs.object_position = i.local;
	inputs.normal = normalize(i.normal);
	inputs.tangent = float4(normalize(i.tangent.xyz), i.tangent.w);
	inputs.uv0 = i.uv0;
	inputs.uv1 = i.uv1;
	inputs.color = i.color;
	inputs.view = normalize(-i.world);
	inputs.front_facing = front;
#if MATERIAL_TWO_SIDED
	// A back face shades as the other side of the surface.
	if (!front) {
		inputs.normal = -inputs.normal;
	}
#endif
	return inputs;
}

// shading_normal is the surface's normal in the world: the shading model's tangent-space normal mapped by the
// interpolated tangent frame, or the interpolated normal.
float3 shading_normal(Material_Inputs inputs, Surface s) {
#if SHADING_HAS_NORMAL
	float3 t = normalize(inputs.tangent.xyz - inputs.normal * dot(inputs.tangent.xyz, inputs.normal));
	float3 b = cross(inputs.normal, t) * inputs.tangent.w;
	return normalize(t * s.normal.x + b * s.normal.y + inputs.normal * s.normal.z);
#else
	return inputs.normal;
#endif
}

#endif
