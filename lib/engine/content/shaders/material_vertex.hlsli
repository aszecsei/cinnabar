// The vertex side of every material pass (see docs/rendering/materials.md#materials): the draw's vertex, pulled through its
// draw record, so one indirect draw draws a whole bin, and the inputs that a material's evaluate reads. The prepass
// and the forward pass place vertices with the same code, so their depths are equal, and so does the mesh shader path
// (see material_mesh.hlsli).
#ifndef MATERIAL_VERTEX_HLSLI
#define MATERIAL_VERTEX_HLSLI

#include "material_common.hlsli"
#include "instanced.hlsli"

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
	// On the mesh shader path, its meshlet's index, with its level above MESHLET_DEPTH_SHIFT, for the debug views.
	uint cluster;
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
	nointerpolation uint cluster : CLUSTER;
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

// axis_scales are how much an instance's rows scale each of the mesh's axes: the lengths of their columns.
float3 axis_scales(float4 rows[3]) {
	return sqrt(rows[0].xyz * rows[0].xyz + rows[1].xyz * rows[1].xyz + rows[2].xyz * rows[2].xyz);
}

// billboard_rows turns an instance's rows to face a camera at eye, in the rows' space, whose right and up are given (see
// docs/rendering/gpu-scene.md#billboards). The mesh's +x goes along the camera's right, its +y along the camera's
// up, and its +z away from the camera, each with its own scale, so a quad in the mesh's x and y planes fronting -z
// faces the camera. An axis billboard (MATERIAL_BILLBOARD 2) keeps its +y, and turns about it to face the camera.
void billboard_rows(inout float4 rows[3], float3 eye, float3 right, float3 up) {
	float3 origin = float3(rows[0].w, rows[1].w, rows[2].w);
	float3 scales = axis_scales(rows);
	float3 forward = cross(right, up);
#if MATERIAL_BILLBOARD == 2
	float3 axis = normalize(float3(rows[0].y, rows[1].y, rows[2].y));
	float3 toward = origin - eye;
	toward -= axis * dot(toward, axis);
	// Seen straight along its axis, it faces the camera's up, which is across the axis then.
	if (dot(toward, toward) < 1e-12) {
		toward = up - axis * dot(up, axis);
	}
	forward = normalize(toward);
	up = axis;
	right = cross(up, forward);
#endif
	for (uint k = 0; k < 3; k++) {
		rows[k] = float4(right[k] * scales.x, up[k] * scales.y, forward[k] * scales.z, origin[k]);
	}
}

Draw_Record load_draw() {
	return cn_buffer(frame.draws).Load<Draw_Record>(CN_DRAW_ID * sizeof(Draw_Record));
}

Mesh_Record load_mesh(Draw_Record d) {
	return cn_buffer(frame.meshes).Load<Mesh_Record>(frame.meshes_offset + (d.mesh & ID_ENTITY_MASK) * sizeof(Mesh_Record));
}

Instance_Record load_instance(Draw_Record d) {
	return cn_buffer(frame.instances).Load<Instance_Record>(d.instance * sizeof(Instance_Record));
}

// draw_instance is the instance that a draw draws at, by the instance ID: its instance's, or for a draw with
// DRAW_INSTANCES the ID's visible instance of its set, whose poses, this frame's and last frame's, are its entity's
// placed by the instance's own.
Instance_Record draw_instance(Draw_Record d, uint instance_id) {
	Instance_Record instance = load_instance(d);
	if ((d.flags & DRAW_INSTANCES) != 0) {
		uint index = cn_buffer(frame.visible_instances).Load((d.visible + instance_id) * 4);
		float4 local[3];
		instance_rows(cn_buffer(instance.instance_set), index, local);
		float4 entity[3] = instance.rows;
		compose_rows(entity, local, instance.rows);
		entity = instance.previous_rows;
		compose_rows(entity, local, instance.previous_rows);
	}
	return instance;
}

// draw_index is the mesh's vertex at a corner of the draw's indices.
uint draw_index(Draw_Record d, Mesh_Record m, uint vertex_id) {
	uint corner = d.first + vertex_id;
	if (m.flags & MESH_INDEX32) {
		return cn_buffer(m.indices).Load(corner * 4);
	}
	uint word = cn_buffer(m.indices).Load((corner * 2) & ~3u);
	return (corner & 1) != 0 ? word >> 16 : word & 0xffff;
}

// finish_vertex places a vertex of the mesh's space by its instance's pose, and moves it by the material's displacement
// when it has one (see docs/rendering/materials.md#vertex-displacement): what the vertex paths and the patch path all
// draw. A billboard's pose faces the camera first, this frame's and last frame's each its own camera. The
// displacement is read at this frame's time for this frame's pose and at last frame's for the previous, so an offset
// that moves gives a velocity.
Material_Vertex finish_vertex(Draw_Record d, Instance_Record instance, float3 local, float3 normal, float3 tangent, float bitangent_sign, float2 uv0, float2 uv1, float4 color) {
#if MATERIAL_BILLBOARD
	billboard_rows(instance.rows, frame.camera_offset.xyz, frame.camera_right.xyz, frame.camera_up.xyz);
	billboard_rows(instance.previous_rows, frame.previous_camera_offset.xyz, frame.previous_camera_right.xyz, frame.previous_camera_up.xyz);
#endif
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
	v.cluster = 0;
#if MATERIAL_DISPLACES
	params = cn_buffer(frame.materials).Load<Params>(frame.materials_offset + d.material);
	Vertex_Inputs now;
	now.position = v.world;
	now.object_position = local;
	now.normal = v.normal;
	now.tangent = v.tangent;
	now.uv0 = uv0;
	now.uv1 = uv1;
	now.color = color;
	now.time = frame.time;
	v.world += displace(now);
	Vertex_Inputs before = now;
	before.position = v.previous;
	before.normal = transform_direction(instance.previous_rows, normal);
	before.tangent = float4(transform_direction(instance.previous_rows, tangent), bitangent_sign);
	before.time = frame.previous_time;
	v.previous += displace(before);
#endif
	return v;
}

// place_vertex is a mesh's vertex, placed by its instance's pose: what both vertex paths draw.
Material_Vertex place_vertex(Draw_Record d, Mesh_Record m, Instance_Record instance, uint index) {
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
	return finish_vertex(d, instance, local, normal, tangent, bitangent_sign, uv0, uv1, color);
}

#if MATERIAL_PATCHES
// A patches material's vertices are a surface's patches, not a mesh's (see docs/rendering/surfaces.md#surfaces).
#include "material_patch.hlsli"
#elif MATERIAL_RIBBON
// A ribbon material's vertices are a particle ribbon's (see docs/rendering/particles.md#ribbons).
#include "material_ribbon.hlsli"
#else
// load_vertex is the vertex pulling path's vertex: the draw's indices, by its draw ID. A draw of mesh particles draws
// its indices once for each particle, each with the particle's instance, and its color scales the mesh's. An
// instanced draw draws them once for each instance ID, at its instance.
Material_Vertex load_vertex(uint vertex_id, uint instance_id) {
	Draw_Record d = load_draw();
	Mesh_Record m = load_mesh(d);
	if ((d.flags & DRAW_PARTICLES) != 0) {
		uint particle = vertex_id / d.count;
		Instance_Record instance = cn_buffer(frame.particle_instances).Load<Instance_Record>((d.instance + particle) * sizeof(Instance_Record));
		Material_Vertex v = place_vertex(d, m, instance, draw_index(d, m, vertex_id - particle * d.count));
		v.color *= unpack_unorm8(instance.color);
		return v;
	}
	return place_vertex(d, m, draw_instance(d, instance_id), draw_index(d, m, vertex_id));
}
#endif

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
	o.cluster = v.cluster;
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
	inputs.time = frame.time;
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
