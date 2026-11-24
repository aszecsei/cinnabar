package ai

import "core:testing"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// Each projection takes the types that it is for, and refuses the rest, nil, which a String decodes to, among them.
@(test)
projections_take_their_types_and_refuse_the_rest :: proc(t: ^testing.T) {
	n, ok := value_number(f32(1.5))
	testing.expect(t, ok && n == 1.5)
	n, ok = value_number(i32(-4))
	testing.expect(t, ok && n == -4)
	n, ok = value_number(true)
	testing.expect(t, ok && n == 1)
	n, ok = value_number(false)
	testing.expect(t, ok && n == 0)
	for v in ([]Value{nil, Enum_Index(1), ecs.Entity(7), [3]f32{1, 2, 3}}) {
		_, ok = value_number(v)
		testing.expectf(t, !ok, "value_number(%v)", v)
	}

	home := ecs.position_offset({}, {1, 2, 3})
	p, placed := value_place(nil, home)
	testing.expect(t, placed && p == home)
	for v in ([]Value{nil, ecs.Entity(0), f32(1), [3]f32{1, 2, 3}}) {
		_, placed = value_place(nil, v)
		testing.expectf(t, !placed, "value_place(%v)", v)
	}

	x: i32
	x, ok = value_plan(true)
	testing.expect(t, ok && x == 1)
	x, ok = value_plan(i32(-9))
	testing.expect(t, ok && x == -9)
	x, ok = value_plan(Enum_Index(2))
	testing.expect(t, ok && x == 2)
	for v in ([]Value{nil, f32(1), ecs.Entity(7), home}) {
		_, ok = value_plan(v)
		testing.expectf(t, !ok, "value_plan(%v)", v)
	}
}

// A planning key's value goes through plan_value, encode, decode and value_plan unchanged.
@(test)
plan_values_round_trip :: proc(t: ^testing.T) {
	cases := []struct {
		type: format.Blackboard_Type,
		x:    i32,
		back: i32,
	} {
		{.Bool, 0, 0},
		{.Bool, 1, 1},
		{.Bool, 5, 1},
		{.Int, -7, -7},
		{.Int, max(i32), max(i32)},
		{.Enum, 3, 3},
	}
	for c in cases {
		type, bytes, ok := encode(plan_value(c.type, c.x))
		testing.expect(t, ok)
		testing.expect_value(t, type, c.type)
		back, is_plan := value_plan(decode(type, bytes[:]))
		testing.expect(t, is_plan)
		testing.expectf(t, back == c.back, "%v %d gave %d", c.type, c.x, back)
	}
	for type in ([]format.Blackboard_Type{.Float, .Entity, .Position, .Vector, .String}) {
		testing.expect_value(t, plan_value(type, 1), nil)
	}
}

// An argument converts to its parameter's type: a float to an int by truncation, an int to a float, and a vector to a
// position in meters. The same type passes as it is.
@(test)
arguments_convert_to_their_parameters_types :: proc(t: ^testing.T) {
	as_bytes :: proc(v: Value) -> [format.BLACKBOARD_VALUE_SIZE]byte {
		_, bytes, _ := encode(v)
		return bytes
	}
	got :: proc(type: format.Blackboard_Type, bytes: [format.BLACKBOARD_VALUE_SIZE]byte) -> Value {
		bytes := bytes
		return decode(type, bytes[:])
	}
	testing.expect_value(t, got(.Int, convert(.Float, .Int, as_bytes(f32(2.75)))), Value(i32(2)))
	testing.expect_value(t, got(.Int, convert(.Float, .Int, as_bytes(f32(-2.75)))), Value(i32(-2)))
	testing.expect_value(t, got(.Float, convert(.Int, .Float, as_bytes(i32(-3)))), Value(f32(-3)))
	testing.expect_value(
		t,
		got(.Position, convert(.Vector, .Position, as_bytes([3]f32{1, 2, 3}))),
		Value(ecs.position_offset({}, {1, 2, 3})),
	)
	testing.expect_value(
		t,
		got(.Entity, convert(.Entity, .Entity, as_bytes(ecs.Entity(9)))),
		Value(ecs.Entity(9)),
	)
	testing.expect_value(
		t,
		got(.Enum, convert(.Enum, .Enum, as_bytes(Enum_Index(1)))),
		Value(Enum_Index(1)),
	)
}
