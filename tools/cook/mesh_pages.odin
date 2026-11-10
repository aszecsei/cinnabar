// A mesh's pages: the cooker splits each submesh's groups of meshlets into pages of at most format.MESH_PAGE_SIZE
// bytes, each with its own copy of the vertices that its meshlets use, and compresses each with LZ4. The renderer
// keeps resident only the pages that a view's levels of detail need. See docs/content/kinds/meshes.md#pages.
package cook

import "core:hash"
import "core:mem"
import "core:slice"

import "cinnabar:core/lz4"
import format "cinnabar:engine/asset/format"

LZ4_VERSION :: #config(LZ4_VERSION, "unknown")

// What the import setting `pages` is for a mesh that does not set it.
PAGES_DEFAULT :: "false"

PAGES_SETTING :: Setting_Info {
	key = "pages",
	values = {"true", "false"},
	default = PAGES_DEFAULT,
	description = "Split the meshlets' hierarchy into compressed pages, which stream in as a view comes near and leave when memory is short. Without it, the whole mesh is in memory while it is in use. Needs cluster_lod, and a mesh without a skin.",
}

// Page_Inputs is what build_pages needs of the hierarchy besides the meshlets: build_meshlets appends to it.
Page_Inputs :: struct {
	// Every group of the mesh, in the order of their meshlets.
	groups:      [dynamic]Page_Group,
	// For each meshlet, its group, and the group that it was simplified from, or -1 at level 0.
	owner:       [dynamic]i32,
	refined:     [dynamic]i32,
	// For each node, its group if it is a leaf, or -1.
	node_groups: [dynamic]i32,
}

// Page_Group is one group's meshlets, as a range of the mesh's.
Page_Group :: struct {
	first_meshlet: u32,
	meshlet_count: u32,
}

// Mesh_Pages is what build_pages made: the pages, and the size of the mesh's level 0 as format.mesh_page_level0
// assembles it from them.
Mesh_Pages :: struct {
	pages:        []format.Page_Entry,
	vertex_count: u32,
	index_count:  u32,
}

// Page_Size counts what a page holds while it fills.
@(private = "file")
Page_Size :: struct {
	meshlets:       int,
	ref_words:      int,
	triangle_words: int,
	vertices:       int,
}

@(private = "file")
page_bytes :: proc(s: Page_Size, vertex_stride: int) -> int {
	return size_of(format.Mesh_Page_Header) + s.meshlets * size_of(format.Meshlet) + (s.ref_words + s.triangle_words) * 4 + s.vertices * vertex_stride
}

// build_pages splits a mesh's groups into pages and compresses them. A page holds whole groups of one submesh. Each
// submesh's pages fill from its coarsest group back, so its last page, the root, is full of its coarsest levels. It
// writes each leaf node's page and its first meshlet in it, each meshlet's refined_page, and each submesh's range of
// the level 0 indices. The meshlets' vertex_offset and triangle_offset are into meshlet_indices, which holds indices
// into vertices, and meshlet_triangles. It fails if a group does not fit in a page, which leaves the mesh unpaged.
build_pages :: proc(vertices: []Vertex, flags: format.Mesh_Flags, meshlets: []format.Meshlet, meshlet_indices: []u32, meshlet_triangles: []u32, nodes: []format.Meshlet_Node, submeshes: []format.Submesh_Entry, inputs: Page_Inputs) -> (result: Mesh_Pages, ok: bool) {
	attribute_stride := int(format.mesh_attribute_stride(flags))
	vertex_stride := 12 + attribute_stride
	groups := inputs.groups[:]
	if len(groups) == 0 || len(inputs.owner) != len(meshlets) || len(inputs.node_groups) != len(nodes) {
		return
	}

	// Which page's count a vertex is in already.
	seen := make([]i32, len(vertices), context.temp_allocator)
	slice.fill(seen, -1)
	stamp: i32
	add_group :: proc(size: ^Page_Size, g: Page_Group, meshlets: []format.Meshlet, meshlet_indices: []u32, seen: []i32, stamp: i32) {
		for m in meshlets[g.first_meshlet:][:g.meshlet_count] {
			size.meshlets += 1
			size.ref_words += (int(m.vertex_count) + 1) / 2
			size.triangle_words += int(m.triangle_count)
			for v in meshlet_indices[m.vertex_offset:][:m.vertex_count] {
				if seen[v] != stamp {
					seen[v] = stamp
					size.vertices += 1
				}
			}
		}
	}

	// Each page as a range of groups, in order, and whether it is its submesh's root.
	Range :: struct {
		first, end: int,
		root:       bool,
	}
	ranges := make([dynamic]Range, context.temp_allocator)
	next_group := 0
	for s in submeshes {
		first := next_group
		for next_group < len(groups) && groups[next_group].first_meshlet < s.first_meshlet + s.meshlet_count {
			next_group += 1
		}
		if next_group == first {
			continue
		}
		at := len(ranges)
		end := next_group
		size: Page_Size
		for g := next_group - 1; g >= first; g -= 1 {
			add_group(&size, groups[g], meshlets, meshlet_indices, seen, stamp)
			if page_bytes(size, vertex_stride) <= format.MESH_PAGE_SIZE {
				continue
			}
			if g + 1 == end {
				// The group alone is more than a page.
				return
			}
			inject_at(&ranges, at, Range{g + 1, end, end == next_group})
			end = g + 1
			stamp += 1
			size = {}
			add_group(&size, groups[g], meshlets, meshlet_indices, seen, stamp)
			if page_bytes(size, vertex_stride) > format.MESH_PAGE_SIZE {
				return
			}
		}
		inject_at(&ranges, at, Range{first, end, end == next_group})
		stamp += 1
	}
	if next_group != len(groups) {
		return
	}

	group_page := make([]u32, len(groups), context.temp_allocator)
	for r, p in ranges {
		for g in r.first ..< r.end {
			group_page[g] = u32(p)
		}
	}
	dependencies := make([][dynamic]u32, len(ranges), context.temp_allocator)
	for &d in dependencies {
		d = make([dynamic]u32, context.temp_allocator)
	}
	for refined, m in inputs.refined {
		if refined < 0 {
			continue
		}
		page, own := group_page[refined], group_page[inputs.owner[m]]
		assert(page <= own, "a meshlet comes before the group that it was simplified from")
		if page != own && !slice.contains(dependencies[page][:], own) {
			append(&dependencies[page], own)
		}
	}

	pages := make([]format.Page_Entry, len(ranges), context.temp_allocator)
	// A vertex's place in the page that is being written.
	local := make([]u32, len(vertices), context.temp_allocator)
	slice.fill(seen, -1)
	submesh := 0
	submesh_indices := make([]u32, len(submeshes), context.temp_allocator)
	submesh_first := make([]u32, len(submeshes), context.temp_allocator)
	for r, p in ranges {
		first_meshlet := groups[r.first].first_meshlet
		last := groups[r.end - 1]
		count := last.first_meshlet + last.meshlet_count - first_meshlet
		for first_meshlet >= submeshes[submesh].first_meshlet + submeshes[submesh].meshlet_count {
			submesh += 1
			submesh_first[submesh] = result.index_count
		}

		records := make([]format.Meshlet, count, context.temp_allocator)
		refs := make([dynamic]u32, context.temp_allocator)
		triangles := make([dynamic]u32, context.temp_allocator)
		page_vertices := make([dynamic]u32, context.temp_allocator)
		level0: u32
		level0_indices: u32
		for &record, i in records {
			source := meshlets[int(first_meshlet) + i]
			record = source
			own := make([]u32, source.vertex_count, context.temp_allocator)
			for v, k in meshlet_indices[source.vertex_offset:][:source.vertex_count] {
				if seen[v] != i32(p) {
					seen[v] = i32(p)
					local[v] = u32(len(page_vertices))
					append(&page_vertices, v)
				}
				own[k] = local[v]
			}
			format.meshlet_write_vertices(&record, own, &refs)
			assert(record.short_refs == 1, "a page has more vertices than 16-bit refs reach")
			record.triangle_offset = u32(len(triangles))
			append(&triangles, ..meshlet_triangles[source.triangle_offset:][:source.triangle_count])
			refined := inputs.refined[int(first_meshlet) + i]
			record.refined_page = refined >= 0 ? group_page[refined] : format.MESH_PAGE_NONE
			if source.depth == 0 {
				assert(int(level0) == i, "a page's level 0 meshlets do not come first")
				level0 += 1
				level0_indices += u32(source.triangle_count) * 3
			}
		}

		header := format.Mesh_Page_Header {
			meshlet_count  = count,
			vertex_count   = u32(len(page_vertices)),
			ref_words      = u32(len(refs)),
			triangle_words = u32(len(triangles)),
		}
		header.vertex_refs = size_of(format.Mesh_Page_Header) + count * size_of(format.Meshlet)
		header.triangles = header.vertex_refs + header.ref_words * 4
		header.positions = header.triangles + header.triangle_words * 4
		header.attributes = header.positions + header.vertex_count * 12
		size := int(header.attributes) + len(page_vertices) * attribute_stride
		assert(size <= format.MESH_PAGE_SIZE && size % 4 == 0, "a page is not the size that it was counted to be")
		page := make([]byte, size, context.temp_allocator)
		mem.copy(raw_data(page), &header, size_of(header))
		copy(page[size_of(format.Mesh_Page_Header):], mem.slice_to_bytes(records))
		copy(page[header.vertex_refs:], mem.slice_to_bytes(refs[:]))
		copy(page[header.triangles:], mem.slice_to_bytes(triangles[:]))
		for v, i in page_vertices {
			write_vertex(vertices[v], flags, page[int(header.positions) + i * 12:], page[int(header.attributes) + i * attribute_stride:])
		}

		block := lz4.compress(page, make([]byte, lz4.bound(size), context.temp_allocator))
		if len(block) == 0 {
			return
		}
		slice.sort(dependencies[p][:])
		pages[p] = {
			record = {
				size = u32(size),
				checksum = hash.fnv32a(block),
				first_meshlet = first_meshlet,
				meshlet_count = count,
				level0_meshlets = level0,
				first_vertex = level0 > 0 ? result.vertex_count : 0,
				vertex_count = header.vertex_count,
				flags = r.root ? {.Root} : {},
			},
			compressed = block,
			dependencies = dependencies[p][:],
		}
		if level0 > 0 {
			result.vertex_count += header.vertex_count
			result.index_count += level0_indices
			submesh_indices[submesh] += level0_indices
		}
		for g in r.first ..< r.end {
			groups[g].first_meshlet -= first_meshlet
		}
	}

	for &n, i in nodes {
		if g := inputs.node_groups[i]; g >= 0 {
			n.page = group_page[g]
			// The group's range is relative to its page by now.
			n.first = groups[g].first_meshlet
		}
	}
	for &s, i in submeshes {
		s.first_index, s.index_count = submesh_first[i], submesh_indices[i]
	}
	result.pages = pages
	return result, true
}

// write_vertex writes a vertex as a mesh's positions and attributes streams have it.
write_vertex :: proc(v: Vertex, flags: format.Mesh_Flags, position: []byte, attributes: []byte) {
	(^[3]f32)(&position[0])^ = v.position
	(^format.Mesh_Attributes)(&attributes[0])^ = {
		normal  = encode_normal(v.normal),
		tangent = encode_tangent(v.tangent),
		uv0     = v.uv0,
	}
	offset := size_of(format.Mesh_Attributes)
	if .UV1 in flags {
		(^[2]f32)(&attributes[offset])^ = v.uv1
		offset += 8
	}
	if .Color in flags {
		for ch in 0 ..< 4 {
			attributes[offset + ch] = u8(clamp(v.color[ch], 0, 1) * 255 + 0.5)
		}
	}
}

// face_area_of is what format.mesh_face_area gives for a mesh's triangles.
face_area_of :: proc(vertices: []Vertex, indices: []$I) -> (area: [3]f32) {
	for i := 0; i + 2 < len(indices); i += 3 {
		a, b, c := vertices[indices[i]].position, vertices[indices[i + 1]].position, vertices[indices[i + 2]].position
		u, v := b - a, c - a
		area += [3]f32{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x} / 2
	}
	return
}
