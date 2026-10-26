package cook

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

// test_gltf is a model of two meshes. Panel is a quad in the xy plane, counterclockwise from +z, in the Stone
// material, and a triangle in the Glass material. Wedge is a triangle that two nodes use. Panel's node is 5 m along +x,
// and Wedge's second node is 2 m up.
@(private = "file")
test_gltf :: proc(wedge_name := "Wedge") -> string {
	positions := [?][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}
	indices := [?]u16{0, 1, 2, 0, 2, 3}
	triangle := [?][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}
	buffer := make([dynamic]byte, context.temp_allocator)
	append(&buffer, ..mem.slice_to_bytes(positions[:]))
	append(&buffer, ..mem.slice_to_bytes(indices[:]))
	append(&buffer, ..mem.slice_to_bytes(triangle[:]))
	encoded := base64.encode(buffer[:], allocator = context.temp_allocator)
	return fmt.tprintf(
		`{{
  "asset": {{"version": "2.0"}},
  "buffers": [{{"byteLength": %d, "uri": "data:application/octet-stream;base64,%s"}}],
  "bufferViews": [
    {{"buffer": 0, "byteOffset": 0, "byteLength": 48}},
    {{"buffer": 0, "byteOffset": 48, "byteLength": 12}},
    {{"buffer": 0, "byteOffset": 60, "byteLength": 36}}
  ],
  "accessors": [
    {{"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]}},
    {{"bufferView": 1, "componentType": 5123, "count": 6, "type": "SCALAR"}},
    {{"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]}}
  ],
  "materials": [{{"name": "Stone"}}, {{"name": "Glass"}}],
  "meshes": [
    {{"name": "Panel", "primitives": [
      {{"attributes": {{"POSITION": 0}}, "indices": 1, "material": 0}},
      {{"attributes": {{"POSITION": 2}}, "material": 1}}
    ]}},
    {{"name": "%s", "primitives": [{{"attributes": {{"POSITION": 2}}, "material": 0}}]}}
  ],
  "nodes": [
    {{"mesh": 0, "translation": [5, 0, 0]}},
    {{"mesh": 1}},
    {{"mesh": 1, "translation": [0, 2, 0]}}
  ],
  "scenes": [{{"nodes": [0, 1, 2]}}],
  "scene": 0
}}`,
		len(buffer),
		encoded,
		wedge_name,
	)
}

@(private = "file")
read_meta :: proc(t: ^testing.T, tree: Tree, path: string) -> format.Meta {
	text, err := os.read_entire_file(fmt.tprintf("%s/content/%s.meta", tree.dir, path), context.temp_allocator)
	testing.expect(t, err == nil)
	meta, ok := format.meta_parse(string(text), context.temp_allocator)
	testing.expect(t, ok)
	return meta
}

@(private = "file")
mesh_blob :: proc(t: ^testing.T, tree: Tree, guid: format.Guid) -> (data: []byte, blob: ^format.Mesh_Blob, ok: bool) {
	data = tree_blob(t, tree, guid)
	blob, ok = format.mesh_view(data)
	testing.expect(t, ok, "a mesh did not cook into a mesh blob")
	return
}

@(test)
each_gltf_mesh_is_a_subasset_in_its_own_space :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/kit.gltf", test_gltf()}})
	defer remove_tree(tree)
	options := tree_options(tree)

	pass := cook(options, {.Model})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Mesh], 2)
	meta := read_meta(t, tree, "kit.gltf")
	panel, panel_found := format.meta_subasset(meta, format.MESH_KIND, "Panel")
	_, wedge_found := format.meta_subasset(meta, format.MESH_KIND, "Wedge")
	testing.expect(t, panel_found && wedge_found)

	data, blob, ok := mesh_blob(t, tree, panel)
	if !ok {
		return
	}
	testing.expect_value(t, format.blob_string(data, blob.name), "Panel")
	submeshes := format.mesh_submeshes(data, blob)
	testing.expect_value(t, len(submeshes), 2)
	if len(submeshes) == 2 {
		testing.expect_value(t, format.blob_string(data, submeshes[0].name), "Stone")
		testing.expect_value(t, submeshes[0].index_count, 6)
		testing.expect_value(t, format.blob_string(data, submeshes[1].name), "Glass")
		testing.expect_value(t, submeshes[1].index_count, 3)
		testing.expect(t, submeshes[0].meshlet_count == 1 && submeshes[1].meshlet_count == 1)
	}
	// The node's translation is not baked in, and x is mirrored into the engine's axes.
	testing.expect_value(t, blob.bounds.min, [3]f32{-1, 0, 0})
	testing.expect_value(t, blob.bounds.max, [3]f32{0, 1, 0})
	// The quad's corners weld into 4 vertices, and the triangle shares 3 positions but not its faces' normal.
	testing.expect(t, blob.vertex_count >= 4)

	// Without normals in the file, faces get their own, and the quad still faces +z.
	attributes := format.blob_bytes(data, blob.attributes)
	normal := (^format.Mesh_Attributes)(&attributes[0]).normal
	testing.expect_value(t, normal, encode_normal({0, 0, 1}))

	again := cook(options, {.Model})
	testing.expect_value(t, again.current[.Model], 1)
	testing.expect_value(t, again.cooked[.Mesh], 0)
}

@(test)
combine_bakes_the_scene_into_one_mesh :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/kit.gltf", test_gltf()}, {"content/kit.gltf.meta", "guid = 00112233445566778899aabbccddeeff\ncombine = true\n"}})
	defer remove_tree(tree)
	testing.expect(t, cook(tree_options(tree), {.Model}).ok)
	meta := read_meta(t, tree, "kit.gltf")
	testing.expect_value(t, len(meta.subassets), 1)
	guid, found := format.meta_subasset(meta, format.MESH_KIND, "kit")
	testing.expect(t, found)
	if _, blob, ok := mesh_blob(t, tree, guid); ok {
		// Panel's quad and triangle, and Wedge twice.
		testing.expect_value(t, blob.index_count, (2 + 1 + 1 + 1) * 3)
		// Panel's node moves it to x = 5, which the mirror makes -5, and Wedge's second node lifts it to y = 3.
		testing.expect_value(t, blob.bounds.min, [3]f32{-6, 0, 0})
		testing.expect_value(t, blob.bounds.max, [3]f32{0, 3, 0})
	}
}

@(test)
a_renamed_mesh_gets_a_new_guid_and_reimport_forgets_the_old :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/kit.gltf", test_gltf()}})
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook(options, {.Model}).ok)
	wedge, _ := format.meta_subasset(read_meta(t, tree, "kit.gltf"), format.MESH_KIND, "Wedge")

	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/kit.gltf", tree.dir), transmute([]byte)test_gltf("Ramp")) == nil)
	pass := cook(options, {.Model})
	testing.expect(t, pass.ok)
	meta := read_meta(t, tree, "kit.gltf")
	ramp, ramp_found := format.meta_subasset(meta, format.MESH_KIND, "Ramp")
	old, old_found := format.meta_subasset(meta, format.MESH_KIND, "Wedge")
	testing.expect(t, ramp_found && ramp != wedge)
	// The old line stays, so a rename back restores the GUID.
	testing.expect(t, old_found && old == wedge)
	found_warning := false
	for p in pass.problems.list {
		found_warning ||= strings.contains(p.text, "mesh.Wedge is no longer in the file")
	}
	testing.expect(t, found_warning)

	force := make(map[format.Guid]bool, context.temp_allocator)
	force[meta.guid] = true
	testing.expect(t, cook(options, {.Model}, force = force).ok)
	_, still_there := format.meta_subasset(read_meta(t, tree, "kit.gltf"), format.MESH_KIND, "Wedge")
	testing.expect(t, !still_there)
}

@(test)
octahedral_vectors_round_trip :: proc(t: ^testing.T) {
	decode :: proc(p: [2]f32) -> [3]f32 {
		n := [3]f32{p.x, p.y, 1 - abs(p.x) - abs(p.y)}
		if n.z < 0 {
			sign := [2]f32{n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1}
			n.xy = (1 - [2]f32{abs(n.y), abs(n.x)}) * sign
		}
		return linalg.normalize(n)
	}
	for n in ([][3]f32{{0, 0, 1}, {0, 0, -1}, {1, 0, 0}, {-0.48, 0.6, -0.64}, {0.267, -0.534, 0.801}}) {
		unit := linalg.normalize(n)
		back := decode(octahedral(unit))
		testing.expectf(t, linalg.length(back - unit) < 1e-4, "%v came back as %v", unit, back)
	}
	// The bitangent's sign is the second component's lowest bit.
	testing.expect_value(t, encode_tangent({1, 0, 0, -1}).y & 1, 1)
	testing.expect_value(t, encode_tangent({1, 0, 0, 1}).y & 1, 0)
}

// grid_gltf is a mesh of one gently bumpy square of size by size quads, which simplifies into several levels.
@(private = "file")
grid_gltf :: proc(size: int) -> string {
	positions := make([dynamic][3]f32, context.temp_allocator)
	for y in 0 ..= size {
		for x in 0 ..= size {
			fx, fy := f32(x) / f32(size), f32(y) / f32(size)
			append(&positions, [3]f32{fx, fy, 0.05 * math.sin(fx * 7) * math.cos(fy * 5)})
		}
	}
	indices := make([dynamic]u32, context.temp_allocator)
	row := u32(size + 1)
	for y in 0 ..< u32(size) {
		for x in 0 ..< u32(size) {
			i := y * row + x
			append(&indices, i, i + 1, i + row + 1, i, i + row + 1, i + row)
		}
	}
	buffer := make([dynamic]byte, context.temp_allocator)
	append(&buffer, ..mem.slice_to_bytes(positions[:]))
	append(&buffer, ..mem.slice_to_bytes(indices[:]))
	encoded := base64.encode(buffer[:], allocator = context.temp_allocator)
	position_bytes := len(positions) * 12
	return fmt.tprintf(
		`{{
  "asset": {{"version": "2.0"}},
  "buffers": [{{"byteLength": %d, "uri": "data:application/octet-stream;base64,%s"}}],
  "bufferViews": [
    {{"buffer": 0, "byteOffset": 0, "byteLength": %d}},
    {{"buffer": 0, "byteOffset": %d, "byteLength": %d}}
  ],
  "accessors": [
    {{"bufferView": 0, "componentType": 5126, "count": %d, "type": "VEC3", "min": [0, 0, -0.05], "max": [1, 1, 0.05]}},
    {{"bufferView": 1, "componentType": 5125, "count": %d, "type": "SCALAR"}}
  ],
  "meshes": [{{"name": "Grid", "primitives": [{{"attributes": {{"POSITION": 0}}, "indices": 1}}]}}],
  "nodes": [{{"mesh": 0}}],
  "scenes": [{{"nodes": [0]}}],
  "scene": 0
}}`,
		len(buffer),
		encoded,
		position_bytes,
		position_bytes,
		len(indices) * 4,
		len(positions),
		len(indices),
	)
}

// Grid_Mesh is a cooked grid's meshlets, as the tests below read them.
@(private = "file")
Grid_Mesh :: struct {
	data:      []byte,
	blob:      ^format.Mesh_Blob,
	meshlets:  []format.Meshlet,
	vertices:  []u32,
	triangles: []u32,
	positions: [][3]f32,
}

@(private = "file")
cook_grid :: proc(t: ^testing.T, meta: string) -> (grid: Grid_Mesh, ok: bool) {
	tree := make_tree(t, {{"content/grid.gltf", grid_gltf(48)}, {"content/grid.gltf.meta", meta}})
	defer remove_tree(tree)
	testing.expect(t, cook(tree_options(tree), {.Model}).ok)
	guid, found := format.meta_subasset(read_meta(t, tree, "grid.gltf"), format.MESH_KIND, "Grid")
	testing.expect(t, found)
	grid.data, grid.blob = mesh_blob(t, tree, guid) or_return
	grid.meshlets = format.mesh_meshlets(grid.data, grid.blob)
	grid.vertices = slice.reinterpret([]u32, format.blob_bytes(grid.data, grid.blob.meshlet_vertices))
	grid.triangles = slice.reinterpret([]u32, format.blob_bytes(grid.data, grid.blob.meshlet_triangles))
	grid.positions = slice.reinterpret([][3]f32, format.blob_bytes(grid.data, grid.blob.positions))
	return grid, true
}

// meshlet_area is the area of a meshlet's triangles.
@(private = "file")
meshlet_area :: proc(grid: Grid_Mesh, m: format.Meshlet) -> f32 {
	area: f32
	for packed in grid.triangles[m.triangle_offset:][:m.triangle_count] {
		corner :: proc(grid: Grid_Mesh, m: format.Meshlet, packed: u32, shift: u32) -> [3]f32 {
			return grid.positions[grid.vertices[m.vertex_offset + (packed >> shift) & 0xff]]
		}
		a, b, c := corner(grid, m, packed, 0), corner(grid, m, packed, 8), corner(grid, m, packed, 16)
		area += linalg.length(linalg.cross(b - a, c - a)) / 2
	}
	return area
}

@(test)
cluster_lod_builds_a_hierarchy_whose_every_cut_covers_the_mesh :: proc(t: ^testing.T) {
	grid, ok := cook_grid(t, "guid = 00112233445566778899aabbccddeeff\n")
	if !ok {
		return
	}
	submeshes := format.mesh_submeshes(grid.data, grid.blob)
	testing.expect_value(t, len(submeshes), 1)
	testing.expect_value(t, int(submeshes[0].meshlet_count), len(grid.meshlets))

	deepest := 0
	for m, i in grid.meshlets {
		testing.expectf(t, m.vertex_count <= format.MESHLET_MAX_VERTICES && m.triangle_count <= format.MESHLET_MAX_TRIANGLES, "meshlet %d has %d vertices and %d triangles", i, m.vertex_count, m.triangle_count)
		for packed in grid.triangles[m.triangle_offset:][:m.triangle_count] {
			testing.expect(t, packed >> 24 == 0 && packed & 0xff < u32(m.vertex_count) && (packed >> 8) & 0xff < u32(m.vertex_count) && (packed >> 16) & 0xff < u32(m.vertex_count))
		}
		for v in grid.vertices[m.vertex_offset:][:m.vertex_count] {
			testing.expect(t, v < grid.blob.vertex_count)
		}
		// The submesh's own triangles have no error, and errors grow a level up, so each view draws one level of each
		// part of the mesh.
		testing.expect(t, m.depth != 0 || m.error == 0)
		testing.expectf(t, m.error <= m.parent_error, "meshlet %d's error %v is over its parent's %v", i, m.error, m.parent_error)
		if i > 0 {
			testing.expect(t, m.depth >= grid.meshlets[i - 1].depth)
		}
		deepest = max(deepest, int(m.depth))
	}
	testing.expectf(t, deepest >= 2, "the grid simplified to only %d levels", deepest + 1)
	testing.expect_value(t, grid.meshlets[len(grid.meshlets) - 1].parent_error, math.F32_MAX)

	// The cut at any threshold is a whole mesh: its area is the grid's, without holes or overlaps.
	full: f32
	for m in grid.meshlets {
		if m.depth == 0 {
			full += meshlet_area(grid, m)
		}
	}
	for threshold in ([]f32{0, 1e-4, 1e-3, 1e-2, 0.1, math.F32_MAX / 2}) {
		area: f32
		triangles := 0
		for m in grid.meshlets {
			if m.error <= threshold && m.parent_error > threshold {
				area += meshlet_area(grid, m)
				triangles += int(m.triangle_count)
			}
		}
		testing.expectf(t, abs(area - full) < full * 0.02, "the cut at %v has an area of %v, not %v", threshold, area, full)
		testing.expect(t, triangles > 0)
	}
}

@(test)
without_cluster_lod_meshlets_are_the_mesh_itself :: proc(t: ^testing.T) {
	grid, ok := cook_grid(t, "guid = 00112233445566778899aabbccddeeff\ncluster_lod = false\n")
	if !ok {
		return
	}
	triangles := 0
	for m in grid.meshlets {
		testing.expect(t, m.depth == 0 && m.error == 0 && m.parent_error == math.F32_MAX)
		triangles += int(m.triangle_count)
	}
	testing.expect_value(t, triangles, int(grid.blob.index_count / 3))
}
