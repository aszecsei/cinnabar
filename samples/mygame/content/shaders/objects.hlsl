#include "cinnabar.hlsli"
#include "pass.hlsli"
#include "objects.hlsli"

// Matches Vertex in game.odin.
struct Vertex {
	float2 position;
	float2 uv;
	float4 color;
};

// Matches Object_Constants in game.odin. The vertex path reads visible, and the mesh path object_count.
struct Push {
	uint vertices;
	uint visible;
	uint texture;
	uint sampler_index;
	uint2 grid;
	uint object_count;
};
CN_PUSH_CONSTANTS(Push, push);


struct Varyings {
	float4 position : SV_Position;
	float2 uv : TEXCOORD0;
	float4 color : COLOR0;
};

// Both paths place an object's vertices with this, so they draw the same image.
Varyings object_vertex(uint object, uint vertex_id) {
	Vertex v = cn_buffer(push.vertices).Load<Vertex>(vertex_id * sizeof(Vertex));
	float s, c;
	sincos(1.5 * pass.time + 0.37 * object, s, c);
	float2 p = object_center(object, push.grid, pass.time, pass.aspect);
	p += float2(v.position.x * c - v.position.y * s, v.position.x * s + v.position.y * c) * (OBJECT_RADIUS / 0.6);

	Varyings o;
	// The objects are a layer on the screen behind the scene, as far as the depth buffer reaches.
	o.position = float4(p.x / pass.aspect, p.y, OBJECT_DEPTH, 1);
	o.uv = v.uv;
	o.color = v.color * 0.8;
	return o;
}

// The vertex path: the compute queue culled the objects, and each indirect draw is one visible object. The draw ID
// indexes the visible list that the cull pass wrote.
Varyings vs_main(uint vertex_id : SV_VertexID) {
	return object_vertex(cn_buffer(push.visible).Load(CN_DRAW_ID * 4), vertex_id);
}

// The mesh path: each amplification group culls OBJECTS_PER_GROUP objects and launches one mesh group for the
// visible ones. Matches OBJECTS_PER_GROUP in game.odin.
#define OBJECTS_PER_GROUP 32

struct Payload {
	uint count;
	uint objects[OBJECTS_PER_GROUP];
};

groupshared Payload payload;
groupshared uint visible_count;

[numthreads(OBJECTS_PER_GROUP, 1, 1)]
void as_main(uint group : SV_GroupID, uint thread : SV_GroupIndex) {
	if (thread == 0) {
		visible_count = 0;
	}
	GroupMemoryBarrierWithGroupSync();

	uint object = group * OBJECTS_PER_GROUP + thread;
	if (object < push.object_count) {
		float2 center = object_center(object, push.grid, pass.time, pass.aspect);
		if (length(center) - OBJECT_RADIUS <= cull_radius(pass.time)) {
			uint slot;
			InterlockedAdd(visible_count, 1, slot);
			payload.objects[slot] = object;
		}
	}
	GroupMemoryBarrierWithGroupSync();

	if (thread == 0) {
		payload.count = visible_count;
	}
	GroupMemoryBarrierWithGroupSync();
	DispatchMesh(payload.count > 0 ? 1 : 0, 1, 1, payload);
}

[outputtopology("triangle")]
[numthreads(OBJECTS_PER_GROUP, 1, 1)]
void ms_main(
	uint thread : SV_GroupIndex,
	in payload Payload objects,
	out vertices Varyings vertices[OBJECTS_PER_GROUP * 3],
	out indices uint3 triangles[OBJECTS_PER_GROUP]
) {
	SetMeshOutputCounts(objects.count * 3, objects.count);
	if (thread < objects.count) {
		uint object = objects.objects[thread];
		for (uint corner = 0; corner < 3; corner++) {
			vertices[thread * 3 + corner] = object_vertex(object, corner);
		}
		triangles[thread] = uint3(thread * 3, thread * 3 + 1, thread * 3 + 2);
	}
}

// The objects are no entities, so the editor's ID buffer gets 0.
struct Targets {
	float4 color : SV_Target0;
	uint id : SV_Target1;
};

Targets ps_main(Varyings i) {
	Targets o;
	o.color = cn_texture(push.texture).Sample(cn_sampler(push.sampler_index), i.uv) * i.color;
	o.color.rgb *= exposure();
	o.id = 0;
	return o;
}
