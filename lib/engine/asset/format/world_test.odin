package asset_format

import "core:testing"

@(private = "file")
test_world :: proc() -> []byte {
	a := guid_parse(TEST_GUID) or_else {}
	scenes := []World_Scene_Record {
		{guid = a, flags = {.Persistent}},
		{
			guid = Guid{1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
			min = {150_000_000_000 << 24, -10 << 24, -20 << 24},
			max = {(150_000_000_040) << 24, 10 << 24, 20 << 24},
			load_distance = 25,
			unload_distance = 40,
		},
	}
	return aligned(
		world_write(
			{key = 9, scenes = scenes, source_path = "game/levels/town.world"},
			context.temp_allocator,
		),
	)
}

@(test)
world_blobs_round_trip :: proc(t: ^testing.T) {
	data := test_world()
	blob, ok := world_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.header.key, 9)
	testing.expect_value(t, blob_string(data, blob.source_path), "game/levels/town.world")
	scenes := world_scenes(data, blob)
	testing.expect_value(t, len(scenes), 2)
	testing.expect_value(t, scenes[0].flags, World_Scene_Flags{.Persistent})
	testing.expect_value(t, scenes[1].min.x, 150_000_000_000 << 24)
	testing.expect_value(t, scenes[1].max.z, 20 << 24)
	testing.expect_value(t, scenes[1].load_distance, 25)
	testing.expect_value(t, scenes[1].unload_distance, 40)
	testing.expect_value(t, scenes[1].guid, Guid{1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})
}

@(test)
world_blobs_with_bad_slices_are_refused :: proc(t: ^testing.T) {
	data := test_world()
	blob, ok := world_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	size := blob.scenes.size
	blob.scenes.size = u32(len(data))
	_, ok = world_view(data)
	testing.expect(t, !ok, "scenes past the end")
	blob.scenes.size = size - 1
	_, ok = world_view(data)
	testing.expect(t, !ok, "a partial scene")
	blob.scenes.size = size
	blob.scenes.offset += 1
	_, ok = world_view(data)
	testing.expect(t, !ok, "misaligned scenes")
	blob.scenes.offset -= 1
	_, ok = world_view(data)
	testing.expect(t, ok)
	_, ok = world_view(data[:size_of(World_Blob) - 1])
	testing.expect(t, !ok)
	blob.header.kind = .Perception
	_, ok = world_view(data)
	testing.expect(t, !ok, "another kind")
}

@(test)
world_positions_are_exact_at_the_far_edge_of_the_range :: proc(t: ^testing.T) {
	raw, ok := world_raw_from_meters(150_000_000_000)
	testing.expect(t, ok)
	testing.expect_value(t, raw, 150_000_000_000 << WORLD_POSITION_FRACTION_BITS)
	raw, ok = world_raw_from_meters(-0.5)
	testing.expect(t, ok)
	testing.expect_value(t, raw, -(1 << 23))
	_, ok = world_raw_from_meters(1e12)
	testing.expect(t, !ok)
	_, ok = world_raw_from_meters(max(f64))
	testing.expect(t, !ok)
}
