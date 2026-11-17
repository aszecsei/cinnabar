package scene

import "base:runtime"

import "cinnabar:core"

// Each test thread has a table of scene memory of its own, as core has one.
@(private = "file", thread_local)
test_scene_memories: core.Scene_Memories

// use_test_scene_memory gives a test's platform the thread's scene memory, with the procs as core's. Its level_unload
// calls close_test_scene_memory, as core's closes every scene's memory.
@(private)
use_test_scene_memory :: proc(platform: ^core.Platform_API) {
	platform.scene_memory_open = proc() -> (core.Scene_Memory, bool) {
		return core.scene_memories_open(&test_scene_memories)
	}
	platform.scene_memory_close = proc(m: core.Scene_Memory) {
		core.scene_memories_close(&test_scene_memories, m)
	}
	platform.scene_memory_alive = proc(m: core.Scene_Memory) -> bool {
		return core.scene_memories_alive(&test_scene_memories, m)
	}
	platform.scene_memory_allocator = proc(m: core.Scene_Memory) -> runtime.Allocator {
		return core.scene_memories_allocator(&test_scene_memories, m)
	}
}

// close_test_scene_memory closes every scene memory of the thread, and gives how many were open.
@(private)
close_test_scene_memory :: proc() -> int {
	return core.scene_memories_close_all(&test_scene_memories)
}

// open_test_scene_memory is how many scene memories of the thread are open.
@(private)
open_test_scene_memory :: proc() -> int {
	return core.scene_memories_open_count(&test_scene_memories)
}
