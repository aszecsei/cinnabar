package scene

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// Each test thread has a level of its own, as core has one: an arena, and a count of its unloads.
@(private = "file", thread_local)
level: virtual.Arena

@(private = "file", thread_local)
level_unloads: u64

// A fake of the host's reads across frames, one for each test thread. A read begins by reading its file's bytes, and
// answers Pending for delay polls before it answers. fail makes every read fail.
@(private = "file")
Reads_Fake :: struct {
	reads: [8]struct {
		open: bool,
		wait: int,
		data: []byte,
	},
	delay: int,
	fail:  bool,
	open:  int,
	ends:  int,
}

@(private = "file", thread_local)
fake: Reads_Fake

@(private = "file")
BIG_GUID :: format.Guid {
	0  = 0x61,
	15 = 1,
}

@(private = "file")
SMALL_GUID :: format.Guid {
	0  = 0x62,
	15 = 1,
}

@(private = "file")
SCRIPT_GUID :: format.Guid {
	0  = 0x63,
	15 = 1,
}

@(private = "file")
LINKED_GUID :: format.Guid {
	0  = 0x64,
	15 = 1,
}

@(private = "file")
TARGET_GUID :: format.Guid {
	0  = 0x65,
	15 = 1,
}

@(private = "file")
BIG_COUNT :: 2000

@(private = "file")
Staged_Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	assets:   asset.Assets,
	scenes:   Scenes,
	runtime:  script.Runtime,
	scripts:  ^script.Runtime,
	dir:      string,
	seen:     ecs.Query,
}

@(private = "file")
setup :: proc(t: ^testing.T, with_scripts := false, delay := 0) -> ^Staged_Fixture {
	fake = {
		delay = delay,
	}
	f := new(Staged_Fixture)
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
					wait = fake.delay,
					data = data,
				}
				fake.open += 1
				return core.File_Read(i + 1)
			}
			return 0
		},
		file_read_result = proc(read: core.File_Read) -> ([]byte, core.File_Read_State) {
			if read == 0 || !fake.reads[read - 1].open || fake.fail {
				return nil, .Failed
			}
			r := &fake.reads[read - 1]
			if r.wait > 0 {
				r.wait -= 1
				return nil, .Pending
			}
			return r.data, .Done
		},
		file_read_end = proc(read: core.File_Read) {
			if read != 0 && fake.reads[read - 1].open {
				delete(fake.reads[read - 1].data)
				fake.reads[read - 1] = {}
				fake.open -= 1
				fake.ends += 1
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
			close_test_scene_memory()
			virtual.arena_free_all(&level)
			level_unloads += 1
		},
		level_generation = proc() -> u64 {
			return level_unloads
		},
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
	}
	use_test_scene_memory(&f.platform)
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	ecs.register_component(&f.world.registry, Probe, PROBE_ID)
	script.register_components(&f.world.registry)
	temp, err := os.make_directory_temp("", "staged_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	init_scenes(&f.scenes, &f.platform, &f.assets)
	f.seen = ecs.query(&f.world, {ecs.read(&f.world, Scene_Entity)})
	if with_scripts {
		testing.expect(
			t,
			script.init(&f.runtime, &f.platform, &f.world, &f.assets, proc(r: ^script.Runtime) {}),
		)
		f.scripts = &f.runtime
		f.scenes.scripts = f.scripts
		bytecode := script.compile("local B = Behaviour.define(\"B\")\nreturn B")
		defer luau.free_bytecode(raw_data(bytecode))
		blob := format.script_write(
			{guid = SCRIPT_GUID, bytecode = bytecode, source_path = "game/b.luau"},
			context.temp_allocator,
		)
		write_bytes(t, f, SCRIPT_GUID, blob)
		linked := script.compile(
			"local L = Behaviour.define(\"Linked\", {target = Field.entity()})\nreturn L",
		)
		defer luau.free_bytecode(raw_data(linked))
		write_bytes(
			t,
			f,
			LINKED_GUID,
			format.script_write(
				{guid = LINKED_GUID, bytecode = linked, source_path = "game/linked.luau"},
				context.temp_allocator,
			),
		)
	}
	return f
}

@(private = "file")
teardown :: proc(f: ^Staged_Fixture) {
	if f.scripts != nil {
		script.destroy(&f.runtime)
	}
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

@(private = "file")
write_bytes :: proc(t: ^testing.T, f: ^Staged_Fixture, guid: format.Guid, blob: []byte) {
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
write_scene :: proc(t: ^testing.T, f: ^Staged_Fixture, guid: format.Guid, text: string) {
	s, problems, ok := format.scene_parse(text, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	write_bytes(
		t,
		f,
		guid,
		format.scene_write(s, guid, 1, .Scene, allocator = context.temp_allocator),
	)
}

// big_scene is count entities. The first is the last one's child and refers to it, and the second is disabled; each
// of the others refers to the entity after it.
@(private = "file")
big_scene :: proc(count: int, behaviours := false) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	fmt.sbprintln(&b, "scene 2")
	buffer: [32]u8
	for i in 0 ..< count {
		fmt.sbprintf(&b, "entity %016x\n", 0x1000 + i)
		fmt.sbprintf(&b, "name = \"E%d\"\n", i)
		if i == 0 {
			fmt.sbprintf(&b, "parent = @%016x\n", 0x1000 + count - 1)
		}
		if i == 1 {
			fmt.sbprintln(&b, "active = false")
		}
		fmt.sbprintln(&b, "component 1 Transform")
		fmt.sbprintln(&b, "\tposition = [0, 0, 0]")
		fmt.sbprintln(&b, "\trotation = [0, 0, 0, 1]")
		fmt.sbprintln(&b, "\tscale = [1, 1, 1]")
		fmt.sbprintln(&b, "component 100 Probe")
		fmt.sbprintf(&b, "\ttarget = @%016x\n", 0x1000 + (i + 1) % count)
		if behaviours && i % 10 == 0 {
			fmt.sbprintf(&b, "behaviour %s\n", format.guid_format(SCRIPT_GUID, &buffer))
		}
		fmt.sbprintln(&b)
	}
	return strings.to_string(b)
}

@(private = "file")
visible :: proc(f: ^Staged_Fixture) -> int {
	return int(ecs.query_entity_count(&f.world, f.seen))
}

@(private = "file")
step :: proc(
	f: ^Staged_Fixture,
	budget := Load_Budget{SCENE_SPAWNS_PER_FRAME, SCENE_FILLS_PER_FRAME},
	pending: []u32 = nil,
	order: []u32 = nil,
) -> (
	ready: []u32,
	failed: []u32,
	work: Load_Work,
) {
	return advance_loads(&f.world, f.scripts, &f.scenes, order, budget, pending)
}

// A scene of 2,000 entities loads over many calls, and no call goes past the budget. Until it is ready no query that
// does not name Inactive sees one of its entities. A reference across the batches resolves, and the entity that the
// file disables stays inactive.
@(test)
a_big_scene_loads_within_the_budget_and_stays_hidden_until_ready :: proc(t: ^testing.T) {
	f := setup(t, delay = 2)
	defer teardown(f)
	w := &f.world
	write_scene(t, f, BIG_GUID, big_scene(BIG_COUNT))
	number, ok := begin_load(w, &f.scenes, BIG_GUID)
	testing.expect(t, ok)
	testing.expect_value(t, number, FIRST_RUNTIME_SCENE)
	testing.expect_value(t, ecs.world_scenes(w)[0], BIG_GUID)
	kind, found := stage_of(&f.scenes, number)
	testing.expect(t, found && kind == .Reading)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 1)

	total: Load_Work
	calls := 0
	for calls < 100 {
		calls += 1
		before := ecs.entity_count(w)
		ready, failed, work := step(f)
		testing.expect(t, work.spawned <= SCENE_SPAWNS_PER_FRAME)
		testing.expect(t, work.filled <= SCENE_FILLS_PER_FRAME)
		testing.expect(t, int(ecs.entity_count(w) - before) <= SCENE_SPAWNS_PER_FRAME)
		testing.expect_value(t, len(failed), 0)
		total.spawned += work.spawned
		total.filled += work.filled
		if len(ready) == 1 {
			testing.expect_value(t, ready[0], number)
			break
		}
		testing.expect_value(t, visible(f), 0)
		if calls <= 2 {
			testing.expect_value(t, work, Load_Work{})
			testing.expect_value(t, ecs.entity_count(w), 0)
		}
	}
	testing.expect_value(t, total.spawned, BIG_COUNT)
	testing.expect_value(t, total.filled, BIG_COUNT)
	// Two reads, two calls to spawn, sixteen to fill, and one to settle.
	testing.expect(t, calls > 16)
	kind, _ = stage_of(&f.scenes, number)
	testing.expect_value(t, kind, Scene_Stage_Kind.Ready)
	testing.expect_value(t, fake.open, 0)

	// The disabled entity stays hidden; the others are seen.
	testing.expect_value(t, visible(f), BIG_COUNT - 1)
	first := find(&f.scenes, w, number, 0x1000)
	second := find(&f.scenes, w, number, 0x1001)
	last := find(&f.scenes, w, number, u64(0x1000 + BIG_COUNT - 1))
	testing.expect(t, first != 0 && second != 0 && last != 0)
	testing.expect(t, !ecs.active_self(w, second))
	testing.expect(t, !ecs.active_in_hierarchy(w, second))
	testing.expect(t, ecs.active_in_hierarchy(w, first))
	testing.expect_value(t, ecs.get(w, first, ecs.Parent).entity, last)
	testing.expect_value(t, ecs.get(w, second, Probe).target, find(&f.scenes, w, number, 0x1002))
	testing.expect_value(t, ecs.get(w, last, Probe).target, first)
	testing.expect(t, !ecs.has(w, first, ecs.Loading))

	// A ready scene is left alone.
	ready, failed, work := step(f)
	testing.expect(t, len(ready) == 0 && len(failed) == 0)
	testing.expect_value(t, work, Load_Work{})

	testing.expect_value(t, unload_scene(w, &f.scenes, number), BIG_COUNT)
	testing.expect_value(t, ecs.entity_count(w), 0)
	testing.expect_value(t, open_test_scene_memory(), 0)
}

// The scenes of order go first, and the scenes share one budget.
@(test)
scenes_share_one_budget_in_order :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	write_scene(t, f, BIG_GUID, big_scene(300))
	write_scene(t, f, SMALL_GUID, big_scene(50))
	first, _ := begin_load(w, &f.scenes, BIG_GUID)
	second, _ := begin_load(w, &f.scenes, SMALL_GUID)

	_, _, work := step(f, {spawns = 100, fills = 30}, order = {second, first})
	testing.expect_value(t, work, Load_Work{100, 30})
	// The second scene's 50 spawn and fill first; the first gets what is left.
	second_kind, _ := stage_of(&f.scenes, second)
	testing.expect_value(t, second_kind, Scene_Stage_Kind.Filling)
	testing.expect_value(t, ecs.entity_count(w), 100)
	for _ in 0 ..< 40 {
		step(f, {spawns = 100, fills = 30})
	}
	for number in ([]u32{first, second}) {
		kind, _ := stage_of(&f.scenes, number)
		testing.expect_value(t, kind, Scene_Stage_Kind.Ready)
	}
	testing.expect_value(t, ecs.entity_count(w), 350)
}

// A scene whose bodies are not made waits in Settling, hidden, until its number is gone from bodies_pending. It does
// not settle in the call that filled it.
@(test)
a_scene_waits_for_its_bodies :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	write_scene(t, f, SMALL_GUID, big_scene(10))
	number, _ := begin_load(w, &f.scenes, SMALL_GUID)
	ready, _, _ := step(f)
	testing.expect_value(t, len(ready), 0)
	kind, _ := stage_of(&f.scenes, number)
	testing.expect_value(t, kind, Scene_Stage_Kind.Settling)
	pending := []u32{number}
	for _ in 0 ..< 3 {
		ready, _, _ = step(f, pending = pending)
		testing.expect_value(t, len(ready), 0)
		testing.expect_value(t, visible(f), 0)
	}
	ready, _, _ = step(f)
	testing.expect_value(t, len(ready), 1)
	testing.expect_value(t, visible(f), 9)
}

// A scene's behaviours attach when it is ready, not before.
@(test)
behaviours_attach_only_when_the_scene_is_ready :: proc(t: ^testing.T) {
	f := setup(t, with_scripts = true)
	defer teardown(f)
	w := &f.world
	write_scene(t, f, BIG_GUID, big_scene(100, behaviours = true))
	number, _ := begin_load(w, &f.scenes, BIG_GUID)
	count_behaviours :: proc(f: ^Staged_Fixture) -> (count: int) {
		for i in 0 ..< 100 {
			e := find(&f.scenes, &f.world, FIRST_RUNTIME_SCENE, u64(0x1000 + i))
			if e != 0 && ecs.get_raw(&f.world, e, script.BEHAVIOURS_ID) != nil {
				count += 1
			}
		}
		return
	}
	for {
		ready, _, _ := step(f, {spawns = 30, fills = 20})
		if len(ready) == 1 {
			break
		}
		testing.expect_value(t, count_behaviours(f), 0)
	}
	testing.expect_value(t, count_behaviours(f), 10)
	testing.expect_value(t, number, FIRST_RUNTIME_SCENE)
}

// Unloading a scene that is reading ends its read, and leaves nothing.
@(test)
unloading_during_reading_ends_the_read :: proc(t: ^testing.T) {
	f := setup(t, delay = 100)
	defer teardown(f)
	w := &f.world
	write_scene(t, f, SMALL_GUID, big_scene(10))
	number, ok := begin_load(w, &f.scenes, SMALL_GUID)
	testing.expect(t, ok)
	step(f)
	testing.expect_value(t, fake.open, 1)
	testing.expect_value(t, unload_scene(w, &f.scenes, number), 0)
	testing.expect_value(t, fake.open, 0)
	testing.expect_value(t, fake.ends, 1)
	testing.expect_value(t, open_test_scene_memory(), 0)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 0)
	ready, failed, _ := step(f)
	testing.expect(t, len(ready) == 0 && len(failed) == 0)
}

// Unloading a scene while it fills despawns every entity that it made, and leaks no memory, read or table row.
@(test)
unloading_during_filling_despawns_everything :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	write_scene(t, f, BIG_GUID, big_scene(300))
	number, _ := begin_load(w, &f.scenes, BIG_GUID)
	step(f)
	step(f, {spawns = 100, fills = 50})
	kind, _ := stage_of(&f.scenes, number)
	testing.expect_value(t, kind, Scene_Stage_Kind.Filling)
	testing.expect_value(t, ecs.entity_count(w), 300)
	testing.expect_value(t, unload_scene(w, &f.scenes, number), 300)
	testing.expect_value(t, ecs.entity_count(w), 0)
	testing.expect_value(t, open_test_scene_memory(), 0)
	testing.expect_value(t, fake.open, 0)
	testing.expect_value(t, find(&f.scenes, w, number, 0x1000), 0)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 0)

	// And again in the middle of spawning.
	again, _ := begin_load(w, &f.scenes, BIG_GUID)
	step(f, {spawns = 100, fills = 50})
	kind, _ = stage_of(&f.scenes, again)
	testing.expect_value(t, kind, Scene_Stage_Kind.Spawning)
	testing.expect_value(t, unload_scene(w, &f.scenes, again), 100)
	testing.expect_value(t, ecs.entity_count(w), 0)
	testing.expect_value(t, open_test_scene_memory(), 0)
}

// Unloading the level while a scene reads ends the read, and while it fills despawns it.
@(test)
unloading_the_level_mid_load_ends_the_read :: proc(t: ^testing.T) {
	f := setup(t, delay = 100)
	defer teardown(f)
	w := &f.world
	write_scene(t, f, SMALL_GUID, big_scene(10))
	begin_load(w, &f.scenes, SMALL_GUID)
	step(f)
	testing.expect_value(t, fake.open, 1)
	unload_level(w, &f.scenes)
	testing.expect_value(t, fake.open, 0)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 0)
	testing.expect_value(t, open_test_scene_memory(), 0)

	// A level that another caller unloaded is followed the same way.
	fake.delay = 0
	begin_load(w, &f.scenes, SMALL_GUID)
	step(f, {spawns = 5, fills = 5})
	testing.expect_value(t, ecs.entity_count(w), 5)
	unload_level(w, &f.scenes)
	testing.expect_value(t, ecs.entity_count(w), 0)
	testing.expect_value(t, open_test_scene_memory(), 0)
}

// A read that fails reports the scene as failed, unloads what it made and frees its number.
@(test)
a_failed_read_reports_failed_and_frees_the_number :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	f := setup(t)
	defer teardown(f)
	w := &f.world
	write_scene(t, f, SMALL_GUID, big_scene(10))
	number, ok := begin_load(w, &f.scenes, SMALL_GUID, u32(7))
	testing.expect(t, ok)
	testing.expect_value(t, number, 7)
	fake.fail = true
	ready, failed, _ := step(f)
	testing.expect_value(t, len(ready), 0)
	testing.expect_value(t, len(failed), 1)
	testing.expect_value(t, failed[0], 7)
	testing.expect(t, !is_loaded(&f.scenes, 7))
	testing.expect_value(t, open_test_scene_memory(), 0)
	testing.expect_value(t, fake.open, 0)
	testing.expect_value(t, len(ecs.world_scenes(w)), 0)

	fake.fail = false
	again, again_ok := begin_load(w, &f.scenes, SMALL_GUID, u32(7))
	testing.expect(t, again_ok)
	testing.expect_value(t, again, 7)

	// A GUID with no blob does not begin.
	_, missing := begin_load(w, &f.scenes, BIG_GUID)
	testing.expect(t, !missing)
	// A loaded number is refused.
	_, taken := begin_load(w, &f.scenes, SMALL_GUID, u32(7))
	testing.expect(t, !taken)
	testing.expect_value(t, fake.open, 1)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 1)
}

// A blob that is not a scene fails the scene when it is read.
@(test)
a_blob_that_is_not_a_scene_fails_the_scene :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	f := setup(t)
	defer teardown(f)
	w := &f.world
	script_blob := format.script_write(
		{guid = BIG_GUID, bytecode = {1, 2, 3, 4, 5, 6, 7, 8}, source_path = "x.luau"},
		context.temp_allocator,
	)
	write_bytes(t, f, BIG_GUID, script_blob)
	number, _ := begin_load(w, &f.scenes, BIG_GUID)
	_, failed, _ := step(f)
	testing.expect_value(t, len(failed), 1)
	testing.expect(t, !is_loaded(&f.scenes, number))
	testing.expect_value(t, open_test_scene_memory(), 0)
}

// The stage changes in order, and no other way.
@(test)
a_stage_changes_only_in_order :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	row: Loaded_Scene
	testing.expect(t, !change_stage(&row, Scene_Filling{}))
	testing.expect(t, !change_stage(&row, nil))
	testing.expect(t, change_stage(&row, Scene_Reading{}))
	testing.expect(t, !change_stage(&row, Scene_Ready{}))
	testing.expect(t, change_stage(&row, Scene_Spawning{}))
	testing.expect(t, !change_stage(&row, Scene_Settling{}))
	testing.expect(t, change_stage(&row, Scene_Filling{}))
	testing.expect(t, change_stage(&row, Scene_Settling{}))
	testing.expect(t, change_stage(&row, Scene_Ready{}))
	testing.expect(t, !change_stage(&row, Scene_Reading{}))
	testing.expect(t, !change_stage(&row, Scene_Ready{}))
}

// From bundles, a scene that loads in stages holds its own bundle, as a streaming chunk does, until it unloads; the
// bundle then closes at the next poll.
@(test)
a_staged_scene_holds_its_bundle_until_it_unloads :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	parsed, problems, parsed_ok := format.scene_parse(big_scene(4), context.temp_allocator)
	testing.expectf(t, parsed_ok, "problems: %v", problems)
	blob := format.scene_write(parsed, SMALL_GUID, 1, .Scene, allocator = context.temp_allocator)
	buffer: [32]u8
	name := format.guid_format(SMALL_GUID, &buffer)
	bundles := []struct {
		name:         string,
		blobs:        []format.Bundle_Blob,
		dependencies: []string,
	} {
		{format.GLOBAL_BUNDLE, nil, nil},
		{
			name,
			{
				{
					guid = SMALL_GUID,
					kind = .Scene,
					codec = .None,
					size = u32(len(blob)),
					stored = blob,
				},
			},
			{format.GLOBAL_BUNDLE},
		},
	}
	for b in bundles {
		testing.expect(
			t,
			os.write_entire_file(
				fmt.tprintf("%s/%s%s", f.dir, b.name, format.BUNDLE_EXTENSION),
				format.bundle_write(b.blobs, b.dependencies, context.temp_allocator),
			) ==
			nil,
		)
	}
	f.platform.file_read_range = core.file_read_range
	asset.destroy(&f.assets)
	asset.init(&f.assets, &f.platform, asset.bundle(f.dir))

	number, ok := begin_load(w, &f.scenes, SMALL_GUID)
	testing.expect(t, ok)
	for _ in 0 ..< 100 {
		if ready, _, _ := step(f); len(ready) > 0 {
			break
		}
	}
	// The second entity is disabled.
	testing.expect_value(t, visible(f), 3)
	asset.poll(&f.assets)
	_, open := asset.blob_location(&f.assets, SMALL_GUID)
	testing.expect(t, open)

	unload_scene(w, &f.scenes, number)
	asset.poll(&f.assets)
	_, open = asset.blob_location(&f.assets, SMALL_GUID)
	testing.expect(t, !open)
}

// A behaviour's field that names an entity of another scene is nil until that scene is ready, and then holds its
// entity.
@(test)
a_behaviours_reference_across_scenes_is_nil_until_the_scene_is_ready :: proc(t: ^testing.T) {
	f := setup(t, with_scripts = true)
	defer teardown(f)
	w := &f.world
	buffer: [32]u8
	other: [32]u8
	holder := fmt.tprintf(
		"scene 3\nentity 00000000000000b1\nbehaviour %s\n\ttarget = @%s/00000000000000d1\n",
		format.guid_format(LINKED_GUID, &buffer),
		format.guid_format(TARGET_GUID, &other),
	)
	write_scene(t, f, BIG_GUID, holder)
	write_scene(t, f, TARGET_GUID, "scene 3\nentity 00000000000000d1\n")
	held, _ := begin_load(w, &f.scenes, BIG_GUID)
	for calls := 0; calls < 100; calls += 1 {
		if ready, _, _ := step(f); len(ready) == 1 {
			break
		}
	}
	linked := find(&f.scenes, w, held, 0xb1)
	target :: proc(f: ^Staged_Fixture, linked: ecs.Entity) -> ecs.Entity {
		snapshots := script.inspect(&f.runtime, linked, context.temp_allocator)
		for field in snapshots[0].fields {
			if field.name == "target" {
				return field.entity
			}
		}
		return 1
	}
	testing.expect_value(t, target(f, linked), 0)
	waiting, is_waiting := pending_behaviour(&f.scenes, w, linked, LINKED_GUID, "target")
	testing.expect(t, is_waiting)
	testing.expect_value(t, waiting, TARGET_GUID)

	number, ok := begin_load(w, &f.scenes, TARGET_GUID)
	testing.expect(t, ok)
	finished := false
	for calls := 0; calls < 100 && !finished; calls += 1 {
		ready, _, _ := step(f, {spawns = 1, fills = 1})
		finished = len(ready) == 1
		if !finished {
			testing.expect_value(t, target(f, linked), 0)
		}
	}
	testing.expect(t, finished)
	door := find(&f.scenes, w, number, 0xd1)
	testing.expect(t, door != 0)
	testing.expect_value(t, target(f, linked), door)
	_, is_waiting = pending_behaviour(&f.scenes, w, linked, LINKED_GUID, "target")
	testing.expect(t, !is_waiting)
}

// A reference to a scene that is still loading waits, as one to a scene that is not loaded does, and binds when the
// scene is ready.
@(test)
a_reference_waits_for_a_scene_that_is_loading :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	buffer: [32]u8
	holder := fmt.tprintf(
		"scene 3\nentity 00000000000000b1\ncomponent 100 Probe\n\ttarget = @%s/00000000000000d1\n",
		format.guid_format(TARGET_GUID, &buffer),
	)
	write_scene(t, f, BIG_GUID, holder)
	write_scene(t, f, TARGET_GUID, "scene 3\nentity 00000000000000d1\n")
	held, _ := begin_load(w, &f.scenes, BIG_GUID)
	for calls := 0; calls < 100; calls += 1 {
		if ready, _, _ := step(f); len(ready) == 1 {
			break
		}
	}
	holder_entity := find(&f.scenes, w, held, 0xb1)
	testing.expect(t, holder_entity != 0)

	number, ok := begin_load(w, &f.scenes, TARGET_GUID)
	testing.expect(t, ok)
	finished := false
	for calls := 0; calls < 100 && !finished; calls += 1 {
		ready, _, _ := step(f, {spawns = 1, fills = 1})
		finished = len(ready) == 1
		if !finished {
			testing.expect_value(t, ecs.get(w, holder_entity, Probe).target, 0)
			_, is_waiting := pending(&f.scenes, w, holder_entity, PROBE_ID, "target")
			testing.expect(t, is_waiting)
		}
	}
	testing.expect(t, finished)
	door := find(&f.scenes, w, number, 0xd1)
	testing.expect(t, door != 0)
	testing.expect_value(t, ecs.get(w, holder_entity, Probe).target, door)
}

// A hall whose probe refers to the lamp of its night sublevel, across the split, as the cooker writes it (see
// docs/content/kinds/scenes.md#sublevels).
@(private = "file")
HALL_GUID :: format.Guid {
	0  = 0x66,
	15 = 1,
}

@(private = "file")
NIGHT_GUID :: format.Guid {
	0  = 0x67,
	15 = 1,
}

@(private = "file")
DAY_GUID :: format.Guid {
	0  = 0x68,
	15 = 1,
}

// write_hall writes the hall's base, which lists a night and a day sublevel, and the parts. night_blob false leaves the
// night part's blob out.
@(private = "file")
write_hall :: proc(t: ^testing.T, f: ^Staged_Fixture, night_blob := true) {
	buffer: [32]u8
	base_text := fmt.tprintf(
		"scene 3\nentity 00000000000000b1\nname = \"Hall\"\ncomponent 100 Probe\n\ttarget = @%s/00000000000000c1\n",
		format.guid_format(NIGHT_GUID, &buffer),
	)
	base, problems, ok := format.scene_parse(base_text, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	sublevels := []format.Scene_Sublevel{{"day", DAY_GUID}, {"night", NIGHT_GUID}}
	write_bytes(
		t,
		f,
		HALL_GUID,
		format.scene_write(
			base,
			HALL_GUID,
			1,
			.Scene,
			sublevels = sublevels,
			allocator = context.temp_allocator,
		),
	)
	if night_blob {
		write_scene(t, f, NIGHT_GUID, "scene 3\nentity 00000000000000c1\nname = \"Lamp\"\n")
	}
	write_scene(t, f, DAY_GUID, "scene 3\nentity 00000000000000e1\nname = \"Sun\"\n")
}

@(private = "file")
expect_events :: proc(
	t: ^testing.T,
	f: ^Staged_Fixture,
	want: []Part_Event_Kind,
	loc := #caller_location,
) {
	got := event_kinds(f)
	testing.expectf(t, slice.equal(got, want), "events %v, not %v", got, want, loc = loc)
}

@(private = "file")
event_kinds :: proc(f: ^Staged_Fixture) -> []Part_Event_Kind {
	kinds := make([dynamic]Part_Event_Kind, context.temp_allocator)
	for event in part_events(&f.scenes) {
		append(&kinds, event.kind)
	}
	clear_part_events(&f.scenes)
	return kinds[:]
}

// A scene loads as its base and the parts of its active sublevels only. A part's entity is in the part, whose base is
// the hall, and the hall's reference into the part binds. Unloading the base unloads the part with it.
@(test)
a_scene_loads_its_base_and_its_active_parts_only :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	write_hall(t, f)
	base, ok := add_scene_asset(w, nil, &f.scenes, HALL_GUID)
	testing.expect(t, ok)
	hall := find(&f.scenes, w, base, 0xb1)
	testing.expect_value(t, ecs.get(w, hall, Probe).target, 0)
	_, waiting := pending(&f.scenes, w, hall, PROBE_ID, "target")
	testing.expect(t, waiting)

	testing.expect_value(t, load_parts(w, nil, &f.scenes, base, {"night"}), 1)
	night, has_night := part_number(&f.scenes, base, "night")
	testing.expect(t, has_night)
	_, has_day := part_number(&f.scenes, base, "day")
	testing.expect(t, !has_day)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 2)

	lamp := find(&f.scenes, w, night, 0xc1)
	testing.expect(t, lamp != 0)
	owner, owned := scene_of(w, lamp)
	testing.expect(t, owned)
	testing.expect_value(t, owner, night)
	of, has_base := base_of(&f.scenes, night)
	testing.expect(t, has_base)
	testing.expect_value(t, of, base)
	of, _ = base_of(&f.scenes, base)
	testing.expect_value(t, of, base)
	testing.expect_value(t, ecs.get(w, hall, Probe).target, lamp)
	testing.expect(t, !loading_with_parts(&f.scenes, base))

	testing.expect_value(t, unload_scene(w, &f.scenes, base), 2)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 0)
	testing.expect(t, !ecs.is_alive(w, lamp))
	testing.expect_value(t, open_test_scene_memory(), 0)
	expect_events(t, f, []Part_Event_Kind{.Loading, .Ready, .Unloaded})
}

// Activating a sublevel loads its part of every loaded scene, in stages across calls. Each copy of the hall binds its
// own part. Deactivating it unloads the parts, what they own goes with them, and the references wait again.
@(test)
activating_a_sublevel_loads_its_parts_of_every_loaded_scene :: proc(t: ^testing.T) {
	f := setup(t, with_scripts = true, delay = 2)
	defer teardown(f)
	w := &f.world
	register_scripts(f.scripts)
	write_hall(t, f)
	first, _ := add_scene_asset(w, f.scripts, &f.scenes, HALL_GUID)
	second, _ := add_scene_asset(w, f.scripts, &f.scenes, HALL_GUID)

	testing.expect_value(t, update_parts(w, &f.scenes, {"night"}), 0)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 4)
	testing.expect(t, loading_with_parts(&f.scenes, first))
	calls := 0
	for ; calls < 100 &&
	    (loading_with_parts(&f.scenes, first) || loading_with_parts(&f.scenes, second));
	    calls += 1 {
		step(f)
	}
	testing.expect(t, calls > 1)
	expect_events(t, f, []Part_Event_Kind{.Loading, .Loading, .Ready, .Ready})
	first_night, _ := part_number(&f.scenes, first, "night")
	second_night, _ := part_number(&f.scenes, second, "night")
	first_lamp := find(&f.scenes, w, first_night, 0xc1)
	second_lamp := find(&f.scenes, w, second_night, 0xc1)
	testing.expect(t, first_lamp != 0 && second_lamp != 0 && first_lamp != second_lamp)
	first_hall := find(&f.scenes, w, first, 0xb1)
	second_hall := find(&f.scenes, w, second, 0xb1)
	testing.expect_value(t, ecs.get(w, first_hall, Probe).target, first_lamp)
	testing.expect_value(t, ecs.get(w, second_hall, Probe).target, second_lamp)

	// An entity that a behaviour of the lamp spawns is the part's.
	spawned := ecs.spawn(w)
	f.runtime.spawned_hook(&f.runtime, spawned, first_lamp)
	owner, owned := scene_of(w, spawned)
	testing.expect(t, owned)
	testing.expect_value(t, owner, first_night)

	testing.expect_value(t, update_parts(w, &f.scenes, {}), 3)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 2)
	testing.expect(t, !ecs.is_alive(w, spawned))
	testing.expect(t, !ecs.is_alive(w, first_lamp))
	testing.expect_value(t, ecs.get(w, first_hall, Probe).target, 0)
	_, waiting := pending(&f.scenes, w, first_hall, PROBE_ID, "target")
	testing.expect(t, waiting)
	expect_events(t, f, []Part_Event_Kind{.Unloaded, .Unloaded})

	// Activating it again binds the references again.
	update_parts(w, &f.scenes, {"night"})
	for calls = 0; calls < 100 && loading_with_parts(&f.scenes, first); calls += 1 {
		step(f)
	}
	first_night, _ = part_number(&f.scenes, first, "night")
	testing.expect_value(
		t,
		ecs.get(w, first_hall, Probe).target,
		find(&f.scenes, w, first_night, 0xc1),
	)
}

// A base that loads in stages learns its sublevels when its blob is read, and the wanted parts begin then, so the base
// is never ready before they begin. They load with it, and it is not ready as one until they are.
@(test)
a_staged_base_begins_its_wanted_parts :: proc(t: ^testing.T) {
	f := setup(t, delay = 1)
	defer teardown(f)
	w := &f.world
	write_hall(t, f)
	base, ok := begin_load(w, &f.scenes, HALL_GUID)
	testing.expect(t, ok)
	_, known := sublevels_of(&f.scenes, base)
	testing.expect(t, !known)
	wanted := []string{"night"}
	for calls := 0; calls < 100 && loading_with_parts(&f.scenes, base); calls += 1 {
		if kind, _ := stage_of(&f.scenes, base); kind == .Ready {
			_, has_part := part_number(&f.scenes, base, "night")
			testing.expect(t, has_part)
		}
		advance_loads(
			w,
			nil,
			&f.scenes,
			nil,
			{SCENE_SPAWNS_PER_FRAME, SCENE_FILLS_PER_FRAME},
			nil,
			wanted,
		)
	}
	sublevels, has := sublevels_of(&f.scenes, base)
	testing.expect(t, has)
	testing.expect_value(t, len(sublevels), 2)
	night, has_night := part_number(&f.scenes, base, "night")
	testing.expect(t, has_night)
	kind, _ := stage_of(&f.scenes, night)
	testing.expect_value(t, kind, Scene_Stage_Kind.Ready)
	testing.expect_value(t, part_count(&f.scenes, base), 1)
}

// A part whose blob is missing fails once, and is not tried again while its sublevel stays active. It is tried again
// once the sublevel is deactivated and activated.
@(test)
a_failed_part_is_not_tried_again_while_it_stays_wanted :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	f := setup(t)
	defer teardown(f)
	w := &f.world
	write_hall(t, f, night_blob = false)
	add_scene_asset(w, nil, &f.scenes, HALL_GUID)
	update_parts(w, &f.scenes, {"night"})
	step(f)
	testing.expect_value(t, len(loaded_scenes(&f.scenes)), 1)
	update_parts(w, &f.scenes, {"night"})
	step(f)
	kinds := event_kinds(f)
	failures := 0
	for kind in kinds {
		failures += 1 if kind == .Failed else 0
	}
	testing.expect_value(t, failures, 1)
	testing.expect(t, sublevel_failed(&f.scenes, "night"))
	testing.expect(t, !sublevel_failed(&f.scenes, "day"))

	retry_sublevel(&f.scenes, "night")
	testing.expect(t, !sublevel_failed(&f.scenes, "night"))
	update_parts(w, &f.scenes, {})
	update_parts(w, &f.scenes, {"night"})
	step(f)
	failures = 0
	for kind in event_kinds(f) {
		failures += 1 if kind == .Failed else 0
	}
	testing.expect_value(t, failures, 1)
}
