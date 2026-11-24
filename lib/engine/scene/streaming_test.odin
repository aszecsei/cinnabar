package scene

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// Each test thread has a level of its own, as core has one: an arena, and a count of its unloads.
@(private = "file", thread_local)
level: virtual.Arena

@(private = "file", thread_local)
level_unloads: u64

// A door and its hinge, a child that refers to it.
@(private = "file")
NORTH :: `scene 2
entity 00000000000000d1
name = "Door"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]

entity 00000000000000d2
name = "Hinge"
parent = @00000000000000d1
component 100 Probe
	target = @00000000000000d1
`

// The same scene IDs as NORTH, in another scene, with a disabled entity.
@(private = "file")
SOUTH :: `scene 2
entity 00000000000000d1
name = "Door"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]

entity 00000000000000d2
name = "Hinge"
parent = @00000000000000d1
active = false
component 100 Probe
	target = @00000000000000d1
`

// A gate whose probe refers to the door of NORTH, in another scene.
@(private = "file")
GATE :: `scene 3
entity 00000000000000a1
name = "Gate"
component 100 Probe
	target = @51000000000000000000000000000001/00000000000000d1
`

@(private = "file")
TURRET :: `scene 2
entity 1000000000000001
name = "Turret"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]

entity 1000000000000002
name = "Barrel"
parent = @1000000000000001
component 2 Local_Transform
	offset = [0, 1, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
`

@(private = "file")
NORTH_GUID :: format.Guid {
	0  = 0x51,
	15 = 1,
}

@(private = "file")
SOUTH_GUID :: format.Guid {
	0  = 0x52,
	15 = 1,
}

@(private = "file")
GATE_GUID :: format.Guid {
	0  = 0x53,
	15 = 1,
}

@(private = "file")
TURRET_GUID :: format.Guid {
	0  = 0x7e,
	15 = 2,
}

@(private = "file")
Streaming_Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	assets:   asset.Assets,
	scenes:   Scenes,
	dir:      string,
}

@(private = "file")
setup :: proc(t: ^testing.T) -> ^Streaming_Fixture {
	f := new(Streaming_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		file_size = core.file_size,
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
		level_allocator = virtual.arena_allocator(&level),
		level_unload = proc() {
			close_test_scene_memory()
			virtual.arena_free_all(&level)
			level_unloads += 1
		},
		level_generation = proc() -> u64 {
			return level_unloads
		},
	}
	use_test_scene_memory(&f.platform)
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	ecs.register_component(&f.world.registry, Probe, PROBE_ID)
	temp, err := os.make_directory_temp("", "streaming_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	init_scenes(&f.scenes, &f.platform, &f.assets)
	write_blob(t, f, NORTH_GUID, NORTH, .Scene)
	write_blob(t, f, SOUTH_GUID, SOUTH, .Scene)
	write_blob(t, f, TURRET_GUID, TURRET, .Prefab)
	write_blob(t, f, GATE_GUID, GATE, .Scene)
	return f
}

@(private = "file")
teardown :: proc(f: ^Streaming_Fixture) {
	destroy_scenes(&f.scenes)
	asset.destroy(&f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	virtual.arena_destroy(&level)
	close_test_scene_memory()
	free(f)
}

// write_blob writes a scene as a blob of a kind, as the cooker would.
@(private = "file")
write_blob :: proc(
	t: ^testing.T,
	f: ^Streaming_Fixture,
	guid: format.Guid,
	text: string,
	kind: format.Asset_Kind,
) {
	s, problems, ok := format.scene_parse(text, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	blob := format.scene_write(s, guid, 1, kind, allocator = context.temp_allocator)
	buffer: [32]u8
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(guid, &buffer)),
			blob,
		) ==
		nil,
	)
}

@(private = "file")
is_resident :: proc(f: ^Streaming_Fixture, guid: format.Guid) -> bool {
	_, loaded := asset.find(&f.assets, guid)
	return loaded
}

// Two scenes with the same scene IDs load side by side, each resolving its own. Unloading the first leaves the
// second's entities, their references and their parents as they were, and the world's scenes keep only its GUID.
@(test)
unloading_one_scene_keeps_the_other :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	game := ecs.spawn(w)
	north, north_ok := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	south, south_ok := add_scene_asset(w, nil, &f.scenes, SOUTH_GUID)
	testing.expect(t, north_ok && south_ok)
	testing.expect(t, north != south)
	testing.expect_value(t, north, FIRST_RUNTIME_SCENE)
	testing.expect_value(t, len(ecs.world_scenes(w)), 2)
	testing.expect_value(t, ecs.world_scenes(w)[0], NORTH_GUID)
	testing.expect_value(t, ecs.world_scenes(w)[1], SOUTH_GUID)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 2)

	north_door := find(&f.scenes, w, north, 0xd1)
	door := find(&f.scenes, w, south, 0xd1)
	hinge := find(&f.scenes, w, south, 0xd2)
	testing.expect(t, north_door != 0 && door != 0 && hinge != 0)
	testing.expect(t, north_door != door)
	testing.expect_value(t, ecs.get(w, hinge, Probe).target, door)

	before := ecs.entity_count(w)
	testing.expect_value(t, unload_scene(w, &f.scenes, north), 2)
	testing.expect_value(t, ecs.entity_count(w), before - 2)
	testing.expect(t, !ecs.is_alive(w, north_door))
	testing.expect_value(t, find(&f.scenes, w, north, 0xd1), 0)
	testing.expect(t, !is_resident(f, NORTH_GUID))
	testing.expect_value(t, len(ecs.world_scenes(w)), 1)
	testing.expect_value(t, ecs.world_scenes(w)[0], SOUTH_GUID)

	// The second scene, the inactive hinge with it, and the game's own entity stay.
	testing.expect(t, ecs.is_alive(w, game))
	testing.expect_value(t, find(&f.scenes, w, south, 0xd1), door)
	testing.expect_value(t, find(&f.scenes, w, south, 0xd2), hinge)
	testing.expect_value(t, ecs.get(w, hinge, Probe).target, door)
	testing.expect_value(t, ecs.get(w, hinge, ecs.Parent).entity, door)
	testing.expect(t, is_resident(f, SOUTH_GUID))

	unload_scene(w, &f.scenes, south)
	testing.expect_value(t, len(ecs.world_scenes(w)), 0)
	testing.expect_value(t, ecs.entity_count(w), 1)
}

// A scene that loads, unloads and loads again leaves nothing behind: no entity, no blob and no table entry, and its
// entities take the freed slots.
@(test)
loading_a_scene_again_leaks_nothing :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	slots: u32
	for round in 0 ..< 3 {
		number, ok := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
		testing.expect(t, ok)
		testing.expect_value(t, ecs.entity_count(w), 2)
		testing.expect(t, is_resident(f, NORTH_GUID))
		if round == 0 {
			slots = ecs.slot_count(w)
		}
		testing.expect_value(t, ecs.slot_count(w), slots)
		testing.expect(t, find(&f.scenes, w, number, 0xd2) != 0)

		testing.expect_value(t, open_test_scene_memory(), 1)
		unload_scene(w, &f.scenes, number)
		testing.expect_value(t, ecs.entity_count(w), 0)
		testing.expect_value(t, open_test_scene_memory(), 0)
		testing.expect(t, !is_resident(f, NORTH_GUID))
		testing.expect_value(t, len(loaded_scenes(&f.scenes)), 0)
	}
}

// A prefab that a scene owns goes when the scene unloads, with its children. A prefab that the game spawned stays.
@(test)
an_owned_prefab_goes_with_its_scene :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	number, _ := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	owned, owned_ok := spawn_prefab(w, nil, &f.assets, TURRET_GUID, ecs.TRANSFORM_IDENTITY, number)
	global, global_ok := spawn_prefab(w, nil, &f.assets, TURRET_GUID, ecs.TRANSFORM_IDENTITY)
	testing.expect(t, owned_ok && global_ok)
	owner, has := scene_of(w, owned)
	testing.expect(t, has)
	testing.expect_value(t, owner, number)
	_, global_has := scene_of(w, global)
	testing.expect(t, !global_has)

	// The scene's two entities, the owned turret and its barrel.
	testing.expect_value(t, unload_scene(w, &f.scenes, number), 4)
	testing.expect(t, !ecs.is_alive(w, owned))
	testing.expect(t, ecs.is_alive(w, global))
	testing.expect_value(t, ecs.entity_count(w), 2)
}

// A scene's number is never taken twice, and the editor's numbers stay apart from the game's.
@(test)
a_loaded_number_is_refused :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	_, first := add_scene_asset(w, nil, &f.scenes, NORTH_GUID, u32(1))
	testing.expect(t, first)
	_, again := add_scene_asset(w, nil, &f.scenes, SOUTH_GUID, u32(1))
	testing.expect(t, !again)
	// The refused scene's blob goes back.
	testing.expect(t, !is_resident(f, SOUTH_GUID))
	reserved := reserve_number(&f.scenes)
	testing.expect_value(t, reserved, FIRST_RUNTIME_SCENE)
	next, _ := add_scene_asset(w, nil, &f.scenes, SOUTH_GUID)
	testing.expect_value(t, next, reserved + 1)
}

// A scene load replaces every scene: the level unloads, and the scenes and their blobs go with it.
@(test)
a_scene_load_unloads_every_scene :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	testing.expect(t, load_asset(w, nil, &f.assets, SOUTH_GUID, &f.scenes))
	loaded := loaded_scenes(&f.scenes)
	testing.expect_value(t, len(loaded), 1)
	testing.expect_value(t, loaded[0].number, 0)
	testing.expect(t, !is_resident(f, NORTH_GUID))
	testing.expect(t, find(&f.scenes, w, 0, 0xd1) != 0)
	testing.expect_value(t, ecs.entity_count(w), 2)

	unload_level(w, &f.scenes)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 0)
	testing.expect(t, !is_resident(f, SOUTH_GUID))
	testing.expect_value(t, open_test_scene_memory(), 0)
}

// Each scene's data is in its own memory. A holder keeps the scene's memory handle beside its data, and drops the data
// once the handle is not alive: when its scene unloads, the other scene's data and IDs stay.
@(test)
a_holder_drops_the_data_of_a_scene_that_unloaded :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	Holder :: struct {
		memory: core.Scene_Memory,
		data:   []int,
	}
	hold :: proc(f: ^Streaming_Fixture, number: u32, value: int) -> Holder {
		memory, _ := memory_of(&f.scenes, number)
		data := make([]int, 64, allocator_of(&f.scenes, number))
		for &d in data {
			d = value
		}
		return {memory, data}
	}
	// What the holder reads: its data while its scene's memory is alive, or nothing once the scene is gone.
	read :: proc(f: ^Streaming_Fixture, h: ^Holder) -> []int {
		if !f.platform.scene_memory_alive(h.memory) {
			h^ = {}
		}
		return h.data
	}

	north, _ := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	south, _ := add_scene_asset(w, nil, &f.scenes, SOUTH_GUID)
	north_holder := hold(f, north, 1)
	south_holder := hold(f, south, 2)
	testing.expect(t, north_holder.memory != south_holder.memory)
	testing.expect_value(t, open_test_scene_memory(), 2)

	old_memory := north_holder.memory
	unload_scene(w, &f.scenes, north)
	testing.expect_value(t, open_test_scene_memory(), 1)
	testing.expect(t, read(f, &north_holder) == nil, "the holder drops the unloaded scene's data")
	_, has := memory_of(&f.scenes, north)
	testing.expect(t, !has)

	south_data := read(f, &south_holder)
	testing.expect_value(t, len(south_data), 64)
	for d in south_data {
		testing.expect_value(t, d, 2)
	}
	testing.expect(t, find(&f.scenes, w, south, 0xd1) != 0)

	// Loading again takes the freed memory, and the old handle stays dead.
	again, _ := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	again_memory, _ := memory_of(&f.scenes, again)
	testing.expect_value(t, again_memory.slot, old_memory.slot)
	testing.expect(t, !f.platform.scene_memory_alive(old_memory))
	testing.expect(t, f.platform.scene_memory_alive(again_memory))
	testing.expect(t, find(&f.scenes, w, again, 0xd2) != 0)

	// The level takes every scene's memory with it.
	unload_level(w, &f.scenes)
	testing.expect(t, read(f, &south_holder) == nil)
	testing.expect_value(t, open_test_scene_memory(), 0)
}

// A field that names an entity of another scene reads none while that scene is not loaded, is that scene's entity
// while it is, and is none again once it unloads. A scene that loads again gives the field its new entity.
@(test)
a_reference_across_scenes_follows_its_scene :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	gate_scene, gate_ok := add_scene_asset(w, nil, &f.scenes, GATE_GUID)
	testing.expect(t, gate_ok)
	gate := find(&f.scenes, w, gate_scene, 0xa1)
	target :: proc(f: ^Streaming_Fixture, gate: ecs.Entity) -> ecs.Entity {
		return ecs.get(&f.world, gate, Probe).target
	}
	testing.expect_value(t, target(f, gate), 0)
	waiting, is_waiting := pending(&f.scenes, w, gate, PROBE_ID, "target")
	testing.expect(t, is_waiting)
	testing.expect_value(t, waiting, NORTH_GUID)

	north, north_ok := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	testing.expect(t, north_ok)
	door := find(&f.scenes, w, north, 0xd1)
	testing.expect(t, door != 0)
	testing.expect_value(t, target(f, gate), door)
	_, is_waiting = pending(&f.scenes, w, gate, PROBE_ID, "target")
	testing.expect(t, !is_waiting)

	unload_scene(w, &f.scenes, north)
	testing.expect_value(t, target(f, gate), 0)
	waiting, is_waiting = pending(&f.scenes, w, gate, PROBE_ID, "target")
	testing.expect(t, is_waiting)
	testing.expect_value(t, waiting, NORTH_GUID)

	again, _ := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	new_door := find(&f.scenes, w, again, 0xd1)
	testing.expect(t, new_door != 0)
	testing.expect_value(t, target(f, gate), new_door)

	// The holder going leaves nothing to follow, and the target going after it is no trouble.
	unload_scene(w, &f.scenes, gate_scene)
	testing.expect_value(t, unload_scene(w, &f.scenes, again), 2)
}

// A gate that loads after its target is bound when it loads, and a second scene with the target's GUID takes over
// when the first unloads.
@(test)
a_reference_across_scenes_moves_to_another_scene_with_the_guid :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	first, _ := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	second, _ := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	gate_scene, _ := add_scene_asset(w, nil, &f.scenes, GATE_GUID)
	gate := find(&f.scenes, w, gate_scene, 0xa1)
	first_door := find(&f.scenes, w, first, 0xd1)
	second_door := find(&f.scenes, w, second, 0xd1)
	testing.expect_value(t, ecs.get(w, gate, Probe).target, first_door)

	unload_scene(w, &f.scenes, first)
	testing.expect_value(t, ecs.get(w, gate, Probe).target, second_door)
	_, is_waiting := pending(&f.scenes, w, gate, PROBE_ID, "target")
	testing.expect(t, !is_waiting)
	unload_scene(w, &f.scenes, second)
	testing.expect_value(t, ecs.get(w, gate, Probe).target, 0)
}

// A value that something else wrote into the field since the link wrote it stays when the scene loads.
@(test)
a_reference_across_scenes_does_not_overwrite_a_newer_value :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	gate_scene, _ := add_scene_asset(w, nil, &f.scenes, GATE_GUID)
	gate := find(&f.scenes, w, gate_scene, 0xa1)
	other := ecs.spawn(w)
	ecs.get(w, gate, Probe).target = other
	add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	testing.expect_value(t, ecs.get(w, gate, Probe).target, other)
	_, is_waiting := pending(&f.scenes, w, gate, PROBE_ID, "target")
	testing.expect(t, !is_waiting)
}

// An edit that sets the field to a local entity ends the link, so the target loading leaves it as it is.
@(test)
setting_a_field_ends_its_link :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	gate_scene, _ := add_scene_asset(w, nil, &f.scenes, GATE_GUID)
	gate := find(&f.scenes, w, gate_scene, 0xa1)
	handles := handles_of(&f.scenes, gate_scene)
	handles[0xa2] = gate
	field := format.Scene_Field {
		name = "target",
		hash = format.scene_field_hash("target"),
		value = {kind = .Entity, entity = 0xa2},
	}
	testing.expect(
		t,
		set_field(w, gate, 0xa1, u64(PROBE_ID), field, false, handles, nil, &f.scenes),
	)
	testing.expect_value(t, ecs.get(w, gate, Probe).target, gate)
	_, is_waiting := pending(&f.scenes, w, gate, PROBE_ID, "target")
	testing.expect(t, !is_waiting)
	add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	testing.expect_value(t, ecs.get(w, gate, Probe).target, gate)
}

// A field that holds an entity of another scene is written with that scene's GUID, and one in its own scene without.
@(test)
a_reference_across_scenes_encodes_with_its_scenes_guid :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	gate_scene, _ := add_scene_asset(w, nil, &f.scenes, GATE_GUID)
	north, _ := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	gate := find(&f.scenes, w, gate_scene, 0xa1)
	hinge := find(&f.scenes, w, north, 0xd2)
	info := ecs.registry_find(&w.registry, PROBE_ID)
	encode :: proc(
		f: ^Streaming_Fixture,
		info: ^ecs.Component_Info,
		entity: ecs.Entity,
		holder: u32,
	) -> format.Scene_Value {
		fields := encode_fields(
			&f.world,
			info,
			ecs.get_raw(&f.world, entity, PROBE_ID),
			nil,
			nil,
			context.temp_allocator,
			scenes = &f.scenes,
			holder = holder,
		)
		for field in fields {
			if field.name == "target" {
				return field.value
			}
		}
		return {}
	}
	across := encode(f, info, gate, gate_scene)
	testing.expect_value(t, across.scene, NORTH_GUID)
	testing.expect_value(t, across.entity, 0xd1)
	within := encode(f, info, hinge, north)
	testing.expect_value(t, within.scene, format.Guid{})
	testing.expect_value(t, within.entity, 0xd1)
}

// A draft, an entity in ids, is new in the document, so a reference to it names no other scene, whatever scene owns it.
@(test)
a_reference_to_a_draft_names_no_other_scene :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	gate_scene, _ := add_scene_asset(w, nil, &f.scenes, GATE_GUID)
	north, _ := add_scene_asset(w, nil, &f.scenes, NORTH_GUID)
	target := find(&f.scenes, w, north, 0xd1)
	ids := make(map[ecs.Entity]u64, context.temp_allocator)
	ids[target] = 0x99
	id, other := encode_entity_ref(w, target, ids, &f.scenes, gate_scene)
	testing.expect_value(t, id, 0x99)
	testing.expect_value(t, other, format.Guid{})
	// The gate's Probe holds the target, so its component's fields name the draft by its new ID alone.
	gate := find(&f.scenes, w, gate_scene, 0xa1)
	encoded := false
	for field in encode_fields(w, ecs.registry_find(&w.registry, PROBE_ID), ecs.get_raw(w, gate, PROBE_ID), nil, ids, context.temp_allocator, scenes = &f.scenes, holder = gate_scene) {
		if field.name == "target" {
			encoded = true
			testing.expect_value(t, field.value.entity, 0x99)
			testing.expect_value(t, field.value.scene, format.Guid{})
		}
	}
	testing.expect(t, encoded)
	delete_key(&ids, target)
	id, other = encode_entity_ref(w, target, ids, &f.scenes, gate_scene)
	testing.expect_value(t, id, 0xd1)
	testing.expect_value(t, other, NORTH_GUID)
}
