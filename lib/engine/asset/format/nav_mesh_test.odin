package asset_format

import "core:slice"
import "core:testing"

// Two tiles side by side, each with a square on y = 0, joined across their shared edge.
@(private = "file")
two_tiles :: proc() -> Nav_Mesh_Contents {
	square :: proc(x: f32) -> [4][3]f32 {
		return {{x, 0, 0}, {x, 0, 1}, {x + 1, 0, 1}, {x + 1, 0, 0}}
	}
	vertices := make([dynamic][3]f32, context.temp_allocator)
	left, right := square(0), square(1)
	append(&vertices, ..left[:])
	append(&vertices, ..right[:])
	detail_vertices := slice.clone(vertices[:], context.temp_allocator)
	east := u16(NAV_EXTERNAL) | u16(Nav_Side.East)
	west := u16(NAV_EXTERNAL) | u16(Nav_Side.West)
	polygons := []Nav_Polygon {
		{vertices = {0, 1, 2, 3, 0, 0}, neighbors = {NAV_NONE, NAV_NONE, east, NAV_NONE, 0, 0}, first_link = 0, link_count = 1, vertex_count = 4},
		{vertices = {0, 1, 2, 3, 0, 0}, neighbors = {west, NAV_NONE, NAV_NONE, NAV_NONE, 0, 0}, first_link = 1, link_count = 1, vertex_count = 4},
	}
	return {
		guid = Guid{0 = 7},
		key = 99,
		anchor = {1 << 24, 0, -(1 << 24)},
		volume = 0x1234,
		agent = {"Human", 0.4, 1.8, 0.35, 45},
		agent_index = 3,
		cell_size = 0.1,
		cell_height = 0.05,
		tile_size = 1,
		tiles_x = 2,
		tiles_z = 1,
		bounds_min = {0, -1, 0},
		bounds_max = {2, 1, 1},
		tiles = slice.clone([]Nav_Tile{
			{key = 1, x = 0, z = 0, bounds_max = {1, 1, 1}, first_vertex = 0, vertex_count = 4, first_polygon = 0, polygon_count = 1, first_detail_vertex = 0, detail_vertex_count = 4, first_detail_triangle = 0, detail_triangle_count = 2},
			{key = 2, x = 1, z = 0, bounds_min = {1, -1, 0}, bounds_max = {2, 1, 1}, first_vertex = 4, vertex_count = 4, first_polygon = 1, polygon_count = 1, first_detail_vertex = 4, detail_vertex_count = 4, first_detail_triangle = 2, detail_triangle_count = 2},
		}, context.temp_allocator),
		vertices = vertices[:],
		polygons = slice.clone(polygons, context.temp_allocator),
		links = slice.clone([]Nav_Link{{polygon = 1, edge = 2, t_min = 0, t_max = 255}, {polygon = 0, edge = 0, t_min = 0, t_max = 255}}, context.temp_allocator),
		details = slice.clone([]Nav_Detail{{0, 4, 0, 2}, {0, 4, 0, 2}}, context.temp_allocator),
		detail_vertices = detail_vertices,
		detail_triangles = slice.clone([][4]u8{{0, 1, 2, 0}, {0, 2, 3, 0}, {0, 1, 2, 0}, {0, 2, 3, 0}}, context.temp_allocator),
	}
}

@(test)
nav_meshes_write_and_read_back :: proc(t: ^testing.T) {
	contents := two_tiles()
	data := aligned(nav_mesh_write(contents, context.temp_allocator))
	blob, ok := nav_mesh_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.header.key, 99)
	testing.expect_value(t, blob.anchor, contents.anchor)
	testing.expect_value(t, blob.volume, 0x1234)
	testing.expect_value(t, nav_mesh_agent(data, blob), contents.agent)
	testing.expect_value(t, blob.agent_index, 3)
	testing.expect(t, slice.equal(nav_mesh_tiles(data, blob), contents.tiles))
	testing.expect(t, slice.equal(nav_mesh_vertices(data, blob), contents.vertices))
	testing.expect(t, slice.equal(nav_mesh_polygons(data, blob), contents.polygons))
	testing.expect(t, slice.equal(nav_mesh_links(data, blob), contents.links))
	testing.expect(t, slice.equal(nav_mesh_details(data, blob), contents.details))
	testing.expect(t, slice.equal(nav_mesh_detail_triangles(data, blob), contents.detail_triangles))
	references, references_ok := blob_references(data, context.temp_allocator)
	testing.expect(t, references_ok && len(references) == 0)
}

@(test)
nav_meshes_that_point_outside_their_runs_are_refused :: proc(t: ^testing.T) {
	bad_vertex := two_tiles()
	bad_vertex.polygons[0].vertices[2] = 4
	_, ok := nav_mesh_view(aligned(nav_mesh_write(bad_vertex, context.temp_allocator)))
	testing.expect(t, !ok)

	bad_neighbor := two_tiles()
	bad_neighbor.polygons[1].neighbors[1] = 1
	_, ok = nav_mesh_view(aligned(nav_mesh_write(bad_neighbor, context.temp_allocator)))
	testing.expect(t, !ok)

	bad_link := two_tiles()
	bad_link.links[0].polygon = 2
	_, ok = nav_mesh_view(aligned(nav_mesh_write(bad_link, context.temp_allocator)))
	testing.expect(t, !ok)

	bad_grid := two_tiles()
	bad_grid.tiles_z = 2
	_, ok = nav_mesh_view(aligned(nav_mesh_write(bad_grid, context.temp_allocator)))
	testing.expect(t, !ok)

	// The second tile's polygons must start where the first's end.
	bad_runs := two_tiles()
	bad_runs.tiles[1].first_polygon = 0
	_, ok = nav_mesh_view(aligned(nav_mesh_write(bad_runs, context.temp_allocator)))
	testing.expect(t, !ok)

	bad_triangle := two_tiles()
	bad_triangle.detail_triangles[3] = {0, 2, 4, 0}
	_, ok = nav_mesh_view(aligned(nav_mesh_write(bad_triangle, context.temp_allocator)))
	testing.expect(t, !ok)
}

@(test)
a_scene_lists_its_nav_meshes_and_names_them :: proc(t: ^testing.T) {
	scene, _, parsed := scene_parse("scene 1\nentity 0000000000000001\n", context.temp_allocator)
	testing.expect(t, parsed)
	navs := []Scene_Nav_Mesh{{entity = 1, agent = "Human", guid = Guid{0 = 5}}, {entity = 1, agent = "Large", guid = Guid{0 = 6}}}
	data := aligned(scene_write(scene, {}, 0, nav_meshes = navs, allocator = context.temp_allocator))
	read, ok := scene_nav_meshes(data, context.temp_allocator)
	testing.expect(t, ok && slice.equal(read, navs))
	references, references_ok := blob_references(data, context.temp_allocator)
	testing.expect(t, references_ok && slice.equal(references, []Guid{{0 = 5}, {0 = 6}}))
	empty, empty_ok := scene_nav_meshes(aligned(scene_write(scene, {}, 0, allocator = context.temp_allocator)), context.temp_allocator)
	testing.expect(t, empty_ok && len(empty) == 0)
}
