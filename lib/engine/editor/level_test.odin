package editor

import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"

// Each test thread has a level of its own, as core has one: an arena, and a count of its unloads.
@(private = "file", thread_local)
test_level: virtual.Arena

@(private = "file", thread_local)
test_level_unloads: u64

// use_test_level gives a test's platform the thread's level, with level_unload and level_generation as core's.
@(private)
use_test_level :: proc(platform: ^core.Platform_API) {
	platform.level_allocator = virtual.arena_allocator(&test_level)
	platform.level_unload = proc() {
		virtual.arena_free_all(&test_level)
		test_level_unloads += 1
	}
	platform.level_generation = proc() -> u64 {
		return test_level_unloads
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
		link.Load_Scene{scenes = {{scene = 1, entities = {{id = 0x51, name = "Door", active = true}}}}},
		nil,
	)
	testing.expect_value(t, f.platform.level_generation(), before + 1)
	testing.expect_value(t, f.editor.level, before + 1)
	door := find_scene_entity(&f.editor, &f.world, 1, 0x51)
	testing.expect(t, door != 0)
	testing.expect(t, test_level.total_used > 0)
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
		link.Load_Scene{scenes = {{scene = 0, entities = {{id = 0x51, name = "Old", active = true}}}}},
		nil,
	)
	old := find_scene_entity(&f.editor, &f.world, 0, 0x51)
	testing.expect(t, old != 0)

	// As scene.load does.
	scene.unload_level(&f.world)
	testing.expect_value(t, len(scene_maps(&f.editor)), 0)
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, scene.Scene_Entity{id = 0x52})

	testing.expect_value(t, find_scene_entity(&f.editor, &f.world, 0, 0x51), 0)
	testing.expect_value(t, find_scene_entity(&f.editor, &f.world, 0, 0x52), e)
	testing.expect_value(t, f.editor.level, f.platform.level_generation())
}
