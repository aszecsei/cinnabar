package nav

import "core:mem"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// A navmesh blob built by hand for the tests, as the cooker lays one out, since the tests cannot link Recast: a floor
// of 1 m square polygons, one for each open cell of a grid, in tiles of tile_cells cells, with links across the tiles.

@(private = "file")
Grid :: struct {
	cells_x, cells_z: int,
	tile_cells:       int,
	// By cell, row by row from -z: no polygon.
	blocked:          []bool,
	// The height of a vertex, or 0 everywhere.
	height:           proc(x, z: f32) -> f32,
	// The links across the tiles' sides at x cover only the lower half of the edge in z.
	half_seams:       bool,
}

// The test's anchor: far from the origin, so the queries' sums are relative to it.
GRID_ANCHOR :: [3]f64{1000, 2, -500}

// at is a point of the grid's floor, relative to its anchor.
@(private)
at :: proc(x, y, z: f64) -> ecs.World_Position {
	return ecs.position_from_meters(GRID_ANCHOR + {x, y, z})
}

// meters is a World_Position relative to the grid's anchor.
@(private)
meters :: proc(p: ecs.World_Position) -> [3]f32 {
	m := ecs.position_to_meters(p) - GRID_ANCHOR
	return {f32(m.x), f32(m.y), f32(m.z)}
}

// The standard grid, 12 by 8 cells in tiles of 4: a wall at x = 6 from z = 0 to 7, with its gap at z = 7; an island at
// x = 9 to 11, z = 1 to 3, in a ring of blocked cells; and a ramp up in z in the cells x < 4, z > 4.
@(private)
STANDARD_X :: 12
@(private)
STANDARD_Z :: 8

@(private)
standard_blocked :: proc() -> []bool {
	blocked := make([]bool, STANDARD_X * STANDARD_Z, context.temp_allocator)
	for z in 0 ..< 7 {
		blocked[z * STANDARD_X + 6] = true
	}
	for z in 0 ..< 4 {
		for x in 8 ..< 12 {
			island := x >= 9 && x <= 10 && z >= 1 && z <= 2
			blocked[z * STANDARD_X + x] = !island
		}
	}
	return blocked
}

@(private)
ramp :: proc(x, z: f32) -> f32 {
	return (z - 4) * 0.25 if x <= 4 && z > 4 else 0
}

// is_island is whether a polygon of the standard grid is on the island.
@(private)
is_island :: proc(m: ^Mesh_View, polygon: u32) -> bool {
	pts := points_of(m, polygon)
	c := (pts.points[0] + pts.points[2]) * 0.5
	return c.x > 9 && c.x < 11 && c.z > 1 && c.z < 3
}

@(private)
standard_grid :: proc(agent: string = "Human", agent_index: u32 = 0, wall := true, guid := format.Guid{0 = 1}) -> []byte {
	blocked := standard_blocked()
	if !wall {
		for z in 0 ..< 7 {
			blocked[z * STANDARD_X + 6] = false
		}
	}
	return grid_blob({cells_x = STANDARD_X, cells_z = STANDARD_Z, tile_cells = 4, blocked = blocked, height = ramp}, agent, agent_index, guid)
}

// grid_blob builds the blob of a grid, in 16-aligned memory, as an asset's blob is.
@(private)
grid_blob :: proc(g: Grid, agent: string, agent_index: u32, guid := format.Guid{0 = 1}) -> []byte {
	tiles_x := (g.cells_x + g.tile_cells - 1) / g.tile_cells
	tiles_z := (g.cells_z + g.tile_cells - 1) / g.tile_cells
	open :: proc(g: Grid, x, z: int) -> bool {
		return x >= 0 && z >= 0 && x < g.cells_x && z < g.cells_z && (g.blocked == nil || !g.blocked[z * g.cells_x + x])
	}
	tile_of_cell :: proc(g: Grid, x, z: int, tiles_x: int) -> int {
		return (z / g.tile_cells) * tiles_x + x / g.tile_cells
	}
	// Each cell's polygon in the blob, by tile and then by cell in the tile.
	index := make([]int, g.cells_x * g.cells_z, context.temp_allocator)
	local := make([]int, g.cells_x * g.cells_z, context.temp_allocator)
	next := 0
	for tz in 0 ..< tiles_z {
		for tx in 0 ..< tiles_x {
			n := 0
			for z in tz * g.tile_cells ..< min((tz + 1) * g.tile_cells, g.cells_z) {
				for x in tx * g.tile_cells ..< min((tx + 1) * g.tile_cells, g.cells_x) {
					index[z * g.cells_x + x] = -1
					if open(g, x, z) {
						index[z * g.cells_x + x] = next
						local[z * g.cells_x + x] = n
						next += 1
						n += 1
					}
				}
			}
		}
	}
	tiles := make([dynamic]format.Nav_Tile, context.temp_allocator)
	vertices := make([dynamic][3]f32, context.temp_allocator)
	polygons := make([dynamic]format.Nav_Polygon, context.temp_allocator)
	links := make([dynamic]format.Nav_Link, context.temp_allocator)
	details := make([dynamic]format.Nav_Detail, context.temp_allocator)
	triangles := make([dynamic][4]u8, context.temp_allocator)
	height := g.height
	if height == nil {
		height = proc(x, z: f32) -> f32 {return 0}
	}
	// West, north, east and south, as a polygon's edges 0 to 3 face.
	steps := [4][2]int{{-1, 0}, {0, 1}, {1, 0}, {0, -1}}
	sides := [4]format.Nav_Side{.West, .North, .East, .South}
	for tz in 0 ..< tiles_z {
		for tx in 0 ..< tiles_x {
			tile := format.Nav_Tile {
				x             = u32(tx),
				z             = u32(tz),
				bounds_min    = {f32(tx * g.tile_cells), -1, f32(tz * g.tile_cells)},
				bounds_max    = {f32(min((tx + 1) * g.tile_cells, g.cells_x)), 3, f32(min((tz + 1) * g.tile_cells, g.cells_z))},
				first_vertex  = u32(len(vertices)),
				first_polygon = u32(len(polygons)),
				first_detail_vertex = u32(len(vertices)),
				first_detail_triangle = u32(len(triangles)),
			}
			for z in tz * g.tile_cells ..< min((tz + 1) * g.tile_cells, g.cells_z) {
				for x in tx * g.tile_cells ..< min((tx + 1) * g.tile_cells, g.cells_x) {
					if !open(g, x, z) {
						continue
					}
					first := u16(len(vertices)) - u16(tile.first_vertex)
					fx, fz := f32(x), f32(z)
					for c in ([4][2]f32{{fx, fz}, {fx, fz + 1}, {fx + 1, fz + 1}, {fx + 1, fz}}) {
						append(&vertices, [3]f32{c.x, height(c.x, c.y), c.y})
					}
					p := format.Nav_Polygon {
						vertices     = {first, first + 1, first + 2, first + 3, 0, 0},
						first_link   = u32(len(links)),
						vertex_count = 4,
					}
					for k in 0 ..< 4 {
						nx, nz := x + steps[k].x, z + steps[k].y
						p.neighbors[k] = format.NAV_NONE
						if !open(g, nx, nz) {
							continue
						}
						if tile_of_cell(g, nx, nz, tiles_x) == tz * tiles_x + tx {
							p.neighbors[k] = u16(local[nz * g.cells_x + nx])
							continue
						}
						p.neighbors[k] = u16(format.NAV_EXTERNAL) | u16(sides[k])
						link := format.Nav_Link{polygon = u32(index[nz * g.cells_x + nx]), edge = u8(k), t_min = 0, t_max = 255}
						// East runs from z + 1 down to z, and west from z up to z + 1.
						if g.half_seams && k == 2 {
							link.t_min = 128
						} else if g.half_seams && k == 0 {
							link.t_max = 127
						}
						append(&links, link)
						p.link_count += 1
					}
					append(&polygons, p)
					append(&details, format.Nav_Detail{first_vertex = u32(first), vertex_count = 4, first_triangle = u32(len(triangles)) - tile.first_detail_triangle, triangle_count = 2})
					append(&triangles, [4]u8{0, 1, 2, 0}, [4]u8{0, 2, 3, 0})
				}
			}
			tile.vertex_count = u32(len(vertices)) - tile.first_vertex
			tile.polygon_count = u32(len(polygons)) - tile.first_polygon
			tile.detail_vertex_count = tile.vertex_count
			tile.detail_triangle_count = u32(len(triangles)) - tile.first_detail_triangle
			append(&tiles, tile)
		}
	}
	data := format.nav_mesh_write(
		{
			guid = guid,
			key = 1,
			anchor = ecs.position_from_meters(GRID_ANCHOR).raw,
			volume = 0x100,
			agent = {name = agent, radius = 0.25, height = 1.8, step_height = 0.35, max_slope = 45},
			agent_index = agent_index,
			cell_size = 0.25,
			cell_height = 0.1,
			tile_size = f32(g.tile_cells),
			tiles_x = u32(tiles_x),
			tiles_z = u32(tiles_z),
			bounds_min = {0, -1, 0},
			bounds_max = {f32(g.cells_x), 3, f32(g.cells_z)},
			tiles = tiles[:],
			vertices = vertices[:],
			polygons = polygons[:],
			links = links[:],
			details = details[:],
			detail_vertices = vertices[:],
			detail_triangles = triangles[:],
		},
		context.temp_allocator,
	)
	aligned, _ := mem.alloc_bytes_non_zeroed(len(data), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, data)
	return aligned
}

// frame_of is a state whose frame views blobs, as prepare makes it, without the asset runtime.
@(private)
frame_of :: proc(blobs: ..[]byte) -> ^State {
	s := new(State, context.temp_allocator)
	views := make([]Mesh_View, len(blobs), context.temp_allocator)
	for b, i in blobs {
		v, ok := view_of(b, {handle = {u32(i), 1}, version = 1}, 0x100)
		assert(ok, "nav: a test grid's blob is refused")
		views[i] = v
	}
	s.frame = views
	return s
}
