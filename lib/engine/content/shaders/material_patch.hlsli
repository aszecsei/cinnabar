// The patch surfaces' vertex path (see docs/rendering/surfaces.md#surfaces): a material with geometry = patches draws the
// patches of Surface_Renderers in place of meshes. material_vertex.hlsli includes this file under MATERIAL_PATCHES, so
// its load_vertex builds a patch's vertex from its draw record: the patch's place in the surface's quadtree, the
// vertex's corner of its quad, the morph that joins its level to the next, and the hole mask. The vertex then goes
// through finish_vertex, as a mesh's does, so the instance's pose and the material's displacement apply.
#ifndef MATERIAL_PATCH_HLSLI
#define MATERIAL_PATCH_HLSLI

// Match SURFACE_PATCH_QUADS and SURFACE_MORPH_START in lib/engine/render/surfaces.odin.
#define SURFACE_PATCH_QUADS 16
static const float SURFACE_MORPH_START = 0.7;
// Matches MESHLET_DEPTH_SHIFT in material_mesh.hlsli: the Meshlets and Lod_Depth debug views color patches by their
// index and their level.
static const uint PATCH_LEVEL_SHIFT = 24;

// Matches Surface_Record in lib/engine/render/surfaces.odin.
struct Surface_Record {
	float2 size;
	float cell;
	uint levels;
	float2 root_origin;
	float root_size;
	float range0;
	float3 camera_local;
	uint hole_mask;
	float2 height_range;
	float bound;
	uint item;
	uint4 padding;
};

Surface_Record load_surface(Draw_Record d) {
	return cn_buffer(frame.surfaces).Load<Surface_Record>(frame.surfaces_offset + (d.mesh & ID_ENTITY_MASK) * sizeof(Surface_Record));
}

// The two triangles of a quad, by their corners: clockwise seen from above, which is the front.
static const uint2 PATCH_CORNERS[2][3] = {{uint2(0, 0), uint2(0, 1), uint2(1, 0)}, {uint2(1, 0), uint2(0, 1), uint2(1, 1)}};

Material_Vertex load_vertex(uint vertex_id, uint instance_id) {
	Draw_Record d = load_draw();
	Instance_Record instance = load_instance(d);
	Surface_Record s = load_surface(d);
	// The patch: its column, its row and its level, as cull_patches.hlsl wrote them.
	uint level = d.first >> 24;
	uint2 node = uint2(d.first & 0xfff, (d.first >> 12) & 0xfff);
	float cell = s.cell * float(1u << level);
	float2 origin = s.root_origin + float2(node) * (cell * SURFACE_PATCH_QUADS);
	// The vertex: a corner of a triangle of a quad of the grid.
	uint tri = vertex_id / 3;
	uint corner = vertex_id - tri * 3;
	uint quad = tri >> 1;
	uint2 ij = uint2(quad & (SURFACE_PATCH_QUADS - 1), quad / SURFACE_PATCH_QUADS);
	uint2 g = ij + PATCH_CORNERS[tri & 1][corner];
	float2 p = origin + float2(g) * cell;
	// The morph: toward the far end of this level's range, the grid's odd vertices slide onto their even neighbours,
	// which are the next level's grid, so the levels meet without a crack, whatever the displacement does after it,
	// since the displacement is of the vertex where it lands. Both sides of an edge see the same distance.
	float range = s.range0 * float(1u << level);
	float3 nearest = float3(p.x, clamp(s.camera_local.y, s.height_range.x, s.height_range.y), p.y);
	float morph = saturate((distance(s.camera_local, nearest) - SURFACE_MORPH_START * range) / ((1 - SURFACE_MORPH_START) * range));
	p -= frac(float2(g) * 0.5) * 2 * cell * morph;
	// The hole: the mask's mip of this level at the quad's middle, so a quad of a coarse level is a hole only where
	// every finest cell under it is, with a mask of one texel for each finest cell.
	float2 quad_uv = (origin + (float2(ij) + 0.5) * cell + s.size * 0.5) / s.size;
	Texture2D<float4> mask = cn_texture(s.hole_mask);
	uint width, height, mips;
	mask.GetDimensions(0, width, height, mips);
	uint mip = min(level, mips - 1);
	uint2 dims = max(uint2(width, height) >> mip, 1);
	uint2 texel = min(uint2(saturate(quad_uv) * float2(dims)), dims - 1);
	bool hole = mask.Load(int3(texel, mip)).r == 0;

	// The surface's frame: its x, its z and up, so a tangent-space normal's x and y are along the surface's x and z.
	float3 local = float3(p.x, 0, p.y);
	float2 uv0 = (p + s.size * 0.5) / s.size;
	float2 uv1 = transform_point(instance.rows, local).xz / 1024;
	Material_Vertex v = finish_vertex(d, instance, local, float3(0, 1, 0), float3(1, 0, 0), -1, uv0, uv1, float4(1, 1, 1, 1));
	if (hole) {
		// A triangle with a NaN position is not drawn.
		v.world = asfloat(0x7fc00000u);
		v.previous = v.world;
	}
	v.cluster = (d.first & 0xffffff) | level << PATCH_LEVEL_SHIFT;
	return v;
}

#endif
