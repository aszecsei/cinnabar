package asset_format

import "core:hash"
import "core:mem"

import "cinnabar:core/layout"

SCENE_EXTENSION :: ".scene"

// Scene is a scene as its file describes it (see docs/editor.md#scenes). The cooker parses it from text, the asset
// runtime reads it from a blob, and the editor sends it over the link. The scene loader in lib/engine applies it.
Scene :: struct {
	entities: []Scene_Entity,
}

Scene_Entity :: struct {
	// The scene ID: random, nonzero and unique in the scene.
	id:         u64,
	name:       string,
	// The parent's scene ID, or 0.
	parent:     u64,
	active:     bool,
	// Sorted by ID.
	components: []Scene_Component,
	// In the order that they are attached.
	behaviours: []Scene_Behaviour,
}

Scene_Component :: struct {
	// The component's stable ID. The loader uses it, and the name is for people and messages.
	id:     u64,
	name:   string,
	fields: []Scene_Field,
}

Scene_Behaviour :: struct {
	script: Guid,
	fields: []Scene_Field,
}

// Scene_Field is a field's value by name. The cooker cannot lay out native components, so a value is tagged, and the
// loader converts it to the field's kind.
Scene_Field :: struct {
	name:  string,
	// scene_field_hash of the name. The loader matches fields by it.
	hash:  u64,
	value: Scene_Value,
}

Scene_Value_Kind :: enum u8 {
	Bool,
	// One to four numbers, such as 90 or [0, 0.7071068, 0, 0.7071068].
	Number,
	// A quoted string.
	String,
	// A bare word, such as an enum value's name.
	Name,
	// An entity's scene ID, or 0 for none.
	Entity,
}

// Scene_Value is a field's value as the file writes it. Only the members for its kind are set.
Scene_Value :: struct {
	kind:    Scene_Value_Kind,
	// Number: how many numbers, 1 for a scalar.
	count:   u8,
	// Number: bit i is set when number i was written as an integer. ints holds it exactly, so a raw position
	// round-trips. floats holds every number as an f64.
	integer: u8,
	// Bool: 1 or 0 in ints[0].
	ints:    [4]i64,
	floats:  [4]f64,
	// String and Name.
	text:    string,
	entity:  u64,
}

scene_field_hash :: proc "contextless" (name: string) -> u64 {
	return hash.fnv64a(transmute([]byte)name)
}

// Scene_Blob is the start of a cooked scene. The records use offsets, like every blob.
Scene_Blob :: struct {
	header:   Blob_Header,
	// Scene_Entity_Record records.
	entities: Slice,
}

Scene_Entity_Record :: struct {
	id:         u64,
	parent:     u64,
	name:       Slice,
	// Scene_Component_Record records.
	components: Slice,
	// Scene_Behaviour_Record records.
	behaviours: Slice,
	active:     b32,
}

Scene_Component_Record :: struct {
	id:     u64,
	name:   Slice,
	// Scene_Field_Record records.
	fields: Slice,
}

Scene_Behaviour_Record :: struct {
	script: Guid,
	fields: Slice,
}

Scene_Field_Record :: struct {
	hash:    u64,
	name:    Slice,
	kind:    Scene_Value_Kind,
	count:   u8,
	integer: u8,
	ints:    [4]i64,
	floats:  [4]f64,
	text:    Slice,
	entity:  u64,
}

scene_layout :: proc() -> u64 {
	return(
		layout.hash(Scene_Blob) ~
		layout.hash(Scene_Entity_Record) * 31 ~
		layout.hash(Scene_Component_Record) * 961 ~
		layout.hash(Scene_Behaviour_Record) * 29791 ~
		layout.hash(Scene_Field_Record) * 923521 \
	)
}

// scene_write builds a scene blob.
scene_write :: proc(scene: Scene, guid: Guid, key: u64, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Scene_Blob), allocator)
	entities := reserve_bytes(&buffer, len(scene.entities) * size_of(Scene_Entity_Record), align_of(Scene_Entity_Record))
	for e, i in scene.entities {
		components := reserve_bytes(&buffer, len(e.components) * size_of(Scene_Component_Record), align_of(Scene_Component_Record))
		for c, j in e.components {
			record := Scene_Component_Record {
				id     = c.id,
				name   = append_bytes(&buffer, transmute([]byte)c.name),
				fields = write_fields(&buffer, c.fields),
			}
			put_record(&buffer, components, j, &record)
		}
		behaviours := reserve_bytes(&buffer, len(e.behaviours) * size_of(Scene_Behaviour_Record), align_of(Scene_Behaviour_Record))
		for b, j in e.behaviours {
			record := Scene_Behaviour_Record {
				script = b.script,
				fields = write_fields(&buffer, b.fields),
			}
			put_record(&buffer, behaviours, j, &record)
		}
		record := Scene_Entity_Record {
			id         = e.id,
			parent     = e.parent,
			name       = append_bytes(&buffer, transmute([]byte)e.name),
			components = components,
			behaviours = behaviours,
			active     = b32(e.active),
		}
		put_record(&buffer, entities, i, &record)
	}
	blob := Scene_Blob {
		header = {magic = BLOB_MAGIC, kind = .Scene, layout = scene_layout(), key = key, guid = guid},
		entities = entities,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}

@(private = "file")
write_fields :: proc(buffer: ^[dynamic]byte, fields: []Scene_Field) -> Slice {
	records := reserve_bytes(buffer, len(fields) * size_of(Scene_Field_Record), align_of(Scene_Field_Record))
	for f, i in fields {
		record := Scene_Field_Record {
			hash    = f.hash,
			name    = append_bytes(buffer, transmute([]byte)f.name),
			kind    = f.value.kind,
			count   = f.value.count,
			integer = f.value.integer,
			ints    = f.value.ints,
			floats  = f.value.floats,
			text    = append_bytes(buffer, transmute([]byte)f.value.text),
			entity  = f.value.entity,
		}
		put_record(buffer, records, i, &record)
	}
	return records
}

@(private = "file")
put_record :: proc(buffer: ^[dynamic]byte, records: Slice, i: int, record: ^$T) {
	mem.copy(&buffer[records.offset + u32(i * size_of(T))], record, size_of(T))
}

// scene_read checks a scene blob and gives its scene. Strings point into the blob, and the slices are in allocator.
scene_read :: proc(data: []byte, allocator := context.allocator) -> (scene: Scene, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Scene || header.layout != scene_layout() || len(data) < size_of(Scene_Blob) {
		return
	}
	blob := (^Scene_Blob)(raw_data(data))
	entity_records := records(data, blob.entities, Scene_Entity_Record) or_return
	entities := make([]Scene_Entity, len(entity_records), allocator)
	for r, i in entity_records {
		component_records := records(data, r.components, Scene_Component_Record) or_return
		components := make([]Scene_Component, len(component_records), allocator)
		for c, j in component_records {
			components[j] = {
				id     = c.id,
				name   = text(data, c.name) or_return,
				fields = read_fields(data, c.fields, allocator) or_return,
			}
		}
		behaviour_records := records(data, r.behaviours, Scene_Behaviour_Record) or_return
		behaviours := make([]Scene_Behaviour, len(behaviour_records), allocator)
		for b, j in behaviour_records {
			behaviours[j] = {
				script = b.script,
				fields = read_fields(data, b.fields, allocator) or_return,
			}
		}
		entities[i] = {
			id         = r.id,
			name       = text(data, r.name) or_return,
			parent     = r.parent,
			active     = bool(r.active),
			components = components,
			behaviours = behaviours,
		}
	}
	return {entities = entities}, true
}

@(private = "file")
read_fields :: proc(data: []byte, s: Slice, allocator: mem.Allocator) -> (fields: []Scene_Field, ok: bool) {
	field_records := records(data, s, Scene_Field_Record) or_return
	fields = make([]Scene_Field, len(field_records), allocator)
	for r, i in field_records {
		if r.count > 4 || r.kind > max(Scene_Value_Kind) {
			return
		}
		fields[i] = {
			name = text(data, r.name) or_return,
			hash = r.hash,
			value = {
				kind = r.kind,
				count = r.count,
				integer = r.integer,
				ints = r.ints,
				floats = r.floats,
				text = text(data, r.text) or_return,
				entity = r.entity,
			},
		}
	}
	return fields, true
}

// records is a slice of a blob as records of T, if it is inside the blob and aligned for T.
@(private = "file")
records :: proc(data: []byte, s: Slice, $T: typeid) -> ([]T, bool) {
	if u64(s.offset) + u64(s.size) > u64(len(data)) || s.size % size_of(T) != 0 || s.offset % align_of(T) != 0 {
		return nil, false
	}
	bytes := blob_bytes(data, s)
	return ([^]T)(raw_data(bytes))[:len(bytes) / size_of(T)], true
}

@(private = "file")
text :: proc(data: []byte, s: Slice) -> (string, bool) {
	if u64(s.offset) + u64(s.size) > u64(len(data)) {
		return "", false
	}
	return blob_string(data, s), true
}
