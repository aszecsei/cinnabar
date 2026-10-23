package engine

import "core:testing"

@(test)
layout_hash_detects_changes :: proc(t: ^testing.T) {
	A :: struct {
		x: i32,
		y: f32,
	}
	Renamed :: struct {
		x: i32,
		z: f32,
	}
	Retyped :: struct {
		x: i64,
		y: f32,
	}
	Nested :: struct {
		a: A,
	}
	Nested_Changed :: struct {
		a: Retyped,
	}

	testing.expect_value(t, layout_hash(A), layout_hash(A))
	testing.expect(t, layout_hash(A) != layout_hash(Renamed))
	testing.expect(t, layout_hash(A) != layout_hash(Retyped))
	testing.expect(t, layout_hash(Nested) != layout_hash(Nested_Changed))
}
