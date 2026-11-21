package cutscene

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:core/testlog"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// Each test thread has a level of its own, as core has one: an arena, its unloads, and its scene memory.
@(private = "file", thread_local)
level: virtual.Arena

@(private = "file", thread_local)
level_unloads: u64

@(private = "file", thread_local)
scene_memories: core.Scene_Memories

// What the scripts reported with Test.report. Each test thread has its own.
@(private = "file", thread_local)
reports: [dynamic]f64

@(private = "file")
LEVEL_GUID :: format.Guid {
	0  = 0x71,
	15 = 1,
}

@(private = "file")
GUARD_GUID :: format.Guid {
	0  = 0x71,
	15 = 2,
}

@(private = "file")
LIFE_GUID :: format.Guid {
	0  = 0x71,
	15 = 3,
}

@(private = "file")
NOWHERE_GUID :: format.Guid {
	0  = 0x71,
	15 = 4,
}

@(private = "file")
DOOR_ID :: 0x00000000000000a1

// The instance in the level, and the ID of the guard's hat inside it, as the cooker's expansion gives it.
@(private = "file")
INSTANCE_ID :: 0x5000000000000001

@(private = "file")
HAT_ID :: 0x2000000000000002

// A guard, whose root has a behaviour that reports its callbacks, and a hat under it.
@(private = "file")
GUARD :: `scene 2
entity 1000000000000001
name = "Guard"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
behaviour 71000000000000000000000000000003

entity 2000000000000002
name = "Hat"
parent = @1000000000000001
component 2 Local_Transform
	offset = [0, 2, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
`

// The behaviour reports 1 to 5 for awake, on_enable, start, on_disable and on_destroy.
@(private = "file")
LIFE :: `
local Life = Behaviour.define("Life")
function Life:awake() Test.report(1) end
function Life:on_enable() Test.report(2) end
function Life:start() Test.report(3) end
function Life:on_disable() Test.report(4) end
function Life:on_destroy() Test.report(5) end
return Life`

@(private = "file")
FRAME :: 16 * time.Millisecond

@(private = "file")
Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	assets:   asset.Assets,
	scenes:   scene.Scenes,
	runtime:  script.Runtime,
	scripts:  ^script.Runtime,
	dir:      string,
	// The level's number, and its door and the hat of its guard instance.
	level:    u32,
	door:     ecs.Entity,
	hat:      ecs.Entity,
}

@(private = "file", thread_local)
current: ^Fixture

// setup loads a level with a door and an instance of the guard, whose entities have the IDs that the cooker's
// expansion gives them, and writes the guard prefab and its behaviour.
@(private = "file")
setup :: proc(t: ^testing.T, with_scripts := false, load_level := true) -> ^Fixture {
	f := new(Fixture)
	current = f
	clear(&reports)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		file_size = core.file_size,
		// A read across frames never finishes, so a scene that begins to load stays loading.
		file_read_begin = proc(path: string, offset: i64, size: int) -> core.File_Read {return 1},
		file_read_result = proc(read: core.File_Read) -> ([]byte, core.File_Read_State) {
			return nil, .Pending
		},
		file_read_end = proc(read: core.File_Read) {},
		time_seconds = proc() -> f64 {return 0},
		gamepad_rumble = proc(slot: int, low, high: f32, seconds: f64) {},
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
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	scene.register_components(&f.world.registry)
	script.register_components(&f.world.registry)
	temp, err := os.make_directory_temp("", "cutscene_bindings_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	scene.init_scenes(&f.scenes, &f.platform, &f.assets)
	write_scene(t, f, GUARD_GUID, GUARD, .Prefab)
	level_text := fmt.tprintf(
		`scene 2
entity %016x
name = "Door"
component 1 Transform
	position = [3, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]

entity %016x
name = "Guard"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]

entity %016x
name = "Hat"
parent = @%016x
component 2 Local_Transform
	offset = [0, 2, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
`,
		u64(DOOR_ID),
		u64(INSTANCE_ID),
		format.scene_path_id(INSTANCE_ID, HAT_ID),
		u64(INSTANCE_ID),
	)
	write_scene(t, f, LEVEL_GUID, level_text, .Scene)
	write_script(t, f, LIFE_GUID, LIFE)
	if with_scripts {
		testing.expect(
			t,
			script.init(&f.runtime, &f.platform, &f.world, &f.assets, proc(r: ^script.Runtime) {
					scene.register_scripts(r, &current.scenes)
					script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
						append(&reports, luau.L_checknumber(L, 1))
						return 0
					})
				}),
		)
		f.scripts = &f.runtime
		f.scenes.scripts = f.scripts
	}
	if load_level {
		number, loaded := scene.add_scene_asset(&f.world, f.scripts, &f.scenes, LEVEL_GUID)
		testing.expect(t, loaded)
		f.level = number
		f.door = scene.find(&f.scenes, &f.world, number, DOOR_ID)
		f.hat = scene.find(&f.scenes, &f.world, number, format.scene_path_id(INSTANCE_ID, HAT_ID))
		testing.expect(t, f.door != 0 && f.hat != 0)
	}
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	if f.scripts != nil {
		script.destroy(&f.runtime)
	}
	scene.destroy_scenes(&f.scenes)
	asset.destroy(&f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	virtual.arena_destroy(&level)
	core.scene_memories_close_all(&scene_memories)
	delete(reports)
	reports = nil
	current = nil
	free(f)
}

@(private = "file")
write_file :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, blob: []byte) {
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
write_scene :: proc(
	t: ^testing.T,
	f: ^Fixture,
	guid: format.Guid,
	text: string,
	kind: format.Asset_Kind,
) {
	s, problems, ok := format.scene_parse(text, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	write_file(
		t,
		f,
		guid,
		format.scene_write(s, guid, 1, kind, allocator = context.temp_allocator),
	)
}

@(private = "file")
write_script :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, source: string) {
	bytecode := script.compile(source)
	defer luau.free_bytecode(raw_data(bytecode))
	write_file(
		t,
		f,
		guid,
		format.script_write(
			{guid = guid, bytecode = bytecode, source_path = "game/life.luau"},
			context.temp_allocator,
		),
	)
}

@(private = "file")
expect_reports :: proc(t: ^testing.T, expected: []f64, loc := #caller_location) {
	same := len(reports) == len(expected)
	for e, i in expected {
		same = same && reports[i] == e
	}
	testing.expectf(t, same, "reports %v, want %v", reports[:], expected, loc = loc)
	clear(&reports)
}

@(private = "file")
possess :: proc(
	id: u32,
	name: string,
	entity: u64,
	policy := format.Cutscene_Policy.Required,
	guid := LEVEL_GUID,
) -> format.Cutscene_Binding_Contents {
	return {
		id = id,
		kind = .Possessed,
		name = name,
		policy = policy,
		parent = format.CUTSCENE_NONE,
		asset = guid,
		entity = entity,
		rotation = {0, 0, 0, 1},
		scale = {1, 1, 1},
	}
}

@(private = "file")
spawn_binding :: proc(
	id: u32,
	name: string,
	meters: [3]f64 = {},
	parent := format.CUTSCENE_NONE,
) -> format.Cutscene_Binding_Contents {
	return {
		id = id,
		kind = .Spawned,
		name = name,
		parent = parent,
		asset = GUARD_GUID,
		position = ecs.position_from_meters(meters).raw,
		rotation = {0, 0, 0, 1},
		scale = {1, 1, 1},
	}
}

// resolve_of writes a cutscene of the bindings, with no tracks, and gives what resolve_bindings takes.
@(private = "file")
resolve_of :: proc(
	t: ^testing.T,
	f: ^Fixture,
	bindings: []format.Cutscene_Binding_Contents,
) -> Resolve {
	written := format.cutscene_write(
		{
			key = 1,
			length = 60000,
			rate = 30,
			range_end = 60000,
			bindings = bindings,
			source_path = "game/cutscenes/test.cutscene",
		},
		context.temp_allocator,
	)
	// A loaded blob is aligned, and cutscene_view refuses one that is not.
	data, _ := mem.make_aligned([]byte, len(written), 16, f.platform.frame_allocator)
	copy(data, written)
	blob, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	return {
		world = &f.world,
		scenes = &f.scenes,
		scripts = f.scripts,
		assets = &f.assets,
		data = data,
		blob = blob,
	}
}

@(private = "file")
active :: proc(w: ^ecs.World, e: ecs.Entity) -> bool {
	return ecs.active_in_hierarchy(w, e)
}

@(private = "file")
first_child :: proc(w: ^ecs.World, e: ecs.Entity) -> ecs.Entity {
	it := ecs.children_iter(w, e)
	child, _ := ecs.children_next(&it)
	return child
}

@(test)
a_possessed_binding_finds_a_scene_entity_and_one_inside_a_prefab_instance :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	b: Bindings
	defer destroy_bindings(&b, &f.world)
	r := resolve_of(
		t,
		f,
		{
			possess(1, "Door", DOOR_ID),
			possess(2, "Hat", format.scene_path_id_of({INSTANCE_ID, HAT_ID})),
		},
	)
	failure := resolve_bindings(&b, r)
	testing.expect_value(t, failure, nil)
	door, has_door := binding_entity(&b, &f.world, 0)
	hat, has_hat := binding_entity(&b, &f.world, 1)
	testing.expect(t, has_door && has_hat)
	testing.expect_value(t, door, f.door)
	testing.expect_value(t, hat, f.hat)
	// A possessed entity is the scene's: release leaves it.
	testing.expect_value(t, release_bindings(&b, &f.world), 0)
	testing.expect(t, ecs.is_alive(&f.world, f.door) && ecs.is_alive(&f.world, f.hat))
	_, after := binding_entity(&b, &f.world, 0)
	testing.expect(t, !after)
}

@(test)
a_spawned_binding_is_hidden_until_revealed_and_leaves_nothing_after_release :: proc(
	t: ^testing.T,
) {
	f := setup(t, with_scripts = true)
	defer teardown(f)
	w := &f.world
	before := ecs.entity_count(w)
	b: Bindings
	defer destroy_bindings(&b, &f.world)
	r := resolve_of(
		t,
		f,
		{spawn_binding(1, "Extra", {10, 0, 0}), spawn_binding(2, "Rider", {0, 1, 0}, parent = 0)},
	)
	testing.expect_value(t, resolve_bindings(&b, r), nil)
	extra, has_extra := binding_entity(&b, w, 0)
	rider, has_rider := binding_entity(&b, w, 1)
	testing.expect(t, has_extra && has_rider)
	// Two instances of a root and a hat each.
	testing.expect_value(t, ecs.entity_count(w), before + 4)
	testing.expect_value(t, ecs.get(w, rider, ecs.Parent).entity, extra)
	testing.expect_value(
		t,
		ecs.get(w, extra, ecs.Transform).position,
		ecs.position_from_meters({10, 0, 0}),
	)
	testing.expect_value(
		t,
		ecs.get(w, rider, ecs.Transform).position,
		ecs.position_from_meters({10, 1, 0}),
	)
	// No scene owns them, so a scene's unload does not take them.
	testing.expect(
		t,
		!ecs.has(w, extra, scene.Scene_Owned) && !ecs.has(w, extra, scene.Scene_Entity),
	)
	// Every entity of the instances is hidden while the cutscene loads, and its behaviours do not wake.
	hat := first_child(w, extra)
	for e in ([?]ecs.Entity{extra, rider, hat}) {
		loading := ecs.get(w, e, ecs.Loading)
		testing.expect(t, loading != nil && loading.scene == LOADING_SCENE)
		testing.expect(t, !active(w, e))
	}
	script.run_phase(f.scripts, FRAME, {})
	expect_reports(t, {})

	reveal_bindings(&b, w)
	for e in ([?]ecs.Entity{extra, rider, hat}) {
		testing.expect(t, !ecs.has(w, e, ecs.Loading))
		testing.expect(t, active(w, e))
	}
	script.run_phase(f.scripts, FRAME, {})
	expect_reports(t, {1, 2, 1, 2, 3, 3})

	// Release takes both roots, the rider with its parent, and every hat.
	testing.expect_value(t, release_bindings(&b, w), 2)
	script.forget_despawned(f.scripts)
	expect_reports(t, {4, 5, 4, 5})
	for e in ([?]ecs.Entity{extra, rider, hat}) {
		testing.expect(t, !ecs.is_alive(w, e))
	}
	testing.expect_value(t, ecs.entity_count(w), before)
}

@(test)
an_override_wins_over_the_assets_reference :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	stand_in := stand(w)
	before := ecs.entity_count(w)
	b: Bindings
	defer destroy_bindings(&b, &f.world)
	r := resolve_of(t, f, {possess(4, "Door", DOOR_ID), spawn_binding(9, "Extra")})
	failure := resolve_bindings(
		&b,
		r,
		{
			{binding = "Door", entity = stand_in},
			{binding = Binding_Id(9), entity = f.door},
			{binding = "Nobody", entity = stand_in},
		},
	)
	testing.expect_value(t, failure, nil)
	door, _ := binding_entity(&b, w, 0)
	extra, _ := binding_entity(&b, w, 1)
	testing.expect_value(t, door, stand_in)
	testing.expect_value(t, extra, f.door)
	// The overridden spawned binding spawned nothing, and its override is not the cutscene's to despawn.
	testing.expect_value(t, ecs.entity_count(w), before)
	testing.expect_value(t, release_bindings(&b, w), 0)
	testing.expect(t, ecs.is_alive(w, stand_in) && ecs.is_alive(w, f.door))
}

@(test)
an_override_that_is_not_alive_counts_as_missing :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	gone := stand(w)
	ecs.despawn(w, gone)
	b: Bindings
	defer destroy_bindings(&b, &f.world)
	r := resolve_of(t, f, {possess(1, "Door", DOOR_ID), spawn_binding(2, "Extra")})
	failure := resolve_bindings(&b, r, {{Binding_Id(1), gone}, {Binding_Id(2), gone}})
	testing.expect_value(t, failure, nil)
	// The possessed binding falls back to its scene's entity, and the spawned one spawns.
	door, _ := binding_entity(&b, w, 0)
	testing.expect_value(t, door, f.door)
	_, spawned := b.states[1].(Binding_Spawned)
	testing.expect(t, spawned)
	release_bindings(&b, w)
}

@(test)
a_missing_required_binding_fails_with_its_name_and_leaves_nothing :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	f := setup(t)
	defer teardown(f)
	w := &f.world
	before := ecs.entity_count(w)
	b: Bindings
	defer destroy_bindings(&b, &f.world)
	r := resolve_of(
		t,
		f,
		{spawn_binding(1, "Extra"), possess(2, "Ghost", 0xdead), possess(3, "Door", DOOR_ID)},
	)
	failure, failed := resolve_bindings(&b, r).?
	testing.expect(t, failed)
	testing.expect_value(t, failure, Binding_Failure{index = 1, reason = .Missing})
	bindings := format.cutscene_bindings(r.data, r.blob)
	testing.expect_value(t, format.blob_string(r.data, bindings[failure.index].name), "Ghost")
	// The extra that spawned before it is gone again.
	testing.expect_value(t, ecs.entity_count(w), before)
	for i in 0 ..< 3 {
		_, has := binding_entity(&b, w, i)
		testing.expect(t, !has)
	}
}

@(test)
a_missing_optional_binding_resolves_and_gives_no_entity :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	b: Bindings
	defer destroy_bindings(&b, &f.world)
	r := resolve_of(
		t,
		f,
		{
			possess(1, "Ghost", 0xdead, .Optional),
			possess(2, "Elsewhere", DOOR_ID, .Optional, NOWHERE_GUID),
			possess(3, "Door", DOOR_ID),
		},
	)
	testing.expect_value(t, resolve_bindings(&b, r), nil)
	_, ghost := b.states[0].(Binding_Missing)
	_, elsewhere := b.states[1].(Binding_Missing)
	testing.expect(t, ghost && elsewhere)
	_, has := binding_entity(&b, &f.world, 0)
	testing.expect(t, !has)
	door, _ := binding_entity(&b, &f.world, 2)
	testing.expect_value(t, door, f.door)
}

@(test)
a_possessed_entity_that_goes_during_play_gives_no_entity :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	b: Bindings
	defer destroy_bindings(&b, &f.world)
	r := resolve_of(
		t,
		f,
		{
			possess(1, "Door", DOOR_ID),
			possess(2, "Hat", format.scene_path_id(INSTANCE_ID, HAT_ID)),
		},
	)
	testing.expect_value(t, resolve_bindings(&b, r), nil)
	// A despawned entity's binding gives nothing, even after its slot is taken again.
	ecs.despawn(w, f.door)
	stand(w)
	_, has_door := binding_entity(&b, w, 0)
	testing.expect(t, !has_door)
	_, has_hat := binding_entity(&b, w, 1)
	testing.expect(t, has_hat)
	// An entity whose scene unloads counts as despawned.
	scene.unload_scene(w, &f.scenes, f.level)
	_, has_hat = binding_entity(&b, w, 1)
	testing.expect(t, !has_hat)
	testing.expect_value(t, release_bindings(&b, w), 0)
}

@(test)
a_possessed_binding_in_a_scene_that_is_still_loading_is_missing :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	f := setup(t, load_level = false)
	defer teardown(f)
	_, began := scene.begin_load(&f.world, &f.scenes, LEVEL_GUID)
	testing.expect(t, began)
	b: Bindings
	defer destroy_bindings(&b, &f.world)
	r := resolve_of(t, f, {possess(1, "Door", DOOR_ID)})
	failure, failed := resolve_bindings(&b, r).?
	testing.expect(t, failed)
	testing.expect_value(t, failure, Binding_Failure{index = 0, reason = .Missing})
}

// stand spawns an entity with a Transform, for the game's own entities.
@(private = "file")
stand :: proc(w: ^ecs.World) -> ecs.Entity {
	e := ecs.spawn(w)
	ecs.add(w, e, ecs.TRANSFORM_IDENTITY)
	return e
}

@(test)
destroying_bindings_despawns_what_they_spawned :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	before := ecs.entity_count(w)
	b: Bindings
	testing.expect_value(
		t,
		resolve_bindings(&b, resolve_of(t, f, {spawn_binding(1, "Extra")})),
		nil,
	)
	extra, _ := binding_entity(&b, w, 0)
	destroy_bindings(&b, w)
	testing.expect(t, !ecs.is_alive(w, extra))
	testing.expect_value(t, ecs.entity_count(w), before)
}
