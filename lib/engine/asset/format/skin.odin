package asset_format

import "core:mem"

import "cinnabar:core/layout"

// Each skin of a glTF file is a Skin sub-asset of its model: the joints that pose a skinned mesh's vertices (see
// docs/content/kinds/skins-and-animations.md#skins). SKIN_KIND names them in .meta files.
SKIN_KIND :: "skin"

// Skin_Joint is one joint of a skin, in the engine's axes and the mesh's units. A skin's joints are its glTF skin's and
// every ancestor of theirs, so each joint's pose is relative to its parent's, or to the mesh's space for a root. They
// are in an order where each parent comes before its children, which the skin stream's joint indices and clips'
// channels follow.
Skin_Joint :: struct {
	// The mesh's space to the joint's, at bind time, as three rows of a 3x4 matrix.
	inverse_bind: [3][4]f32,
	// The rest pose relative to the parent: a translation, a unit quaternion x, y, z, w, and a scale. A clip's channels
	// replace the parts that they animate.
	translation:  [3]f32,
	// The parent's index, or -1 for a root.
	parent:       i32,
	rotation:     [4]f32,
	scale:        [3]f32,
	// A sphere in the joint's space at bind time, about every vertex of the skin's meshes that the joint influences:
	// posed by the joint, the spheres hold the posed mesh. A joint that influences no vertex has a radius of -1.
	sphere:       [4]f32,
	// The joint's node's name.
	name:         Slice,
	padding:      [3]u32,
}

#assert(size_of(Skin_Joint) == 128)

// Skin_Blob is the start of a skin blob (see docs/content/blobs-and-loading.md#blob-format).
Skin_Blob :: struct {
	header:      Blob_Header,
	joint_count: u32,
	padding:     [3]u32,
	// Skin_Joint records.
	joints:      Slice,
	// The skin's name in its model, and the model's path, prefixed with its root's name.
	name:        Slice,
	source_path: Slice,
}

skin_layout :: proc() -> u64 {
	return layout.hash(Skin_Blob) ~ layout.hash(Skin_Joint) * 31
}

// skin_view checks a skin blob: its header, its layout, its slices, and that each joint's parent comes before it.
skin_view :: proc(data: []byte) -> (blob: ^Skin_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Skin || header.layout != skin_layout() || len(data) < size_of(Skin_Blob) {
		return
	}
	blob = (^Skin_Blob)(raw_data(data))
	for s in ([?]Slice{blob.joints, blob.name, blob.source_path}) {
		if u64(s.offset) + u64(s.size) > u64(len(data)) {
			return nil, false
		}
	}
	if blob.joints.size != blob.joint_count * size_of(Skin_Joint) || blob.joints.offset % align_of(Skin_Joint) != 0 {
		return nil, false
	}
	for j, i in skin_joints(data, blob) {
		if j.parent < -1 || int(j.parent) >= i || u64(j.name.offset) + u64(j.name.size) > u64(len(data)) {
			return nil, false
		}
	}
	return blob, true
}

skin_joints :: proc "contextless" (data: []byte, blob: ^Skin_Blob) -> []Skin_Joint {
	bytes := blob_bytes(data, blob.joints)
	return ([^]Skin_Joint)(raw_data(bytes))[:len(bytes) / size_of(Skin_Joint)]
}

Skin_Joint_Entry :: struct {
	name:         string,
	parent:       i32,
	inverse_bind: [3][4]f32,
	translation:  [3]f32,
	rotation:     [4]f32,
	scale:        [3]f32,
	sphere:       [4]f32,
}

// Skin_Contents is what skin_write builds a blob from: joints already with each parent before its children.
Skin_Contents :: struct {
	guid:        Guid,
	key:         u64,
	joints:      []Skin_Joint_Entry,
	name:        string,
	source_path: string,
}

// skin_write builds a skin blob.
skin_write :: proc(contents: Skin_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Skin_Blob), allocator)
	joints := reserve_bytes(&buffer, len(contents.joints) * size_of(Skin_Joint), BLOB_ALIGN)
	name := append_bytes(&buffer, transmute([]byte)contents.name)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	for j, i in contents.joints {
		record := Skin_Joint {
			inverse_bind = j.inverse_bind,
			translation  = j.translation,
			parent       = j.parent,
			rotation     = j.rotation,
			scale        = j.scale,
			sphere       = j.sphere,
			name         = append_bytes(&buffer, transmute([]byte)j.name),
		}
		mem.copy(&buffer[joints.offset + u32(i * size_of(Skin_Joint))], &record, size_of(record))
	}
	blob := Skin_Blob {
		header = {magic = BLOB_MAGIC, kind = .Skin, layout = skin_layout(), key = contents.key, guid = contents.guid},
		joint_count = u32(len(contents.joints)),
		joints = joints,
		name = name,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
