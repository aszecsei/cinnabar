package editor

import "base:runtime"
import "core:reflect"
import "core:strconv"
import "core:strings"

import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"

// component_types describes every registered component. Strings and slices are in allocator.
@(private)
component_types :: proc(w: ^ecs.World, allocator: runtime.Allocator) -> link.Component_Types {
	types := make([]link.Component_Type, w.registry.count, allocator)
	for info, i in w.registry.infos[:w.registry.count] {
		fields := make([dynamic]link.Field_Info, allocator)
		add_fields(&fields, type_info_of(info.type), "", 0, false, allocator)
		types[i] = {id = u64(info.id), name = info.name, size = u32(info.size), fields = fields[:]}
	}
	return {types = types}
}

// add_fields adds the fields of a struct that the editor can show. A nested struct that is not a kind of its own adds
// its fields with its name and a dot in front. The struct tag editor:"-" hides a field, editor:"read" makes it and
// what is in it read-only, and editor:"range=min,max" gives a number's range. Other field types are hidden.
add_fields :: proc(fields: ^[dynamic]link.Field_Info, ti: ^runtime.Type_Info, prefix: string, base: uintptr, read_only: bool, allocator: runtime.Allocator) {
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
		field := link.Field_Info {
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
			append(fields, field)
		} else {
			add_fields(fields, s.types[i], name, base + s.offsets[i], field.read_only, allocator)
		}
	}
}

// field_kind sets the field's kind, and returns false for a type that is not a field kind.
@(private)
field_kind :: proc(ti: ^runtime.Type_Info, field: ^link.Field_Info, allocator: runtime.Allocator) -> bool {
	switch ti.id {
	case ecs.World_Position:
		field.kind = .Position
		return true
	case ecs.Entity:
		field.kind = .Entity
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
		values := make([]link.Enum_Value, len(v.names), allocator)
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

@(private)
integer_kind :: proc(signed: bool, size: int) -> (link.Field_Kind, bool) {
	kinds := [4]link.Field_Kind{.I8, .I16, .I32, .I64} if signed else [4]link.Field_Kind{.U8, .U16, .U32, .U64}
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
