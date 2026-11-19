package scene

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "core:time"

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

// What the scripts reported with Test.report. Each test thread has its own.
@(private = "file", thread_local)
reports: [dynamic]f64

// A turret, whose barrel refers to it, and whose root has a behaviour that reports its callbacks.
@(private = "file")
TURRET :: `scene 2
entity 1000000000000001
name = "Turret"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
behaviour 70000000000000000000000000000002

entity 1000000000000002
name = "Barrel"
parent = @1000000000000001
component 2 Local_Transform
	offset = [0, 1, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
component 100 Probe
	target = @1000000000000001
	ratio = 0.5
`

// The night sublevel's part of the court, whose base is YARD.
@(private = "file")
NIGHT :: `scene 2
entity 00000000000000c1
name = "Lamp"
`

// A scene for the turrets to belong to.
@(private = "file")
YARD :: `scene 2
entity 00000000000000d1
name = "Yard"
`

@(private = "file")
COURT_GUID :: format.Guid {
	0  = 0x70,
	15 = 5,
}

@(private = "file")
NIGHT_GUID :: format.Guid {
	0  = 0x70,
	15 = 6,
}

@(private = "file")
TURRET_GUID :: format.Guid {
	0  = 0x70,
	15 = 1,
}

@(private = "file")
LIFECYCLE_GUID :: format.Guid {
	0  = 0x70,
	15 = 2,
}

@(private = "file")
SPAWNER_GUID :: format.Guid {
	0  = 0x70,
	15 = 3,
}

@(private = "file")
YARD_GUID :: format.Guid {
	0  = 0x70,
	15 = 4,
}

// The turret's behaviour reports 1 to 5 for awake, on_enable, start, on_disable and on_destroy.
@(private = "file")
LIFECYCLE :: `
local Life = Behaviour.define("Life")
function Life:awake() Test.report(1) end
function Life:on_enable() Test.report(2) end
function Life:start() Test.report(3) end
function Life:on_disable() Test.report(4) end
function Life:on_destroy() Test.report(5) end
return Life`

// A behaviour that takes a turret from the pool, gives it back, and takes it again.
@(private = "file")
SPAWNER :: `
local Spawner = Behaviour.define("Spawner", {prefab = Field.asset("prefab")})
function Spawner:start()
	local first = Pool.spawn(self.prefab, WorldPosition.from_meters(2, 0, 0))
	Test.report(10)
	Pool.release(first)
	Test.report(11)
	local second = Pool.spawn(self.prefab)
	Test.report(first == second and 12 or 0)
	local ok = pcall(Pool.release, self.entity)
	Test.report(ok and 0 or 13)
end
return Spawner`

// A component that the game adds, which the prefab does not have.
@(private = "file")
MARK_ID :: ecs.Component_Id(101)

@(private = "file")
Mark :: struct {
	value: i32,
}

@(private = "file")
FRAME :: 16 * time.Millisecond

@(private = "file")
Pool_Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	assets:   asset.Assets,
	scenes:   Scenes,
	runtime:  script.Runtime,
	scripts:  ^script.Runtime,
	dir:      string,
}

// The fixture of the test that runs on this thread, for the runtime's Register_Proc.
@(private = "file", thread_local)
current: ^Pool_Fixture

@(private = "file")
setup :: proc(t: ^testing.T, with_scripts := false) -> ^Pool_Fixture {
	f := new(Pool_Fixture)
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
	ecs.register_component(&f.world.registry, Mark, MARK_ID)
	script.register_components(&f.world.registry)
	temp, err := os.make_directory_temp("", "pool_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	init_scenes(&f.scenes, &f.platform, &f.assets)
	write_scene(t, f, TURRET_GUID, TURRET, .Prefab)
	write_scene(t, f, YARD_GUID, YARD, .Scene)
	write_court(t, f)
	write_script(t, f, LIFECYCLE_GUID, LIFECYCLE)
	write_script(t, f, SPAWNER_GUID, SPAWNER)
	if with_scripts {
		testing.expect(
			t,
			script.init(&f.runtime, &f.platform, &f.world, &f.assets, proc(r: ^script.Runtime) {
					register_scripts(r, &current.scenes)
					script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
						append(&reports, luau.L_checknumber(L, 1))
						return 0
					})
				}),
		)
		f.scripts = &f.runtime
		f.scenes.scripts = f.scripts
	}
	return f
}

@(private = "file")
teardown :: proc(f: ^Pool_Fixture) {
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
	delete(reports)
	reports = nil
	current = nil
	free(f)
}

@(private = "file")
write_file :: proc(t: ^testing.T, f: ^Pool_Fixture, guid: format.Guid, blob: []byte) {
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
	f: ^Pool_Fixture,
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

// write_court writes a scene whose base lists a night sublevel, and the night's part, which has a lamp.
@(private = "file")
write_court :: proc(t: ^testing.T, f: ^Pool_Fixture) {
	base, problems, ok := format.scene_parse(YARD, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	write_file(
		t,
		f,
		COURT_GUID,
		format.scene_write(
			base,
			COURT_GUID,
			1,
			.Scene,
			sublevels = []format.Scene_Sublevel{{"night", NIGHT_GUID}},
			allocator = context.temp_allocator,
		),
	)
	write_scene(t, f, NIGHT_GUID, NIGHT, .Scene)
}

@(private = "file")
write_script :: proc(t: ^testing.T, f: ^Pool_Fixture, guid: format.Guid, source: string) {
	bytecode := script.compile(source)
	defer luau.free_bytecode(raw_data(bytecode))
	write_file(
		t,
		f,
		guid,
		format.script_write(
			{guid = guid, bytecode = bytecode, source_path = "game/pool.luau"},
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
meters :: proc(x: f64) -> ecs.Transform {
	pose := ecs.TRANSFORM_IDENTITY
	pose.position = {
		raw = {i64(x * 16777216), 0, 0},
	}
	return pose
}

// The barrel of a turret: the entity with a Probe whose Parent is the root.
@(private = "file")
barrel_of :: proc(w: ^ecs.World, root: ecs.Entity) -> ecs.Entity {
	probes := make([dynamic]ecs.Entity, context.temp_allocator)
	ecs.collect(w, {PROBE_ID}, &probes)
	for e in probes {
		if parent := ecs.get(w, e, ecs.Parent); parent != nil && parent.entity == root {
			return e
		}
	}
	return 0
}

// An instance that goes back to the pool comes out again as the prefab spawns it: the same entities, with the
// prefab's values, and without what the game added.
@(test)
a_pooled_instance_spawns_again_with_the_prefabs_values :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	root, ok := pool_spawn(&f.scenes, w, TURRET_GUID, meters(1))
	testing.expect(t, ok)
	barrel := barrel_of(w, root)
	testing.expect(t, barrel != 0)
	count := ecs.entity_count(w)

	// The game plays with it: it renames the turret, points the barrel away, aims it and marks it.
	ecs.add(w, root, ecs.intern(w, "Wreck"))
	probe := ecs.get(w, barrel, Probe)
	probe.target = 0
	probe.ratio = 2
	ecs.get(w, barrel, ecs.Local_Transform).offset = {5, 5, 5}
	ecs.add(w, barrel, Mark{7})
	ecs.add(w, barrel, ecs.Disabled{})
	ecs.update_activity(w)

	testing.expect(t, pool_release(&f.scenes, w, root))
	testing.expect_value(t, pool_count(&f.scenes, TURRET_GUID), 1)
	// It waits in the world, inactive.
	testing.expect(t, ecs.is_alive(w, root))
	testing.expect(t, ecs.has(w, root, ecs.Inactive))
	testing.expect(t, ecs.has(w, barrel, ecs.Inactive))
	// Only a live instance's root goes back, and only once.
	testing.expect(t, !pool_release(&f.scenes, w, root))
	testing.expect(t, !pool_release(&f.scenes, w, barrel))

	again, again_ok := pool_spawn(&f.scenes, w, TURRET_GUID, meters(3))
	testing.expect(t, again_ok)
	testing.expect_value(t, again, root)
	testing.expect_value(t, barrel_of(w, again), barrel)
	testing.expect_value(t, ecs.entity_count(w), count)
	testing.expect_value(t, pool_count(&f.scenes, TURRET_GUID), 0)

	// The prefab's values, at the new pose, active.
	testing.expect_value(t, ecs.get(w, root, ecs.Transform).position, meters(3).position)
	testing.expect_value(t, ecs.name_text(w, ecs.get(w, root, ecs.Name)^), "Turret")
	testing.expect_value(t, ecs.get(w, barrel, Probe).target, root)
	testing.expect_value(t, ecs.get(w, barrel, Probe).ratio, 0.5)
	testing.expect_value(t, ecs.get(w, barrel, ecs.Local_Transform).offset, [3]f32{0, 1, 0})
	testing.expect(t, !ecs.has(w, barrel, Mark))
	testing.expect(t, !ecs.has(w, root, ecs.Inactive))
	testing.expect(t, !ecs.has(w, barrel, ecs.Inactive))
	testing.expect(t, !ecs.has(w, barrel, ecs.Disabled))

	// A second spawn while the first is out makes a new instance.
	other, other_ok := pool_spawn(&f.scenes, w, TURRET_GUID, meters(0))
	testing.expect(t, other_ok)
	testing.expect(t, other != root)
	testing.expect_value(t, ecs.entity_count(w), 2 * count)
}

// An instance whose entities the game despawned is replaced by a whole one.
@(test)
a_broken_pooled_instance_is_replaced :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	root, _ := pool_spawn(&f.scenes, w, TURRET_GUID, meters(0))
	count := ecs.entity_count(w)
	ecs.despawn(w, barrel_of(w, root))
	testing.expect(t, pool_release(&f.scenes, w, root))

	again, ok := pool_spawn(&f.scenes, w, TURRET_GUID, meters(0))
	testing.expect(t, ok)
	testing.expect(t, !ecs.is_alive(w, root))
	testing.expect_value(t, ecs.entity_count(w), count)
	barrel := barrel_of(w, again)
	testing.expect(t, barrel != 0)
	testing.expect_value(t, ecs.get(w, barrel, Probe).target, again)
}

// An instance in use goes with its scene. A waiting one belongs to no scene, so it outlives the scene that released it
// and the next spawn takes it, with that spawn's owner. An unload of the level forgets the pools.
@(test)
a_waiting_instance_outlives_its_scene :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	number, loaded := add_scene_asset(w, nil, &f.scenes, YARD_GUID)
	testing.expect(t, loaded)
	waiting, _ := pool_spawn(&f.scenes, w, TURRET_GUID, meters(0), number)
	out, _ := pool_spawn(&f.scenes, w, TURRET_GUID, meters(0), number)
	testing.expect(t, pool_release(&f.scenes, w, waiting))
	_, waiting_owned := scene_of(w, waiting)
	testing.expect(t, !waiting_owned)

	unload_scene(w, &f.scenes, number)
	testing.expect(t, ecs.is_alive(w, waiting))
	testing.expect(t, !ecs.is_alive(w, out))
	forget_despawned_pools(&f.scenes, w)
	testing.expect_value(t, len(f.scenes.pools.live), 0)
	testing.expect_value(t, pool_count(&f.scenes, TURRET_GUID), 1)

	again, loaded_again := add_scene_asset(w, nil, &f.scenes, YARD_GUID)
	testing.expect(t, loaded_again)
	reused, ok := pool_spawn(&f.scenes, w, TURRET_GUID, meters(0), again)
	testing.expect(t, ok)
	testing.expect_value(t, reused, waiting)
	owner, owned := scene_of(w, reused)
	testing.expect(t, owned)
	testing.expect_value(t, owner, again)

	testing.expect_value(t, pool_reserve(&f.scenes, w, TURRET_GUID, 3), 3)
	testing.expect_value(t, pool_count(&f.scenes, TURRET_GUID), 3)
	unload_level(w, &f.scenes)
	testing.expect_value(t, pool_count(&f.scenes, TURRET_GUID), 0)
	testing.expect_value(t, len(f.scenes.pools.live), 0)
}

// A sublevel's part is a scene, so a deactivated sublevel takes the instances that its behaviours have in use, and
// leaves the waiting ones in the pool, which the part takes again when the sublevel comes back.
@(test)
a_sublevel_leaves_its_waiting_instances_in_the_pool :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	base, loaded := add_scene_asset(w, nil, &f.scenes, COURT_GUID)
	testing.expect(t, loaded)
	testing.expect_value(t, load_parts(w, nil, &f.scenes, base, {"night"}), 1)
	night, has_night := part_number(&f.scenes, base, "night")
	testing.expect(t, has_night)

	waiting, _ := pool_spawn(&f.scenes, w, TURRET_GUID, meters(0), night)
	out, _ := pool_spawn(&f.scenes, w, TURRET_GUID, meters(0), night)
	testing.expect(t, pool_release(&f.scenes, w, waiting))
	count := ecs.entity_count(w)

	// Deactivating the sublevel unloads its part: its lamp and the turret in use, with its barrel.
	testing.expect_value(t, update_parts(w, &f.scenes, {}), 3)
	_, still := part_number(&f.scenes, base, "night")
	testing.expect(t, !still)
	testing.expect(t, !ecs.is_alive(w, out))
	testing.expect(t, ecs.is_alive(w, waiting))
	testing.expect_value(t, ecs.entity_count(w), count - 3)
	forget_despawned_pools(&f.scenes, w)
	testing.expect_value(t, len(f.scenes.pools.live), 0)
	testing.expect_value(t, pool_count(&f.scenes, TURRET_GUID), 1)

	// It comes back as a new part, whose first spawn takes the waiting turret, with the prefab's values.
	testing.expect_value(t, load_parts(w, nil, &f.scenes, base, {"night"}), 1)
	night, _ = part_number(&f.scenes, base, "night")
	reused, ok := pool_spawn(&f.scenes, w, TURRET_GUID, meters(2), night)
	testing.expect(t, ok)
	testing.expect_value(t, reused, waiting)
	owner, _ := scene_of(w, reused)
	testing.expect_value(t, owner, night)
	testing.expect(t, !ecs.has(w, reused, ecs.Inactive))
	testing.expect_value(t, ecs.get(w, barrel_of(w, reused), Probe).target, reused)
	testing.expect_value(t, pool_count(&f.scenes, TURRET_GUID), 0)
}

// A reused instance's behaviours end when it goes back, and start again as new ones when it comes out.
@(test)
a_pooled_instance_has_the_lifecycle_of_a_fresh_spawn :: proc(t: ^testing.T) {
	f := setup(t, with_scripts = true)
	defer teardown(f)
	w := &f.world

	root, ok := pool_spawn(&f.scenes, w, TURRET_GUID, meters(0))
	testing.expect(t, ok)
	script.run_phase(f.scripts, FRAME, {})
	expect_reports(t, {1, 2, 3})

	testing.expect(t, pool_release(&f.scenes, w, root))
	expect_reports(t, {4, 5})
	script.run_phase(f.scripts, FRAME, {})
	expect_reports(t, {})

	again, _ := pool_spawn(&f.scenes, w, TURRET_GUID, meters(0))
	testing.expect_value(t, again, root)
	script.run_phase(f.scripts, FRAME, {})
	expect_reports(t, {1, 2, 3})

	// A reserved instance attaches its behaviours only when it comes out.
	testing.expect_value(t, pool_reserve(&f.scenes, w, TURRET_GUID, 1), 1)
	script.run_phase(f.scripts, FRAME, {})
	expect_reports(t, {})
	pool_spawn(&f.scenes, w, TURRET_GUID, meters(0))
	script.run_phase(f.scripts, FRAME, {})
	expect_reports(t, {1, 2, 3})
}

// Pool.spawn wakes the instance's behaviours before it returns, as World.spawn(prefab) does, and Pool.release ends
// them before it returns.
@(test)
scripts_spawn_from_a_pool_and_give_back :: proc(t: ^testing.T) {
	f := setup(t, with_scripts = true)
	defer teardown(f)
	context.logger = log_nothing()
	w := &f.world
	spawner := ecs.spawn(w)
	testing.expect(
		t,
		script.attach_script(
			f.scripts,
			spawner,
			SPAWNER_GUID,
			{{name = "prefab", kind = .Asset, asset = TURRET_GUID}},
		),
	)
	script.run_phase(f.scripts, FRAME, {})
	testing.expectf(
		t,
		len(reports) >= 10 &&
		reports[0] == 1 &&
		reports[1] == 2 &&
		reports[2] == 10 &&
		reports[3] == 4 &&
		reports[4] == 5 &&
		reports[5] == 11 &&
		reports[6] == 1 &&
		reports[7] == 2 &&
		reports[8] == 12 &&
		reports[9] == 13,
		"reports %v",
		reports[:],
	)
}

// A logger that drops what a test expects to be logged, such as the error that a refused Pool.release raises.
@(private = "file")
log_nothing :: proc() -> runtime.Logger {
	return {
		procedure = proc(
			data: rawptr,
			level: runtime.Logger_Level,
			text: string,
			options: runtime.Logger_Options,
			location := #caller_location,
		) {},
	}
}
