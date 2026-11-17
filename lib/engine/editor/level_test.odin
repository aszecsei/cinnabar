package editor

import "base:runtime"
import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"

// Each test thread has a level of its own, as core has one: an arena, a count of its unloads, and the scenes' memory.
@(private = "file", thread_local)
test_level: virtual.Arena

@(private = "file", thread_local)
test_scene_memories: core.Scene_Memories

@(private = "file", thread_local)
test_level_unloads: u64

// use_test_level gives a test's platform the thread's level and scene memory, with level_unload, level_generation and
// the scene memory procs as core's.
@(private)
use_test_level :: proc(platform: ^core.Platform_API) {
	// What the thread's last test left open goes, so each test starts with every slot free.
	core.scene_memories_close_all(&test_scene_memories)
	platform.level_allocator = virtual.arena_allocator(&test_level)
	platform.level_unload = proc() {
		core.scene_memories_close_all(&test_scene_memories)
		virtual.arena_free_all(&test_level)
		test_level_unloads += 1
	}
	platform.level_generation = proc() -> u64 {
		return test_level_unloads
	}
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

@(private = "file")
Level_Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	editor:   Editor,
}

@(private = "file")
level_setup :: proc(t: ^testing.T) -> ^Level_Fixture {
	f := new(Level_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = context.allocator,
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
	}
	use_test_level(&f.platform)
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	scene.register_components(&f.world.registry)
	init(&f.editor, &f.platform, nil)
	return f
}

@(private = "file")
level_teardown :: proc(f: ^Level_Fixture) {
	destroy(&f.editor)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// The editor's scenes replace the level: loading them unloads it, and the maps from scene ID to entity are made in the
// new level's memory.
@(test)
the_editors_scenes_unload_the_level :: proc(t: ^testing.T) {
	f := level_setup(t)
	defer level_teardown(f)
	before := f.platform.level_generation()
	load_scenes(
		&f.editor,
		&f.world,
		nil,
		link.Load_Scene {
			scenes = {{scene = 1, entities = {{id = 0x51, name = "Door", active = true}}}},
		},
		nil,
	)
	testing.expect_value(t, f.platform.level_generation(), before + 1)
	testing.expect_value(t, f.editor.scenes.level, before + 1)
	door := scene.find(f.editor.scenes, &f.world, 1, 0x51)
	testing.expect(t, door != 0)
	// The scene's map is in the scene's own memory, which the level's unload closes.
	memory, loaded := scene.memory_of(f.editor.scenes, 1)
	testing.expect(t, loaded && f.platform.scene_memory_alive(memory))
	testing.expect_value(t, core.scene_memories_open_count(&test_scene_memories), 1)
	f.platform.level_unload()
	testing.expect(t, !f.platform.scene_memory_alive(memory))
}

// A scene that the game loads unloads the level, and with it the editor's maps. The next lookup builds them again in
// the new level, so the editor finds the new scene's entities and none of the old one's.
@(test)
the_maps_go_with_the_level_when_the_game_loads_a_scene :: proc(t: ^testing.T) {
	f := level_setup(t)
	defer level_teardown(f)
	load_scenes(
		&f.editor,
		&f.world,
		nil,
		link.Load_Scene {
			scenes = {{scene = 0, entities = {{id = 0x51, name = "Old", active = true}}}},
		},
		nil,
	)
	old := scene.find(f.editor.scenes, &f.world, 0, 0x51)
	testing.expect(t, old != 0)

	// As scene.load does.
	scene.unload_level(&f.world)
	testing.expect(t, !scene.has_maps(f.editor.scenes))
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, scene.Scene_Entity{id = 0x52})

	testing.expect_value(t, scene.find(f.editor.scenes, &f.world, 0, 0x51), 0)
	testing.expect_value(t, scene.find(f.editor.scenes, &f.world, 0, 0x52), e)
	testing.expect_value(t, f.editor.scenes.level, f.platform.level_generation())
}
