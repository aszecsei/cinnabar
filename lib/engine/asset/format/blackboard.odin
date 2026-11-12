package asset_format

import "core:mem"

import "cinnabar:core/layout"

// A blackboard is a .blackboard text file: the typed keys that an agent's decision reads and its actions and scripts
// write. The cooker gives each key a slot and an offset in the agent's values (see docs/content/kinds/blackboards.md).
BLACKBOARD_EXTENSION :: ".blackboard"

// A blackboard has at most this many keys.
MAX_BLACKBOARD_KEYS :: 256
// An agent's values are at most this many bytes.
MAX_BLACKBOARD_SIZE :: 4096
// A value's bytes in a blob: the largest type, a position, is 24.
BLACKBOARD_VALUE_SIZE :: 24

// Blackboard_Type is what a key holds. A Position is a World_Position's raw Q39.24 axes. String is only an action's
// argument, never a key.
Blackboard_Type :: enum u32 {
	Float,
	Int,
	Bool,
	Enum,
	Entity,
	Position,
	Vector,
	String,
}

// blackboard_type_size is the bytes that a key of the type takes in the values: f32, i32, a u8 of 1 or 0, a u32 index
// into the enum's names, an Entity, a World_Position and a [3]f32.
blackboard_type_size :: proc "contextless" (t: Blackboard_Type) -> int {
	switch t {
	case .Float, .Int, .Enum:
		return 4
	case .Bool:
		return 1
	case .Entity:
		return 8
	case .Position:
		return 24
	case .Vector:
		return 12
	case .String:
		return 0
	}
	return 0
}

blackboard_type_align :: proc "contextless" (t: Blackboard_Type) -> int {
	switch t {
	case .Entity, .Position:
		return 8
	case .Bool:
		return 1
	case .Float, .Int, .Enum, .Vector:
		return 4
	case .String:
		return 1
	}
	return 1
}

// Blackboard_Key is a key, at its slot: its record's index.
Blackboard_Key :: struct {
	name:       Slice,
	// animation_graph_hash of the name, which scripts find the key by.
	hash:       u32,
	type:       Blackboard_Type,
	// The key's bytes in the values.
	offset:     u32,
	// An Enum's names, as a range of the blob's enum_names.
	first_enum: u32,
	enum_count: u32,
	padding:    u32,
}
#assert(size_of(Blackboard_Key) == 32)

// Blackboard_Blob is the start of a blackboard blob (see docs/content/blobs-and-loading.md#blob-format).
Blackboard_Blob :: struct {
	header:      Blob_Header,
	// The size of an agent's values, a multiple of 8.
	values_size: u32,
	padding:     u32,
	keys:        Slice,
	// Slice records, each an enum name.
	enum_names:  Slice,
	// The values that an agent starts with, values_size bytes.
	defaults:    Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/ai/guard.blackboard".
	source_path: Slice,
}

blackboard_layout :: proc() -> u64 {
	return layout.hash(Blackboard_Blob) ~ layout.hash(Blackboard_Key) * 31
}

// blackboard_view checks a blackboard blob: its header, its layout, that its slices are inside it, and that each key
// lies inside the values and its enum names inside the names.
blackboard_view :: proc(data: []byte) -> (blob: ^Blackboard_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Blackboard || header.layout != blackboard_layout() || len(data) < size_of(Blackboard_Blob) {
		return
	}
	blob = (^Blackboard_Blob)(raw_data(data))
	inside :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(data)) && int(s.size) % size == 0 && int(s.offset) % align == 0
	}
	if !inside(data, blob.keys, size_of(Blackboard_Key), align_of(Blackboard_Key)) ||
	   !inside(data, blob.enum_names, size_of(Slice), align_of(Slice)) || !inside(data, blob.defaults, 1, 8) ||
	   !inside(data, blob.source_path, 1, 1) || blob.values_size > MAX_BLACKBOARD_SIZE || blob.values_size % 8 != 0 ||
	   blob.defaults.size != blob.values_size {
		return nil, false
	}
	keys := blackboard_keys(data, blob)
	names := blackboard_enum_names(data, blob)
	if len(keys) > MAX_BLACKBOARD_KEYS {
		return nil, false
	}
	for k in keys {
		if k.type > .Vector || !inside(data, k.name, 1, 1) || int(k.offset) % blackboard_type_align(k.type) != 0 ||
		   u64(k.offset) + u64(blackboard_type_size(k.type)) > u64(blob.values_size) ||
		   u64(k.first_enum) + u64(k.enum_count) > u64(len(names)) || (k.type == .Enum) != (k.enum_count > 0) {
			return nil, false
		}
	}
	for n in names {
		if !inside(data, n, 1, 1) {
			return nil, false
		}
	}
	return blob, true
}

blackboard_keys :: proc "contextless" (data: []byte, blob: ^Blackboard_Blob) -> []Blackboard_Key {
	bytes := blob_bytes(data, blob.keys)
	return ([^]Blackboard_Key)(raw_data(bytes))[:len(bytes) / size_of(Blackboard_Key)]
}

blackboard_enum_names :: proc "contextless" (data: []byte, blob: ^Blackboard_Blob) -> []Slice {
	bytes := blob_bytes(data, blob.enum_names)
	return ([^]Slice)(raw_data(bytes))[:len(bytes) / size_of(Slice)]
}

// blackboard_find is the slot of the key whose name has the hash, or false.
blackboard_find :: proc "contextless" (data: []byte, blob: ^Blackboard_Blob, hash: u32) -> (slot: int, ok: bool) {
	for k, i in blackboard_keys(data, blob) {
		if k.hash == hash {
			return i, true
		}
	}
	return -1, false
}

// blackboard_enum_name is an Enum key's name for a value, or "" for one out of range.
blackboard_enum_name :: proc "contextless" (data: []byte, blob: ^Blackboard_Blob, key: Blackboard_Key, value: u32) -> string {
	if value >= key.enum_count {
		return ""
	}
	return blob_string(data, blackboard_enum_names(data, blob)[key.first_enum + value])
}

// Blackboard_Key_Contents is a key as blackboard_write takes it. default holds the key's bytes, as the values hold
// them.
Blackboard_Key_Contents :: struct {
	name:       string,
	type:       Blackboard_Type,
	enum_names: []string,
	default:    [BLACKBOARD_VALUE_SIZE]byte,
}

Blackboard_Contents :: struct {
	guid:        Guid,
	key:         u64,
	// In slot order.
	keys:        []Blackboard_Key_Contents,
	source_path: string,
}

// blackboard_offsets lays the keys out in the values in slot order, each at its type's alignment, and gives the
// values' size, rounded up to 8.
blackboard_offsets :: proc(keys: []Blackboard_Key_Contents, allocator := context.allocator) -> (offsets: []u32, size: u32) {
	offsets = make([]u32, len(keys), allocator)
	end := 0
	for k, i in keys {
		end = mem.align_forward_int(end, blackboard_type_align(k.type))
		offsets[i] = u32(end)
		end += blackboard_type_size(k.type)
	}
	return offsets, u32(mem.align_forward_int(end, 8))
}

// blackboard_write builds a blackboard blob.
blackboard_write :: proc(contents: Blackboard_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Blackboard_Blob), allocator)
	offsets, values_size := blackboard_offsets(contents.keys, context.temp_allocator)
	name_count := 0
	for k in contents.keys {
		name_count += len(k.enum_names)
	}
	keys := reserve_bytes(&buffer, len(contents.keys) * size_of(Blackboard_Key), align_of(Blackboard_Key))
	enum_names := reserve_bytes(&buffer, name_count * size_of(Slice), align_of(Slice))
	defaults := reserve_bytes(&buffer, int(values_size), 8)
	next_name := 0
	for k, i in contents.keys {
		record := Blackboard_Key {
			name       = append_bytes(&buffer, transmute([]byte)k.name),
			hash       = animation_graph_hash(k.name),
			type       = k.type,
			offset     = offsets[i],
			first_enum = u32(next_name),
			enum_count = u32(len(k.enum_names)),
		}
		mem.copy(&buffer[int(keys.offset) + i * size_of(Blackboard_Key)], &record, size_of(record))
		for n in k.enum_names {
			s := append_bytes(&buffer, transmute([]byte)n)
			mem.copy(&buffer[int(enum_names.offset) + next_name * size_of(Slice)], &s, size_of(s))
			next_name += 1
		}
		default := k.default
		mem.copy(&buffer[int(defaults.offset) + int(offsets[i])], &default, blackboard_type_size(k.type))
	}
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Blackboard_Blob {
		header = {magic = BLOB_MAGIC, kind = .Blackboard, layout = blackboard_layout(), key = contents.key, guid = contents.guid},
		values_size = values_size,
		keys = keys,
		enum_names = enum_names,
		defaults = defaults,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
