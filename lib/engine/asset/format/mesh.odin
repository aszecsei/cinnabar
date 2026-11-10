package asset_format

import "core:math"
import "core:mem"

import "cinnabar:core/layout"

// A glTF file is a Model asset, which has no blob of its own. Each of its meshes is a Mesh sub-asset with its own blob
// (see docs/content/kinds/meshes.md#meshes). MESH_KIND names them in .meta files.
MESH_KIND :: "mesh"

// Meshlets hold at most this many vertices and triangles, which mesh shaders can draw in one group.
MESHLET_MAX_VERTICES :: 64
MESHLET_MAX_TRIANGLES :: 124

Mesh_Flag :: enum u32 {
	// The attributes have a second UV set.
	UV1,
	// The attributes have a vertex color.
	Color,
	// Indices are u32. Otherwise they are u16.
	Index32,
	// The mesh has a skin stream: each vertex's joints and weights, which a Skin's joints pose (see
	// docs/content/kinds/skins-and-animations.md#skins).
	Skinned,
	// The mesh's meshlets and vertices are in pages (see docs/content/kinds/meshes.md#pages): the blob has a page table
	// and no positions, attributes, indices, meshlets, meshlet_vertices or meshlet_triangles streams.
	Paged,
}

Mesh_Flags :: bit_set[Mesh_Flag;u32]

// Mesh_Bounds is an axis-aligned box and a sphere, in the mesh's space.
Mesh_Bounds :: struct {
	min, max: [3]f32,
	center:   [3]f32,
	radius:   f32,
}

// A mesh's levels of detail from this one on share a bucket, in what mesh_level_buckets finds.
MESH_LEVEL_BUCKETS :: 8

// Mesh_Submesh is the part of a mesh that one material draws. Its indices, meshlets and meshlet nodes are ranges of the
// mesh's. Its first root_count nodes are the roots of its levels' trees; a submesh without a hierarchy has none. A paged
// mesh's indices are those of its level 0 as mesh_page_level0 assembles it, and level_first is what mesh_level_buckets
// finds, which nothing can find at run time without every page.
Mesh_Submesh :: struct {
	// The material slot's name: the glTF material's.
	name:          Slice,
	first_index:   u32,
	index_count:   u32,
	first_meshlet: u32,
	meshlet_count: u32,
	first_node:    u32,
	node_count:    u32,
	root_count:    u32,
	level_first:   [MESH_LEVEL_BUCKETS]u32,
	bounds:        Mesh_Bounds,
}

// Meshlet is a cluster of at most MESHLET_MAX_VERTICES vertices and MESHLET_MAX_TRIANGLES triangles, at one level of
// its submesh's LOD hierarchy, with the bounds that culling tests and the errors that pick the level (see
// docs/content/kinds/meshes.md#meshlets). Its vertices are refs in meshlet_vertices, which meshlet_write_vertices writes
// and meshlet_vertex reads, and its triangles a range of meshlet_triangles. In a paged mesh the offsets, the base and the
// refs are into its page's streams and vertices. Shaders read it as it is: matches Meshlet in material_mesh.hlsli.
Meshlet :: struct {
	// In u32 words of meshlet_vertices.
	vertex_offset:   u32,
	triangle_offset: u32,
	// The lowest of its vertices. Each ref is a vertex's index in the mesh less this.
	base_vertex:     u32,
	vertex_count:    u8,
	triangle_count:  u8,
	// Its level: 0 for the submesh's own triangles, and one more for each simplification.
	depth:           u8,
	// 1 when its refs are 16 bits, two to a word, lowest half first. 0 when they are one to a word.
	short_refs:      u8,
	// The normal cone, in snorm8: decode with x / 127. A meshlet whose cone points away from the view can be culled. A
	// cutoff of 127 is a cone too wide to cull.
	cone_axis:       [3]i8,
	cone_cutoff:     i8,
	// The sphere that culling tests, from meshlet_encode_sphere, which holds the meshlet's. An infinite radius is a
	// meshlet too far from the mesh's origin for f16, which culling always keeps.
	center:          [3]f16,
	radius:          f16,
	// The sphere of the simplification that made this meshlet, whose error is error: 0 for the submesh's own triangles.
	error_center:    [3]f32,
	error_radius:    f32,
	// The sphere of its group's simplification, a level up, whose error is parent_error: F32_MAX at the top. A view draws
	// the meshlet when error projects to at most its threshold and parent_error to more.
	parent_center:   [3]f32,
	parent_radius:   f32,
	error:           f32,
	parent_error:    f32,
	// The page of the group that it was simplified from, whose error is error: MESH_PAGE_NONE at level 0 and in a mesh
	// without pages. While that page is not resident, a view draws the meshlet whatever error is.
	refined_page:    u32,
}

MESH_PAGE_NONE :: max(u32)

#assert(size_of(Meshlet) == 72)
#assert(offset_of(Meshlet, center) == 20)
#assert(offset_of(Meshlet, error_center) == 28)

// The largest finite f16.
@(private = "file")
F16_LARGEST :: 65504
// The smallest normal f16, 2^-14. A shader's f16tof32 need not keep anything smaller.
@(private = "file")
F16_SMALLEST_NORMAL :: 1.0 / 16384.0
// An infinite f16's bits. Matches MESHLET_RADIUS_INFINITE in material_mesh.hlsli.
@(private = "file")
F16_INFINITE_BITS :: u16(0x7c00)

// meshlet_write_vertices appends a meshlet's vertices to the stream as refs from their lowest, two to a word when every
// ref fits in 16 bits, and sets the meshlet's fields that say so.
meshlet_write_vertices :: proc(m: ^Meshlet, vertices: []u32, stream: ^[dynamic]u32) {
	low, high := max(u32), u32(0)
	for v in vertices {
		low, high = min(low, v), max(high, v)
	}
	m.vertex_offset = u32(len(stream))
	m.vertex_count = u8(len(vertices))
	m.base_vertex = low
	m.short_refs = high - low <= 0xffff ? 1 : 0
	if m.short_refs == 0 {
		for v in vertices {
			append(stream, v - low)
		}
		return
	}
	for i := 0; i < len(vertices); i += 2 {
		word := vertices[i] - low
		if i + 1 < len(vertices) {
			word |= (vertices[i + 1] - low) << 16
		}
		append(stream, word)
	}
}

// meshlet_vertex is a meshlet's vertex i, as an index into the mesh's vertices. Matches cluster_vertex in
// material_mesh.hlsli.
meshlet_vertex :: proc "contextless" (m: Meshlet, stream: []u32, i: int) -> u32 {
	if m.short_refs == 0 {
		return m.base_vertex + stream[int(m.vertex_offset) + i]
	}
	word := stream[int(m.vertex_offset) + i / 2]
	return m.base_vertex + (i % 2 != 0 ? word >> 16 : word & 0xffff)
}

// meshlet_encode_sphere is the smallest f16 sphere near a sphere that holds it, for culling: the center rounds, and the
// radius grows by how far it moved and rounds up. A sphere that f16 cannot reach, or that is not a number, has an
// infinite radius. An f16 under the smallest normal does not stay in either, so that a shader that flushes it to 0 reads
// the same sphere.
meshlet_encode_sphere :: proc "contextless" (center: [3]f32, radius: f32) -> (encoded: [3]f16, encoded_radius: f16) {
	infinite := transmute(f16)F16_INFINITE_BITS
	for v in ([4]f32{center.x, center.y, center.z, radius}) {
		if v != v {
			return {}, infinite
		}
	}
	moved: f64
	for k in 0 ..< 3 {
		encoded[k] = f16(clamp(center[k], -F16_LARGEST, F16_LARGEST))
		if abs(f32(encoded[k])) < F16_SMALLEST_NORMAL {
			encoded[k] = 0
		}
		step := f64(center[k]) - f64(encoded[k])
		moved += step * step
	}
	r := f64(radius) + math.sqrt(moved)
	if r > F16_LARGEST {
		return encoded, infinite
	}
	encoded_radius = f16(f32(r))
	for f64(encoded_radius) < r {
		encoded_radius = transmute(f16)(transmute(u16)encoded_radius + 1)
	}
	if r > 0 && f32(encoded_radius) < F16_SMALLEST_NORMAL {
		encoded_radius = F16_SMALLEST_NORMAL
	}
	return
}

// meshlet_sphere is the sphere that culling tests. Matches cluster_visible in material_mesh.hlsli.
meshlet_sphere :: proc "contextless" (m: Meshlet) -> (center: [3]f32, radius: f32) {
	return {f32(m.center.x), f32(m.center.y), f32(m.center.z)}, f32(m.radius)
}

// Meshlet_Node is a node of the tree over one level's groups of meshlets (see docs/content/kinds/meshes.md#meshlets).
// Its sphere holds every group's below it, and its error is the largest of theirs, so a node whose error does not show
// has no meshlet below it that a view draws. An internal node's children are count nodes from first, relative to its
// submesh's first_node. A leaf, whose count has MESHLET_NODE_LEAF, is one group: count meshlets from first, relative to
// its submesh's first_meshlet, whose parent bounds are the node's. In a paged mesh a leaf's first is relative to the
// first meshlet of its page, which page is the index of. Shaders read it as it is: matches Meshlet_Node in
// meshlet_lod.hlsli.
Meshlet_Node :: struct {
	center:  [3]f32,
	radius:  f32,
	error:   f32,
	first:   u32,
	count:   u32,
	page:    u32,
}

#assert(size_of(Meshlet_Node) == 32)

MESHLET_NODE_LEAF :: u32(1) << 31

// The attribute stream's layout, in order. Normals and tangents are octahedral: a unit vector folded onto a square.
// The tangent's second component keeps the bitangent's sign in its lowest bit: set means -1.
Mesh_Attributes :: struct {
	// snorm16 pairs.
	normal:  [2]i16,
	// unorm16 pairs.
	tangent: [2]u16,
	uv0:     [2]f32,
	// Then, when the flags say, the second UV set as [2]f32 and the color as RGBA8 unorm.
}

// Mesh_Skin_Vertex is one vertex of the skin stream: up to four joints, which index the joints of the mesh's skin, and
// their weights in unorm16, which add up to 65535. A joint that does not influence the vertex has a weight of 0.
// Shaders read it as it is: matches Skin_Vertex in skin_meshes.hlsl.
Mesh_Skin_Vertex :: struct {
	joints:  [4]u16,
	weights: [4]u16,
}

#assert(size_of(Mesh_Skin_Vertex) == 16)

// mesh_octahedral folds a unit vector onto the square [-1, 1]².
mesh_octahedral :: proc "contextless" (n: [3]f32) -> [2]f32 {
	sum := abs(n.x) + abs(n.y) + abs(n.z)
	if sum == 0 {
		return {0, 0}
	}
	p := n.xy / sum
	if n.z < 0 {
		sign := [2]f32{p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1}
		p = (1 - [2]f32{abs(p.y), abs(p.x)}) * sign
	}
	return p
}

// mesh_encode_normal stores a normal as Mesh_Attributes has it: octahedral, in snorm16 pairs.
mesh_encode_normal :: proc "contextless" (n: [3]f32) -> [2]i16 {
	p := mesh_octahedral(n)
	return {i16(math.round(clamp(p.x, -1, 1) * 32767)), i16(math.round(clamp(p.y, -1, 1) * 32767))}
}

// mesh_encode_tangent stores a tangent as Mesh_Attributes has it: octahedral, in unorm16 pairs, with the bitangent's
// sign in the lowest bit of the second.
mesh_encode_tangent :: proc "contextless" (t: [4]f32) -> [2]u16 {
	p := mesh_octahedral(t.xyz) * 0.5 + 0.5
	x := u16(math.round(clamp(p.x, 0, 1) * 65535))
	y := u16(math.round(clamp(p.y, 0, 1) * 65535)) & ~u16(1)
	if t.w < 0 {
		y |= 1
	}
	return {x, y}
}

// An impostor's atlas is IMPOSTOR_FRAMES by IMPOSTOR_FRAMES views of the mesh, each a square of the impostor's size
// in texels (see docs/content/kinds/meshes.md#impostors).
IMPOSTOR_FRAMES :: 8
// The sizes of a frame that a mesh blob may have, around the import setting impostor_size's values.
IMPOSTOR_MIN_SIZE :: 16
IMPOSTOR_MAX_SIZE :: 256

// Impostor_Texel is one texel of an impostor's view: what the mesh's nearest surface there gives a material, in the
// mesh's space. Shaders read it as it is: matches Impostor_Texel in material_impostor.hlsli.
Impostor_Texel :: struct {
	// The first UV set.
	uv:      [2]f16le,
	// How far the surface is from the view's plane through the sphere's center, toward the view, over the radius.
	depth:   f16le,
	// The submesh's index plus 1 in the low byte, 0 where the view sees no surface, and IMPOSTOR_TEXEL_FLIP set where
	// the bitangent's sign is -1.
	flags:   u16le,
	// Octahedral, in snorm16 pairs.
	normal:  [2]i16le,
	tangent: [2]i16le,
}

IMPOSTOR_TEXEL_FLIP :: 0x100

#assert(size_of(Impostor_Texel) == 16)

// mesh_attribute_stride is the size of one vertex's attributes for the flags: from 16 to 28 bytes.
mesh_attribute_stride :: proc "contextless" (flags: Mesh_Flags) -> u32 {
	stride := u32(size_of(Mesh_Attributes))
	if .UV1 in flags {
		stride += 8
	}
	if .Color in flags {
		stride += 4
	}
	return stride
}

// Mesh_Blob is the start of a mesh blob (see docs/content/blobs-and-loading.md#blob-format). Each stream starts at BLOB_ALIGN,
// so it can stream straight into a GPU buffer.
Mesh_Blob :: struct {
	header:            Blob_Header,
	flags:             Mesh_Flags,
	vertex_count:      u32,
	index_count:       u32,
	bounds:            Mesh_Bounds,
	// Mesh_Submesh records.
	submeshes:         Slice,
	// [3]f32 per vertex.
	positions:         Slice,
	// mesh_attribute_stride bytes per vertex.
	attributes:        Slice,
	// Mesh_Skin_Vertex records, one per vertex with the Skinned flag, or empty.
	skin:              Slice,
	// u16 or u32 per index, by the Index32 flag, in triangles whose front faces are clockwise on screen.
	indices:           Slice,
	// Meshlet records.
	meshlets:          Slice,
	// Each meshlet's refs to its vertices, in u32 words: two to a word, or one when they do not fit in 16 bits.
	meshlet_vertices:  Slice,
	// u32 per meshlet triangle: its three indices into its meshlet's vertices in the low three bytes.
	meshlet_triangles: Slice,
	// Meshlet_Node records.
	meshlet_nodes:     Slice,
	// The mesh's name in its model, and the model's path, prefixed with its root's name.
	name:              Slice,
	source_path:       Slice,
	// The collision data that physics builds a mesh collider from (see docs/physics/design.md#shapes), empty when the
	// import setting collision is false: positions welded by position alone, so triangles that the render mesh splits
	// at a seam share their edge, [3]f32 each; triangles of three u32 indices into them, without degenerate ones, front
	// faces wound as the render mesh's; and each triangle's submesh, u16 each.
	collision_positions: Slice,
	collision_triangles: Slice,
	collision_submeshes: Slice,
	// The impostor's atlas, Impostor_Texel records, frame by frame in rows of IMPOSTOR_FRAMES, each frame row by row,
	// empty when the import setting impostor is false. impostor_size is a frame's side in texels, and impostor_error
	// how far the impostor may be from the mesh, in meters: the larger of its coarsest level's error and a texel.
	impostor:            Slice,
	impostor_size:       u32,
	impostor_error:      f32,
	// How many meshlets the mesh has, in its meshlets stream or in its pages.
	meshlet_count:       u32,
	// A paged mesh's Mesh_Page records, in the order of their meshlets, and the pages that each depends on, as indices
	// into them. Empty without the Paged flag.
	pages:               Slice,
	page_dependencies:   Slice,
	// The blob's first bytes that a reader needs before any page that is not a root: everything but those pages. The
	// asset runtime loads only these. file_size is the whole blob's size. Both are the blob's size without pages.
	head_size:           u32,
	file_size:           u32,
	// What mesh_face_area gives, kept because a paged mesh's triangles are not in its head.
	face_area:           [3]f32,
	// Each level's largest parent error and how far its groups reach from the bounds' center, from mesh_level_buckets.
	// Only a paged mesh has them here.
	levels:              [MESH_LEVEL_BUCKETS][2]f32,
}

// A page's size before compression is at most this, and a multiple of 4. A resident page takes one slot of this size in
// the renderer's pool (see docs/rendering/assets.md#gpu-residency).
MESH_PAGE_SIZE :: 128 << 10

// Mesh_Page is one page in a paged mesh's table: where its LZ4 block is in the blob, and what it holds. A page holds
// whole groups of one submesh: `meshlet_count` meshlets from the mesh's `first_meshlet`. Uncompressed it is a
// Mesh_Page_Header and its streams (see mesh_page_view).
Mesh_Page :: struct {
	// From the blob's start.
	offset:           u32,
	compressed_size:  u32,
	size:             u32,
	// fnv32a of the compressed bytes, which tells a page of this blob from bytes of a blob cooked over it.
	checksum:         u32,
	first_meshlet:    u32,
	meshlet_count:    u32,
	// How many of its first meshlets are level 0, whose triangles are the mesh's own.
	level0_meshlets:  u32,
	// Where its vertices are among the mesh's level 0 as mesh_page_level0 assembles it. Only for a page with level 0
	// meshlets.
	first_vertex:     u32,
	vertex_count:     u32,
	// Its dependencies: the pages that hold meshlets simplified from its groups, which must be resident while it is.
	// Every one comes after it. A range of page_dependencies.
	first_dependency: u32,
	dependency_count: u32,
	flags:            Mesh_Page_Flags,
}

Mesh_Page_Flag :: enum u32 {
	// The page holds its submesh's coarsest groups. It is in the blob's head, and always resident.
	Root,
}

Mesh_Page_Flags :: bit_set[Mesh_Page_Flag;u32]

// Mesh_Page_Header starts an uncompressed page. The Meshlet records follow it, and then the streams at its offsets,
// which are in bytes from the page's start and multiples of 4: the vertex refs and the triangles in u32 words, as
// meshlet_vertices and meshlet_triangles are, [3]f32 positions, and attributes of the mesh's stride. Shaders read it as
// it is: matches Mesh_Page_Header in mesh_pages.hlsli.
Mesh_Page_Header :: struct {
	meshlet_count:  u32,
	vertex_count:   u32,
	vertex_refs:    u32,
	triangles:      u32,
	positions:      u32,
	attributes:     u32,
	ref_words:      u32,
	triangle_words: u32,
}

#assert(size_of(Mesh_Page_Header) == 32)

mesh_layout :: proc() -> u64 {
	return layout.hash(Mesh_Blob) ~ layout.hash(Mesh_Submesh) * 31 ~ layout.hash(Meshlet) * 961 ~ layout.hash(Mesh_Attributes) * 29791 ~ layout.hash(Impostor_Texel) * 923521 ~ layout.hash(Meshlet_Node) * 28629151 ~ layout.hash(Mesh_Skin_Vertex) * 887503681 ~ layout.hash(Mesh_Page) * 27512614111 ~ layout.hash(Mesh_Page_Header) * 852891037441
}

// mesh_view checks a mesh blob: its header, its layout, its slices, and that its streams have the sizes that its
// counts give. data is the whole blob or, for a paged mesh, at least its head: the pages past the head are checked
// against the blob's file_size, and each page's contents by mesh_page_view when it is read.
mesh_view :: proc(data: []byte) -> (blob: ^Mesh_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Mesh || header.layout != mesh_layout() || len(data) < size_of(Mesh_Blob) {
		return
	}
	blob = (^Mesh_Blob)(raw_data(data))
	slices := [?]Slice {
		blob.submeshes,
		blob.positions,
		blob.attributes,
		blob.skin,
		blob.indices,
		blob.meshlets,
		blob.meshlet_vertices,
		blob.meshlet_triangles,
		blob.meshlet_nodes,
		blob.name,
		blob.source_path,
		blob.collision_positions,
		blob.collision_triangles,
		blob.collision_submeshes,
		blob.impostor,
		blob.pages,
		blob.page_dependencies,
	}
	for s in slices {
		if u64(s.offset) + u64(s.size) > u64(len(data)) {
			return nil, false
		}
	}
	index_size: u32 = .Index32 in blob.flags ? 4 : 2
	paged := .Paged in blob.flags
	if paged {
		// Its vertices, indices and meshlets are in its pages.
		for s in ([?]Slice{blob.positions, blob.attributes, blob.indices, blob.meshlets, blob.meshlet_vertices, blob.meshlet_triangles}) {
			if s.size != 0 {
				return nil, false
			}
		}
		if .Skinned in blob.flags || u64(blob.head_size) > u64(len(data)) || blob.head_size > blob.file_size || blob.pages.size == 0 {
			return nil, false
		}
	} else if blob.positions.size != blob.vertex_count * 12 ||
	   blob.attributes.size != blob.vertex_count * mesh_attribute_stride(blob.flags) ||
	   blob.indices.size != blob.index_count * index_size ||
	   blob.meshlet_count != blob.meshlets.size / size_of(Meshlet) ||
	   blob.pages.size != 0 ||
	   blob.page_dependencies.size != 0 {
		return nil, false
	}
	switch {
	case blob.skin.size != (.Skinned in blob.flags ? blob.vertex_count * size_of(Mesh_Skin_Vertex) : 0),
	     blob.skin.offset % BLOB_ALIGN != 0,
	     blob.pages.size % size_of(Mesh_Page) != 0 || blob.pages.offset % align_of(Mesh_Page) != 0,
	     blob.page_dependencies.size % 4 != 0 || blob.page_dependencies.offset % 4 != 0,
	     blob.submeshes.size % size_of(Mesh_Submesh) != 0 || blob.submeshes.offset % align_of(Mesh_Submesh) != 0,
	     blob.meshlets.size % size_of(Meshlet) != 0 || blob.meshlets.offset % align_of(Meshlet) != 0,
	     blob.meshlet_vertices.size % 4 != 0 || blob.meshlet_triangles.size % 4 != 0,
	     blob.meshlet_nodes.size % size_of(Meshlet_Node) != 0 || blob.meshlet_nodes.offset % align_of(Meshlet_Node) != 0,
	     blob.collision_positions.size % 12 != 0 || blob.collision_triangles.size % 12 != 0,
	     blob.collision_submeshes.size != blob.collision_triangles.size / 12 * 2,
	     blob.impostor.offset % align_of(Impostor_Texel) != 0,
	     blob.impostor.size != 0 && (blob.impostor_size < IMPOSTOR_MIN_SIZE || blob.impostor_size > IMPOSTOR_MAX_SIZE),
	     blob.impostor.size != impostor_texels(blob.impostor.size == 0 ? 0 : blob.impostor_size) * size_of(Impostor_Texel):
		return nil, false
	}
	collision_vertices := blob.collision_positions.size / 12
	for t in mesh_collision_triangles(data, blob) {
		if t.x >= collision_vertices || t.y >= collision_vertices || t.z >= collision_vertices {
			return nil, false
		}
	}
	meshlet_count := blob.meshlet_count
	nodes := mesh_meshlet_nodes(data, blob)
	pages := mesh_pages(data, blob)
	dependencies := mesh_page_dependencies(data, blob)
	next_meshlet: u32
	for p, i in pages {
		root := .Root in p.flags
		end := u64(p.offset) + u64(p.compressed_size)
		switch {
		case p.compressed_size == 0 || end > u64(blob.file_size),
		     // A root is in the head, and every other page past it.
		     root ? end > u64(blob.head_size) : p.offset < blob.head_size,
		     p.size < size_of(Mesh_Page_Header) || p.size > MESH_PAGE_SIZE || p.size % 4 != 0,
		     p.first_meshlet != next_meshlet || p.meshlet_count == 0 || p.level0_meshlets > p.meshlet_count,
		     u64(p.first_meshlet) + u64(p.meshlet_count) > u64(meshlet_count),
		     p.level0_meshlets > 0 && u64(p.first_vertex) + u64(p.vertex_count) > u64(blob.vertex_count),
		     u64(p.first_dependency) + u64(p.dependency_count) > u64(len(dependencies)):
			return nil, false
		}
		next_meshlet += p.meshlet_count
		// A dependency comes after its page, so no pages depend on each other in a ring, and a root's are roots, so the
		// roots alone are a set that a view can draw.
		for d in dependencies[p.first_dependency:][:p.dependency_count] {
			if d <= u32(i) || d >= u32(len(pages)) || (root && .Root not_in pages[d].flags) {
				return nil, false
			}
		}
	}
	if paged && next_meshlet != meshlet_count {
		return nil, false
	}
	for s in mesh_submeshes(data, blob) {
		if u64(s.name.offset) + u64(s.name.size) > u64(len(data)) ||
		   u64(s.first_index) + u64(s.index_count) > u64(blob.index_count) ||
		   u64(s.first_meshlet) + u64(s.meshlet_count) > u64(meshlet_count) ||
		   u64(s.first_node) + u64(s.node_count) > u64(len(nodes)) ||
		   s.root_count > s.node_count {
			return nil, false
		}
		// Every node stays in its submesh, so a walk cannot read past it.
		for n in nodes[s.first_node:][:s.node_count] {
			count := n.count & ~MESHLET_NODE_LEAF
			leaf := n.count & MESHLET_NODE_LEAF != 0
			limit := leaf ? s.meshlet_count : s.node_count
			if leaf && paged {
				// A group is in one page, among its submesh's meshlets.
				if n.page >= u32(len(pages)) {
					return nil, false
				}
				page := pages[n.page]
				if page.first_meshlet < s.first_meshlet || u64(page.first_meshlet) + u64(page.meshlet_count) > u64(s.first_meshlet) + u64(s.meshlet_count) {
					return nil, false
				}
				limit = page.meshlet_count
			}
			if u64(n.first) + u64(count) > u64(limit) {
				return nil, false
			}
		}
		if paged && s.meshlet_count > 0 {
			// Its last page is a root.
			has_root := false
			for p in pages {
				if .Root in p.flags && p.first_meshlet >= s.first_meshlet && p.first_meshlet + p.meshlet_count == s.first_meshlet + s.meshlet_count {
					has_root = true
				}
			}
			if !has_root {
				return nil, false
			}
		}
	}
	return blob, true
}

// mesh_head_size is how many of a blob's first bytes a reader needs, from at least its first size_of(Mesh_Blob) bytes:
// the head of a paged mesh. It is 0 for any other blob, which a reader needs the whole of.
mesh_head_size :: proc(start: []byte) -> int {
	header, ok := blob_header(start)
	if !ok || header.kind != .Mesh || header.layout != mesh_layout() || len(start) < size_of(Mesh_Blob) {
		return 0
	}
	blob := (^Mesh_Blob)(raw_data(start))
	if .Paged not_in blob.flags || blob.head_size < size_of(Mesh_Blob) || blob.head_size > blob.file_size {
		return 0
	}
	return int(blob.head_size)
}

// mesh_pages is a paged mesh's page table, empty for a mesh without pages.
mesh_pages :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> []Mesh_Page {
	bytes := blob_bytes(data, blob.pages)
	return ([^]Mesh_Page)(raw_data(bytes))[:len(bytes) / size_of(Mesh_Page)]
}

// mesh_page_dependencies is what the pages' first_dependency and dependency_count are ranges of.
mesh_page_dependencies :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> []u32 {
	bytes := blob_bytes(data, blob.page_dependencies)
	return ([^]u32)(raw_data(bytes))[:len(bytes) / 4]
}

// mesh_page_view checks an uncompressed page against its record in the table and the mesh's attribute stride: its
// streams are inside it, in order and of the sizes that its counts give, and every meshlet's refs and triangles are
// inside its streams and name vertices that the page has. A reader checks each page that it decompresses with this.
mesh_page_view :: proc "contextless" (page: []byte, record: Mesh_Page, stride: u32) -> (header: ^Mesh_Page_Header, ok: bool) {
	if len(page) != int(record.size) || len(page) < size_of(Mesh_Page_Header) || uintptr(raw_data(page)) % 4 != 0 {
		return
	}
	header = (^Mesh_Page_Header)(raw_data(page))
	size := u64(len(page))
	meshlets_end := u64(size_of(Mesh_Page_Header)) + u64(header.meshlet_count) * size_of(Meshlet)
	switch {
	case header.meshlet_count != record.meshlet_count,
	     header.vertex_count == 0 || header.vertex_count > 0x10000,
	     record.level0_meshlets > 0 && header.vertex_count != record.vertex_count,
	     u64(header.vertex_refs) != meshlets_end,
	     u64(header.triangles) != u64(header.vertex_refs) + u64(header.ref_words) * 4,
	     u64(header.positions) != u64(header.triangles) + u64(header.triangle_words) * 4,
	     u64(header.attributes) != u64(header.positions) + u64(header.vertex_count) * 12,
	     size != u64(header.attributes) + u64(header.vertex_count) * u64(stride):
		return nil, false
	}
	refs := mesh_page_refs(page, header)
	for m, i in mesh_page_meshlets(page, header) {
		words := m.short_refs != 0 ? (u64(m.vertex_count) + 1) / 2 : u64(m.vertex_count)
		if u64(m.vertex_offset) + words > u64(header.ref_words) ||
		   u64(m.triangle_offset) + u64(m.triangle_count) > u64(header.triangle_words) ||
		   m.vertex_count > MESHLET_MAX_VERTICES ||
		   m.triangle_count > MESHLET_MAX_TRIANGLES ||
		   (u32(i) < record.level0_meshlets) != (m.depth == 0) {
			return nil, false
		}
		for v in 0 ..< int(m.vertex_count) {
			if meshlet_vertex(m, refs, v) >= header.vertex_count {
				return nil, false
			}
		}
	}
	return header, true
}

mesh_page_meshlets :: proc "contextless" (page: []byte, header: ^Mesh_Page_Header) -> []Meshlet {
	return ([^]Meshlet)(raw_data(page[size_of(Mesh_Page_Header):]))[:header.meshlet_count]
}

mesh_page_refs :: proc "contextless" (page: []byte, header: ^Mesh_Page_Header) -> []u32 {
	return ([^]u32)(raw_data(page[header.vertex_refs:]))[:header.ref_words]
}

mesh_page_triangles :: proc "contextless" (page: []byte, header: ^Mesh_Page_Header) -> []u32 {
	return ([^]u32)(raw_data(page[header.triangles:]))[:header.triangle_words]
}

mesh_page_positions :: proc "contextless" (page: []byte, header: ^Mesh_Page_Header) -> [][3]f32 {
	return ([^][3]f32)(raw_data(page[header.positions:]))[:header.vertex_count]
}

// mesh_page_attributes is the page's vertices' attributes, of the mesh's stride each.
mesh_page_attributes :: proc "contextless" (page: []byte, header: ^Mesh_Page_Header) -> []byte {
	return page[header.attributes:]
}

// mesh_page_level0 writes the indices of a page's level 0 triangles, three for each, into indices, and returns how many
// it wrote. Each is the vertex's place in the page plus the page's first_vertex, so they are indices into the mesh's
// level 0: the positions and attributes of every page with level 0 meshlets, one page after another (see
// docs/content/kinds/meshes.md#pages). The page must have passed mesh_page_view, and indices must hold
// mesh_page_level0_indices.
mesh_page_level0 :: proc "contextless" (page: []byte, header: ^Mesh_Page_Header, record: Mesh_Page, indices: []u32) -> (count: int) {
	refs := mesh_page_refs(page, header)
	triangles := mesh_page_triangles(page, header)
	for m in mesh_page_meshlets(page, header)[:record.level0_meshlets] {
		for packed in triangles[m.triangle_offset:][:m.triangle_count] {
			for shift in ([3]u32{0, 8, 16}) {
				indices[count] = record.first_vertex + meshlet_vertex(m, refs, int((packed >> shift) & 0xff))
				count += 1
			}
		}
	}
	return
}

// mesh_page_level0_indices is how many indices mesh_page_level0 writes for a page.
mesh_page_level0_indices :: proc "contextless" (page: []byte, header: ^Mesh_Page_Header, record: Mesh_Page) -> (count: int) {
	for m in mesh_page_meshlets(page, header)[:record.level0_meshlets] {
		count += int(m.triangle_count) * 3
	}
	return
}

// mesh_level_buckets finds, among a submesh's meshlets, which the cooker orders by level, the first meshlet of each
// level bucket, relative to the submesh's first: bucket b holds the levels from b on, and the last bucket that the
// submesh reaches holds its deepest level. It raises levels to each level's largest parent error and how far its groups
// reach from center, and returns the submesh's deepest level. The renderer draws instanced meshes by these (see
// docs/rendering/gpu-scene.md#instanced-meshes).
mesh_level_buckets :: proc "contextless" (meshlets: []Meshlet, center: [3]f32, levels: ^[MESH_LEVEL_BUCKETS][2]f32) -> (first: [MESH_LEVEL_BUCKETS]u32, deepest: int) {
	for m in meshlets {
		deepest = max(deepest, int(m.depth))
	}
	for &f, bucket in first {
		f = u32(len(meshlets))
		for m, k in meshlets {
			if int(m.depth) >= min(bucket, deepest) {
				f = u32(k)
				break
			}
		}
	}
	for m in meshlets {
		if int(m.depth) >= MESH_LEVEL_BUCKETS {
			continue
		}
		l := &levels[m.depth]
		l[0] = max(l[0], m.parent_error)
		if m.parent_error < max(f32) {
			offset := m.parent_center - center
			reach := math.sqrt(offset.x * offset.x + offset.y * offset.y + offset.z * offset.z) + m.parent_radius
			l[1] = max(l[1], reach)
		}
	}
	return
}

mesh_submeshes :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> []Mesh_Submesh {
	bytes := blob_bytes(data, blob.submeshes)
	return ([^]Mesh_Submesh)(raw_data(bytes))[:len(bytes) / size_of(Mesh_Submesh)]
}

// mesh_face_area is the sum of a mesh's triangles' areas as vectors: it points the way that its faces look, and is
// nothing for a closed mesh. A paged mesh's is what the cooker found, as its triangles are in its pages.
mesh_face_area :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> (area: [3]f32) {
	if .Paged in blob.flags {
		return blob.face_area
	}
	position_bytes := blob_bytes(data, blob.positions)
	positions := ([^][3]f32)(raw_data(position_bytes))[:len(position_bytes) / 12]
	index_bytes := blob_bytes(data, blob.indices)
	wide := .Index32 in blob.flags
	count := len(index_bytes) / (wide ? 4 : 2)
	narrow_indices := ([^]u16)(raw_data(index_bytes))
	wide_indices := ([^]u32)(raw_data(index_bytes))
	for i := 0; i + 2 < count; i += 3 {
		corners: [3][3]f32
		for c in 0 ..< 3 {
			index := wide ? int(wide_indices[i + c]) : int(narrow_indices[i + c])
			if index >= len(positions) {
				return
			}
			corners[c] = positions[index]
		}
		u, v := corners[1] - corners[0], corners[2] - corners[0]
		area += [3]f32{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x} / 2
	}
	return
}

// mesh_collision_positions, mesh_collision_triangles and mesh_collision_submeshes are a mesh's collision data. A mesh
// cooked without it has none.
mesh_collision_positions :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> [][3]f32 {
	bytes := blob_bytes(data, blob.collision_positions)
	return ([^][3]f32)(raw_data(bytes))[:len(bytes) / 12]
}

mesh_collision_triangles :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> [][3]u32 {
	bytes := blob_bytes(data, blob.collision_triangles)
	return ([^][3]u32)(raw_data(bytes))[:len(bytes) / 12]
}

mesh_collision_submeshes :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> []u16 {
	bytes := blob_bytes(data, blob.collision_submeshes)
	return ([^]u16)(raw_data(bytes))[:len(bytes) / 2]
}

// impostor_texels is how many texels an impostor's atlas has, for a frame's side.
impostor_texels :: proc "contextless" (size: u32) -> u32 {
	return IMPOSTOR_FRAMES * IMPOSTOR_FRAMES * size * size
}

// mesh_impostor is a mesh's impostor atlas, empty for a mesh cooked without one.
mesh_impostor :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> []Impostor_Texel {
	bytes := blob_bytes(data, blob.impostor)
	return ([^]Impostor_Texel)(raw_data(bytes))[:len(bytes) / size_of(Impostor_Texel)]
}

// mesh_skin is a mesh's skin stream, empty for a mesh without the Skinned flag.
mesh_skin :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> []Mesh_Skin_Vertex {
	bytes := blob_bytes(data, blob.skin)
	return ([^]Mesh_Skin_Vertex)(raw_data(bytes))[:len(bytes) / size_of(Mesh_Skin_Vertex)]
}

mesh_meshlets :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> []Meshlet {
	bytes := blob_bytes(data, blob.meshlets)
	return ([^]Meshlet)(raw_data(bytes))[:len(bytes) / size_of(Meshlet)]
}

mesh_meshlet_nodes :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> []Meshlet_Node {
	bytes := blob_bytes(data, blob.meshlet_nodes)
	return ([^]Meshlet_Node)(raw_data(bytes))[:len(bytes) / size_of(Meshlet_Node)]
}

Submesh_Entry :: struct {
	name:          string,
	first_index:   u32,
	index_count:   u32,
	first_meshlet: u32,
	meshlet_count: u32,
	first_node:    u32,
	node_count:    u32,
	root_count:    u32,
	level_first:   [MESH_LEVEL_BUCKETS]u32,
	bounds:        Mesh_Bounds,
}

// Page_Entry is one page of a paged mesh for mesh_write: its record, whose place in the blob and whose dependencies'
// range mesh_write fills, its LZ4 block, and the pages that it depends on.
Page_Entry :: struct {
	record:       Mesh_Page,
	compressed:   []byte,
	dependencies: []u32,
}

Mesh_Contents :: struct {
	guid:              Guid,
	key:               u64,
	flags:             Mesh_Flags,
	vertex_count:      u32,
	index_count:       u32,
	bounds:            Mesh_Bounds,
	submeshes:         []Submesh_Entry,
	positions:         []byte,
	attributes:        []byte,
	// With the Skinned flag, one record per vertex.
	skin:              []Mesh_Skin_Vertex,
	indices:           []byte,
	meshlets:          []Meshlet,
	meshlet_vertices:  []byte,
	meshlet_triangles: []byte,
	meshlet_nodes:     []Meshlet_Node,
	name:              string,
	source_path:       string,
	collision_positions: [][3]f32,
	collision_triangles: [][3]u32,
	collision_submeshes: []u16,
	impostor:            []Impostor_Texel,
	impostor_size:       u32,
	impostor_error:      f32,
	// With the Paged flag: the pages, in the order of their meshlets, how many meshlets they hold, and what the blob
	// keeps because the pages hold the streams that give it. The six streams of vertices, indices and meshlets are then
	// empty, and vertex_count and index_count are those of level 0 as mesh_page_level0 assembles it.
	pages:               []Page_Entry,
	meshlet_count:       u32,
	face_area:           [3]f32,
	levels:              [MESH_LEVEL_BUCKETS][2]f32,
}

// mesh_write builds a mesh blob. A paged mesh's head comes first, with its root pages at its end, and the other pages
// after it.
mesh_write :: proc(contents: Mesh_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Mesh_Blob), allocator)
	stream :: proc(buffer: ^[dynamic]byte, data: []byte) -> Slice {
		s := reserve_bytes(buffer, len(data), BLOB_ALIGN)
		copy(buffer[s.offset:], data)
		return s
	}
	submeshes := reserve_bytes(&buffer, len(contents.submeshes) * size_of(Mesh_Submesh), BLOB_ALIGN)
	positions := stream(&buffer, contents.positions)
	attributes := stream(&buffer, contents.attributes)
	skin := stream(&buffer, mem.slice_to_bytes(contents.skin))
	indices := stream(&buffer, contents.indices)
	meshlets := stream(&buffer, mem.slice_to_bytes(contents.meshlets))
	meshlet_vertices := stream(&buffer, contents.meshlet_vertices)
	meshlet_triangles := stream(&buffer, contents.meshlet_triangles)
	meshlet_nodes := stream(&buffer, mem.slice_to_bytes(contents.meshlet_nodes))
	collision_positions := stream(&buffer, mem.slice_to_bytes(contents.collision_positions))
	collision_triangles := stream(&buffer, mem.slice_to_bytes(contents.collision_triangles))
	collision_submeshes := stream(&buffer, mem.slice_to_bytes(contents.collision_submeshes))
	impostor := stream(&buffer, mem.slice_to_bytes(contents.impostor))
	name := append_bytes(&buffer, transmute([]byte)contents.name)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	pages := reserve_bytes(&buffer, len(contents.pages) * size_of(Mesh_Page), BLOB_ALIGN)
	dependency_count := 0
	for p in contents.pages {
		dependency_count += len(p.dependencies)
	}
	page_dependencies := reserve_bytes(&buffer, dependency_count * 4, BLOB_ALIGN)
	for s, i in contents.submeshes {
		record := Mesh_Submesh {
			name          = append_bytes(&buffer, transmute([]byte)s.name),
			first_index   = s.first_index,
			index_count   = s.index_count,
			first_meshlet = s.first_meshlet,
			meshlet_count = s.meshlet_count,
			first_node    = s.first_node,
			node_count    = s.node_count,
			root_count    = s.root_count,
			level_first   = s.level_first,
			bounds        = s.bounds,
		}
		mem.copy(&buffer[submeshes.offset + u32(i * size_of(Mesh_Submesh))], &record, size_of(record))
	}
	// The roots end the head, and the other pages follow it.
	records := make([]Mesh_Page, len(contents.pages), context.temp_allocator)
	head_size := u32(len(buffer))
	for root in ([2]bool{true, false}) {
		for p, i in contents.pages {
			if (.Root in p.record.flags) != root {
				continue
			}
			records[i] = p.record
			records[i].offset = stream(&buffer, p.compressed).offset
			records[i].compressed_size = u32(len(p.compressed))
		}
		if root {
			head_size = u32(len(buffer))
		}
	}
	next_dependency: u32
	for p, i in contents.pages {
		records[i].first_dependency = next_dependency
		records[i].dependency_count = u32(len(p.dependencies))
		for d in p.dependencies {
			(^u32)(&buffer[page_dependencies.offset + next_dependency * 4])^ = d
			next_dependency += 1
		}
	}
	copy(buffer[pages.offset:], mem.slice_to_bytes(records))
	blob := Mesh_Blob {
		header = {magic = BLOB_MAGIC, kind = .Mesh, layout = mesh_layout(), key = contents.key, guid = contents.guid},
		flags = contents.flags,
		vertex_count = contents.vertex_count,
		index_count = contents.index_count,
		bounds = contents.bounds,
		submeshes = submeshes,
		positions = positions,
		attributes = attributes,
		skin = skin,
		indices = indices,
		meshlets = meshlets,
		meshlet_vertices = meshlet_vertices,
		meshlet_triangles = meshlet_triangles,
		meshlet_nodes = meshlet_nodes,
		name = name,
		source_path = source_path,
		collision_positions = collision_positions,
		collision_triangles = collision_triangles,
		collision_submeshes = collision_submeshes,
		impostor = impostor,
		impostor_size = len(contents.impostor) > 0 ? contents.impostor_size : 0,
		impostor_error = contents.impostor_error,
		meshlet_count = .Paged in contents.flags ? contents.meshlet_count : u32(len(contents.meshlets)),
		pages = pages,
		page_dependencies = page_dependencies,
		head_size = head_size,
		file_size = u32(len(buffer)),
		face_area = contents.face_area,
		levels = contents.levels,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
