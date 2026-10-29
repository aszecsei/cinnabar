package asset_format

import "core:mem"

import "cinnabar:core/layout"

// A USD point instancer is an Instance_Set sub-asset of its stage: the poses of its points, which an
// Instanced_Mesh_Renderer draws its mesh at (see docs/content/kinds/stages.md#point-instancers). INSTANCE_SET_KIND names
// them in .meta files.
INSTANCE_SET_KIND :: "instance_set"

// A cell holds at most this many instances, which are near each other, so culling can test the cell before them.
INSTANCE_CELL_SIZE :: 256

// Instance is one pose of an instance set, relative to its entity. Shaders read it as it is: matches Instance in
// instanced.hlsli.
Instance :: struct {
	position: [3]f32,
	// A unit quaternion, x, y, z, w, in snorm16: decode with v / 32767.
	rotation: [4]i16,
	scale:    [3]f16,
	padding:  u16,
	// The point's index in its instancer, among the points that are not invisible or inactive.
	point:    u32,
}

// Instance_Cell is a run of an instance set's instances that are near each other: a sphere about their positions, and
// the largest scale of any of their axes, which culling grows a mesh's sphere by.
Instance_Cell :: struct {
	center:    [3]f32,
	radius:    f32,
	max_scale: f32,
	first:     u32,
	count:     u32,
	padding:   u32,
}

// Instance_Set_Blob is the start of an instance set blob (see docs/content/blobs-and-loading.md#blob-format). Each stream
// starts at BLOB_ALIGN, so it can stream straight into a GPU buffer.
Instance_Set_Blob :: struct {
	header:      Blob_Header,
	count:       u32,
	cell_count:  u32,
	// A sphere about every instance's position, and the largest scale of any instance's axes.
	center:      [3]f32,
	radius:      f32,
	max_scale:   f32,
	padding:     [3]u32,
	// Instance records, cell by cell.
	instances:   Slice,
	// Instance_Cell records.
	cells:       Slice,
	// The instancer's name in its stage, and the stage's path, prefixed with its root's name.
	name:        Slice,
	source_path: Slice,
}

#assert(size_of(Instance) == 32 && size_of(Instance_Cell) == 32)

instance_set_layout :: proc() -> u64 {
	return layout.hash(Instance_Set_Blob) ~ layout.hash(Instance) * 31 ~ layout.hash(Instance_Cell) * 961
}

// instance_set_view checks an instance set blob: its header, its layout, its slices, and that its streams have the sizes
// that its counts give and its cells cover its instances.
instance_set_view :: proc(data: []byte) -> (blob: ^Instance_Set_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Instance_Set || header.layout != instance_set_layout() || len(data) < size_of(Instance_Set_Blob) {
		return
	}
	blob = (^Instance_Set_Blob)(raw_data(data))
	for s in ([?]Slice{blob.instances, blob.cells, blob.name, blob.source_path}) {
		if u64(s.offset) + u64(s.size) > u64(len(data)) {
			return nil, false
		}
	}
	if blob.instances.size != blob.count * size_of(Instance) || blob.instances.offset % BLOB_ALIGN != 0 ||
	   blob.cells.size != blob.cell_count * size_of(Instance_Cell) || blob.cells.offset % BLOB_ALIGN != 0 {
		return nil, false
	}
	next: u32
	for c in instance_set_cells(data, blob) {
		if c.first != next || c.count == 0 || c.count > INSTANCE_CELL_SIZE {
			return nil, false
		}
		next += c.count
	}
	if next != blob.count {
		return nil, false
	}
	return blob, true
}

instance_set_instances :: proc(data: []byte, blob: ^Instance_Set_Blob) -> []Instance {
	return mem.slice_data_cast([]Instance, blob_bytes(data, blob.instances))
}

instance_set_cells :: proc(data: []byte, blob: ^Instance_Set_Blob) -> []Instance_Cell {
	return mem.slice_data_cast([]Instance_Cell, blob_bytes(data, blob.cells))
}

// Instance_Set_Contents is what instance_set_write builds a blob from: instances already in their cells' order.
Instance_Set_Contents :: struct {
	guid:        Guid,
	key:         u64,
	instances:   []Instance,
	cells:       []Instance_Cell,
	center:      [3]f32,
	radius:      f32,
	max_scale:   f32,
	name:        string,
	source_path: string,
}

// instance_set_write builds an instance set blob.
instance_set_write :: proc(contents: Instance_Set_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Instance_Set_Blob), allocator)
	instances := reserve_bytes(&buffer, len(contents.instances) * size_of(Instance), BLOB_ALIGN)
	copy(buffer[instances.offset:], mem.slice_to_bytes(contents.instances))
	cells := reserve_bytes(&buffer, len(contents.cells) * size_of(Instance_Cell), BLOB_ALIGN)
	copy(buffer[cells.offset:], mem.slice_to_bytes(contents.cells))
	name := append_bytes(&buffer, transmute([]byte)contents.name)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Instance_Set_Blob {
		header = {magic = BLOB_MAGIC, kind = .Instance_Set, layout = instance_set_layout(), key = contents.key, guid = contents.guid},
		count = u32(len(contents.instances)),
		cell_count = u32(len(contents.cells)),
		center = contents.center,
		radius = contents.radius,
		max_scale = contents.max_scale,
		instances = instances,
		cells = cells,
		name = name,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
