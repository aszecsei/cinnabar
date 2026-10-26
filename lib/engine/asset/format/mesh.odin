package asset_format

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
}

Mesh_Flags :: bit_set[Mesh_Flag;u32]

// Mesh_Bounds is an axis-aligned box and a sphere, in the mesh's space.
Mesh_Bounds :: struct {
	min, max: [3]f32,
	center:   [3]f32,
	radius:   f32,
}

// Mesh_Submesh is the part of a mesh that one material draws. Its indices and meshlets are ranges of the mesh's.
Mesh_Submesh :: struct {
	// The material slot's name: the glTF material's.
	name:          Slice,
	first_index:   u32,
	index_count:   u32,
	first_meshlet: u32,
	meshlet_count: u32,
	bounds:        Mesh_Bounds,
}

// Meshlet is a cluster of at most MESHLET_MAX_VERTICES vertices and MESHLET_MAX_TRIANGLES triangles, at one level of
// its submesh's LOD hierarchy, with the bounds that culling tests and the errors that pick the level (see
// docs/content/kinds/meshes.md#meshlets). Its vertices are a range of meshlet_vertices, which index the mesh's vertices,
// and its triangles a range of meshlet_triangles. Shaders read it as it is: matches Meshlet in material_mesh.hlsli.
Meshlet :: struct {
	vertex_offset:   u32,
	triangle_offset: u32,
	vertex_count:    u8,
	triangle_count:  u8,
	// Its level: 0 for the submesh's own triangles, and one more for each simplification.
	depth:           u16,
	// The normal cone, in snorm8: decode with x / 127. A meshlet whose cone points away from the view can be culled. A
	// cutoff of 127 is a cone too wide to cull.
	cone_axis:       [3]i8,
	cone_cutoff:     i8,
	// The sphere that culling tests.
	center:          [3]f32,
	radius:          f32,
	// The sphere of the simplification that made this meshlet, whose error is error: 0 for the submesh's own triangles.
	error_center:    [3]f32,
	error_radius:    f32,
	// The sphere of its group's simplification, a level up, whose error is parent_error: F32_MAX at the top. A view draws
	// the meshlet when error projects to at most its threshold and parent_error to more.
	parent_center:   [3]f32,
	parent_radius:   f32,
	error:           f32,
	parent_error:    f32,
	padding:         [2]u32,
}

#assert(size_of(Meshlet) == 80)

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
	// u16 or u32 per index, by the Index32 flag, in triangles whose front faces are clockwise on screen.
	indices:           Slice,
	// Meshlet records.
	meshlets:          Slice,
	// u32 per meshlet vertex.
	meshlet_vertices:  Slice,
	// u32 per meshlet triangle: its three indices into its meshlet's vertices in the low three bytes.
	meshlet_triangles: Slice,
	// The mesh's name in its model, and the model's path, prefixed with its root's name.
	name:              Slice,
	source_path:       Slice,
}

mesh_layout :: proc() -> u64 {
	return layout.hash(Mesh_Blob) ~ layout.hash(Mesh_Submesh) * 31 ~ layout.hash(Meshlet) * 961 ~ layout.hash(Mesh_Attributes) * 29791
}

// mesh_view checks a mesh blob: its header, its layout, its slices, and that its streams have the sizes that its
// counts give.
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
		blob.indices,
		blob.meshlets,
		blob.meshlet_vertices,
		blob.meshlet_triangles,
		blob.name,
		blob.source_path,
	}
	for s in slices {
		if u64(s.offset) + u64(s.size) > u64(len(data)) {
			return nil, false
		}
	}
	index_size: u32 = .Index32 in blob.flags ? 4 : 2
	switch {
	case blob.positions.size != blob.vertex_count * 12,
	     blob.attributes.size != blob.vertex_count * mesh_attribute_stride(blob.flags),
	     blob.indices.size != blob.index_count * index_size,
	     blob.submeshes.size % size_of(Mesh_Submesh) != 0 || blob.submeshes.offset % align_of(Mesh_Submesh) != 0,
	     blob.meshlets.size % size_of(Meshlet) != 0 || blob.meshlets.offset % align_of(Meshlet) != 0,
	     blob.meshlet_vertices.size % 4 != 0 || blob.meshlet_triangles.size % 4 != 0:
		return nil, false
	}
	meshlet_count := blob.meshlets.size / size_of(Meshlet)
	for s in mesh_submeshes(data, blob) {
		if u64(s.name.offset) + u64(s.name.size) > u64(len(data)) ||
		   u64(s.first_index) + u64(s.index_count) > u64(blob.index_count) ||
		   u64(s.first_meshlet) + u64(s.meshlet_count) > u64(meshlet_count) {
			return nil, false
		}
	}
	return blob, true
}

mesh_submeshes :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> []Mesh_Submesh {
	bytes := blob_bytes(data, blob.submeshes)
	return ([^]Mesh_Submesh)(raw_data(bytes))[:len(bytes) / size_of(Mesh_Submesh)]
}

mesh_meshlets :: proc "contextless" (data: []byte, blob: ^Mesh_Blob) -> []Meshlet {
	bytes := blob_bytes(data, blob.meshlets)
	return ([^]Meshlet)(raw_data(bytes))[:len(bytes) / size_of(Meshlet)]
}

Submesh_Entry :: struct {
	name:          string,
	first_index:   u32,
	index_count:   u32,
	first_meshlet: u32,
	meshlet_count: u32,
	bounds:        Mesh_Bounds,
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
	indices:           []byte,
	meshlets:          []Meshlet,
	meshlet_vertices:  []byte,
	meshlet_triangles: []byte,
	name:              string,
	source_path:       string,
}

// mesh_write builds a mesh blob.
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
	indices := stream(&buffer, contents.indices)
	meshlets := stream(&buffer, mem.slice_to_bytes(contents.meshlets))
	meshlet_vertices := stream(&buffer, contents.meshlet_vertices)
	meshlet_triangles := stream(&buffer, contents.meshlet_triangles)
	name := append_bytes(&buffer, transmute([]byte)contents.name)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	for s, i in contents.submeshes {
		record := Mesh_Submesh {
			name          = append_bytes(&buffer, transmute([]byte)s.name),
			first_index   = s.first_index,
			index_count   = s.index_count,
			first_meshlet = s.first_meshlet,
			meshlet_count = s.meshlet_count,
			bounds        = s.bounds,
		}
		mem.copy(&buffer[submeshes.offset + u32(i * size_of(Mesh_Submesh))], &record, size_of(record))
	}
	blob := Mesh_Blob {
		header = {magic = BLOB_MAGIC, kind = .Mesh, layout = mesh_layout(), key = contents.key, guid = contents.guid},
		flags = contents.flags,
		vertex_count = contents.vertex_count,
		index_count = contents.index_count,
		bounds = contents.bounds,
		submeshes = submeshes,
		positions = positions,
		attributes = attributes,
		indices = indices,
		meshlets = meshlets,
		meshlet_vertices = meshlet_vertices,
		meshlet_triangles = meshlet_triangles,
		name = name,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
