package scene

import "base:runtime"
import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

@(private = "file")
BASE_GUID :: format.Guid {
	0 = 0xba,
}
@(private = "file")
NIGHT_GUID :: format.Guid {
	0 = 0x11,
}
@(private = "file")
LAMP :: u64(0x1a)
@(private = "file")
BULB :: u64(0x1b)
@(private = "file")
SWITCH :: u64(0x5c)

@(private = "file")
Move_Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	scenes:   Scenes,
}

@(private = "file", thread_local)
move_level_unloads: u64

@(private = "file")
setup :: proc(t: ^testing.T) -> ^Move_Fixture {
	f := new(Move_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
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
		level_allocator = virtual.arena_allocator(&f.frame),
		level_unload = proc() {
			close_test_scene_memory()
			move_level_unloads += 1
		},
		level_generation = proc() -> u64 {
			return move_level_unloads
		},
	}
	use_test_scene_memory(&f.platform)
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	ecs.register_component(&f.world.registry, Probe, PROBE_ID)
	init_scenes(&f.scenes, &f.platform)
	return f
}

@(private = "file")
teardown :: proc(f: ^Move_Fixture) {
	destroy_scenes(&f.scenes)
	close_test_scene_memory()
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// points_at is a Probe whose target is the entity with the scene ID, in the scene with the GUID, or zero for its own.
@(private = "file")
points_at :: proc(id: u64, scene: format.Guid = {}) -> []format.Scene_Component {
	fields := make([]format.Scene_Field, 1, context.temp_allocator)
	fields[0] = {
		name = "target",
		hash = format.scene_field_hash("target"),
		value = {kind = .Entity, entity = id, scene = scene},
	}
	components := make([]format.Scene_Component, 1, context.temp_allocator)
	components[0] = {
		id     = u64(PROBE_ID),
		name   = "Probe",
		fields = fields,
	}
	return components
}

// A base with a switch that points at the night's lamp, and the night's part with the lamp and its bulb.
@(private = "file")
load_room :: proc(t: ^testing.T, f: ^Move_Fixture) -> (base, night: u32) {
	w := &f.world
	base_entities := []format.Scene_Entity {
		{id = SWITCH, active = true, components = points_at(LAMP, NIGHT_GUID)},
	}
	ok: bool
	base, ok = add_scene(w, nil, &f.scenes, {entities = base_entities, guid = BASE_GUID}, 1)
	testing.expect(t, ok)
	night_entities := []format.Scene_Entity {
		{id = LAMP, active = true},
		{id = BULB, parent = LAMP, active = true, components = points_at(SWITCH, BASE_GUID)},
	}
	night, ok = add_scene(
		w,
		nil,
		&f.scenes,
		{entities = night_entities, guid = NIGHT_GUID},
		2,
		nil,
		Part_Of{base, format.sublevel_name("night")},
	)
	testing.expect(t, ok)
	return
}

// The editor adds a part beside its base, and a reference across the parts holds its target while both are loaded.
@(test)
a_part_from_the_editor_names_its_base :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	base, night := load_room(t, f)
	w := &f.world
	testing.expect_value(t, base_of(&f.scenes, night) or_else 0, base)
	name, is_part := sublevel_of(&f.scenes, night)
	testing.expect(t, is_part)
	testing.expect_value(t, format.sublevel_name_text(&name), "night")

	lamp := find(&f.scenes, w, night, LAMP)
	switch_ := find(&f.scenes, w, base, SWITCH)
	bulb := find(&f.scenes, w, night, BULB)
	testing.expect(t, lamp != 0 && switch_ != 0 && bulb != 0)
	testing.expect_value(t, ecs.get(w, switch_, Probe).target, lamp)
	testing.expect_value(t, ecs.get(w, bulb, Probe).target, switch_)

	// A part whose base is not loaded is refused.
	_, ok := add_scene(w, nil, &f.scenes, {}, 9, nil, Part_Of{7, format.sublevel_name("night")})
	testing.expect(t, !ok)
}

// An entity that moves to another part keeps its handle, and so do its descendants. The maps, the links that they hold
// and the links bound to them follow, so unloading the part that they left does not touch them.
@(test)
a_moved_entity_keeps_its_handle_and_its_links :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	base, night := load_room(t, f)
	w := &f.world
	lamp := find(&f.scenes, w, night, LAMP)
	bulb := find(&f.scenes, w, night, BULB)
	switch_ := find(&f.scenes, w, base, SWITCH)

	moved, ok := move_entities(w, &f.scenes, lamp, night, base)
	testing.expect(t, ok)
	testing.expect_value(t, moved, 2)
	testing.expect_value(t, find(&f.scenes, w, base, LAMP), lamp)
	testing.expect_value(t, find(&f.scenes, w, base, BULB), bulb)
	testing.expect_value(t, find(&f.scenes, w, night, LAMP), 0)
	testing.expect_value(t, key_of(w, bulb), Key{base, BULB})
	testing.expect_value(t, scene_size(&f.scenes, night), 0)

	// The night part goes, and the lamp, the bulb and the fields that link them stay.
	testing.expect_value(t, unload_scene(w, &f.scenes, night), 0)
	testing.expect(t, ecs.is_alive(w, lamp) && ecs.is_alive(w, bulb))
	testing.expect_value(t, ecs.get(w, switch_, Probe).target, lamp)
	testing.expect_value(t, ecs.get(w, bulb, Probe).target, switch_)

	// Moving back to a new part of the night: the switch's link follows the lamp there, and goes when it unloads.
	again, added := add_scene(
		w,
		nil,
		&f.scenes,
		{guid = NIGHT_GUID},
		3,
		nil,
		Part_Of{base, format.sublevel_name("night")},
	)
	testing.expect(t, added)
	_, ok = move_entities(w, &f.scenes, lamp, base, again)
	testing.expect(t, ok)
	testing.expect_value(t, find(&f.scenes, w, again, BULB), bulb)
	unload_scene(w, &f.scenes, again)
	testing.expect(t, !ecs.is_alive(w, lamp))
	testing.expect_value(t, ecs.get(w, switch_, Probe).target, 0)
}

// A move from a scene that the entity is not in, or to a scene that is not loaded, changes nothing.
@(test)
a_move_that_does_not_fit_changes_nothing :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	base, night := load_room(t, f)
	w := &f.world
	lamp := find(&f.scenes, w, night, LAMP)
	_, ok := move_entities(w, &f.scenes, lamp, base, night)
	testing.expect(t, !ok)
	_, ok = move_entities(w, &f.scenes, lamp, night, 42)
	testing.expect(t, !ok)
	testing.expect_value(t, find(&f.scenes, w, night, LAMP), lamp)
}
