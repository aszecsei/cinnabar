package asset_format

import "core:math/linalg"
import "core:mem"
import "core:slice"

import "cinnabar:core/layout"

// An Instance_Set is the poses that an Instanced_Mesh_Renderer draws its mesh at. A USD point instancer is one, a
// sub-asset of its stage (see docs/content/kinds/stages.md#point-instancers), and so is an .instances file (see
// docs/content/kinds/instance-sets.md). INSTANCE_SET_KIND names the sub-assets in .meta files.
INSTANCE_SET_KIND :: "instance_set"

// INSTANCES_EXTENSION is the extension of an instance set's text source.
INSTANCES_EXTENSION :: ".instances"

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
	return(
		layout.hash(Instance_Set_Blob) ~
		layout.hash(Instance) * 31 ~
		layout.hash(Instance_Cell) * 961 \
	)
}

// instance_set_view checks an instance set blob: its header, its layout, its slices, and that its streams have the sizes
// that its counts give and its cells cover its instances.
instance_set_view :: proc(data: []byte) -> (blob: ^Instance_Set_Blob, ok: bool) {
	blob = blob_open(data, .Instance_Set, instance_set_layout(), Instance_Set_Blob) or_return
	if !slice_fits(data, blob.instances, size_of(Instance), BLOB_ALIGN) ||
	   !slice_fits(data, blob.cells, size_of(Instance_Cell), BLOB_ALIGN) ||
	   !slice_fits(data, blob.name, 1, 1) ||
	   !slice_fits(data, blob.source_path, 1, 1) ||
	   blob.instances.size != blob.count * size_of(Instance) ||
	   blob.cells.size != blob.cell_count * size_of(Instance_Cell) {
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
instance_set_write :: proc(
	contents: Instance_Set_Contents,
	allocator := context.allocator,
) -> []byte {
	buffer := make([dynamic]byte, size_of(Instance_Set_Blob), allocator)
	instances := reserve_bytes(&buffer, len(contents.instances) * size_of(Instance), BLOB_ALIGN)
	copy(buffer[instances.offset:], mem.slice_to_bytes(contents.instances))
	cells := reserve_bytes(&buffer, len(contents.cells) * size_of(Instance_Cell), BLOB_ALIGN)
	copy(buffer[cells.offset:], mem.slice_to_bytes(contents.cells))
	name := append_bytes(&buffer, transmute([]byte)contents.name)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Instance_Set_Blob {
		header = {
			magic = BLOB_MAGIC,
			kind = .Instance_Set,
			layout = instance_set_layout(),
			key = contents.key,
			guid = contents.guid,
		},
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

// Instance_Pose is a pose before it is packed as an Instance: meters, a unit quaternion and a scale, relative to the
// entity of the Instanced_Mesh_Renderer.
Instance_Pose :: struct {
	position: [3]f32,
	rotation: quaternion128,
	scale:    [3]f32,
}

// instance_pack packs a pose as an instance, its rotation with w at least 0 in snorm16 and its scale in f16. Point is
// the pose's index in its source.
instance_pack :: proc(pose: Instance_Pose, point: u32) -> Instance {
	q := [4]f32{imag(pose.rotation), jmag(pose.rotation), kmag(pose.rotation), real(pose.rotation)}
	if q.w < 0 {
		q = -q
	}
	snorm :: proc(v: f32) -> i16 {
		return i16(clamp(v, -1, 1) * 32767 + (v < 0 ? -0.5 : 0.5))
	}
	return {
		position = pose.position,
		rotation = {snorm(q.x), snorm(q.y), snorm(q.z), snorm(q.w)},
		scale = {f16(pose.scale.x), f16(pose.scale.y), f16(pose.scale.z)},
		point = point,
	}
}

// instance_cells orders instances along a Morton curve over their bounds, so each run of INSTANCE_CELL_SIZE is near
// together, and makes a cell of each run. The contents have no GUID, key or names.
instance_cells :: proc(
	instances: []Instance,
	allocator := context.allocator,
) -> (
	contents: Instance_Set_Contents,
) {
	context.allocator = allocator
	if len(instances) == 0 {
		return {instances = instances}
	}
	lo, hi := instances[0].position, instances[0].position
	for i in instances {
		lo = linalg.min(lo, i.position)
		hi = linalg.max(hi, i.position)
	}
	extent := linalg.max(hi - lo, [3]f32{1e-6, 1e-6, 1e-6})
	// 21 bits an axis, spread to every third bit.
	spread :: proc(v: u64) -> u64 {
		x := v & 0x1fffff
		x = (x | x << 32) & 0x1f00000000ffff
		x = (x | x << 16) & 0x1f0000ff0000ff
		x = (x | x << 8) & 0x100f00f00f00f00f
		x = (x | x << 4) & 0x10c30c30c30c30c3
		x = (x | x << 2) & 0x1249249249249249
		return x
	}
	Keyed :: struct {
		code:     u64,
		instance: Instance,
	}
	keyed := make([]Keyed, len(instances))
	defer delete(keyed)
	for i, k in instances {
		t := (i.position - lo) / extent * f32((1 << 21) - 1)
		keyed[k] = {spread(u64(t.x)) | spread(u64(t.y)) << 1 | spread(u64(t.z)) << 2, i}
	}
	slice.sort_by(
		keyed,
		proc(x, y: Keyed) -> bool {return(
				x.code < y.code ||
				(x.code == y.code && x.instance.point < y.instance.point) \
			)},
	)
	sorted := make([]Instance, len(instances))
	for k, i in keyed {
		sorted[i] = k.instance
	}
	sphere :: proc(run: []Instance) -> (center: [3]f32, radius: f32, max_scale: f32) {
		lo, hi := run[0].position, run[0].position
		for i in run {
			lo = linalg.min(lo, i.position)
			hi = linalg.max(hi, i.position)
			max_scale = max(
				max_scale,
				abs(f32(i.scale.x)),
				abs(f32(i.scale.y)),
				abs(f32(i.scale.z)),
			)
		}
		center = (lo + hi) / 2
		for i in run {
			radius = max(radius, linalg.length(i.position - center))
		}
		return
	}
	cells := make([dynamic]Instance_Cell)
	for first := 0; first < len(sorted); first += INSTANCE_CELL_SIZE {
		run := sorted[first:min(first + INSTANCE_CELL_SIZE, len(sorted))]
		center, radius, max_scale := sphere(run)
		append(
			&cells,
			Instance_Cell {
				center = center,
				radius = radius,
				max_scale = max_scale,
				first = u32(first),
				count = u32(len(run)),
			},
		)
	}
	contents.instances = sorted
	contents.cells = cells[:]
	contents.center, contents.radius, contents.max_scale = sphere(sorted)
	return
}
