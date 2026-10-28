// Particle ribbons (see docs/rendering/particles.md#ribbons): the vertices that ribbon_build.hlsl writes, two for each of
// a ribbon's living particles, oldest first, and that material_ribbon.hlsli draws.
#ifndef RIBBONS_HLSLI
#define RIBBONS_HLSLI

// Matches RIBBON_VERTEX_SIZE in lib/engine/render/particles.odin: a ribbon's edge at a particle, in its system's anchor's
// space. u is the particle's share of its life, v 0 on one edge and 1 on the other, and normal faces the camera.
struct Ribbon_Vertex {
	float3 position;
	float u;
	float3 normal;
	float v;
	float3 tangent;
	float padding;
	float4 color;
};

#endif
