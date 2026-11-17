package streaming

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/testlog"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/scene"

// Each test thread has a level of its own, as core has one: an arena, and a count of its unloads.
@(private = "file", thread_local)
level: virtual.Arena

@(private = "file", thread_local)
level_unloads: u64

// Each test thread has a table of scene memory of its own, as core has one.
@(private = "file", thread_local)
scene_memories: core.Scene_Memories

// A fake of the host's reads across frames, one for each test thread: a read is done at its first poll.
@(private = "file")
Reads_Fake :: struct {
	reads: [8]struct {
		open: bool,
		data: []byte,
	},
}

@(private = "file", thread_local)
fake: Reads_Fake

@(private = "file")
WORLD_GUID :: format.Guid {
	0  = 0x90,
	15 = 1,
}

@(private = "file")
OTHER_WORLD_GUID :: format.Guid {
	0  = 0x90,
	15 = 2,
}

@(private = "file")
scene_guid :: proc(i: int) -> format.Guid {
	return {0 = 0xa0, 14 = u8(i), 15 = 1}
}

@(private = "file")
SCENE_TEXT :: `scene 2
entity 00000000000000d1
name = "Door"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
`

@(private = "file")
Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	assets:   asset.Assets,
	scenes:   scene.Scenes,
	state:    State,
	dir:      string,
	streamer: ecs.Entity,
}

@(private = "file")
setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		file_size = core.file_size,
		file_read_begin = proc(path: string, offset: i64, size: int) -> core.File_Read {
			for &read, i in fake.reads {
				if read.open {
					continue
				}
				data := make([]byte, size)
				if core.file_read_range(path, offset, data) != size {
					delete(data)
					return 0
				}
				read = {
					open = true,
					data = data,
				}
				return core.File_Read(i + 1)
			}
			return 0
		},
		file_read_result = proc(read: core.File_Read) -> ([]byte, core.File_Read_State) {
			if read == 0 || !fake.reads[read - 1].open {
				return nil, .Failed
			}
			return fake.reads[read - 1].data, .Done
		},
		file_read_end = proc(read: core.File_Read) {
			if read != 0 && fake.reads[read - 1].open {
				delete(fake.reads[read - 1].data)
				fake.reads[read - 1] = {}
			}
		},
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
			core.scene_memories_close_all(&scene_memories)
			virtual.arena_free_all(&level)
			level_unloads += 1
		},
		level_generation = proc() -> u64 {
			return level_unloads
		},
		scene_memory_open = proc() -> (core.Scene_Memory, bool) {
			return core.scene_memories_open(&scene_memories)
		},
		scene_memory_close = proc(m: core.Scene_Memory) {
			core.scene_memories_close(&scene_memories, m)
		},
		scene_memory_alive = proc(m: core.Scene_Memory) -> bool {
			return core.scene_memories_alive(&scene_memories, m)
		},
		scene_memory_allocator = proc(m: core.Scene_Memory) -> runtime.Allocator {
			return core.scene_memories_allocator(&scene_memories, m)
		},
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	scene.register_components(&f.world.registry)
	register_components(&f.world.registry)
	temp, err := os.make_directory_temp("", "streaming_policy_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	scene.init_scenes(&f.scenes, &f.platform, &f.assets)
	init(&f.state, &f.platform, &f.assets)
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	destroy(&f.state)
	scene.destroy_scenes(&f.scenes)
	asset.destroy(&f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	virtual.arena_destroy(&level)
	core.scene_memories_close_all(&scene_memories)
	free(f)
}

@(private = "file")
write_blob :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, blob: []byte) {
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

// write_scenes writes the scenes with the numbers of the indexes to the cache.
@(private = "file")
write_scenes :: proc(t: ^testing.T, f: ^Fixture, indexes: []int) {
	s, problems, ok := format.scene_parse(SCENE_TEXT, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	for i in indexes {
		guid := scene_guid(i)
		write_blob(
			t,
			f,
			guid,
			format.scene_write(s, guid, 1, .Scene, allocator = context.temp_allocator),
		)
	}
}

// meters is a position in meters.
@(private = "file")
meters :: proc(x, y, z: f64) -> ecs.World_Position {
	result: ecs.World_Position
	for v, i in ([3]f64{x, y, z}) {
		raw, ok := format.world_raw_from_meters(v)
		assert(ok)
		result.raw[i] = raw
	}
	return result
}

// box is the record of a scene that is 10 m wide on each axis, from x on the x axis.
@(private = "file")
box :: proc(
	i: int,
	x: f64,
	load, unload: f32,
	flags := format.World_Scene_Flags{},
) -> format.World_Scene_Record {
	low, high := meters(x, 0, 0), meters(x + 10, 10, 10)
	return {
		guid = scene_guid(i),
		min = low.raw,
		max = high.raw,
		load_distance = load,
		unload_distance = unload,
		flags = flags,
	}
}

@(private = "file")
world_blob :: proc(guid: format.Guid, records: []format.World_Scene_Record) -> []byte {
	return format.world_write({guid = guid, key = 1, scenes = records}, context.temp_allocator)
}

// start writes the world of the records, and gives the world a streamer.
@(private = "file")
start :: proc(t: ^testing.T, f: ^Fixture, records: []format.World_Scene_Record) {
	write_blob(t, f, WORLD_GUID, world_blob(WORLD_GUID, records))
	f.streamer = ecs.spawn(&f.world)
	ecs.add(&f.world, f.streamer, World_Streamer{world = WORLD_GUID})
}

// tick is one update with one source at x on the x axis, and a copy of its events.
@(private = "file")
tick :: proc(f: ^Fixture, x: f64) -> (events: []Stream_Event, unloaded: bool) {
	sources := []ecs.World_Position{meters(x, 5, 5)}
	unloaded = update(&f.state, &f.world, nil, &f.scenes, sources, nil)
	events = make([]Stream_Event, len(events_of(f)), context.temp_allocator)
	copy(events, events_of(f))
	return
}

@(private = "file")
events_of :: proc(f: ^Fixture) -> []Stream_Event {
	return events(&f.state)
}

@(private = "file")
expect_kinds :: proc(
	t: ^testing.T,
	got: []Stream_Event,
	want: []Stream_Event_Kind,
	loc := #caller_location,
) {
	kinds := make([]Stream_Event_Kind, len(got), context.temp_allocator)
	for e, i in got {
		kinds[i] = e.kind
	}
	testing.expect_value(t, len(kinds), len(want), loc)
	if len(kinds) == len(want) {
		for k, i in want {
			testing.expect_value(t, kinds[i], k, loc)
		}
	}
}

// Loads and unloads of one scene, until it is ready.
@(private = "file")
ready_scene :: proc(t: ^testing.T, f: ^Fixture, x: f64) {
	for _ in 0 ..< 4 {
		tick(f, x)
		if stats(&f.state).scenes_loading == 0 {
			return
		}
	}
	testing.fail_now(t, "the scene is not ready")
}

// A scene loads when a source comes within its load distance, and unloads past its unload distance. Between the two, a
// source that moves back and forth loads and unloads nothing.
@(test)
the_gap_between_the_distances_is_hysteresis :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_scenes(t, f, {0})
	start(t, f, {box(0, 100, 20, 30)})

	// 35 m away: out.
	events, _ := tick(f, 65)
	expect_kinds(t, events, {})
	// 25 m away: in the gap, and still out, however often it moves there.
	for x in ([]f64{75, 72, 75, 73}) {
		events, _ = tick(f, x)
		expect_kinds(t, events, {})
	}
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 0)

	// 15 m away: Loading, and Ready in a later update.
	events, _ = tick(f, 85)
	expect_kinds(t, events, {.Loading})
	testing.expect_value(t, events[0].scene, scene_guid(0))
	testing.expect_value(t, stats(&f.state).scenes_loading, 1)
	events, _ = tick(f, 85)
	expect_kinds(t, events, {.Ready})
	testing.expect_value(t, stats(&f.state).scenes_loading, 0)

	// In the gap, it stays loaded.
	for x in ([]f64{75, 85, 75, 72, 85}) {
		quiet, moved_out := tick(f, x)
		expect_kinds(t, quiet, {})
		testing.expect(t, !moved_out)
	}
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 1)

	// Past 30 m, it unloads, and the update says so.
	unloaded: bool
	events, unloaded = tick(f, 65)
	expect_kinds(t, events, {.Unloaded})
	testing.expect(t, unloaded)
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 0)
	// And it does not load again in the gap.
	events, _ = tick(f, 75)
	expect_kinds(t, events, {})
}

// A scene that unloads while it still loads says Unloaded, and its entities never show.
@(test)
a_scene_that_is_still_loading_unloads :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_scenes(t, f, {0})
	start(t, f, {box(0, 100, 20, 30)})
	events, _ := tick(f, 85)
	expect_kinds(t, events, {.Loading})
	number := events[0].number
	events, _ = tick(f, 40)
	expect_kinds(t, events, {.Unloaded})
	testing.expect_value(t, events[0].number, number)
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 0)
}

// A persistent scene loads wherever the sources are, and never unloads.
@(test)
a_persistent_scene_always_loads :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_scenes(t, f, {0})
	start(t, f, {box(0, 0, 0, 0, {.Persistent})})
	events, _ := tick(f, 5000)
	expect_kinds(t, events, {.Loading})
	events, _ = tick(f, -5000)
	expect_kinds(t, events, {.Ready})
	events, _ = tick(f, 90000)
	expect_kinds(t, events, {})
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 1)
}

// The persistent scene begins first, then the nearest, and no more than MAX_SCENE_LOADS are loading at once.
@(test)
scenes_load_nearest_first_and_two_at_a_time :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_scenes(t, f, {0, 1, 2, 3, 4})
	// Scene 4 is persistent and far; the others are 10, 30, 20 and 40 m from x = 0 on the negative side.
	start(
		t,
		f,
		{
			box(0, -20, 100, 125),
			box(1, -40, 100, 125),
			box(2, -30, 100, 125),
			box(3, -50, 100, 125),
			box(4, 900, 0, 0, {.Persistent}),
		},
	)
	events, _ := tick(f, 0)
	expect_kinds(t, events, {.Loading, .Loading})
	testing.expect_value(t, events[0].scene, scene_guid(4))
	testing.expect_value(t, events[1].scene, scene_guid(0))
	testing.expect_value(t, stats(&f.state).scenes_loading, 2)

	// Two are in flight, so no more begin until they are ready.
	events, _ = tick(f, 0)
	expect_kinds(t, events, {.Ready, .Ready})
	events, _ = tick(f, 0)
	expect_kinds(t, events, {.Loading, .Loading})
	testing.expect_value(t, events[0].scene, scene_guid(2))
	testing.expect_value(t, events[1].scene, scene_guid(1))
	events, _ = tick(f, 0)
	expect_kinds(t, events, {.Ready, .Ready})
	events, _ = tick(f, 0)
	expect_kinds(t, events, {.Loading})
	testing.expect_value(t, events[0].scene, scene_guid(3))
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 5)
}

// A scene that has no blob fails once. It is not tried again each frame, and is tried again when the world's blob
// changes.
@(test)
a_missing_scene_fails_once :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	// A scene that cannot begin to load logs an error, which a test would count as its failure.
	context.logger = testlog.expected_errors()
	records := []format.World_Scene_Record{box(0, 100, 20, 30), box(1, 200, 20, 30)}
	write_scenes(t, f, {1})
	start(t, f, records)
	events, _ := tick(f, 95)
	expect_kinds(t, events, {.Failed})
	testing.expect_value(t, events[0].scene, scene_guid(0))
	testing.expect_value(t, events[0].number, 0)
	_, failed := f.state.slots[0].(Slot_Failed)
	testing.expect(t, failed)
	for _ in 0 ..< 3 {
		events, _ = tick(f, 95)
		expect_kinds(t, events, {})
	}
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 0)

	// The world's blob changed, and now the scene is there: the failure is forgotten.
	write_scenes(t, f, {0})
	testing.expect(t, asset.set_live(&f.assets, WORLD_GUID, world_blob(WORLD_GUID, records)))
	events, _ = tick(f, 95)
	expect_kinds(t, events, {.Loading})
	// The other scene is far, and does not load.
	testing.expect_value(t, events[0].scene, scene_guid(0))
}

// Without a source nothing unloads, and only a persistent scene starts.
@(test)
without_sources_nothing_changes :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_scenes(t, f, {0, 1, 2})
	start(t, f, {box(0, 100, 20, 30), box(1, 0, 0, 0, {.Persistent}), box(2, 300, 20, 30)})
	ready_scene(t, f, 95)
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 2)
	for _ in 0 ..< 3 {
		unloaded := update(&f.state, &f.world, nil, &f.scenes, nil, nil)
		testing.expect(t, !unloaded)
		expect_kinds(t, events(&f.state), {})
	}
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 2)
}

// Without a source a persistent scene still loads.
@(test)
a_persistent_scene_loads_without_sources :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_scenes(t, f, {0, 1})
	start(t, f, {box(0, 0, 20, 30), box(1, 0, 0, 0, {.Persistent})})
	unloaded := update(&f.state, &f.world, nil, &f.scenes, nil, nil)
	testing.expect(t, !unloaded)
	got := events(&f.state)
	expect_kinds(t, got, {.Loading})
	if len(got) == 1 {
		testing.expect_value(t, got[0].scene, scene_guid(1))
	}
}

// The distance is to the scene's bounds, so a source above or beside the box is as far as the nearest face.
@(test)
the_distance_is_to_the_bounds :: proc(t: ^testing.T) {
	record := box(0, 0, 1, 1)
	inside := scene_distance(record, {meters(5, 5, 5)})
	testing.expect_value(t, inside, 0)
	above := scene_distance(record, {meters(5, 5, 14)})
	testing.expect_value(t, above, 4)
	corner := scene_distance(record, {meters(13, 14, 5)})
	testing.expect_value(t, corner, 5)
	two := scene_distance(record, {meters(100, 5, 5), meters(-2, 5, 5)})
	testing.expect_value(t, two, 2)
}

// When the streamer goes, every scene that it loaded unloads.
@(test)
the_streamer_going_unloads_every_scene :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_scenes(t, f, {0, 1})
	start(t, f, {box(0, 100, 20, 30), box(1, 110, 20, 30)})
	ready_scene(t, f, 105)
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 2)
	ecs.despawn(&f.world, f.streamer)
	events, unloaded := tick(f, 105)
	testing.expect(t, unloaded)
	expect_kinds(t, events, {.Unloaded, .Unloaded})
	testing.expect_value(t, len(scene.loaded_scenes(&f.scenes)), 0)
	events, unloaded = tick(f, 105)
	testing.expect(t, !unloaded)
	expect_kinds(t, events, {})
}

// The first streamer selects the world, and one that names another world replaces the scenes.
@(test)
the_streamer_selects_the_world :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_scenes(t, f, {0, 1})
	start(t, f, {box(0, 100, 20, 30)})
	write_blob(t, f, OTHER_WORLD_GUID, world_blob(OTHER_WORLD_GUID, {box(1, 100, 20, 30)}))
	second := ecs.spawn(&f.world)
	ecs.add(&f.world, second, World_Streamer{world = OTHER_WORLD_GUID})
	events, _ := tick(f, 95)
	expect_kinds(t, events, {.Loading})
	testing.expect_value(t, events[0].scene, scene_guid(0))
	ready_scene(t, f, 95)

	ecs.get(&f.world, f.streamer, World_Streamer).world = OTHER_WORLD_GUID
	unloaded: bool
	events, unloaded = tick(f, 95)
	testing.expect(t, unloaded)
	expect_kinds(t, events, {.Unloaded, .Loading})
	testing.expect_value(t, events[1].scene, scene_guid(1))
}

// The level unloading forgets the world, the slots and the streamer.
@(test)
the_level_unloading_forgets_everything :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_scenes(t, f, {0})
	start(t, f, {box(0, 100, 20, 30)})
	ready_scene(t, f, 95)
	f.platform.level_unload()
	ecs.despawn(&f.world, f.streamer)
	events, unloaded := tick(f, 95)
	testing.expect(t, !unloaded)
	expect_kinds(t, events, {})
	testing.expect_value(t, len(f.state.slots), 0)
	testing.expect_value(t, f.state.streamer, ecs.Entity(0))
}
