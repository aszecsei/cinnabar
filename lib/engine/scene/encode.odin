package scene

import "base:runtime"
import "core:mem"
import "core:strings"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The encoder is the loader's inverse: it turns a component's bytes into the values that a scene writes, so what an
// edit-mode behaviour did to the world goes to the editor's document (see docs/scripting/behaviours.md#writes-in-edit-mode).
// A loaded value writes back the same bytes.

// encode_fields gives the fields of a component whose bytes in data differ from those in base, as a scene sets them:
// base is the component's bytes before a change, or nil for its defaults, as for a new component, and with all, every
// field is given, as a pose that must be whole. A volume's setting
// whose override flag differs gives the flag too, as <name>.override. ids gives an entity's scene ID: drafts, which
// have none yet, by the IDs that they will have, and the others by their Scene_Entity. An entity with neither is 0.
encode_fields :: proc(
	w: ^ecs.World,
	info: ^ecs.Component_Info,
	data, base: rawptr,
	ids: map[ecs.Entity]u64,
	allocator: runtime.Allocator,
	all := false,
) -> []format.Scene_Field {
	base := base
	if base == nil {
		base = ecs.registry_defaults(&w.registry, info)
	}
	if base == nil {
		zero := make([]byte, info.size, allocator)
		base = raw_data(zero)
	}
	result := make([dynamic]format.Scene_Field, allocator)
	for field in component_fields(info.type, allocator) {
		at := uintptr(field.offset)
		if all ||
		   mem.compare_ptrs(
			   rawptr(uintptr(data) + at),
			   rawptr(uintptr(base) + at),
			   field_size(field),
		   ) !=
			   0 {
			append(
				&result,
				format.Scene_Field {
					name = field.name,
					hash = format.scene_field_hash(field.name),
					value = field_value(w, rawptr(uintptr(data) + at), field, ids, allocator),
				},
			)
		}
		if !field.has_override {
			continue
		}
		flag := (^bool)(uintptr(data) + uintptr(field.override_offset))^
		if flag != (^bool)(uintptr(base) + uintptr(field.override_offset))^ {
			name := strings.concatenate({field.name, OVERRIDE_SUFFIX}, allocator)
			append(
				&result,
				format.Scene_Field {
					name = name,
					hash = format.scene_field_hash(name),
					value = {kind = .Bool, ints = {0 = 1 if flag else 0}},
				},
			)
		}
	}
	return result[:]
}

// field_value is the value of the field at src, as a scene writes it.
field_value :: proc(
	w: ^ecs.World,
	src: rawptr,
	field: Field,
	ids: map[ecs.Entity]u64,
	allocator: runtime.Allocator,
) -> (
	v: format.Scene_Value,
) {
	switch field.kind {
	case .Bool:
		v = {
			kind = .Bool,
			ints = {0 = 1 if (^bool)(src)^ else 0},
		}
	case .I8, .I16, .I32, .I64, .U8, .U16, .U32, .U64:
		v = integer_value(get_integer(src, field.kind))
	case .F32:
		v = numbers(f64((^f32)(src)^))
	case .F64:
		v = numbers((^f64)(src)^)
	case .Enum:
		value := get_integer(src, field.enum_base)
		for e in field.enum_values {
			if e.value == value {
				return {kind = .Name, text = strings.clone(e.name, allocator)}
			}
		}
		v = integer_value(value)
	case .Vector3:
		x := (^[3]f32)(src)^
		v = numbers(f64(x[0]), f64(x[1]), f64(x[2]))
	case .Vector2:
		x := (^[2]f32)(src)^
		v = numbers(f64(x[0]), f64(x[1]))
	case .Quaternion:
		x := (^[4]f32)(src)^
		v = numbers(f64(x[0]), f64(x[1]), f64(x[2]), f64(x[3]))
	case .Position:
		p := (^ecs.World_Position)(src)^
		v = {
			kind    = .Number,
			count   = 3,
			integer = 0b111,
		}
		for raw, i in p.raw {
			v.ints[i] = raw
			v.floats[i] = f64(raw)
		}
	case .Entity:
		v = {
			kind   = .Entity,
			entity = scene_id_for(w, (^ecs.Entity)(src)^, ids),
		}
	case .Asset:
		v = {
			kind  = .Asset,
			asset = (^format.Guid)(src)^,
		}
	}
	return
}

// scene_id_for is an entity's scene ID: a draft's from ids, or its Scene_Entity's, or 0.
scene_id_for :: proc(w: ^ecs.World, e: ecs.Entity, ids: map[ecs.Entity]u64) -> u64 {
	if e == 0 {
		return 0
	}
	if id, ok := ids[e]; ok {
		return id
	}
	if s := (^Scene_Entity)(ecs.get_raw(w, e, SCENE_ENTITY_ID)); s != nil {
		return s.id
	}
	return 0
}

@(private = "file")
numbers :: proc(values: ..f64) -> (v: format.Scene_Value) {
	v.kind = .Number
	v.count = u8(len(values))
	copy(v.floats[:], values)
	return
}

@(private = "file")
integer_value :: proc(value: i64) -> format.Scene_Value {
	return {kind = .Number, count = 1, integer = 1, ints = {0 = value}, floats = {0 = f64(value)}}
}

// get_integer reads an integer of the kind. A u64 beyond i64's range keeps its bits, as put_integer takes it.
@(private = "file")
get_integer :: proc(src: rawptr, kind: Field_Kind) -> i64 {
	#partial switch kind {
	case .I8:
		return i64((^i8)(src)^)
	case .I16:
		return i64((^i16)(src)^)
	case .I32:
		return i64((^i32)(src)^)
	case .I64:
		return (^i64)(src)^
	case .U8:
		return i64((^u8)(src)^)
	case .U16:
		return i64((^u16)(src)^)
	case .U32:
		return i64((^u32)(src)^)
	case .U64:
		return i64((^u64)(src)^)
	}
	return 0
}
