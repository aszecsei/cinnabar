package asset_format

import "core:mem"
import "core:testing"

// test_sheet is a sheet of four frames in a row of a 64 by 16 atlas, with a looping walk, a jump that ends, and a blink
// whose frames have their own durations.
@(private = "file")
test_sheet :: proc() -> []byte {
	frames := []Sprite_Frame_Contents {
		{name = "walk_0", rect = {0, 0, 16, 16}, pivot = {0.5, 0}},
		{name = "walk_1", rect = {16, 0, 16, 16}, pivot = {0.5, 0}},
		{name = "open", rect = {32, 0, 16, 16}, pivot = {0.5, 0.5}, duration = 0.5},
		{name = "shut", rect = {48, 0, 16, 16}, pivot = {0.5, 0.5}, duration = 0.25},
	}
	animations := []Sprite_Animation_Contents {
		{name = "walk", frames = {0, 1}, rate = 4, loop = true},
		{name = "jump", frames = {1, 0, 1}, rate = 2},
		{name = "blink", frames = {2, 3}, rate = 10, loop = true},
	}
	blob := sprite_sheet_write(
		{
			guid = {0 = 7},
			key = 9,
			atlas = {0 = 8},
			atlas_size = {64, 16},
			pixels_per_unit = 16,
			filter = .Nearest,
			frames = frames,
			animations = animations,
			source_path = "game/hero.sprite_sheet",
		},
		context.temp_allocator,
	)
	aligned, _ := mem.alloc_bytes(len(blob), BLOB_ALIGN, context.temp_allocator)
	copy(aligned, blob)
	return aligned
}

@(test)
a_sprite_sheet_blob_has_its_frames_and_animations_by_name :: proc(t: ^testing.T) {
	data := test_sheet()
	blob, ok := sprite_sheet_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.atlas, Guid{0 = 8})
	testing.expect_value(t, blob.atlas_size, [2]u32{64, 16})
	testing.expect_value(t, blob.pixels_per_unit, 16)
	testing.expect_value(t, blob.filter, Sprite_Filter.Nearest)
	testing.expect_value(t, blob_string(data, blob.source_path), "game/hero.sprite_sheet")
	frames := sprite_sheet_frames(data, blob)
	testing.expect_value(t, len(frames), 4)
	testing.expect_value(t, frames[1].rect, [4]u16{16, 0, 16, 16})
	testing.expect_value(t, frames[2].pivot, [2]f32{0.5, 0.5})
	testing.expect_value(t, blob_string(data, frames[3].name), "shut")
	index, found := sprite_sheet_find_frame(data, blob, "open")
	testing.expect(t, found && index == 2)
	_, found = sprite_sheet_find_frame(data, blob, "none")
	testing.expect(t, !found)
	animations := sprite_sheet_animations(data, blob)
	testing.expect_value(t, len(animations), 3)
	index, found = sprite_sheet_find_animation(data, blob, "jump")
	testing.expect(t, found && index == 1)
	testing.expect_value(t, animations[1].count, 3)
	testing.expect(t, !animations[1].loop && bool(animations[0].loop))
	_, found = sprite_sheet_find_animation(data, blob, "walk_0")
	testing.expect(t, !found)
}

@(test)
an_animation_shows_the_frame_of_its_time :: proc(t: ^testing.T) {
	data := test_sheet()
	blob, ok := sprite_sheet_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	at :: proc(data: []byte, blob: ^Sprite_Sheet_Blob, animation: int, time: f32) -> [2]int {
		frame, over := sprite_sheet_frame_at(data, blob, animation, time)
		return {frame, int(over)}
	}
	// The walk loops: a quarter of a second a frame.
	testing.expect_value(t, at(data, blob, 0, 0), [2]int{0, 0})
	testing.expect_value(t, at(data, blob, 0, 0.3), [2]int{1, 0})
	testing.expect_value(t, at(data, blob, 0, 0.55), [2]int{0, 0})
	testing.expect_value(t, at(data, blob, 0, 100.3), [2]int{1, 0})
	testing.expect_value(t, at(data, blob, 0, -1), [2]int{0, 0})
	// The jump holds its last frame, and is over.
	testing.expect_value(t, at(data, blob, 1, 0.6), [2]int{0, 0})
	testing.expect_value(t, at(data, blob, 1, 1.2), [2]int{1, 0})
	testing.expect_value(t, at(data, blob, 1, 1.5), [2]int{1, 1})
	testing.expect_value(t, at(data, blob, 1, 50), [2]int{1, 1})
	// The blink's frames have their own durations, whatever its rate.
	testing.expect_value(t, at(data, blob, 2, 0.4), [2]int{2, 0})
	testing.expect_value(t, at(data, blob, 2, 0.6), [2]int{3, 0})
	testing.expect_value(t, at(data, blob, 2, 0.8), [2]int{2, 0})
	// No such animation.
	testing.expect_value(t, at(data, blob, 3, 0), [2]int{0, 1})
	testing.expect_value(t, at(data, blob, -1, 0), [2]int{0, 1})
}

@(test)
a_sprite_sheet_blob_that_is_wrong_is_refused :: proc(t: ^testing.T) {
	good := test_sheet()
	_, ok := sprite_sheet_view(good)
	testing.expect(t, ok)
	broken :: proc(good: []byte) -> ([]byte, ^Sprite_Sheet_Blob) {
		data, _ := mem.alloc_bytes(len(good), BLOB_ALIGN, context.temp_allocator)
		copy(data, good)
		return data, (^Sprite_Sheet_Blob)(raw_data(data))
	}
	// Another kind's blob, and one cut short.
	data, blob := broken(good)
	blob.header.kind = .Font
	_, ok = sprite_sheet_view(data)
	testing.expect(t, !ok)
	_, ok = sprite_sheet_view(good[:len(good) - 40])
	testing.expect(t, !ok)
	// A frame outside the atlas.
	data, blob = broken(good)
	sprite_sheet_frames(data, blob)[3].rect.z = 17
	_, ok = sprite_sheet_view(data)
	testing.expect(t, !ok)
	// An animation of a frame that the sheet does not have, and one past the indices.
	data, blob = broken(good)
	sprite_sheet_frame_indices(data, blob)[0] = 4
	_, ok = sprite_sheet_view(data)
	testing.expect(t, !ok)
	data, blob = broken(good)
	sprite_sheet_animations(data, blob)[2].count = 3
	_, ok = sprite_sheet_view(data)
	testing.expect(t, !ok)
	// No texels to a meter.
	data, blob = broken(good)
	blob.pixels_per_unit = 0
	_, ok = sprite_sheet_view(data)
	testing.expect(t, !ok)
}
