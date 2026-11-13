package nav

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/luau"
import core_physics "cinnabar:core/physics"
import physics_host "cinnabar:core/physics/host"
import physics_jolt "cinnabar:core/physics/jolt"
import script_host "cinnabar:core/script"
import "cinnabar:core/testlog"
import "cinnabar:engine/ai"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"
import "cinnabar:engine/script"

// The crowd's tests run on Jolt: each grid's floor is a static box, each blocked cell a static box smaller than the
// cell by the navmesh's agent radius, as Recast keeps the navmesh that far from the walls, and the agents are
// characters. Jolt's characters step on the scheduler's workers, so it runs even when the systems' jobs are serial.

@(private = "file")
Fixture :: struct {
	frame:    virtual.Arena,
	platform: core.Platform_API,
	host:     core_physics.Host,
	world:    ecs.World,
	physics:  physics.State,
	cache:    string,
	assets:   asset.Assets,
	nav:      State,
	agents:   ai.State,
	serial:   bool,
	scripts:  bool,
	runtime:  script.Runtime,
	agent:    ecs.Entity,
	reports:  [dynamic]f64,
}

@(private = "file")
SCENE :: format.Guid {
	0 = 0x5d,
}
@(private = "file")
MESH :: format.Guid {
	0 = 0x43,
}
@(private = "file")
BOARD :: format.Guid {
	0 = 0xb1,
}
@(private = "file")
DECISION :: format.Guid {
	0 = 0xd1,
}

// The navmesh's agent radius, which grid_blob gives, and the characters'.
@(private = "file")
RADIUS :: 0.25

// The decisions' module records the last action that it saw, under test_lock, for one agent at a time. Its action is
// the decision's first, ref 0, once it started.
@(private = "file")
seen_action: ai.Action_View

@(private = "file")
setup :: proc(t: ^testing.T, serial := true, workers := 0, scripts := false) -> ^Fixture {
	sync.lock(&test_lock)
	f := new(Fixture)
	f.serial = serial
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.host = physics_host.table()
	api := physics_jolt.load(&f.host)
	physics_host.bind(api)
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
		physics = api^,
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
	testing.expect(t, jobs.init(workers))
	if serial {
		f.platform.jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		}
		f.platform.jobs_wait = proc(counter: ^jobs.Counter) {}
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	ai.register_components(&f.world.registry)
	physics.register_components(&f.world.registry)
	script.register_components(&f.world.registry)
	cache, err := os.make_directory_temp("", "crowd_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	testing.expect(t, physics.init(&f.physics, &f.platform, assets = &f.assets))
	physics.register(&f.physics, &f.world)
	ai.init(&f.agents, &f.platform, &f.assets, &f.runtime if scripts else nil, &f.physics)
	init(&f.nav, &f.platform, &f.assets, &f.physics)
	ai.register(&f.agents, &f.world)
	register(&f.nav, &f.world, &f.agents)
	ai.register_module(&f.agents, .Behavior_Tree, {think = test_think})
	if scripts {
		f.scripts = true
		f.reports = make([dynamic]f64)
		context.user_ptr = f
		testing.expect(t, script.init(&f.runtime, &f.platform, &f.world, nil, register_crowd_scripts))
	}
	return f
}

@(private = "file")
register_crowd_scripts :: proc(r: ^script.Runtime) {
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
	ai.destroy(&f.agents)
	physics.destroy(&f.physics)
	testing.expect_value(t, f.platform.physics.world_destroy_all(), 0)
	asset.destroy(&f.assets)
	os.remove_all(f.cache)
	delete(f.cache)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	testing.expect(t, jobs.drain_frame())
	jobs.shutdown()
	free(f)
	sync.unlock(&test_lock)
}

@(private = "file")
write_blob :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, data: []byte) {
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(guid, &buffer))
	testing.expect(t, os.write_entire_file(path, data) == nil)
}

// level writes a grid of cells_x by cells_z cells whose blocked ones are walls, its navmesh and its scene, and makes
// the floor and the walls in physics.
@(private = "file")
level :: proc(t: ^testing.T, f: ^Fixture, cells_x, cells_z: int, blocked: []bool = nil) {
	write_blob(t, f, MESH, grid_blob({cells_x = cells_x, cells_z = cells_z, tile_cells = 4, blocked = blocked}, "Human", 0, guid = MESH))
	listed := []format.Scene_Nav_Mesh{{entity = 0x100, agent = "Human", guid = MESH}}
	write_blob(t, f, SCENE, format.scene_write({}, SCENE, 1, nav_meshes = listed, allocator = context.temp_allocator))
	f.world.scene = SCENE
	box(f, {f64(cells_x) / 2, -0.5, f64(cells_z) / 2}, {f32(cells_x) + 4, 1, f32(cells_z) + 4})
	for z in 0 ..< cells_z {
		for x in 0 ..< cells_x {
			if blocked != nil && blocked[z * cells_x + x] {
				box(f, {f64(x) + 0.5, 1, f64(z) + 0.5}, {1 - 2 * RADIUS, 2, 1 - 2 * RADIUS})
			}
		}
	}
	// The grid's border too, so nothing leaves it.
	box(f, {-0.5, 1, f64(cells_z) / 2}, {1, 2, f32(cells_z) + 2})
	box(f, {f64(cells_x) + 0.5, 1, f64(cells_z) / 2}, {1, 2, f32(cells_z) + 2})
	box(f, {f64(cells_x) / 2, 1, -0.5}, {f32(cells_x) + 2, 2, 1})
	box(f, {f64(cells_x) / 2, 1, f64(cells_z) + 0.5}, {f32(cells_x) + 2, 2, 1})
}

@(private = "file")
box :: proc(f: ^Fixture, center: [3]f64, size: [3]f32) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{position = at(center.x, center.y, center.z), rotation = 1, scale = 1})
	collider := physics.DEFAULT_COLLIDER
	collider.size = size
	ecs.add(&f.world, e, collider)
	return e
}

// spawn_agent is a character of the navmesh's radius with a Nav_Agent, standing at x, z.
@(private = "file")
spawn_agent :: proc(f: ^Fixture, x, z: f64, priority: u8 = 50, stopping: f32 = 0.2) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{position = at(x, 0, z), rotation = 1, scale = 1})
	character := physics.DEFAULT_CHARACTER
	character.radius = RADIUS
	ecs.add(&f.world, e, character)
	agent := DEFAULT_NAV_AGENT
	agent.max_speed, agent.radius, agent.priority, agent.stopping_distance = 2, RADIUS, priority, stopping
	ecs.add(&f.world, e, agent)
	return e
}

// frame runs frames of one fixed tick each as the game does: prepare, the tick's systems, the physics tick and the
// frame's end. The views are read again after, so the test can look.
@(private = "file")
frame :: proc(f: ^Fixture, n := 1) {
	context.user_ptr = f
	for _ in 0 ..< n {
		free_all(f.platform.frame_allocator)
		prepare(&f.nav, &f.world)
		ai.prepare(&f.agents, &f.world)
		clock := &f.world.clock
		it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
		for ecs.next_tick(&it) {
			ecs.run_tick_systems(&it, f)
			if f.scripts {
				script.fixed_update(&f.runtime, &it, {})
			}
			ecs.update_transforms(&f.world)
			physics.tick(&f.physics, &f.world)
			if f.scripts {
				script.fixed_events(&f.runtime)
			}
			ecs.update_transforms(&f.world)
		}
		ai.end_frame(&f.agents)
		end_frame(&f.nav)
	}
	free_all(f.platform.frame_allocator)
	prepare(&f.nav, &f.world)
}

// run runs frames until every agent arrived, or ticks of them, and returns how many it ran.
@(private = "file")
run :: proc(f: ^Fixture, ticks: int, agents: ..ecs.Entity) -> int {
	for n in 0 ..< ticks {
		done := true
		for e in agents {
			done &&= status(f, e) == .Arrived
		}
		if done {
			return n
		}
		frame(f)
	}
	return ticks
}

@(private = "file")
status :: proc(f: ^Fixture, e: ecs.Entity) -> Move_Status {
	state := ecs.get(&f.world, e, Nav_Agent_State)
	return state.status if state != nil else .Idle
}

@(private = "file")
where_is :: proc(f: ^Fixture, e: ecs.Entity) -> [3]f32 {
	return meters(ecs.get(&f.world, e, ecs.Transform).position)
}

@(private = "file")
distance_xz :: proc(a, b: [3]f32) -> f32 {
	return linalg.length([2]f32{a.x - b.x, a.z - b.z})
}

@(private = "file")
send :: proc(f: ^Fixture, e: ecs.Entity, x, z: f64) {
	move_to(crowd_requests(&f.nav, &f.world), e, at(x, 0, z))
}

// An L: a strip along x at z < 2, and one along z at x >= 6, in a grid of 8 by 8.
@(private = "file")
l_blocked :: proc() -> []bool {
	blocked := make([]bool, 64, context.temp_allocator)
	for z in 0 ..< 8 {
		for x in 0 ..< 8 {
			blocked[z * 8 + x] = z >= 2 && x < 6
		}
	}
	return blocked
}

@(test)
following_a_path_around_a_corner :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	level(t, f, 8, 8, l_blocked())
	e := spawn_agent(f, 0.75, 1)
	send(f, e, 7, 7.25)
	frame(f)
	testing.expect_value(t, status(f, e), Move_Status.Moving)
	turned := false
	for _ in 0 ..< 600 {
		if status(f, e) == .Arrived {
			break
		}
		frame(f)
		p := where_is(f, e)
		// The agent stays in the L, around the corner, and never inside the blocked block.
		testing.expectf(t, !(p.z > 2.1 && p.x < 5.9), "the agent cut the corner at %v", p)
		turned ||= p.x > 6 && p.z < 2
	}
	testing.expect(t, turned, "the agent went around the corner")
	testing.expect_value(t, status(f, e), Move_Status.Arrived)
	testing.expectf(t, distance_xz(where_is(f, e), {7, 0, 7.25}) <= 0.3, "the agent stopped at %v", where_is(f, e))
}

@(test)
arrives_within_the_stopping_distance :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	level(t, f, 8, 4)
	e := spawn_agent(f, 1, 2, stopping = 0.6)
	send(f, e, 6.5, 2)
	frame(f)
	testing.expect(t, run(f, 600, e) < 600, "the agent arrives")
	first := where_is(f, e)
	testing.expectf(t, distance_xz(first, {6.5, 0, 2}) <= 0.6, "the agent arrived at %v", first)
	// It slows to a stop where it arrived, short of the goal.
	frame(f, 60)
	last := where_is(f, e)
	testing.expectf(t, distance_xz(last, {6.5, 0, 2}) > 0.2, "the agent went past its stopping distance to %v", last)
	testing.expectf(t, linalg.length(ecs.get(&f.world, e, Nav_Agent_State).velocity) < 0.01, "the agent stopped")
	testing.expect_value(t, status(f, e), Move_Status.Arrived)
	stop(crowd_requests(&f.nav, &f.world), e)
	frame(f)
	testing.expect_value(t, status(f, e), Move_Status.Idle)
}

@(test)
a_moved_target_gets_a_new_path :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	level(t, f, 8, 8, l_blocked())
	target := ecs.spawn(&f.world)
	ecs.add(&f.world, target, ecs.Transform{position = at(7, 0, 1), rotation = 1, scale = 1})
	e := spawn_agent(f, 0.75, 1, stopping = 0.4)
	move_to(crowd_requests(&f.nav, &f.world), e, target)
	frame(f, 30)
	testing.expect_value(t, status(f, e), Move_Status.Moving)
	// The target goes up the L's other strip: the agent's path goes there too.
	ecs.get_write(&f.world, target, ecs.Transform).position = at(7, 0, 7)
	testing.expect(t, run(f, 900, e) < 900, "the agent arrives at the moved target")
	testing.expectf(t, distance_xz(where_is(f, e), {7, 0, 7}) <= 0.45, "the agent stopped at %v", where_is(f, e))
	// A followed target that moves away again takes the agent after it.
	ecs.get_write(&f.world, target, ecs.Transform).position = at(7, 0, 4)
	frame(f, 3)
	testing.expect_value(t, status(f, e), Move_Status.Moving)
	testing.expect(t, run(f, 600, e) < 600, "the agent arrives again")
}

@(test)
a_pushed_agent_gets_back_on_its_corridor :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	level(t, f, 12, 6)
	e := spawn_agent(f, 1, 1)
	send(f, e, 11, 1)
	frame(f, 40)
	before := where_is(f, e)
	testing.expect(t, before.x > 1.5, "the agent walks")
	// Pushed across the room and back: a moved Transform teleports the character.
	ecs.get_write(&f.world, e, ecs.Transform).position = at(f64(before.x) - 1, 0, 4.5)
	frame(f)
	testing.expectf(t, where_is(f, e).z > 4, "the agent was pushed to %v", where_is(f, e))
	testing.expect(t, run(f, 900, e) < 900, "the pushed agent arrives")
	testing.expectf(t, distance_xz(where_is(f, e), {11, 0, 1}) <= 0.3, "the agent stopped at %v", where_is(f, e))
	_, slot := find_agent(&f.nav, &f.world, e)
	following, ok := slot.phase.(Crowd_Following)
	testing.expect(t, !ok || len(following.corridor) >= 1)
}

// corridor is a grid of 14 by 2 cells: two agents' width.
@(private = "file")
pass :: proc(t: ^testing.T, high: u8) -> (a_wander, b_wander: f32) {
	f := setup(t)
	defer teardown(t, f)
	level(t, f, 14, 2)
	a := spawn_agent(f, 1, 1, priority = high)
	b := spawn_agent(f, 13, 1)
	send(f, a, 13, 1)
	send(f, b, 1, 1)
	frame(f)
	closest := max(f32)
	for _ in 0 ..< 900 {
		if status(f, a) == .Arrived && status(f, b) == .Arrived {
			break
		}
		frame(f)
		pa, pb := where_is(f, a), where_is(f, b)
		closest = min(closest, distance_xz(pa, pb))
		a_wander, b_wander = max(a_wander, abs(pa.z - 1)), max(b_wander, abs(pb.z - 1))
	}
	testing.expect_value(t, status(f, a), Move_Status.Arrived)
	testing.expect_value(t, status(f, b), Move_Status.Arrived)
	testing.expectf(t, closest > 1.6 * RADIUS, "the agents came within %v of each other", closest)
	return
}

@(test)
two_agents_pass_in_a_corridor :: proc(t: ^testing.T) {
	a, b := pass(t, 50)
	testing.expectf(t, a > 0.05 && b > 0.05, "both give way: %v and %v", a, b)
}

@(test)
the_higher_priority_keeps_its_way :: proc(t: ^testing.T) {
	a, b := pass(t, 90)
	testing.expectf(t, a < b, "the higher priority wanders %v, and the other %v", a, b)
}

// A room of 14 by 10 cells, with a wall at x = 7 and a doorway two cells wide at z = 4 and 5.
@(private = "file")
DOOR_X :: 14
@(private = "file")
DOOR_Z :: 10

@(private = "file")
door_blocked :: proc() -> []bool {
	blocked := make([]bool, DOOR_X * DOOR_Z, context.temp_allocator)
	for z in 0 ..< DOOR_Z {
		blocked[z * DOOR_X + 7] = z != 4 && z != 5
	}
	return blocked
}

// crossers are agents on both sides of the doorway, half of them on each, each sent to the mirrored place on the other
// side.
@(private = "file")
crossers :: proc(f: ^Fixture, count: int) -> []ecs.Entity {
	agents := make([]ecs.Entity, count, context.temp_allocator)
	for i in 0 ..< count {
		side := i % 2
		row := i / 2
		x := 1.0 + f64(row % 2) * 1.2 + f64(row / 5) * 2.4
		z := 1.0 + f64(row % 5) * 1.9
		if side == 1 {
			x = DOOR_X - x
		}
		agents[i] = spawn_agent(f, x, z)
		send(f, agents[i], DOOR_X - x, z)
	}
	return agents
}

@(test)
twenty_agents_cross_a_doorway :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	level(t, f, DOOR_X, DOOR_Z, door_blocked())
	agents := crossers(f, 20)
	still := make([]int, len(agents), context.temp_allocator)
	longest := make([]int, len(agents), context.temp_allocator)
	ticks := run_watching(f, 60 * 60, agents, still, longest)
	testing.expectf(t, ticks < 60 * 60, "the agents cross in a minute, not %v ticks", ticks)
	for e, i in agents {
		testing.expectf(t, status(f, e) == .Arrived, "agent %d is %v at %v", i, status(f, e), where_is(f, e))
		start_side := i % 2 == 0
		testing.expectf(t, (where_is(f, e).x > 7) == start_side, "agent %d crossed to %v", i, where_is(f, e))
		// None stands still on its way for a second.
		testing.expectf(t, longest[i] < 60, "agent %d stood still for %d ticks", i, longest[i])
	}
}

// run_watching runs until every agent arrived, keeping each agent's longest run of ticks standing still before it
// arrived.
@(private = "file")
run_watching :: proc(f: ^Fixture, ticks: int, agents: []ecs.Entity, still, longest: []int) -> int {
	for n in 0 ..< ticks {
		done := true
		for e, i in agents {
			if status(f, e) == .Arrived {
				continue
			}
			done = false
			pc := ecs.get(&f.world, e, physics.Physics_Character)
			if pc != nil && n > 2 && linalg.length([2]f32{pc.velocity.x, pc.velocity.z}) < 0.05 {
				still[i] += 1
				longest[i] = max(longest[i], still[i])
			} else {
				still[i] = 0
			}
		}
		if done {
			return n
		}
		frame(f)
	}
	return ticks
}

@(private = "file")
crowd_run :: proc(t: ^testing.T, serial: bool, workers: int, ticks: int) -> [][3]f32 {
	f := setup(t, serial, workers)
	defer teardown(t, f)
	level(t, f, DOOR_X, DOOR_Z, door_blocked())
	agents := crossers(f, 40)
	frame(f, ticks)
	out := make([][3]f32, len(agents))
	for e, i in agents {
		out[i] = where_is(f, e)
	}
	return out
}

@(test)
crowds_are_the_same_on_one_job_and_many :: proc(t: ^testing.T) {
	one := crowd_run(t, true, 0, 240)
	defer delete(one)
	many := crowd_run(t, false, 8, 240)
	defer delete(many)
	testing.expect(t, slice.equal(one, many), "the agents are where they are on one job and on eight workers")
}

// The test decision runs its one action, which an argument names, once.
@(private = "file")
action_blobs :: proc(t: ^testing.T, f: ^Fixture, action: string, goal: ecs.World_Position) {
	value :: proc(v: $T) -> (bytes: [format.BLACKBOARD_VALUE_SIZE]byte) {
		v := v
		(^T)(&bytes)^ = v
		return
	}
	keys := make([]format.Blackboard_Key_Contents, 2, context.temp_allocator)
	keys[0] = {
		name    = "goal",
		type    = .Position,
		default = value(goal),
	}
	keys[1] = {
		name = "count",
		type = .Int,
	}
	write_blob(t, f, BOARD, format.blackboard_write({guid = BOARD, key = 11, keys = keys}, context.temp_allocator))
	decision := format.Decision_Contents {
		guid           = DECISION,
		key            = 33,
		technique      = .Behavior_Tree,
		state_size     = 8,
		blackboard     = BOARD,
		blackboard_key = 11,
		nodes          = slice.clone([]format.Decision_Node_Contents{{id = 1, kind = "pick", condition = format.DECISION_NONE, action = 0}}, context.temp_allocator),
		constants      = slice.clone([]format.Decision_Constant_Contents{{type = .String, text = "goal"}}, context.temp_allocator),
		actions        = slice.clone([]format.Decision_Action_Contents{{name = action, first_arg = 0, arg_count = 1 if action == "move_to" else 0}}, context.temp_allocator),
		args           = slice.clone([]format.Decision_Arg_Contents{{name = "key", source = .Constant, index = 0, type = .String}}, context.temp_allocator),
		source_path    = "game/ai/crowd.decision",
	}
	write_blob(t, f, DECISION, format.decision_write(decision, context.temp_allocator))
}

// test_think starts the decision's action once, and records what it sees of it.
@(private = "file")
test_think :: proc(t: ^ai.Think_Context) {
	seen_action = t.action
	started := (^u32)(&t.state[0])
	if started^ == 0 {
		started^ = 1
		ai.start_action(t, 0)
	}
}

@(private = "file")
thinking_agent :: proc(f: ^Fixture, x, z: f64) -> ecs.Entity {
	e := spawn_agent(f, x, z)
	ecs.add(&f.world, e, ai.Agent{blackboard = BOARD, decision = DECISION, interval = 0.05})
	seen_action = {
		ref = format.DECISION_NONE,
	}
	return e
}

@(test)
move_to_succeeds_on_arrival :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	level(t, f, 8, 8, l_blocked())
	action_blobs(t, f, "move_to", at(7, 0, 6))
	e := thinking_agent(f, 0.75, 1)
	for _ in 0 ..< 900 {
		if seen_action.ref == 0 && seen_action.status != .Running {
			break
		}
		frame(f)
	}
	testing.expect_value(t, seen_action.status, ai.Action_Status.Succeeded)
	testing.expectf(t, distance_xz(where_is(f, e), {7, 0, 6}) <= 0.3, "the agent stopped at %v", where_is(f, e))
	testing.expect_value(t, status(f, e), Move_Status.Arrived)
}

@(test)
move_to_fails_where_no_path_reaches :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	// A wall across the room, with no door.
	blocked := make([]bool, 8 * 4, context.temp_allocator)
	for z in 0 ..< 4 {
		blocked[z * 8 + 4] = true
	}
	level(t, f, 8, 4, blocked)
	action_blobs(t, f, "move_to", at(7, 0, 2))
	e := thinking_agent(f, 1, 2)
	for _ in 0 ..< 600 {
		if seen_action.ref == 0 && seen_action.status != .Running {
			break
		}
		frame(f)
	}
	testing.expect_value(t, seen_action.status, ai.Action_Status.Failed)
	testing.expect_value(t, status(f, e), Move_Status.Failed)
	testing.expectf(t, where_is(f, e).x < 4, "the agent stayed on its side, at %v", where_is(f, e))
}

@(test)
the_stop_action_stops_the_agent :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	level(t, f, 12, 4)
	action_blobs(t, f, "stop", at(0, 0, 0))
	e := spawn_agent(f, 1, 2)
	send(f, e, 11, 2)
	frame(f, 30)
	testing.expect_value(t, status(f, e), Move_Status.Moving)
	ecs.add(&f.world, e, ai.Agent{blackboard = BOARD, decision = DECISION, interval = 0.05})
	seen_action = {
		ref = format.DECISION_NONE,
	}
	frame(f, 10)
	testing.expect_value(t, seen_action.ref, 0)
	testing.expect_value(t, seen_action.status, ai.Action_Status.Succeeded)
	testing.expect_value(t, status(f, e), Move_Status.Idle)
	frame(f, 60)
	testing.expectf(t, where_is(f, e).x < 8, "the stopped agent stood at %v", where_is(f, e))
	testing.expectf(t, linalg.length(ecs.get(&f.world, e, Nav_Agent_State).velocity) < 0.01, "the agent stopped")
}

@(test)
agents_are_freed_with_their_entities :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	level(t, f, 8, 4)
	e := spawn_agent(f, 1, 2)
	send(f, e, 6, 2)
	frame(f, 5)
	h := ecs.get(&f.world, e, Nav_Agent_State).crowd
	testing.expect(t, crowd_slot_of(&f.nav, h) != nil)
	ecs.despawn(&f.world, e)
	frame(f)
	testing.expect(t, crowd_slot_of(&f.nav, h) == nil, "the slot is freed with its entity")
	other := spawn_agent(f, 1, 1)
	frame(f)
	ecs.remove(&f.world, other, Nav_Agent)
	h = ecs.get(&f.world, other, Nav_Agent_State).crowd
	frame(f)
	testing.expect(t, crowd_slot_of(&f.nav, h) == nil, "the slot is freed with its Nav_Agent")
}

@(test)
a_duplicated_agent_gets_its_own_slot :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	level(t, f, 8, 4)
	e := spawn_agent(f, 1, 1)
	send(f, e, 6, 1)
	frame(f, 5)
	copy := ecs.spawn(&f.world)
	ecs.add(&f.world, copy, ecs.Transform{position = at(1, 0, 3), rotation = 1, scale = 1})
	ecs.add(&f.world, copy, ecs.get(&f.world, e, physics.Character)^)
	ecs.add(&f.world, copy, ecs.get(&f.world, e, Nav_Agent)^)
	ecs.add(&f.world, copy, ecs.get(&f.world, e, Nav_Agent_State)^)
	frame(f)
	a, b := ecs.get(&f.world, e, Nav_Agent_State).crowd, ecs.get(&f.world, copy, Nav_Agent_State).crowd
	testing.expect(t, a != b, "the copy has its own slot")
	testing.expect_value(t, status(f, e), Move_Status.Moving)
	testing.expect_value(t, status(f, copy), Move_Status.Idle)
	send(f, copy, 6, 3)
	testing.expect(t, run(f, 600, e, copy) < 600, "both arrive")
}

@(test)
scripts_move_agents :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(t, f)
	level(t, f, 8, 4)
	f.agent = spawn_agent(f, 1, 2)
	frame(f)
	context.user_ptr = f
	_, ok := script.spawn_source(
		&f.runtime,
		"=move",
		`
local origin = WorldPosition.from_meters(1000, 2, -500)
Navigation.move_to(Test.agent(), origin + vector.create(6, 0, 2))
Test.report(Navigation.arrived(Test.agent()) and 1 or 0)
`,
	)
	testing.expect(t, ok)
	frame(f, 30)
	_, ok = script.spawn_source(&f.runtime, "=moving", `
Test.report(vector.magnitude(Navigation.velocity(Test.agent())))
Test.report(Test.agent():get(NavAgentState).status == "Moving" and 1 or 0)
`)
	testing.expect(t, ok)
	testing.expect(t, run(f, 600, f.agent) < 600, "the agent arrives")
	_, ok = script.spawn_source(&f.runtime, "=arrived", `
Test.report(Navigation.arrived(Test.agent()) and 1 or 0)
Navigation.stop(Test.agent())
`)
	testing.expect(t, ok)
	frame(f)
	testing.expect_value(t, status(f, f.agent), Move_Status.Idle)
	if testing.expectf(t, len(f.reports) == 4, "reports %v", f.reports[:]) {
		testing.expect_value(t, f.reports[0], 0)
		testing.expectf(t, f.reports[1] > 0.5, "the agent walks at %v", f.reports[1])
		testing.expect_value(t, f.reports[2], 1)
		testing.expect_value(t, f.reports[3], 1)
	}
	context.logger = testlog.expected_errors()
	_, ok = script.spawn_source(&f.runtime, "=not_an_agent", `Navigation.move_to(World.spawn(), WorldPosition.origin)`)
	testing.expect(t, !ok, "an entity without a NavAgent is an error")
	_, ok = script.spawn_source(&f.runtime, "=no_target", `Navigation.move_to(Test.agent(), 3)`)
	testing.expect(t, !ok, "a target is a position or an entity")
}
