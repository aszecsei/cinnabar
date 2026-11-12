package cook

// Recast, and cn_recast.cpp, the cooker's C interface to it, which `just recast` builds from tools/cook/recast (see
// docs/content/kinds/nav-meshes.md#recast).
foreign import recast "../../build/obj/recast/out/cn_recast.lib"

// The justfile passes the vendor/recastnavigation tag, so a Recast update bakes every navmesh again.
RECAST_VERSION :: #config(RECAST_VERSION, "unknown")

// The mark of a neighbor that is none, and of an edge on the tile's border, in Recast's polygons: the border's side is
// in the low bits.
RECAST_NULL_INDEX :: 0xffff
RECAST_BORDER_EDGE :: 0x8000

// Recast_Tile_In matches Cn_Recast_Tile_In in cn_recast.h.
Recast_Tile_In :: struct {
	vertices:                 [^]f32,
	vertex_count:             i32,
	triangles:                [^]i32,
	triangle_count:           i32,
	bounds_min:               [3]f32,
	bounds_max:               [3]f32,
	width:                    i32,
	height:                   i32,
	border:                   i32,
	cell_size:                f32,
	cell_height:              f32,
	walkable_slope:           f32,
	walkable_height:          i32,
	walkable_climb:           i32,
	walkable_radius:          i32,
	min_region_area:          i32,
	merge_region_area:        i32,
	max_edge_length:          i32,
	max_simplification_error: f32,
	detail_sample_distance:   f32,
	detail_sample_max_error:  f32,
}

// Recast_Tile_Out matches Cn_Recast_Tile_Out in cn_recast.h.
Recast_Tile_Out :: struct {
	vertices:              [^]u16,
	vertex_count:          i32,
	polygons:              [^]u16,
	polygon_count:         i32,
	max_vertices:          i32,
	bounds_min:            [3]f32,
	detail_meshes:         [^]u32,
	detail_vertices:       [^]f32,
	detail_vertex_count:   i32,
	detail_triangles:      [^]u8,
	detail_triangle_count: i32,
	internal:              rawptr,
}

@(default_calling_convention = "c")
foreign recast {
	cn_recast_bake_tile :: proc(input: ^Recast_Tile_In, output: ^Recast_Tile_Out) -> i32 ---
	cn_recast_tile_free :: proc(output: ^Recast_Tile_Out) ---
}
