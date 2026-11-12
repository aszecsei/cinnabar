package asset_format

import "core:testing"

// test_board is a blackboard of one key of each type, at the runtime's alignment.
@(private = "file")
test_board :: proc() -> []byte {
	value :: proc(v: $T) -> (bytes: [BLACKBOARD_VALUE_SIZE]byte) {
		v := v
		(^T)(&bytes)^ = v
		return
	}
	contents := Blackboard_Contents {
		key = 9,
		keys = {
			{name = "alert", type = .Bool, default = value(u8(1))},
			{name = "health", type = .Float, default = value(f32(0.75))},
			{name = "mood", type = .Enum, enum_names = {"calm", "alert", "angry"}, default = value(u32(2))},
			{name = "target", type = .Entity},
			{name = "home", type = .Position, default = value([3]i64{1 << 24, 0, -(2 << 24)})},
			{name = "ammo", type = .Int, default = value(i32(-3))},
			{name = "heading", type = .Vector, default = value([3]f32{0, 0, 1})},
		},
		source_path = "game/ai/guard.blackboard",
	}
	return aligned(blackboard_write(contents, context.temp_allocator))
}

@(test)
blackboard_blobs_round_trip :: proc(t: ^testing.T) {
	data := test_board()
	blob, ok := blackboard_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.header.key, 9)
	testing.expect_value(t, blob_string(data, blob.source_path), "game/ai/guard.blackboard")
	keys := blackboard_keys(data, blob)
	testing.expect_value(t, len(keys), 7)
	// Each key is at its type's alignment, after the one before it, and the values' size is a multiple of 8.
	expected := [?]u32{0, 4, 8, 16, 24, 48, 52}
	for k, i in keys {
		testing.expect_value(t, k.offset, expected[i])
	}
	testing.expect_value(t, blob.values_size, 64)
	defaults := blob_bytes(data, blob.defaults)
	testing.expect_value(t, defaults[0], 1)
	testing.expect_value(t, (^f32)(&defaults[4])^, 0.75)
	testing.expect_value(t, (^u32)(&defaults[8])^, 2)
	testing.expect_value(t, (^u64)(&defaults[16])^, 0)
	testing.expect_value(t, (^[3]i64)(&defaults[24])^, [3]i64{1 << 24, 0, -(2 << 24)})
	testing.expect_value(t, (^i32)(&defaults[48])^, -3)
	testing.expect_value(t, (^[3]f32)(&defaults[52])^, [3]f32{0, 0, 1})

	testing.expect_value(t, blackboard_enum_name(data, blob, keys[2], 1), "alert")
	testing.expect_value(t, blackboard_enum_name(data, blob, keys[2], 3), "")
	slot, found := blackboard_find(data, blob, animation_graph_hash("target"))
	testing.expect(t, found)
	testing.expect_value(t, slot, 3)
	_, found = blackboard_find(data, blob, animation_graph_hash("nothing"))
	testing.expect(t, !found)
}

@(test)
blackboard_blobs_with_bad_keys_are_refused :: proc(t: ^testing.T) {
	data := test_board()
	blob, ok := blackboard_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	keys := blackboard_keys(data, blob)

	saved := keys[4].offset
	keys[4].offset = 48
	_, ok = blackboard_view(data)
	testing.expect(t, !ok, "a position past the values' end")
	keys[4].offset = 4
	_, ok = blackboard_view(data)
	testing.expect(t, !ok, "a position off its alignment")
	keys[4].offset = saved

	saved = keys[2].enum_count
	keys[2].enum_count = 4
	_, ok = blackboard_view(data)
	testing.expect(t, !ok, "an enum with more names than the blob has")
	keys[2].enum_count = saved

	keys[1].type = .String
	_, ok = blackboard_view(data)
	testing.expect(t, !ok, "a string key")
	keys[1].type = .Float

	_, ok = blackboard_view(data)
	testing.expect(t, ok)
	_, ok = blackboard_view(data[:size_of(Blackboard_Blob) - 1])
	testing.expect(t, !ok)
}
