package core

import "base:runtime"
import "core:log"
import "core:mem"
import "core:mem/virtual"

// The most scenes that have memory at once. scene_memories_open refuses one more.
MAX_SCENE_MEMORY :: 64

// The address range that each scene's memory reserves. Only the pages that it uses are committed.
SCENE_RESERVE :: 256 * mem.Megabyte

// Scene_Memories is the host's table of the memory of each loaded scene (see docs/core/jobs-and-memory.md#scene-memory).
// Each open slot is an arena in a range of its own, which closes with the range, so a scene that unloads gives its
// pages and its addresses back and leaves no holes. The table is the host's, so it survives code reload.
Scene_Memories :: struct {
	slots: [MAX_SCENE_MEMORY]Scene_Memory_Slot,
}

// Scene_Memory_Slot is one scene's memory. arena is nil while the slot is free.
Scene_Memory_Slot :: struct {
	arena:      Maybe(virtual.Arena),
	// Makes an old handle of this slot differ from the newest one. It counts from 1, so the zero handle names nothing.
	generation: u16,
}

// scene_memories_open gives a free slot an arena, and its handle, or false if every slot is open or the range cannot
// be reserved.
scene_memories_open :: proc(pool: ^Scene_Memories) -> (Scene_Memory, bool) {
	for &slot, i in pool.slots {
		if slot.arena != nil {
			continue
		}
		arena: virtual.Arena
		if err := virtual.arena_init_static(&arena, SCENE_RESERVE); err != nil {
			log.errorf("core: scene memory: %v", err)
			return {}, false
		}
		slot.arena = arena
		slot.generation += 1
		if slot.generation == 0 {
			slot.generation = 1
		}
		return {slot = u16(i), generation = slot.generation}, true
	}
	log.errorf("core: %d scenes have memory, which is the most", MAX_SCENE_MEMORY)
	return {}, false
}

// scene_memories_alive is whether the memory that the handle names is still open.
scene_memories_alive :: proc(pool: ^Scene_Memories, m: Scene_Memory) -> bool {
	return scene_memories_arena(pool, m) != nil
}

// scene_memories_allocator is the allocator of the memory that the handle names, or the nil allocator if it closed.
scene_memories_allocator :: proc(pool: ^Scene_Memories, m: Scene_Memory) -> runtime.Allocator {
	if arena := scene_memories_arena(pool, m); arena != nil {
		return virtual.arena_allocator(arena)
	}
	return runtime.nil_allocator()
}

// scene_memories_close frees the memory that the handle names, and gives its slot, or false if it was closed already.
scene_memories_close :: proc(pool: ^Scene_Memories, m: Scene_Memory) -> (slot: int, ok: bool) {
	arena := scene_memories_arena(pool, m)
	if arena == nil {
		return 0, false
	}
	virtual.arena_destroy(arena)
	pool.slots[m.slot].arena = nil
	return int(m.slot), true
}

// scene_memories_close_all frees every open memory, calls closed with each one's slot, and gives how many there were.
scene_memories_close_all :: proc(
	pool: ^Scene_Memories,
	closed: proc(slot: int) = nil,
) -> (
	count: int,
) {
	for slot, i in pool.slots {
		if slot.arena == nil {
			continue
		}
		scene_memories_close(pool, {slot = u16(i), generation = slot.generation})
		if closed != nil {
			closed(i)
		}
		count += 1
	}
	return
}

// scene_memories_open_count is how many memories are open.
scene_memories_open_count :: proc(pool: ^Scene_Memories) -> (count: int) {
	for slot in pool.slots {
		if slot.arena != nil {
			count += 1
		}
	}
	return
}

// The arena that a handle names, or nil if the handle is zero, or its memory closed.
@(private = "file")
scene_memories_arena :: proc(pool: ^Scene_Memories, m: Scene_Memory) -> ^virtual.Arena {
	if m.generation == 0 || int(m.slot) >= MAX_SCENE_MEMORY {
		return nil
	}
	slot := &pool.slots[m.slot]
	if slot.generation != m.generation || slot.arena == nil {
		return nil
	}
	return &slot.arena.?
}
