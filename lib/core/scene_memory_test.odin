package core

import "core:testing"

import "cinnabar:core/testlog"

@(test)
closing_a_scenes_memory_keeps_the_others :: proc(t: ^testing.T) {
	pool := new(Scene_Memories)
	defer free(pool)
	defer scene_memories_close_all(pool)

	north, north_ok := scene_memories_open(pool)
	south, south_ok := scene_memories_open(pool)
	testing.expect(t, north_ok && south_ok)
	testing.expect(t, north != south)

	north_data := make([]int, 1000, scene_memories_allocator(pool, north))
	south_data := make([]int, 1000, scene_memories_allocator(pool, south))
	for i in 0 ..< 1000 {
		north_data[i] = i
		south_data[i] = -i
	}

	slot, closed := scene_memories_close(pool, north)
	testing.expect(t, closed)
	testing.expect_value(t, slot, int(north.slot))
	testing.expect(t, !scene_memories_alive(pool, north), "a closed memory is not alive")
	testing.expect(t, scene_memories_alive(pool, south))
	for i in 0 ..< 1000 {
		if south_data[i] != -i {
			testing.fail_now(t, "the other scene's data changed")
		}
	}
	_, closed = scene_memories_close(pool, north)
	testing.expect(t, !closed, "a memory closes once")
	testing.expect_value(t, scene_memories_open_count(pool), 1)
}

@(test)
a_reopened_slot_does_not_revive_an_old_handle :: proc(t: ^testing.T) {
	pool := new(Scene_Memories)
	defer free(pool)
	defer scene_memories_close_all(pool)

	old, _ := scene_memories_open(pool)
	scene_memories_close(pool, old)
	again, ok := scene_memories_open(pool)
	testing.expect(t, ok)
	testing.expect_value(t, again.slot, old.slot)
	testing.expect(t, again.generation != old.generation)
	testing.expect(t, !scene_memories_alive(pool, old), "the old handle stays dead")
	testing.expect(t, scene_memories_alive(pool, again))
	testing.expect(t, !scene_memories_alive(pool, {}), "the zero handle names nothing")
}

@(test)
a_full_table_refuses_a_scene_and_close_all_empties_it :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	pool := new(Scene_Memories)
	defer free(pool)

	handles: [MAX_SCENE_MEMORY]Scene_Memory
	for &h in handles {
		ok: bool
		h, ok = scene_memories_open(pool)
		testing.expect(t, ok)
	}
	_, ok := scene_memories_open(pool)
	testing.expect(t, !ok, "a full table refuses")

	@(static) closed_slots: int
	closed_slots = 0
	count := scene_memories_close_all(pool, proc(slot: int) {closed_slots += 1})
	testing.expect_value(t, count, MAX_SCENE_MEMORY)
	testing.expect_value(t, closed_slots, MAX_SCENE_MEMORY)
	testing.expect_value(t, scene_memories_open_count(pool), 0)
	for h in handles {
		testing.expect(t, !scene_memories_alive(pool, h))
	}
}
