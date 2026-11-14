package cook

import "core:hash"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:testing"

import "cinnabar:core/lz4"
import format "cinnabar:engine/asset/format"

// Paged_Grid is a grid cooked with pages, with every page decompressed and checked.
@(private = "file")
Paged_Grid :: struct {
	data:         []byte,
	blob:         ^format.Mesh_Blob,
	records:      []format.Mesh_Page,
	dependencies: []u32,
	pages:        [][]byte,
	headers:      []^format.Mesh_Page_Header,
}

// A grid of this many quads a side has several pages.
@(private = "file")
PAGED_GRID_SIZE :: 160

@(private = "file")
cook_paged_grid :: proc(t: ^testing.T, size := PAGED_GRID_SIZE, settings := "pages = true\n", normals := false) -> (grid: Paged_Grid, ok: bool) {
	tree := make_tree(t, {{"content/grid.gltf", grid_gltf(size, normals)}, {"content/grid.gltf.meta", fmt_meta(settings)}})
	defer remove_tree(tree)
	testing.expect(t, cook(tree_options(tree), {.Model}).ok)
	guid, found := format.meta_subasset(read_meta(t, tree, "grid.gltf"), format.MESH_KIND, "Grid")
	testing.expect(t, found)
	grid.data, grid.blob = mesh_blob(t, tree, guid) or_return
	grid.records = format.mesh_pages(grid.data, grid.blob)
	grid.dependencies = format.mesh_page_dependencies(grid.data, grid.blob)
	grid.pages = make([][]byte, len(grid.records), context.temp_allocator)
	grid.headers = make([]^format.Mesh_Page_Header, len(grid.records), context.temp_allocator)
	stride := format.mesh_attribute_stride(grid.blob.flags)
	for record, i in grid.records {
		block := grid.data[record.offset:][:record.compressed_size]
		testing.expect_value(t, hash.fnv32a(block), record.checksum)
		grid.pages[i] = make([]byte, record.size, context.temp_allocator)
		if !testing.expectf(t, lz4.decompress(block, grid.pages[i]), "page %d does not decompress", i) {
			return
		}
		viewed: bool
		grid.headers[i], viewed = format.mesh_page_view(grid.pages[i], record, stride)
		if !testing.expectf(t, viewed, "page %d is not a page", i) {
			return
		}
	}
	return grid, true
}

@(private = "file")
fmt_meta :: proc(settings: string) -> string {
	text := make([dynamic]byte, context.temp_allocator)
	append(&text, "guid = 00112233445566778899aabbccddeeff\n")
	append(&text, settings)
	return string(text[:])
}

// page_meshlet_area is the area of a meshlet of a page.
@(private = "file")
page_meshlet_area :: proc(grid: Paged_Grid, page: int, m: format.Meshlet) -> f32 {
	header := grid.headers[page]
	refs := format.mesh_page_refs(grid.pages[page], header)
	positions := format.mesh_page_positions(grid.pages[page], header)
	area: f32
	triangles := format.mesh_page_triangles(grid.pages[page], header)
	for i in 0 ..< int(m.triangle_count) {
		corners: [3][3]f32
		for local, k in format.meshlet_triangle(m, triangles, i) {
			corners[k] = positions[format.meshlet_vertex(m, refs, int(local))]
		}
		area += linalg.length(linalg.cross(corners[1] - corners[0], corners[2] - corners[0])) / 2
	}
	return area
}

@(test)
pages_hold_whole_groups_and_fit_their_size :: proc(t: ^testing.T) {
	grid, ok := cook_paged_grid(t)
	if !ok {
		return
	}
	blob := grid.blob
	testing.expect(t, .Paged in blob.flags)
	testing.expectf(t, len(grid.records) >= 4, "the grid has only %d pages", len(grid.records))
	testing.expect_value(t, blob.positions.size + blob.attributes.size + blob.indices.size + blob.meshlets.size + blob.meshlet_vertices.size + blob.meshlet_triangles.size, 0)
	testing.expect(t, blob.head_size < blob.file_size && int(blob.file_size) == len(grid.data))

	s := format.mesh_submeshes(grid.data, blob)[0]
	next: u32
	roots := 0
	previous_depth: u8
	for record, i in grid.records {
		testing.expect(t, record.size <= format.MESH_PAGE_SIZE && record.compressed_size < record.size)
		testing.expect_value(t, record.first_meshlet, next)
		next += record.meshlet_count
		root := .Root in record.flags
		roots += int(root)
		// Only the last page is the one submesh's root, in the head. The others follow the head.
		testing.expect_value(t, root, i == len(grid.records) - 1)
		testing.expect(t, root ? record.offset + record.compressed_size <= blob.head_size : record.offset >= blob.head_size)
		for d in grid.dependencies[record.first_dependency:][:record.dependency_count] {
			testing.expectf(t, int(d) > i && int(d) < len(grid.records), "page %d depends on page %d", i, d)
		}
		// The levels are in order through the pages, and a meshlet's source is in its page or before it.
		for m in format.mesh_page_meshlets(grid.pages[i], grid.headers[i]) {
			testing.expect(t, m.depth >= previous_depth)
			previous_depth = m.depth
			testing.expect(t, (m.depth == 0) == (m.refined_page == format.MESH_PAGE_NONE))
			testing.expect(t, m.refined_page == format.MESH_PAGE_NONE || int(m.refined_page) <= i)
		}
	}
	testing.expect_value(t, next, blob.meshlet_count)
	testing.expect_value(t, next, s.meshlet_count)
	testing.expect_value(t, roots, 1)
	// A page was closed because the group before it did not fit in it, so two pages in a row are more than one.
	for record, i in grid.records[1:] {
		testing.expectf(t, record.size + grid.records[i].size > format.MESH_PAGE_SIZE, "pages %d and %d have %d and %d bytes, which fit in one", i, i + 1, grid.records[i].size, record.size)
	}

	// Each leaf is one group, whole in its page: its meshlets have the node's bounds as their parent's, and each
	// meshlet is under one leaf.
	under := make([]int, blob.meshlet_count, context.temp_allocator)
	leaves := 0
	for n in format.mesh_meshlet_nodes(grid.data, blob)[s.first_node:][:s.node_count] {
		if n.count & format.MESHLET_NODE_LEAF == 0 {
			continue
		}
		leaves += 1
		count := n.count & ~format.MESHLET_NODE_LEAF
		record := grid.records[n.page]
		testing.expect(t, n.first + count <= record.meshlet_count)
		for m, k in format.mesh_page_meshlets(grid.pages[n.page], grid.headers[n.page])[n.first:][:count] {
			under[int(record.first_meshlet + n.first) + k] += 1
			testing.expect(t, m.parent_center == n.center && m.parent_radius == n.radius && m.parent_error == n.error)
		}
	}
	testing.expect(t, leaves > len(grid.records))
	for count, i in under {
		testing.expectf(t, count == 1, "meshlet %d is under %d leaves", i, count)
	}

	// A page depends on exactly the pages that hold what was simplified from its groups.
	for _, i in grid.records {
		for m in format.mesh_page_meshlets(grid.pages[i], grid.headers[i]) {
			if m.refined_page == format.MESH_PAGE_NONE || int(m.refined_page) == i {
				continue
			}
			source := grid.records[m.refined_page]
			found := false
			for d in grid.dependencies[source.first_dependency:][:source.dependency_count] {
				found ||= int(d) == i
			}
			testing.expectf(t, found, "page %d does not depend on page %d, which holds what was simplified from it", m.refined_page, i)
		}
	}
}

@(test)
a_pages_level_0_is_the_meshs_own_triangles :: proc(t: ^testing.T) {
	grid, ok := cook_paged_grid(t)
	if !ok {
		return
	}
	blob := grid.blob
	s := format.mesh_submeshes(grid.data, blob)[0]
	positions := make([dynamic][3]f32, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for record, i in grid.records {
		if record.level0_meshlets == 0 {
			continue
		}
		testing.expect_value(t, int(record.first_vertex), len(positions))
		append(&positions, ..format.mesh_page_positions(grid.pages[i], grid.headers[i]))
		count := format.mesh_page_level0_indices(grid.pages[i], grid.headers[i], record)
		at := len(indices)
		resize(&indices, at + count)
		testing.expect_value(t, format.mesh_page_level0(grid.pages[i], grid.headers[i], record, indices[at:]), count)
	}
	testing.expect_value(t, len(positions), int(blob.vertex_count))
	testing.expect_value(t, len(indices), int(blob.index_count))
	testing.expect_value(t, s.first_index, 0)
	testing.expect_value(t, s.index_count, blob.index_count)
	testing.expect_value(t, .Index32 in blob.flags, blob.vertex_count > 65535)
	// The grid's own triangles, each once: two for each quad, over a unit square that is nearly flat.
	testing.expect_value(t, len(indices), PAGED_GRID_SIZE * PAGED_GRID_SIZE * 6)
	area: f32
	face: [3]f32
	for i := 0; i < len(indices); i += 3 {
		testing.expect(t, indices[i] < blob.vertex_count && indices[i + 1] < blob.vertex_count && indices[i + 2] < blob.vertex_count)
		a, b, c := positions[indices[i]], positions[indices[i + 1]], positions[indices[i + 2]]
		normal := linalg.cross(b - a, c - a) / 2
		area += linalg.length(normal)
		face += normal
	}
	testing.expectf(t, area > 1 && area < 1.1, "level 0 has an area of %v", area)
	testing.expectf(t, linalg.distance(face, blob.face_area) < 1e-3, "the faces look along %v, and the blob says %v", face, blob.face_area)
	testing.expect(t, linalg.distance(format.mesh_face_area(grid.data, blob), blob.face_area) == 0)
}

// Page_Cut is what a view draws of a paged grid with some of its pages resident.
@(private = "file")
Page_Cut :: struct {
	area:   f32,
	drawn:  int,
	// Meshlets that the view draws but that the walk of the nodes did not reach.
	missed: int,
}

// cut_pages draws the grid from an eye as the renderer does (see docs/rendering/gpu-scene.md#mesh-shader-path): the
// walk takes a leaf whose error shows and whose page is resident, and of its meshlets the ones whose own error does not
// show, or whose source's page is not resident.
@(private = "file")
cut_pages :: proc(grid: Paged_Grid, resident: []bool, eye: [3]f32, lod_scale: f32) -> (cut: Page_Cut) {
	s := format.mesh_submeshes(grid.data, grid.blob)[0]
	nodes := format.mesh_meshlet_nodes(grid.data, grid.blob)[s.first_node:][:s.node_count]
	found := make([]bool, grid.blob.meshlet_count, context.temp_allocator)
	queue := make([dynamic]u32, context.temp_allocator)
	for root in 0 ..< s.root_count {
		append(&queue, root)
	}
	for len(queue) > 0 {
		n := nodes[pop(&queue)]
		if paged_projected_error(n.center, n.radius, n.error, eye, lod_scale) <= 1 {
			continue
		}
		count := n.count & ~format.MESHLET_NODE_LEAF
		if n.count & format.MESHLET_NODE_LEAF == 0 {
			for k in n.first ..< n.first + count {
				append(&queue, k)
			}
		} else if resident[n.page] {
			for k in n.first ..< n.first + count {
				found[grid.records[n.page].first_meshlet + k] = true
			}
		}
	}
	for record, p in grid.records {
		if !resident[p] {
			continue
		}
		for m, k in format.mesh_page_meshlets(grid.pages[p], grid.headers[p]) {
			source_missing := m.refined_page != format.MESH_PAGE_NONE && !resident[m.refined_page]
			fine_enough := paged_projected_error(m.error_center, m.error_radius, m.error, eye, lod_scale) <= 1
			if paged_projected_error(m.parent_center, m.parent_radius, m.parent_error, eye, lod_scale) > 1 && (fine_enough || source_missing) {
				cut.area += page_meshlet_area(grid, p, m)
				cut.drawn += 1
				cut.missed += int(!found[int(record.first_meshlet) + k])
			}
		}
	}
	return
}

@(private = "file")
paged_projected_error :: proc(center: [3]f32, radius, error: f32, eye: [3]f32, lod_scale: f32) -> f32 {
	return error / max(linalg.distance(center, eye) - radius, 1e-3) * lod_scale
}

// residents is a set of resident pages that the renderer can reach: the roots, and `more` pages added one at a time,
// each only when everything that it depends on is resident.
@(private = "file")
residents :: proc(grid: Paged_Grid, more: int, generator: ^rand.Default_Random_State) -> []bool {
	context.random_generator = rand.default_random_generator(generator)
	resident := make([]bool, len(grid.records), context.temp_allocator)
	for record, i in grid.records {
		resident[i] = .Root in record.flags
	}
	for _ in 0 ..< more {
		ready := make([dynamic]int, context.temp_allocator)
		for record, i in grid.records {
			if resident[i] {
				continue
			}
			loadable := true
			for d in grid.dependencies[record.first_dependency:][:record.dependency_count] {
				loadable &&= resident[d]
			}
			if loadable {
				append(&ready, i)
			}
		}
		if len(ready) == 0 {
			break
		}
		resident[rand.choice(ready[:])] = true
	}
	return resident
}

// A page keeps every triangle of its meshlets, those of a full meshlet too, whose triangles' bytes are more than a u8
// counts.
@(test)
a_page_keeps_every_triangle_of_a_full_meshlet :: proc(t: ^testing.T) {
	grid, ok := cook_paged_grid(t, normals = true)
	if !ok {
		return
	}
	testing.expectf(t, len(grid.records) > 1, "the grid has %d pages", len(grid.records))
	most, level0 := 0, 0
	for record, i in grid.records {
		for m, k in format.mesh_page_meshlets(grid.pages[i], grid.headers[i]) {
			most = max(most, int(m.triangle_count))
			if u32(k) < record.level0_meshlets {
				level0 += int(m.triangle_count)
			}
		}
	}
	testing.expectf(t, most * 3 > int(max(u8)), "the largest meshlet has only %d triangles", most)
	testing.expect_value(t, level0, PAGED_GRID_SIZE * PAGED_GRID_SIZE * 2)
}

@(test)
every_cut_covers_the_mesh_with_pages_missing :: proc(t: ^testing.T) {
	grid, ok := cook_paged_grid(t)
	if !ok {
		return
	}
	full: f32
	for record, p in grid.records {
		for m in format.mesh_page_meshlets(grid.pages[p], grid.headers[p])[:record.level0_meshlets] {
			full += page_meshlet_area(grid, p, m)
		}
	}
	s := format.mesh_submeshes(grid.data, grid.blob)[0]
	center, radius := s.bounds.center, s.bounds.radius
	generator := rand.create(252)
	sets := 0
	fallbacks := 0
	// From the roots alone to every page, through sets of each size between.
	for more := 0; more < len(grid.records); more += 1 {
		for _ in 0 ..< 3 {
			resident := residents(grid, more, &generator)
			sets += 1
			for distance in ([]f32{0, 0.1, 1, 4, 20}) {
				for lod_scale in ([]f32{1, 100, 1e4, 1e6}) {
					eye := center + {0.3, 1, 0.2} * radius * distance
					cut := cut_pages(grid, resident, eye, lod_scale)
					testing.expectf(t, abs(cut.area - full) < full * 0.02, "with %d pages more than the roots, from %v at %v, the cut has an area of %v, not %v", more, distance, lod_scale, cut.area, full)
					testing.expectf(t, cut.missed == 0, "with %d pages more than the roots, from %v at %v, the walk misses %d meshlets", more, distance, lod_scale, cut.missed)
					testing.expect(t, cut.drawn > 0)
				}
			}
			// Up close at the finest level, a set without every page draws coarser meshlets in the missing ones' place.
			all := true
			for r in resident {
				all &&= r
			}
			near := cut_pages(grid, resident, center, 1e6)
			everything := make([]bool, len(resident), context.temp_allocator)
			for &r in everything {
				r = true
			}
			finest := cut_pages(grid, everything, center, 1e6)
			if !all {
				testing.expect(t, near.drawn < finest.drawn)
				fallbacks += 1
			}
		}
	}
	testing.expect(t, sets >= 12 && fallbacks >= 9)

	// A set that the renderer cannot reach, pages without what they depend on, is what the rule does not cover: the
	// roots draw in the place of what they do not hold, over the first pages' own triangles. The test would not see an
	// overlap if it could not find this one.
	broken := make([]bool, len(grid.records), context.temp_allocator)
	unmet := 0
	for record, i in grid.records {
		broken[i] = .Root in record.flags || i < 3
	}
	for record in grid.records[:3] {
		for d in grid.dependencies[record.first_dependency:][:record.dependency_count] {
			unmet += int(!broken[d])
		}
	}
	testing.expect(t, unmet > 0)
	cut := cut_pages(grid, broken, center, 1e6)
	testing.expectf(t, cut.area > full * 1.05, "pages without what they depend on gave an area of %v for %v", cut.area, full)
}

@(test)
a_paged_mesh_cooks_smaller_than_its_streams :: proc(t: ^testing.T) {
	paged, ok := cook_paged_grid(t)
	if !ok {
		return
	}
	tree := make_tree(t, {{"content/grid.gltf", grid_gltf(PAGED_GRID_SIZE)}, {"content/grid.gltf.meta", fmt_meta("pages = false\n")}})
	defer remove_tree(tree)
	testing.expect(t, cook(tree_options(tree), {.Model}).ok)
	guid, found := format.meta_subasset(read_meta(t, tree, "grid.gltf"), format.MESH_KIND, "Grid")
	testing.expect(t, found)
	data, blob, viewed := mesh_blob(t, tree, guid)
	if !viewed {
		return
	}
	testing.expect(t, .Paged not_in blob.flags && blob.pages.size == 0)
	testing.expect_value(t, blob.meshlet_count, paged.blob.meshlet_count)
	testing.expect_value(t, blob.index_count, paged.blob.index_count)
	// The pages share few vertices, so level 0 has few more than the mesh.
	testing.expectf(t, paged.blob.vertex_count >= blob.vertex_count && paged.blob.vertex_count < blob.vertex_count * 9 / 8, "level 0 has %d vertices for the mesh's %d", paged.blob.vertex_count, blob.vertex_count)
	testing.expectf(t, linalg.distance(format.mesh_face_area(data, blob), paged.blob.face_area) < 1e-3, "the paged blob's faces look along %v, and the mesh's along %v", paged.blob.face_area, format.mesh_face_area(data, blob))
	testing.expectf(t, len(paged.data) < len(data) * 3 / 4, "the paged blob has %d bytes, and the unpaged one %d", len(paged.data), len(data))
	// A reader of the head alone holds a small part of the blob.
	testing.expectf(t, int(paged.blob.head_size) < len(paged.data) / 2, "the head is %d of %d bytes", paged.blob.head_size, len(paged.data))
	head := make([]byte, paged.blob.head_size, context.temp_allocator)
	aligned, _ := mem.alloc_bytes(len(head), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, paged.data[:len(head)])
	_, head_ok := format.mesh_view(aligned)
	testing.expect(t, head_ok, "the head alone is a mesh blob")
}

@(test)
a_mesh_without_a_hierarchy_or_with_a_skin_has_no_pages :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/grid.gltf", grid_gltf(48)}, {"content/grid.gltf.meta", fmt_meta("pages = true\ncluster_lod = false\n")}})
	defer remove_tree(tree)
	testing.expect(t, cook(tree_options(tree), {.Model}).ok)
	guid, found := format.meta_subasset(read_meta(t, tree, "grid.gltf"), format.MESH_KIND, "Grid")
	testing.expect(t, found)
	_, blob, viewed := mesh_blob(t, tree, guid)
	if !viewed {
		return
	}
	testing.expect(t, .Paged not_in blob.flags && blob.pages.size == 0 && blob.meshlets.size > 0)

	// A mesh that fits in its root page has nothing to stream, and keeps its streams.
	small, small_ok := cook_paged_grid_blob(t, 8)
	testing.expect(t, small_ok && .Paged not_in small.flags && small.meshlets.size > 0 && small.meshlet_nodes.size > 0)
}

// cook_paged_grid_blob cooks a grid with pages = true, whatever it comes out as.
@(private = "file")
cook_paged_grid_blob :: proc(t: ^testing.T, size: int) -> (blob: ^format.Mesh_Blob, ok: bool) {
	tree := make_tree(t, {{"content/grid.gltf", grid_gltf(size)}, {"content/grid.gltf.meta", fmt_meta("pages = true\n")}})
	defer remove_tree(tree)
	testing.expect(t, cook(tree_options(tree), {.Model}).ok)
	guid, found := format.meta_subasset(read_meta(t, tree, "grid.gltf"), format.MESH_KIND, "Grid")
	testing.expect(t, found)
	_, blob = mesh_blob(t, tree, guid) or_return
	return blob, true
}

@(test)
a_paged_mesh_blob_that_is_wrong_is_refused :: proc(t: ^testing.T) {
	grid, ok := cook_paged_grid(t)
	if !ok {
		return
	}
	// broken is the blob with one change, and whether mesh_view still takes it.
	broken :: proc(grid: Paged_Grid, change: proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node)) -> bool {
		data, _ := mem.alloc_bytes(len(grid.data), format.BLOB_ALIGN, context.temp_allocator)
		copy(data, grid.data)
		blob := (^format.Mesh_Blob)(raw_data(data))
		change(blob, format.mesh_pages(data, blob), format.mesh_page_dependencies(data, blob), format.mesh_meshlet_nodes(data, blob))
		_, viewed := format.mesh_view(data)
		return viewed
	}
	testing.expect(t, broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {}), "the blob as it is is taken")
	testing.expect(t, !broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {
		pages[1].offset = blob.file_size
	}), "a page past the blob's end")
	testing.expect(t, !broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {
		pages[0].size = format.MESH_PAGE_SIZE + 4
	}), "a page of more than a page's size")
	testing.expect(t, !broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {
		pages[1].first_meshlet += 1
	}), "pages whose meshlets are not one range after another")
	testing.expect(t, !broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {
		dependencies[0] = 0
	}), "a page that depends on a page that is not after it")
	testing.expect(t, !broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {
		pages[len(pages) - 1].flags = {}
	}), "a submesh without a root, or a page in the head that is not one")
	testing.expect(t, !broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {
		pages[0].flags = {.Root}
	}), "a root that is not in the head")
	testing.expect(t, !broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {
		blob.meshlet_count += 1
	}), "more meshlets than the pages hold")
	testing.expect(t, !broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {
		for &n in nodes {
			if n.count & format.MESHLET_NODE_LEAF != 0 {
				n.page = u32(len(pages))
				return
			}
		}
	}), "a leaf in a page that the mesh does not have")
	testing.expect(t, !broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {
		blob.head_size = blob.file_size + 16
	}), "a head of more than the blob")
	testing.expect(t, !broken(grid, proc(blob: ^format.Mesh_Blob, pages: []format.Mesh_Page, dependencies: []u32, nodes: []format.Meshlet_Node) {
		blob.flags += {.Skinned}
	}), "pages and a skin")

	// A page that is wrong is refused when it is read.
	stride := format.mesh_attribute_stride(grid.blob.flags)
	record := grid.records[0]
	changed :: proc(grid: Paged_Grid, change: proc(header: ^format.Mesh_Page_Header, meshlets: []format.Meshlet)) -> []byte {
		page, _ := mem.alloc_bytes(len(grid.pages[0]), 16, context.temp_allocator)
		copy(page, grid.pages[0])
		header := (^format.Mesh_Page_Header)(raw_data(page))
		change(header, format.mesh_page_meshlets(page, header))
		return page
	}
	page_ok :: proc(page: []byte, record: format.Mesh_Page, stride: u32) -> bool {
		_, viewed := format.mesh_page_view(page, record, stride)
		return viewed
	}
	testing.expect(t, page_ok(changed(grid, proc(header: ^format.Mesh_Page_Header, meshlets: []format.Meshlet) {}), record, stride))
	testing.expect(t, !page_ok(changed(grid, proc(header: ^format.Mesh_Page_Header, meshlets: []format.Meshlet) {
		header.vertex_count += 1
	}), record, stride), "more vertices than the page holds")
	testing.expect(t, !page_ok(changed(grid, proc(header: ^format.Mesh_Page_Header, meshlets: []format.Meshlet) {
		header.meshlet_count -= 1
	}), record, stride), "fewer meshlets than the table says")
	testing.expect(t, !page_ok(changed(grid, proc(header: ^format.Mesh_Page_Header, meshlets: []format.Meshlet) {
		meshlets[0].triangle_offset = header.triangle_bytes / 3
	}), record, stride), "a meshlet whose triangles are past the stream")
	testing.expect(t, !page_ok(changed(grid, proc(header: ^format.Mesh_Page_Header, meshlets: []format.Meshlet) {
		header.triangle_bytes -= 1
	}), record, stride), "triangles that are not three bytes each")
	testing.expect(t, !page_ok(changed(grid, proc(header: ^format.Mesh_Page_Header, meshlets: []format.Meshlet) {
		meshlets[0].base_vertex = header.vertex_count
	}), record, stride), "a meshlet whose vertices the page does not have")
	testing.expect(t, !page_ok(changed(grid, proc(header: ^format.Mesh_Page_Header, meshlets: []format.Meshlet) {
		meshlets[0].depth = 1
	}), record, stride), "a level 0 meshlet that is not level 0")
	testing.expect(t, !page_ok(grid.pages[0][:len(grid.pages[0]) - 4], record, stride), "a page of another size")
	testing.expect(t, !page_ok(grid.pages[0], record, stride + 4), "a page for another stride")

	// LZ4 refuses a block that is cut short, and the checksum tells bytes that are not the page's.
	block := grid.data[record.offset:][:record.compressed_size]
	out := make([]byte, record.size, context.temp_allocator)
	testing.expect(t, !lz4.decompress(block[:len(block) / 2], out))
	other := grid.records[1]
	testing.expect(t, hash.fnv32a(grid.data[other.offset:][:other.compressed_size]) != record.checksum)
}
