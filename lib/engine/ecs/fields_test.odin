package ecs

import "base:runtime"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
Range :: struct {
	kind:      Field_Kind,
	low, high: i64,
}

@(private = "file")
RANGES :: [?]Range {
	{.I8, i64(min(i8)), i64(max(i8))},
	{.I16, i64(min(i16)), i64(max(i16))},
	{.I32, i64(min(i32)), i64(max(i32))},
	{.U8, 0, i64(max(u8))},
	{.U16, 0, i64(max(u16))},
	{.U32, 0, i64(max(u32))},
}

// Refuse writes a value in the kind's range and refuses one past either end, writing nothing.
@(test)
write_integer_refuses_a_value_outside_each_kinds_range :: proc(t: ^testing.T) {
	for r in RANGES {
		for v in ([2]i64{r.low, r.high}) {
			dst: u64 = 0xaaaaaaaaaaaaaaaa
			testing.expectf(t, write_integer(&dst, r.kind, v, .Refuse), "%v refused %d", r.kind, v)
			testing.expect_value(t, read_integer(&dst, r.kind, .Refuse), v)
		}
		for v in ([2]i64{r.low - 1, r.high + 1}) {
			dst: u64 = 0xaaaaaaaaaaaaaaaa
			testing.expectf(t, !write_integer(&dst, r.kind, v, .Refuse), "%v took %d", r.kind, v)
			testing.expect_value(t, dst, 0xaaaaaaaaaaaaaaaa)
		}
	}
	dst: i64
	testing.expect(t, write_integer(&dst, .I64, min(i64), .Refuse))
	testing.expect_value(t, read_integer(&dst, .I64, .Refuse), min(i64))
	testing.expect(t, !write_integer(&dst, .F32, 1, .Refuse))
	testing.expect(t, !write_integer(&dst, .Enum, 1, .Clamp))
}

// Clamp writes a value past either end of the kind's range as that end.
@(test)
write_integer_clamps_a_value_outside_each_kinds_range :: proc(t: ^testing.T) {
	for r in RANGES {
		dst: u64
		testing.expect(t, write_integer(&dst, r.kind, r.low - 1, .Clamp))
		testing.expect_value(t, read_integer(&dst, r.kind, .Clamp), r.low)
		testing.expect(t, write_integer(&dst, r.kind, r.high + 1, .Clamp))
		testing.expect_value(t, read_integer(&dst, r.kind, .Clamp), r.high)
	}
	dst: i64
	testing.expect(t, write_integer(&dst, .I64, max(i64), .Clamp))
	testing.expect_value(t, read_integer(&dst, .I64, .Clamp), max(i64))
}

// A u64 keeps its bits through an i64 with Refuse, as a scene writes it back, and saturates with Clamp.
@(test)
a_u64_keeps_its_bits_or_saturates :: proc(t: ^testing.T) {
	dst: u64
	testing.expect(t, write_integer(&dst, .U64, -1, .Refuse))
	testing.expect_value(t, dst, max(u64))
	testing.expect_value(t, read_integer(&dst, .U64, .Refuse), -1)
	testing.expect_value(t, read_integer(&dst, .U64, .Clamp), max(i64))
	testing.expect(t, write_integer(&dst, .U64, -1, .Clamp))
	testing.expect_value(t, dst, 0)
	testing.expect(t, write_integer(&dst, .U64, max(i64), .Clamp))
	testing.expect_value(t, dst, u64(max(i64)))
}

// Each kind's traits match the Odin type that holds it.
@(test)
field_traits_match_the_types :: proc(t: ^testing.T) {
	Expected :: struct {
		kind:        Field_Kind,
		size, align: int,
	}
	traits := FIELD_TRAITS
	for e in ([?]Expected{{.Bool, size_of(bool), align_of(bool)}, {.I8, size_of(i8), align_of(i8)}, {.I16, size_of(i16), align_of(i16)}, {.I32, size_of(i32), align_of(i32)}, {.I64, size_of(i64), align_of(i64)}, {.U8, size_of(u8), align_of(u8)}, {.U16, size_of(u16), align_of(u16)}, {.U32, size_of(u32), align_of(u32)}, {.U64, size_of(u64), align_of(u64)}, {.F32, size_of(f32), align_of(f32)}, {.F64, size_of(f64), align_of(f64)}, {.Vector3, size_of([3]f32), align_of([3]f32)}, {.Quaternion, size_of(quaternion128), 4}, {.Position, size_of(World_Position), align_of(World_Position)}, {.Entity, size_of(Entity), align_of(Entity)}, {.Asset, size_of(format.Guid), align_of(format.Guid)}, {.Vector2, size_of([2]f32), align_of([2]f32)}}) {
		testing.expectf(
			t,
			field_size(e.kind, .Bool) == e.size,
			"%v is %d bytes",
			e.kind,
			field_size(e.kind, .Bool),
		)
		testing.expectf(
			t,
			int(traits[e.kind].align) == e.align,
			"%v aligns to %d",
			e.kind,
			traits[e.kind].align,
		)
	}
	testing.expect_value(t, field_size(.Enum, .U16), 2)
	testing.expect_value(t, field_size(.Enum, .I64), 8)
	for kind in Field_Kind {
		integer := kind >= .I8 && kind <= .U64
		testing.expectf(t, traits[kind].integer == integer, "%v integer", kind)
		testing.expectf(t, traits[kind].signed == (kind >= .I8 && kind <= .I64), "%v signed", kind)
		continuous := kind == .F32 || kind == .Vector2 || kind == .Vector3
		testing.expectf(t, traits[kind].continuous == continuous, "%v continuous", kind)
	}
}

@(private = "file")
Sorts :: enum i16 {
	Low = -3,
	High,
}

@(private = "file")
Classified :: struct {
	on:       bool,
	count:    u32,
	rate:     f64,
	sort:     Sorts,
	at:       [3]f32,
	uv:       [2]f32,
	turn:     quaternion128,
	position: World_Position,
	target:   Entity,
	art:      format.Guid,
	wide:     [4]f32,
	name:     string,
}

@(test)
field_kind_of_classifies_each_type :: proc(t: ^testing.T) {
	Expected :: struct {
		kind, enum_base: Field_Kind,
		ok:              bool,
	}
	expected := [?]Expected {
		{.Bool, {}, true},
		{.U32, {}, true},
		{.F64, {}, true},
		{.Enum, .I16, true},
		{.Vector3, {}, true},
		{.Vector2, {}, true},
		{.Quaternion, {}, true},
		{.Position, {}, true},
		{.Entity, {}, true},
		{.Asset, {}, true},
		{{}, {}, false},
		{{}, {}, false},
	}
	s := runtime.type_info_base(type_info_of(Classified)).variant.(runtime.Type_Info_Struct)
	testing.expect_value(t, int(s.field_count), len(expected))
	for e, i in expected {
		kind, enum_base, ok := field_kind_of(s.types[i])
		testing.expectf(t, ok == e.ok, "%s ok %v", s.names[i], ok)
		if e.ok {
			testing.expectf(
				t,
				kind == e.kind && enum_base == e.enum_base,
				"%s is %v %v",
				s.names[i],
				kind,
				enum_base,
			)
		}
	}
}
