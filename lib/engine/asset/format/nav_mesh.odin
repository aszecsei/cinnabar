package asset_format

import "core:mem"

import "cinnabar:core/layout"

// A navmesh is a sub-asset of its scene, one for each Nav_Mesh_Volume and agent type, `navmesh.<volume>.<agent>` in
// the scene's .meta file (see docs/content/kinds/nav-meshes.md#sub-assets). NAV_MESH_KIND names them.
NAV_MESH_KIND :: "navmesh"

// A polygon has at most this many vertices.
NAV_MAX_POLYGON_VERTICES :: 6
// A Nav_Polygon's neighbor across an edge that meets no polygon.
NAV_NONE :: 0xffff
// A Nav_Polygon's neighbor across an edge on its tile's border: the polygon's links give what is across it. The low bits
// are the side of the tile, a Nav_Side.
NAV_EXTERNAL :: 0x8000

// Nav_Side is a side of a tile, which a border edge lies on.
Nav_Side :: enum u16 {
	// Toward -x.
	West,
	// Toward +z.
	North,
	// Toward +x.
	East,
	// Toward -z.
	South,
}

// Nav_Mesh_Blob is the start of a navmesh blob (see docs/content/kinds/nav-meshes.md#the-blob). Positions are meters
// relative to anchor, the volume's center, along the world's axes. The tiles are a grid of tiles_x by tiles_z over the
// bounds, row by row from -z, and each one's polygons, vertices and detail are runs of the streams.
Nav_Mesh_Blob :: struct {
	header:           Blob_Header,
	// The volume's center: a World_Position's raw value.
	anchor:           [3]i64,
	// The volume's scene ID in the scene, after prefabs are expanded.
	volume:           u64,
	bounds_min:       [3]f32,
	bounds_max:       [3]f32,
	agent_radius:     f32,
	agent_height:     f32,
	agent_step:       f32,
	agent_max_slope:  f32,
	cell_size:        f32,
	cell_height:      f32,
	// A tile's edge, in meters.
	tile_size:        f32,
	tiles_x:          u32,
	tiles_z:          u32,
	padding:          u32,
	// The agent type's name.
	agent:            Slice,
	// Nav_Tile records.
	tiles:            Slice,
	// [3]f32, each tile's run.
	vertices:         Slice,
	// Nav_Polygon records, each tile's run.
	polygons:         Slice,
	// Nav_Link records, each polygon's run.
	links:            Slice,
	// A Nav_Detail record for each polygon.
	details:          Slice,
	// [3]f32, each polygon's run.
	detail_vertices:  Slice,
	// [4]u8: three of the polygon's detail vertices and the edge flags, each polygon's run.
	detail_triangles: Slice,
}

// Nav_Tile is one tile of the grid: its bounds, the key that it was baked under, so a bake that gives the same key keeps
// it, and its runs of the streams.
Nav_Tile :: struct {
	key:                   u64,
	x, z:                  u32,
	bounds_min:            [3]f32,
	bounds_max:            [3]f32,
	first_vertex:          u32,
	vertex_count:          u32,
	first_polygon:         u32,
	polygon_count:         u32,
	first_detail_vertex:   u32,
	detail_vertex_count:   u32,
	first_detail_triangle: u32,
	detail_triangle_count: u32,
}

// Nav_Polygon is a convex polygon that agents walk on. Edge i goes from vertices[i] to vertices[(i + 1) % vertex_count].
// Across it is neighbors[i]: a polygon of the same tile, by its index in the tile, NAV_NONE, or NAV_EXTERNAL with the
// tile's Nav_Side, whose links give the polygons of the next tile.
Nav_Polygon :: struct {
	// Indices into the tile's vertices.
	vertices:     [NAV_MAX_POLYGON_VERTICES]u16,
	neighbors:    [NAV_MAX_POLYGON_VERTICES]u16,
	// Indices into links: this polygon's.
	first_link:   u32,
	link_count:   u8,
	vertex_count: u8,
	// The area's kind. Every polygon is walkable ground, 0, for now.
	area:         u8,
	padding:      u8,
}

// Nav_Link joins a polygon's edge on its tile's border to a polygon of the next tile, over the part of the edge between
// t_min and t_max, out of 255, from the edge's first vertex.
Nav_Link :: struct {
	// The polygon across, by its index in the blob's polygons.
	polygon: u32,
	edge:    u8,
	t_min:   u8,
	t_max:   u8,
	padding: u8,
}

// Nav_Detail is a polygon's detail mesh, which gives the height of its surface: its runs of the detail streams, relative
// to its tile's.
Nav_Detail :: struct {
	first_vertex:   u32,
	vertex_count:   u32,
	first_triangle: u32,
	triangle_count: u32,
}

#assert(size_of(Nav_Polygon) == 32 && size_of(Nav_Link) == 8 && size_of(Nav_Detail) == 16 && size_of(Nav_Tile) == 72)

nav_mesh_layout :: proc() -> u64 {
	return(
		layout.hash(Nav_Mesh_Blob) ~
		layout.hash(Nav_Tile) * 31 ~
		layout.hash(Nav_Polygon) * 961 ~
		layout.hash(Nav_Link) * 29791 ~
		layout.hash(Nav_Detail) * 923521 \
	)
}

// nav_mesh_view checks a navmesh blob: its header, its layout, that every stream is inside it and aligned, that its
// tiles are its grid, and that every index points into its run.
nav_mesh_view :: proc(data: []byte) -> (blob: ^Nav_Mesh_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Nav_Mesh || header.layout != nav_mesh_layout() || len(data) < size_of(Nav_Mesh_Blob) {
		return
	}
	blob = (^Nav_Mesh_Blob)(raw_data(data))
	stream :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(data)) && int(s.size) % size == 0 && int(s.offset) % align == 0
	}
	if !stream(data, blob.agent, 1, 1) ||
	   !stream(data, blob.tiles, size_of(Nav_Tile), align_of(Nav_Tile)) ||
	   !stream(data, blob.vertices, size_of([3]f32), align_of([3]f32)) ||
	   !stream(data, blob.polygons, size_of(Nav_Polygon), align_of(Nav_Polygon)) ||
	   !stream(data, blob.links, size_of(Nav_Link), align_of(Nav_Link)) ||
	   !stream(data, blob.details, size_of(Nav_Detail), align_of(Nav_Detail)) ||
	   !stream(data, blob.detail_vertices, size_of([3]f32), align_of([3]f32)) ||
	   !stream(data, blob.detail_triangles, size_of([4]u8), 1) {
		return nil, false
	}
	tiles := nav_mesh_tiles(data, blob)
	polygons := nav_mesh_polygons(data, blob)
	links := nav_mesh_links(data, blob)
	details := nav_mesh_details(data, blob)
	vertex_total := u64(blob.vertices.size) / size_of([3]f32)
	detail_vertex_total := u64(blob.detail_vertices.size) / size_of([3]f32)
	detail_triangle_total := u64(blob.detail_triangles.size) / size_of([4]u8)
	if u64(len(tiles)) != u64(blob.tiles_x) * u64(blob.tiles_z) || len(details) != len(polygons) {
		return nil, false
	}
	inside :: proc(first, count: u32, total: u64) -> bool {
		return u64(first) + u64(count) <= total
	}
	triangles := nav_mesh_detail_triangles(data, blob)
	for tile, i in tiles {
		if tile.x != u32(i) % max(blob.tiles_x, 1) || tile.z != u32(i) / max(blob.tiles_x, 1) ||
		   !inside(tile.first_vertex, tile.vertex_count, vertex_total) ||
		   !inside(tile.first_polygon, tile.polygon_count, u64(len(polygons))) ||
		   !inside(tile.first_detail_vertex, tile.detail_vertex_count, detail_vertex_total) ||
		   !inside(tile.first_detail_triangle, tile.detail_triangle_count, detail_triangle_total) {
			return nil, false
		}
		for &p, j in polygons[tile.first_polygon:][:tile.polygon_count] {
			if p.vertex_count < 3 || p.vertex_count > NAV_MAX_POLYGON_VERTICES ||
			   !inside(p.first_link, u32(p.link_count), u64(len(links))) {
				return nil, false
			}
			for k in 0 ..< int(p.vertex_count) {
				n := p.neighbors[k]
				if u32(p.vertices[k]) >= tile.vertex_count ||
				   (n != NAV_NONE && n & NAV_EXTERNAL == 0 && u32(n) >= tile.polygon_count) ||
				   (n != NAV_NONE && n & NAV_EXTERNAL != 0 && n & ~u16(NAV_EXTERNAL) > u16(max(Nav_Side))) {
					return nil, false
				}
			}
			for l in links[p.first_link:][:p.link_count] {
				if u64(l.polygon) >= u64(len(polygons)) || l.edge >= p.vertex_count || l.t_min > l.t_max {
					return nil, false
				}
			}
			d := details[tile.first_polygon + u32(j)]
			if !inside(d.first_vertex, d.vertex_count, u64(tile.detail_vertex_count)) ||
			   !inside(d.first_triangle, d.triangle_count, u64(tile.detail_triangle_count)) {
				return nil, false
			}
			for t in triangles[tile.first_detail_triangle + d.first_triangle:][:d.triangle_count] {
				if u32(t[0]) >= d.vertex_count || u32(t[1]) >= d.vertex_count || u32(t[2]) >= d.vertex_count {
					return nil, false
				}
			}
		}
	}
	return blob, true
}

nav_mesh_agent :: proc "contextless" (data: []byte, blob: ^Nav_Mesh_Blob) -> Nav_Agent {
	return {
		name = blob_string(data, blob.agent),
		radius = blob.agent_radius,
		height = blob.agent_height,
		step_height = blob.agent_step,
		max_slope = blob.agent_max_slope,
	}
}

nav_mesh_tiles :: proc(data: []byte, blob: ^Nav_Mesh_Blob) -> []Nav_Tile {
	return mem.slice_data_cast([]Nav_Tile, blob_bytes(data, blob.tiles))
}

nav_mesh_vertices :: proc(data: []byte, blob: ^Nav_Mesh_Blob) -> [][3]f32 {
	return mem.slice_data_cast([][3]f32, blob_bytes(data, blob.vertices))
}

nav_mesh_polygons :: proc(data: []byte, blob: ^Nav_Mesh_Blob) -> []Nav_Polygon {
	return mem.slice_data_cast([]Nav_Polygon, blob_bytes(data, blob.polygons))
}

nav_mesh_links :: proc(data: []byte, blob: ^Nav_Mesh_Blob) -> []Nav_Link {
	return mem.slice_data_cast([]Nav_Link, blob_bytes(data, blob.links))
}

nav_mesh_details :: proc(data: []byte, blob: ^Nav_Mesh_Blob) -> []Nav_Detail {
	return mem.slice_data_cast([]Nav_Detail, blob_bytes(data, blob.details))
}

nav_mesh_detail_vertices :: proc(data: []byte, blob: ^Nav_Mesh_Blob) -> [][3]f32 {
	return mem.slice_data_cast([][3]f32, blob_bytes(data, blob.detail_vertices))
}

nav_mesh_detail_triangles :: proc(data: []byte, blob: ^Nav_Mesh_Blob) -> [][4]u8 {
	return mem.slice_data_cast([][4]u8, blob_bytes(data, blob.detail_triangles))
}

// Nav_Mesh_Contents is what nav_mesh_write builds a blob from. The tiles' runs index the streams as the blob's do.
Nav_Mesh_Contents :: struct {
	guid:             Guid,
	key:              u64,
	anchor:           [3]i64,
	volume:           u64,
	agent:            Nav_Agent,
	cell_size:        f32,
	cell_height:      f32,
	tile_size:        f32,
	tiles_x:          u32,
	tiles_z:          u32,
	bounds_min:       [3]f32,
	bounds_max:       [3]f32,
	tiles:            []Nav_Tile,
	vertices:         [][3]f32,
	polygons:         []Nav_Polygon,
	links:            []Nav_Link,
	details:          []Nav_Detail,
	detail_vertices:  [][3]f32,
	detail_triangles: [][4]u8,
}

// nav_mesh_write builds a navmesh blob.
nav_mesh_write :: proc(contents: Nav_Mesh_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Nav_Mesh_Blob), allocator)
	put :: proc(buffer: ^[dynamic]byte, items: []$T) -> Slice {
		s := reserve_bytes(buffer, len(items) * size_of(T), BLOB_ALIGN)
		copy(buffer[s.offset:], mem.slice_to_bytes(items))
		return s
	}
	tiles := put(&buffer, contents.tiles)
	vertices := put(&buffer, contents.vertices)
	polygons := put(&buffer, contents.polygons)
	links := put(&buffer, contents.links)
	details := put(&buffer, contents.details)
	detail_vertices := put(&buffer, contents.detail_vertices)
	detail_triangles := put(&buffer, contents.detail_triangles)
	agent := append_bytes(&buffer, transmute([]byte)contents.agent.name)
	blob := Nav_Mesh_Blob {
		header = {magic = BLOB_MAGIC, kind = .Nav_Mesh, layout = nav_mesh_layout(), key = contents.key, guid = contents.guid},
		anchor = contents.anchor,
		volume = contents.volume,
		bounds_min = contents.bounds_min,
		bounds_max = contents.bounds_max,
		agent_radius = contents.agent.radius,
		agent_height = contents.agent.height,
		agent_step = contents.agent.step_height,
		agent_max_slope = contents.agent.max_slope,
		cell_size = contents.cell_size,
		cell_height = contents.cell_height,
		tile_size = contents.tile_size,
		tiles_x = contents.tiles_x,
		tiles_z = contents.tiles_z,
		agent = agent,
		tiles = tiles,
		vertices = vertices,
		polygons = polygons,
		links = links,
		details = details,
		detail_vertices = detail_vertices,
		detail_triangles = detail_triangles,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
