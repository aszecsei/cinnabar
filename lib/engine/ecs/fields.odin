package ecs

import "base:runtime"

import format "cinnabar:engine/asset/format"

// Field_Kind is the kind of a component field that scenes, cutscenes, scripts and the editor read and write. The link
// has a mirror of it, link.Field_Kind, with asserts in editor/types.odin, so a new kind goes at the end.
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
	// An asset's GUID, format.Guid.
	Asset,
	// [2]f32.
	Vector2,
}

// Field_Traits is what every consumer of a field kind needs to know about it, in place of a switch of its own.
Field_Traits :: struct {
	// In bytes. An enum's is its base kind's, so its row is 0 (see field_size).
	size:       u8,
	align:      u8,
	// An integer of 8 to 64 bits, which read_integer and write_integer take. Bool and Enum are not.
	integer:    bool,
	signed:     bool,
	// A number or vector that blends between keys. F64 and Quaternion do not: a cutscene cannot animate an F64, and a
	// transform track animates a rotation.
	continuous: bool,
}

FIELD_TRAITS :: [Field_Kind]Field_Traits {
	.Bool = {size = 1, align = 1},
	.I8 = {size = 1, align = 1, integer = true, signed = true},
	.I16 = {size = 2, align = 2, integer = true, signed = true},
	.I32 = {size = 4, align = 4, integer = true, signed = true},
	.I64 = {size = 8, align = 8, integer = true, signed = true},
	.U8 = {size = 1, align = 1, integer = true},
	.U16 = {size = 2, align = 2, integer = true},
	.U32 = {size = 4, align = 4, integer = true},
	.U64 = {size = 8, align = 8, integer = true},
	.F32 = {size = 4, align = 4, continuous = true},
	.F64 = {size = 8, align = 8},
	.Enum = {},
	.Vector3 = {size = 12, align = 4, continuous = true},
	.Quaternion = {size = 16, align = 4},
	.Position = {size = 24, align = 8},
	.Entity = {size = 8, align = 8},
	.Asset = {size = 16, align = 1},
	.Vector2 = {size = 8, align = 4, continuous = true},
}

// field_size is the size in bytes of a field of the kind. enum_base is the integer kind of an enum.
field_size :: proc(kind: Field_Kind, enum_base: Field_Kind = .Bool) -> int {
	traits := FIELD_TRAITS
	return int(traits[enum_base if kind == .Enum else kind].size)
}

// Overflow is what an integer access does with a value outside the field kind's range. Each caller passes its own:
// scenes refuse a value that does not fit, and keep a u64's bits in an i64, so a loaded value writes back the same
// bytes; cutscenes clamp, because a blend can step past either end.
Overflow :: enum u8 {
	Refuse,
	Clamp,
}

// read_integer reads an integer field of the kind. A u64 beyond i64's range keeps its bits with Refuse, as
// write_integer takes it back, and saturates at max(i64) with Clamp.
read_integer :: proc(src: rawptr, kind: Field_Kind, overflow: Overflow) -> i64 {
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
		v := (^u64)(src)^
		return i64(min(v, u64(max(i64)))) if overflow == .Clamp else i64(v)
	}
	return 0
}

// write_integer writes an integer field of the kind. With Refuse, a value outside the kind's range writes nothing and
// gives false; a u64 takes the bits of any i64, as read_integer gives them. With Clamp, the value is clamped to the
// range, and a u64 takes a negative value as 0. A kind that is not an integer writes nothing and gives false.
write_integer :: proc(dst: rawptr, kind: Field_Kind, value: i64, overflow: Overflow) -> bool {
	put :: proc(dst: rawptr, value: i64, overflow: Overflow, $T: typeid) -> bool {
		low, high := i64(min(T)), i64(max(T))
		if value < low || value > high {
			if overflow == .Refuse {
				return false
			}
		}
		(^T)(dst)^ = T(clamp(value, low, high))
		return true
	}
	#partial switch kind {
	case .I8:
		return put(dst, value, overflow, i8)
	case .I16:
		return put(dst, value, overflow, i16)
	case .I32:
		return put(dst, value, overflow, i32)
	case .I64:
		(^i64)(dst)^ = value
	case .U8:
		return put(dst, value, overflow, u8)
	case .U16:
		return put(dst, value, overflow, u16)
	case .U32:
		return put(dst, value, overflow, u32)
	case .U64:
		(^u64)(dst)^ = u64(max(value, 0)) if overflow == .Clamp else u64(value)
	case:
		return false
	}
	return true
}

// field_kind_of is the field kind of a type, and for an enum the kind of its integer. It gives false for a type that
// is no field kind. What a package then does with the kind, such as which kinds it shows, is its own.
field_kind_of :: proc(ti: ^runtime.Type_Info) -> (kind, enum_base: Field_Kind, ok: bool) {
	switch ti.id {
	case World_Position:
		return .Position, {}, true
	case Entity:
		return .Entity, {}, true
	case format.Guid:
		return .Asset, {}, true
	}
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Float:
		switch ti.size {
		case 4:
			return .F32, {}, true
		case 8:
			return .F64, {}, true
		}
	case runtime.Type_Info_Integer:
		kind, ok = integer_kind(v.signed, ti.size)
		return
	case runtime.Type_Info_Boolean:
		return .Bool, {}, ti.size == 1
	case runtime.Type_Info_Enum:
		base := runtime.type_info_base(v.base).variant.(runtime.Type_Info_Integer)
		enum_base, ok = integer_kind(base.signed, ti.size)
		return .Enum, enum_base, ok
	case runtime.Type_Info_Array:
		if v.elem.id == f32 && (v.count == 2 || v.count == 3) {
			return .Vector2 if v.count == 2 else .Vector3, {}, true
		}
	case runtime.Type_Info_Quaternion:
		return .Quaternion, {}, ti.size == size_of(quaternion128)
	}
	return
}

@(private = "file")
integer_kind :: proc(signed: bool, size: int) -> (Field_Kind, bool) {
	kinds :=
		[4]Field_Kind{.I8, .I16, .I32, .I64} if signed else [4]Field_Kind{.U8, .U16, .U32, .U64}
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
