package scene

import "base:runtime"
import "core:reflect"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

Field_Kind :: enum u8 {
	Bool,
	I8,
	I16,
	I32,
	I64,
	U8,
	U16,
	U32,
	U64,
	F32,
	F64,
	// An integer of the kind enum_base, with names in enum_values.
	Enum,
	// [3]f32.
	Vector3,
	// quaternion128: x, y, z, w.
	Quaternion,
	// World_Position: three i64 in units of 2^-24 m.
	Position,
	// An entity handle.
	Entity,
	// An asset's GUID, format.Guid. asset_kind names the kind of asset that it takes.
	Asset,
}

Enum_Value :: struct {
	name:  string,
	value: i64,
}

// Field is a field of a component that scenes and the editor can set. Names point into the DLL image or allocator,
// so a Field is valid only for the frame that it is made in.
Field :: struct {
	// Nested structs are flattened, with dotted names, such as inner.amount.
	name:        string,
	offset:      u32,
	kind:        Field_Kind,
	enum_base:   Field_Kind,
	enum_values: []Enum_Value,
	// From the struct tag editor:"read".
	read_only:   bool,
	// From the struct tag editor:"range=min,max".
	has_range:   bool,
	range_min:   f64,
	range_max:   f64,
	// For an Asset field, the kind of asset that it takes, from the struct tag asset:"<kind>", as the cook link names
	// kinds in lowercase, such as "mesh". "" takes any asset.
	asset_kind:  string,
}

// component_fields lists the fields of a component type. A nested struct that is not a kind of its own adds its
// fields with its name and a dot in front. The struct tag editor:"-" hides a field, editor:"read" makes it and what
// is in it read-only, and editor:"range=min,max" gives a number's range. A format.Guid field is an asset reference,
// and asset:"<kind>" names the kind of asset that it takes (see docs/rendering.md#asset-fields). Other field types
// are hidden.
component_fields :: proc(type: typeid, allocator: runtime.Allocator) -> []Field {
	fields := make([dynamic]Field, allocator)
	add_fields(&fields, type_info_of(type), "", 0, false, allocator)
	return fields[:]
}

@(private = "file")
add_fields :: proc(fields: ^[dynamic]Field, ti: ^runtime.Type_Info, prefix: string, base: uintptr, read_only: bool, allocator: runtime.Allocator) {
	s, is_struct := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	if !is_struct {
		return
	}
	for i in 0 ..< s.field_count {
		tag := reflect.struct_tag_get(reflect.Struct_Tag(s.tags[i]), "editor")
		if tag == "-" {
			continue
		}
		name := s.names[i] if prefix == "" else strings.concatenate({prefix, ".", s.names[i]}, allocator)
		field := Field {
			name      = name,
			offset    = u32(base + s.offsets[i]),
			read_only = read_only || tag == "read",
		}
		if strings.has_prefix(tag, "range=") {
			low, _, high := strings.partition(tag[len("range="):], ",")
			min_value, min_ok := strconv.parse_f64(strings.trim_space(low))
			max_value, max_ok := strconv.parse_f64(strings.trim_space(high))
			if min_ok && max_ok {
				field.has_range, field.range_min, field.range_max = true, min_value, max_value
			}
		}
		if field_kind(s.types[i], &field, allocator) {
			if field.kind == .Asset {
				field.asset_kind = reflect.struct_tag_get(reflect.Struct_Tag(s.tags[i]), "asset")
			}
			append(fields, field)
		} else {
			add_fields(fields, s.types[i], name, base + s.offsets[i], field.read_only, allocator)
		}
	}
}

// field_kind sets the field's kind, and returns false for a type that is not a field kind.
@(private = "file")
field_kind :: proc(ti: ^runtime.Type_Info, field: ^Field, allocator: runtime.Allocator) -> bool {
	switch ti.id {
	case ecs.World_Position:
		field.kind = .Position
		return true
	case ecs.Entity:
		field.kind = .Entity
		return true
	case format.Guid:
		field.kind = .Asset
		return true
	}
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Float:
		switch ti.size {
		case 4:
			field.kind = .F32
			return true
		case 8:
			field.kind = .F64
			return true
		}
	case runtime.Type_Info_Integer:
		kind, ok := integer_kind(v.signed, ti.size)
		field.kind = kind
		return ok
	case runtime.Type_Info_Boolean:
		field.kind = .Bool
		return ti.size == 1
	case runtime.Type_Info_Enum:
		base, ok := integer_kind(runtime.type_info_base(v.base).variant.(runtime.Type_Info_Integer).signed, ti.size)
		if !ok {
			return false
		}
		values := make([]Enum_Value, len(v.names), allocator)
		for name, i in v.names {
			values[i] = {name = name, value = i64(v.values[i])}
		}
		field.kind, field.enum_base, field.enum_values = .Enum, base, values
		return true
	case runtime.Type_Info_Array:
		if v.count == 3 && v.elem.id == f32 {
			field.kind = .Vector3
			return true
		}
	case runtime.Type_Info_Quaternion:
		field.kind = .Quaternion
		return ti.size == size_of(quaternion128)
	}
	return false
}

@(private = "file")
integer_kind :: proc(signed: bool, size: int) -> (Field_Kind, bool) {
	kinds := [4]Field_Kind{.I8, .I16, .I32, .I64} if signed else [4]Field_Kind{.U8, .U16, .U32, .U64}
	switch size {
	case 1:
		return kinds[0], true
	case 2:
		return kinds[1], true
	case 4:
		return kinds[2], true
	case 8:
		return kinds[3], true
	}
	return {}, false
}
