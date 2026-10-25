// The forward pass of every material (see docs/rendering.md#materials). The cooker includes it after the shading
// model, the Params struct and the material's evaluate, with these defined:
//   MATERIAL_TWO_SIDED, MATERIAL_MASKED and MATERIAL_CUTOFF: the material's settings.
//   SHADING_NO_LIGHTING: the shading model only emits.
//   SHADING_HAS_NORMAL: the shading model's Surface has a tangent-space normal, which this pass maps to the world.
// The vertex shader pulls the draw's vertex through its draw record, so one indirect draw draws a whole bin.
#ifndef MATERIAL_FORWARD_HLSLI
#define MATERIAL_FORWARD_HLSLI

#include "material_common.hlsli"

struct Varyings {
	float4 position : SV_Position;
	float3 world : POSITION1;
	float3 normal : NORMAL;
	float4 tangent : TANGENT;
	float2 uv0 : TEXCOORD0;
	float2 uv1 : TEXCOORD1;
	float4 color : COLOR0;
	nointerpolation uint material : MATERIAL;
	nointerpolation uint id : ENTITY;
};

// The scene's HDR colors, and the entity IDs that the editor picks from.
struct Targets {
	float4 color : SV_Target0;
	uint id : SV_Target1;
};

float3 transform_point(float4 rows[3], float3 p) {
	float4 v = float4(p, 1);
	return float3(dot(rows[0], v), dot(rows[1], v), dot(rows[2], v));
}

// The rows' rotation and scale turn a direction. A scale that is not uniform bends normals a little, which this pass
// does not correct.
float3 transform_direction(float4 rows[3], float3 d) {
	return float3(dot(rows[0].xyz, d), dot(rows[1].xyz, d), dot(rows[2].xyz, d));
}

Varyings vs_main(uint vertex_id : SV_VertexID) {
	Draw_Record d = cn_buffer(frame.draws).Load<Draw_Record>(CN_DRAW_ID * sizeof(Draw_Record));
	Mesh_Record m = cn_buffer(frame.meshes).Load<Mesh_Record>(frame.meshes_offset + d.mesh * sizeof(Mesh_Record));
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
	float3 world = transform_point(instance.rows, local) - frame.camera_offset.xyz;
	Varyings o;
	o.position = mul(frame.view_projection, float4(world, 1));
	o.world = world;
	o.normal = transform_direction(instance.rows, normal);
	o.tangent = float4(transform_direction(instance.rows, tangent), bitangent_sign);
	o.uv0 = uv0;
	o.uv1 = uv1;
	o.color = color;
	o.material = d.material;
	o.id = instance.id;
	return o;
}

Targets ps_main(Varyings i, bool front : SV_IsFrontFace) {
	params = cn_buffer(frame.materials).Load<Params>(frame.materials_offset + i.material);
	Material_Inputs inputs;
	inputs.position = i.world;
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
	Surface s = evaluate(inputs);
#if MATERIAL_MASKED
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
#endif
	float3 color = shade_emission(s);
#if !SHADING_NO_LIGHTING
	Shading_Point p;
	p.position = i.world;
	p.view = inputs.view;
#if SHADING_HAS_NORMAL
	float3 t = normalize(inputs.tangent.xyz - inputs.normal * dot(inputs.tangent.xyz, inputs.normal));
	float3 b = cross(inputs.normal, t) * inputs.tangent.w;
	p.normal = normalize(t * s.normal.x + b * s.normal.y + inputs.normal * s.normal.z);
#else
	p.normal = inputs.normal;
#endif
	Light sun;
	sun.direction = frame.sun_direction.xyz;
	sun.color = frame.sun_color.rgb;
	color += shade_direct(s, p, sun);
	// The sky's light from above and the ground's from below, until global illumination.
	Indirect indirect;
	indirect.diffuse = lerp(frame.ground_color.rgb, frame.sky_color.rgb, p.normal.y * 0.5 + 0.5);
	float3 reflected = reflect(-p.view, p.normal);
	indirect.specular = lerp(frame.ground_color.rgb, frame.sky_color.rgb, reflected.y * 0.5 + 0.5);
	color += shade_indirect(s, p, indirect);
#endif
	Targets o;
	o.color = float4(color, 1);
	o.id = i.id;
	return o;
}

#endif
