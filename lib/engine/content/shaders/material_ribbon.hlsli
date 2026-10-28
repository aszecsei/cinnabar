// The vertex path of a ribbon material (geometry = ribbon, see docs/rendering/particles.md#ribbons), which draws particle
// ribbons in place of meshes. material_vertex.hlsli includes this file under MATERIAL_RIBBON, so its load_vertex builds
// a ribbon's vertex from its draw record: first is the ribbon's first vertex in frame.ribbon_vertices, which
// ribbon_build.hlsl wrote, two for each particle. A segment between two particles is two triangles, without an index
// buffer. The vertex then goes through finish_vertex, as a mesh's does, so its instance, the anchor, places it.
#ifndef MATERIAL_RIBBON_HLSLI
#define MATERIAL_RIBBON_HLSLI

#include "ribbons.hlsli"

// A segment's corners: x is the particle, this one or the next, and y the edge.
static const uint2 RIBBON_CORNERS[6] = {uint2(0, 0), uint2(0, 1), uint2(1, 0), uint2(1, 0), uint2(0, 1), uint2(1, 1)};

Material_Vertex load_vertex(uint vertex_id) {
	Draw_Record d = load_draw();
	Instance_Record instance = load_instance(d);
	uint segment = vertex_id / 6;
	uint2 corner = RIBBON_CORNERS[vertex_id - segment * 6];
	uint index = d.first + (segment + corner.x) * 2 + corner.y;
	Ribbon_Vertex r = cn_buffer(frame.ribbon_vertices).Load<Ribbon_Vertex>(index * sizeof(Ribbon_Vertex));
	return finish_vertex(d, instance, r.position, r.normal, r.tangent, 1, float2(r.u, r.v), 0, r.color);
}

#endif
