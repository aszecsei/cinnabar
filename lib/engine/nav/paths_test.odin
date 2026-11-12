package nav

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:core/testlog"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The scheduler is a singleton, and the test runner runs tests on several threads.
@(private = "file")
lock: sync.Mutex

@(private = "file")
Fixture :: struct {
	frame:    virtual.Arena,
	platform: core.Platform_API,
	world:    ecs.World,
	cache:    string,
	assets:   asset.Assets,
	nav:      State,
	serial:   bool,
	cooks:    int,
	// With scripts: the runtime, the entity that Test.agent gives, and what Test.report reported.
	scripts:  bool,
	runtime:  script.Runtime,
	agent:    ecs.Entity,
	reports:  [dynamic]f64,
}

@(private = "file")
SCENE :: format.Guid{0 = 0x5c}
@(private = "file")
HUMAN :: format.Guid{0 = 0x41}
@(private = "file")
SMALL :: format.Guid{0 = 0x42}

// setup makes a world with nav's components and system, over a loose cache. serial runs every job at once on the
// calling thread, as one job would; otherwise the scheduler has workers threads.
@(private = "file")
setup :: proc(t: ^testing.T, serial := false, workers := 0, scripts := false) -> ^Fixture {
	sync.lock(&lock)
	f := new(Fixture)
	f.serial = serial
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		jobs_run = jobs.run,
		jobs_wait = jobs.wait,
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
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {return 0},
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
	}
	if serial {
		f.platform.jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		}
		f.platform.jobs_wait = proc(counter: ^jobs.Counter) {}
	} else {
		testing.expect(t, jobs.init(workers))
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	cache, err := os.make_directory_temp("", "nav_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	init(&f.nav, &f.platform, &f.assets)
	register(&f.nav, &f.world)
	if scripts {
		f.scripts = true
		f.reports = make([dynamic]f64)
		script.register_components(&f.world.registry)
		context.user_ptr = f
		testing.expect(t, script.init(&f.runtime, &f.platform, &f.world, nil, register_test_scripts))
	}
	return f
}

@(private = "file")
register_test_scripts :: proc(r: ^script.Runtime) {
	f := (^Fixture)(context.user_ptr)
	register_scripts(r, &f.nav)
	script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
		f := (^Fixture)(context.user_ptr)
		append(&f.reports, luau.L_checknumber(L, 1))
		return 0
	})
	script.define(r, "Test.agent", proc(L: ^luau.State) -> c.int {
		script.push_entity(L, (^Fixture)(context.user_ptr).agent)
		return 1
	})
}

@(private = "file")
teardown :: proc(t: ^testing.T, f: ^Fixture) {
	if f.scripts {
		script.destroy(&f.runtime)
		delete(f.reports)
	}
	destroy(&f.nav)
	asset.destroy(&f.assets)
	os.remove_all(f.cache)
	delete(f.cache)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	if !f.serial {
		testing.expect(t, jobs.drain_frame())
		jobs.shutdown()
	}
	free(f)
	sync.unlock(&lock)
}

@(private = "file")
write_blob :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, data: []byte) {
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(guid, &buffer))
	testing.expect(t, os.write_entire_file(path, data) == nil)
}

// write_scene writes the scene's blob, which lists its navmeshes on the volume 0x100.
@(private = "file")
write_scene :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, meshes: []Scene_Mesh) {
	listed := make([]format.Scene_Nav_Mesh, len(meshes), context.temp_allocator)
	for m, i in meshes {
		listed[i] = {entity = 0x100, agent = m.agent, guid = m.guid}
	}
	write_blob(t, f, guid, format.scene_write({}, guid, 1, nav_meshes = listed, allocator = context.temp_allocator))
}

@(private = "file")
Scene_Mesh :: struct {
	agent: string,
	guid:  format.Guid,
}

// cook ends a cook as the cooker does: it writes the cache's generation file, and the blobs' and its times move on, as
// the poll looks for a new time, which a write in the same moment can lack. Then the frame's end polls.
@(private = "file")
cook :: proc(t: ^testing.T, f: ^Fixture, written: ..format.Guid) {
	f.cooks += 1
	later := time.time_add(time.now(), time.Duration(f.cooks) * time.Minute)
	generation := fmt.tprintf("%s/%s", f.cache, format.GENERATION_FILE)
	testing.expect(t, os.write_entire_file(generation, transmute([]byte)fmt.tprintf("%d", f.cooks)) == nil)
	testing.expect(t, os.change_times(generation, later, later) == nil)
	for guid in written {
		buffer: [32]u8
		path := fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(guid, &buffer))
		testing.expect(t, os.change_times(path, later, later) == nil)
	}
	asset.poll(&f.assets)
}

// standard_scene writes the standard grid for Human and, without its wall, for Small, and the scene that lists them,
// and makes it the world's.
@(private = "file")
standard_scene :: proc(t: ^testing.T, f: ^Fixture) {
	write_blob(t, f, HUMAN, standard_grid("Human", 0, guid = HUMAN))
	write_blob(t, f, SMALL, standard_grid("Small", 1, wall = false, guid = SMALL))
	write_scene(t, f, SCENE, {{"Human", HUMAN}, {"Small", SMALL}})
	f.world.scene = SCENE
}

// frame runs a frame of one fixed tick as the frame code does: prepare, the tick's systems, and the frame's end.
@(private = "file")
frame :: proc(f: ^Fixture, n := 1) {
	for _ in 0 ..< n {
		free_all(f.platform.frame_allocator)
		prepare(&f.nav, &f.world)
		clock := &f.world.clock
		it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
		for ecs.next_tick(&it) {
			ecs.run_tick_systems(&it, f)
			ecs.update_transforms(&f.world)
		}
		end_frame(&f.nav)
	}
	// The next frame's queries read the views again.
	free_all(f.platform.frame_allocator)
	prepare(&f.nav, &f.world)
}

@(private = "file")
agent :: proc(f: ^Fixture, x, z: f64, type: Agent_Type = 0) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{position = at(x, 0, z), rotation = 1, scale = 1})
	ecs.add(&f.world, e, Nav_Path{agent = type})
	return e
}

@(private = "file")
status_of :: proc(f: ^Fixture, e: ecs.Entity) -> Path_Status {
	return ecs.get(&f.world, e, Nav_Path).status
}

@(test)
navmeshes_load_and_unload_with_the_scene :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	standard_scene(t, f)
	frame(f)
	testing.expect_value(t, len(f.nav.frame), 2)
	small, ok := agent_type(&f.nav, "Small")
	testing.expect(t, ok && small == 1)
	_, loaded := asset.find(&f.assets, HUMAN)
	testing.expect(t, loaded)
	// Another scene, without navmeshes: the first's go.
	OTHER :: format.Guid{0 = 0x77}
	write_scene(t, f, OTHER, {})
	f.world.scene = OTHER
	frame(f)
	testing.expect_value(t, len(f.nav.frame), 0)
	_, loaded = asset.find(&f.assets, HUMAN)
	testing.expect(t, !loaded)
	_, loaded = asset.find(&f.assets, SCENE)
	testing.expect(t, !loaded)
	// No scene.
	f.world.scene = {}
	frame(f)
	_, loaded = asset.find(&f.assets, OTHER)
	testing.expect(t, !loaded)
	testing.expect(t, f.nav.scene == nil)
}

@(test)
a_missing_scene_loads_after_a_cook :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	context.logger = testlog.expected_errors()
	f.world.scene = SCENE
	frame(f)
	_, missing := f.nav.scene.(Scene_Missing)
	testing.expect(t, missing)
	testing.expect_value(t, len(f.nav.frame), 0)
	// The scene cooks first, and its navmesh in a later cook.
	write_scene(t, f, SCENE, {{"Human", HUMAN}})
	cook(t, f, SCENE)
	frame(f)
	testing.expect_value(t, len(f.nav.frame), 0)
	write_blob(t, f, HUMAN, standard_grid(guid = HUMAN))
	cook(t, f, HUMAN)
	frame(f)
	testing.expect_value(t, len(f.nav.frame), 1)
}

@(test)
a_scene_that_lists_another_navmesh_loads_it :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	write_blob(t, f, HUMAN, standard_grid(guid = HUMAN))
	write_scene(t, f, SCENE, {{"Human", HUMAN}})
	f.world.scene = SCENE
	frame(f)
	testing.expect_value(t, len(f.nav.frame), 1)
	// A volume for Small is added: the scene cooks again with both, and Human's stays loaded.
	write_blob(t, f, SMALL, standard_grid("Small", 1, guid = SMALL))
	write_scene(t, f, SCENE, {{"Human", HUMAN}, {"Small", SMALL}})
	cook(t, f, SCENE, SMALL)
	frame(f)
	testing.expect_value(t, len(f.nav.frame), 2)
	h, _ := asset.find(&f.assets, HUMAN)
	testing.expect_value(t, asset.version(&f.assets, h), 1)
}

// The agents of the budget's tests: their starts and their goals on the standard grid.
@(private = "file")
TRIPS := [?][2][2]f64 {
	{{2.5, 2.5}, {9.5, 5.5}},
	{{0.5, 0.5}, {7.5, 0.5}},
	{{11.5, 7.5}, {0.5, 0.5}},
	{{3.5, 6.5}, {9.5, 4.5}},
	{{5.5, 0.5}, {5.5, 7.5}},
	{{7.5, 3.5}, {1.5, 5.5}},
}

@(private = "file")
Trip_Result :: struct {
	status:  Path_Status,
	corners: []ecs.World_Position,
	// The frame that it was ready after.
	frame:   int,
}

// run_trips asks for each trip's path in one frame, and runs frames until every one is solved.
@(private = "file")
run_trips :: proc(t: ^testing.T, f: ^Fixture, budget: int) -> (out: [len(TRIPS)]Trip_Result) {
	standard_scene(t, f)
	set_budget(&f.nav, budget)
	frame(f)
	agents: [len(TRIPS)]ecs.Entity
	for trip, i in TRIPS {
		agents[i] = agent(f, trip[0].x, trip[0].y)
		request_path(requests(&f.nav), agents[i], at(trip[1].x, 0, trip[1].y))
	}
	for n in 1 ..= 500 {
		frame(f)
		done := true
		for e, i in agents {
			status := status_of(f, e)
			if status != .Pending && out[i].frame == 0 {
				out[i] = {status, slice.clone(path_corners(&f.nav, &f.world, e), context.temp_allocator), n}
			}
			done &&= status != .Pending
		}
		if done {
			break
		}
	}
	return
}

@(test)
requests_spread_over_ticks_by_the_node_budget :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	standard_scene(t, f)
	set_budget(&f.nav, 12)
	frame(f)
	agents: [len(TRIPS)]ecs.Entity
	for trip, i in TRIPS {
		agents[i] = agent(f, trip[0].x, trip[0].y)
		request_path(requests(&f.nav), agents[i], at(trip[1].x, 0, trip[1].y))
	}
	// The first tick admits them all, and shares 12 nodes among the six searches.
	frame(f)
	for e in agents {
		testing.expect_value(t, status_of(f, e), Path_Status.Pending)
	}
	for &a in f.nav.searches[:len(TRIPS)] {
		testing.expect_value(t, a.search.expanded, 2)
	}
	testing.expect_value(t, len(f.nav.queue), len(TRIPS))
	ready: [len(TRIPS)]int
	for n in 2 ..= 200 {
		frame(f)
		for e, i in agents {
			if ready[i] == 0 && status_of(f, e) != .Pending {
				ready[i] = n
			}
		}
	}
	first, last := max(int), 0
	for e, i in agents {
		testing.expect_value(t, status_of(f, e), Path_Status.Found)
		first, last = min(first, ready[i]), max(last, ready[i])
		// The path is the one that a search with no budget finds.
		trip := TRIPS[i]
		want := find_path(&f.nav, at(trip[0].x, 0, trip[0].y), at(trip[1].x, 0, trip[1].y), 0)
		testing.expect(t, slice.equal(path_corners(&f.nav, &f.world, e), want.corners))
		testing.expect_value(t, ecs.get(&f.world, e, Nav_Path).corners, u32(len(want.corners)))
	}
	testing.expectf(t, first > 2 && last > first, "the paths are ready from frame %d to %d", first, last)
}

@(test)
paths_are_the_same_on_one_job_and_many :: proc(t: ^testing.T) {
	results: [4][len(TRIPS)]Trip_Result
	configs := [4]struct {
		serial: bool,
		budget: int,
	}{{true, 8}, {false, 8}, {true, 10000}, {false, 10000}}
	for c, i in configs {
		f := setup(t, serial = c.serial, workers = 8)
		results[i] = run_trips(t, f, c.budget)
		teardown(t, f)
	}
	for r, i in results[1:] {
		for trip, j in r {
			testing.expect_value(t, trip.status, results[0][j].status)
			testing.expectf(t, slice.equal(trip.corners, results[0][j].corners), "config %d, trip %d", i + 1, j)
		}
	}
	// The same budget solves each in the same frame on one job or many; a larger one, sooner.
	for j in 0 ..< len(TRIPS) {
		testing.expect_value(t, results[1][j].frame, results[0][j].frame)
		testing.expect(t, results[2][j].frame < results[0][j].frame)
	}
}

@(test)
a_recooked_navmesh_finds_its_paths_again :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	standard_scene(t, f)
	frame(f)
	e := agent(f, 2.5, 2.5)
	request_path(requests(&f.nav), e, at(7.5, 0, 2.5))
	frame(f)
	testing.expect_value(t, status_of(f, e), Path_Status.Found)
	around := len(path_corners(&f.nav, &f.world, e))
	testing.expect(t, around > 2)
	// The wall goes: the path is found again, straight.
	write_blob(t, f, HUMAN, standard_grid(wall = false, guid = HUMAN))
	cook(t, f, HUMAN)
	frame(f)
	testing.expect_value(t, status_of(f, e), Path_Status.Found)
	testing.expect_value(t, len(path_corners(&f.nav, &f.world, e)), 2)
}

@(test)
paths_are_freed_with_their_entities :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	standard_scene(t, f)
	frame(f)
	a, b := agent(f, 2.5, 2.5), agent(f, 0.5, 0.5)
	request_path(requests(&f.nav), a, at(9.5, 0, 5.5))
	request_path(requests(&f.nav), b, at(9.5, 0, 5.5))
	frame(f)
	testing.expect(t, path_corners(&f.nav, &f.world, a) != nil)
	ecs.despawn(&f.world, a)
	ecs.remove(&f.world, b, Nav_Path)
	frame(f)
	testing.expect_value(t, len(f.nav.paths.free), 2)
	// A new request reuses a slot, with its generation moved on.
	c := agent(f, 2.5, 2.5)
	request_path(requests(&f.nav), c, at(9.5, 0, 5.5))
	frame(f)
	h := ecs.get(&f.world, c, Nav_Path).path
	testing.expect_value(t, h.generation, 2)
}

@(test)
a_new_request_supersedes_the_last :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	standard_scene(t, f)
	set_budget(&f.nav, 1)
	frame(f)
	e := agent(f, 2.5, 2.5)
	request_path(requests(&f.nav), e, at(9.5, 0, 5.5))
	frame(f)
	h := ecs.get(&f.world, e, Nav_Path).path
	request_path(requests(&f.nav), e, at(3.5, 0, 2.5))
	frame(f, 5)
	np := ecs.get(&f.world, e, Nav_Path)
	testing.expect_value(t, np.path, h)
	testing.expect_value(t, np.status, Path_Status.Found)
	testing.expect_value(t, len(f.nav.queue), 0)
	corners := path_corners(&f.nav, &f.world, e)
	testing.expect_value(t, len(corners), 2)
}

@(test)
a_duplicated_agent_has_no_path :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	standard_scene(t, f)
	frame(f)
	e := agent(f, 2.5, 2.5)
	request_path(requests(&f.nav), e, at(9.5, 0, 5.5))
	frame(f)
	copy := ecs.spawn(&f.world)
	ecs.add(&f.world, copy, ecs.get(&f.world, e, ecs.Transform)^)
	ecs.add(&f.world, copy, ecs.get(&f.world, e, Nav_Path)^)
	frame(f)
	testing.expect_value(t, status_of(f, copy), Path_Status.None)
	testing.expect(t, path_corners(&f.nav, &f.world, copy) == nil)
	testing.expect_value(t, status_of(f, e), Path_Status.Found)
}

@(test)
an_agent_off_the_navmesh_fails :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	standard_scene(t, f)
	frame(f)
	off, other := agent(f, -20, -20), agent(f, 2.5, 2.5, type = 7)
	request_path(requests(&f.nav), off, at(9.5, 0, 5.5))
	request_path(requests(&f.nav), other, at(9.5, 0, 5.5))
	frame(f)
	testing.expect_value(t, status_of(f, off), Path_Status.Failed)
	testing.expect_value(t, status_of(f, other), Path_Status.Failed)
}

@(private = "file")
Asker_A :: struct {
	tag: u32,
}

@(private = "file")
Asker_B :: struct {
	tag: u32,
}

// Two Fixed systems ask in one tick: the requests are admitted in system order, not in the entities' order, whichever
// job ran first.
@(test)
requests_from_systems_land_in_system_order :: proc(t: ^testing.T) {
	f := setup(t, workers = 4)
	defer teardown(t, f)
	ecs.register_component(&f.world.registry, Asker_A, 9001)
	ecs.register_component(&f.world.registry, Asker_B, 9002)
	ask :: proc(ctx: ^ecs.System_Context) {
		s := (^State)(ctx.data)
		it := ecs.query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
		for view in ecs.query_next(&it) {
			for e in ecs.entities(view) {
				request_path(job_requests(s, ctx), e, at(9.5, 0, 5.5))
			}
		}
	}
	ecs.register_system(&f.world, {name = "a", stage = .Fixed, procedure = ask, terms = {ecs.read(&f.world, Asker_A)}, data = &f.nav})
	ecs.register_system(&f.world, {name = "b", stage = .Fixed, procedure = ask, terms = {ecs.read(&f.world, Asker_B)}, data = &f.nav})
	standard_scene(t, f)
	set_budget(&f.nav, 1)
	frame(f)
	b := agent(f, 0.5, 0.5)
	ecs.add(&f.world, b, Asker_B{})
	a := agent(f, 2.5, 2.5)
	ecs.add(&f.world, a, Asker_A{})
	frame(f, 2)
	testing.expect_value(t, len(f.nav.queue), 2)
	if len(f.nav.queue) == 2 {
		testing.expect_value(t, f.nav.paths.slots[f.nav.queue[0].index].entity, a)
		testing.expect_value(t, f.nav.paths.slots[f.nav.queue[1].index].entity, b)
	}
}

// Scripts find paths, walk along the navmesh, snap to it and draw points on it, and ask for an entity's path.
@(test)
scripts_find_paths :: proc(t: ^testing.T) {
	f := setup(t, serial = true, scripts = true)
	defer teardown(t, f)
	standard_scene(t, f)
	frame(f)
	f.agent = agent(f, 2.5, 2.5)
	context.user_ptr = f
	_, ok := script.spawn_source(&f.runtime, "=queries", `
local origin = WorldPosition.from_meters(1000, 2, -500)
local function at(x: number, z: number) return origin + vector.create(x, 0, z) end
local path = Navigation.find_path(at(2.5, 2.5), at(9.5, 5.5), "Human")
Test.report(path.status == "found" and #path.corners > 2 and 1 or 0)
Test.report((path.corners[#path.corners] - origin).x)
Test.report(Navigation.find_path(at(2.5, 2.5), at(9.5, 5.5), "Large").status == "failed" and 1 or 0)
Test.report(Navigation.find_path(at(2.5, 2.5), at(9.5, 1.5), "Human").status == "partial" and 1 or 0)
local hit = Navigation.raycast(at(2.5, 2.5), at(9.5, 2.5), "Human")
Test.report(hit.t)
Test.report(hit.normal.x)
Test.report(Navigation.raycast(at(0.5, 0.5), at(1.5, 0.5), "Human").normal == nil and 1 or 0)
Test.report((Navigation.nearest(at(6.4, 2.5), "Human", vector.create(1, 1, 1)) - origin).x)
Test.report(Navigation.nearest(at(-9, -9), "Human") == nil and 1 or 0)
Random.seed(3)
local a = Navigation.random_point(at(2.5, 2.5), 2, "Human")
Random.seed(3)
local b = Navigation.random_point(at(2.5, 2.5), 2, "Human")
Test.report(a ~= nil and (a - b).x == 0 and (a - b).z == 0 and 1 or 0)
Navigation.request_path(Test.agent(), at(9.5, 5.5))
Test.report(Navigation.path(Test.agent()) == nil and 1 or 0)
`)
	testing.expect(t, ok)
	want := []f64{1, 9.5, 1, 1, 0.5, -1, 1, 6, 1, 1, 1}
	if testing.expectf(t, len(f.reports) == len(want), "reports %v", f.reports[:]) {
		for w, i in want {
			testing.expectf(t, abs(f.reports[i] - w) < 1e-4, "report %d: %v, not %v", i, f.reports[i], w)
		}
	}
	frame(f)
	clear(&f.reports)
	_, ok = script.spawn_source(&f.runtime, "=path", `
local path = Navigation.path(Test.agent())
Test.report(#path)
Test.report(Test.agent():get(NavPath).status == "Found" and 1 or 0)
Test.report(Test.agent():get(NavPath).corners)
`)
	testing.expect(t, ok)
	np := ecs.get(&f.world, f.agent, Nav_Path)
	testing.expectf(t, len(f.reports) == 3 && f.reports[0] == f64(np.corners) && f.reports[1] == 1 && f.reports[2] == f64(np.corners), "reports %v", f.reports[:])

	context.logger = testlog.expected_errors()
	_, ok = script.spawn_source(&f.runtime, "=pathless", `Navigation.request_path(World.spawn(), WorldPosition.origin)`)
	testing.expect(t, !ok, "an entity without a NavPath is an error")
	_, ok = script.spawn_source(&f.runtime, "=readonly", `Test.agent():get(NavPath).corners = 3`)
	testing.expect(t, !ok, "a NavPath's corners are the engine's")
}
