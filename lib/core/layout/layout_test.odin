package layout

import "core:testing"

@(test)
hash_detects_changes :: proc(t: ^testing.T) {
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

	testing.expect_value(t, hash(A), hash(A))
	testing.expect(t, hash(A) != hash(Renamed))
	testing.expect(t, hash(A) != hash(Retyped))
	testing.expect(t, hash(Nested) != hash(Nested_Changed))

	E :: enum {
		A,
		B,
	}
	Reordered :: enum {
		B,
		A,
	}
	testing.expect(t, hash(E) != hash(Reordered))
}
