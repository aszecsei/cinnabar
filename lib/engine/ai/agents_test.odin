package ai

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
import "cinnabar:engine/random"
import "cinnabar:engine/script"

// The scheduler and the physics backend are singletons, and the test runner runs tests on several threads, so every
// test of the package takes this lock.
@(private)
test_lock: sync.Mutex

@(private = "file")
Fixture :: struct {
	frame:    virtual.Arena,
	platform: core.Platform_API,
	world:    ecs.World,
	cache:    string,
	assets:   asset.Assets,
	ai:       State,
	serial:   bool,
	cooks:    int,
	// What the native actions did, in the order that they did it, which a lock keeps, since they run on jobs.
	log_lock: sync.Mutex,
	events:   [dynamic]string,
	scripts:  bool,
	runtime:  script.Runtime,
	agent:    ecs.Entity,
	reports:  [dynamic]f64,
}

@(private = "file")
BOARD :: format.Guid{0 = 0xb0}
@(private = "file")
DECISION :: format.Guid{0 = 0xd0}

@(private = "file")
value :: proc(v: $T) -> (bytes: [format.BLACKBOARD_VALUE_SIZE]byte) {
	v := v
	(^T)(&bytes)^ = v
	return
}

// The test blackboard: health, ammo, alarmed, mood, target, home and heading, at slots 0 to 6.
@(private = "file")
board_contents :: proc(key: u64 = 77, health: f32 = 1) -> format.Blackboard_Contents {
	keys := make([]format.Blackboard_Key_Contents, 7, context.temp_allocator)
	keys[0] = {name = "health", type = .Float, default = value(health)}
	keys[1] = {name = "ammo", type = .Int, default = value(i32(3))}
	keys[2] = {name = "alarmed", type = .Bool}
	keys[3] = {name = "mood", type = .Enum, enum_names = slice.clone([]string{"calm", "alert"}, context.temp_allocator)}
	keys[4] = {name = "target", type = .Entity}
	keys[5] = {name = "home", type = .Position, default = value(ecs.position_offset({}, {1, 0, 0}))}
	keys[6] = {name = "heading", type = .Vector, default = value([3]f32{0, 0, 1})}
	return {guid = BOARD, key = key, keys = keys}
}

// The test decision, for the test module, which runs the first node whose condition holds:
//
//	node 1: when = health < 0.5, action = flee(speed = 2), set mood = alert
//	node 2: when = target != none and distance(self, target) < 3, action = bark(line = "hey", at = target)
//	node 3: action = walk(steps = ammo), set alarmed = true
@(private = "file")
decision_contents :: proc(board_key: u64 = 77, walk := "walk") -> format.Decision_Contents {
	return {
		guid = DECISION,
		key = board_key * 3,
		technique = .Behavior_Tree,
		state_size = 8,
		blackboard = BOARD,
		blackboard_key = board_key,
		nodes = slice.clone([]format.Decision_Node_Contents{
			{id = 1, kind = "pick", condition = 0, action = 0, first_write = 0, write_count = 1},
			{id = 2, kind = "pick", condition = 1, action = 1},
			{id = 3, kind = "pick", condition = format.DECISION_NONE, action = 2, first_write = 1, write_count = 1},
		}, context.temp_allocator),
		conditions = slice.clone([]format.Decision_Condition{{first_op = 0, op_count = 3}, {first_op = 3, op_count = 9}}, context.temp_allocator),
		ops = slice.clone([]format.Decision_Op{
			{code = .Key, operand = 0},
			{code = .Constant, operand = 0},
			{code = .Less, type = u8(format.Blackboard_Type.Float)},
			{code = .Key, operand = 4},
			{code = .Constant, operand = 2},
			{code = .Not_Equal, type = u8(format.Blackboard_Type.Entity)},
			{code = .Self},
			{code = .Key, operand = 4},
			{code = .Distance},
			{code = .Constant, operand = 3},
			{code = .Less, type = u8(format.Blackboard_Type.Float)},
			{code = .And},
		}, context.temp_allocator),
		constants = slice.clone([]format.Decision_Constant_Contents{
			{type = .Float, value = value(f32(0.5))},
			{type = .Float, value = value(f32(2))},
			{type = .Entity},
			{type = .Float, value = value(f32(3))},
			{type = .String, text = "hey"},
			{type = .Enum, value = value(u32(1))},
			{type = .Bool, value = value(u8(1))},
		}, context.temp_allocator),
		actions = slice.clone([]format.Decision_Action_Contents{{name = "flee", first_arg = 0, arg_count = 1}, {name = "bark", first_arg = 1, arg_count = 2}, {name = walk, first_arg = 3, arg_count = 1}}, context.temp_allocator),
		args = slice.clone([]format.Decision_Arg_Contents{
			{name = "speed", source = .Constant, index = 1, type = .Float},
			{name = "line", source = .Constant, index = 4, type = .String},
			{name = "at", source = .Key, index = 4, type = .Entity},
			{name = "steps", source = .Key, index = 1, type = .Int},
		}, context.temp_allocator),
		writes = slice.clone([]format.Decision_Write{{key = 3, source = .Constant, index = 5}, {key = 2, source = .Constant, index = 6}}, context.temp_allocator),
		source_path = "game/ai/test.decision",
	}
}

// test_think is the test module: it counts its thinks in its state, and runs the first node whose condition holds,
// with its writes, whose index it keeps after the count. Without one, it stops the action.
@(private = "file")
test_think :: proc(t: ^Think_Context) {
	(^u32)(&t.state[0])^ += 1
	for node, i in format.decision_nodes(t.decision.data, t.decision.blob) {
		if condition_holds(t, node.condition) {
			node_writes(t, node)
			start_action(t, node.action)
			(^u32)(&t.state[4])^ = u32(i + 1)
			return
		}
	}
	stop_action(t)
}

// test_scores gives one option, with the module's think count as its score's tenths, and one consideration.
@(private = "file")
test_scores :: proc(decision: Decision, board: Board, state: []byte, allocator: runtime.Allocator) -> []Option_Score {
	considerations := make([]Consideration_Score, 1, allocator)
	considerations[0] = {id = 7, input = 0.25, score = 0.75}
	result := make([]Option_Score, 1, allocator)
	result[0] = {id = 1, action = "flee", score = f32((^u32)(&state[0])^) / 10, considerations = considerations}
	return result
}

// test_plan is a plan of two steps, the second of which runs, for a goal whose priority is the thinks so far.
@(private = "file")
test_plan :: proc(decision: Decision, board: Board, state: []byte, allocator: runtime.Allocator) -> Plan_View {
	goals := make([]Goal_Priority, 1, allocator)
	goals[0] = {id = 3, priority = f32((^u32)(&state[0])^)}
	steps := make([]Plan_Step, 2, allocator)
	steps[0] = {id = 4, action = "walk"}
	steps[1] = {id = 5, action = "flee"}
	return {goal = 3, goals = goals, steps = steps, step = 1, nodes = 9}
}

@(private = "file")
log_event :: proc(a: ^Action_Context, f: string, args: ..any) {
	fixture := (^Fixture)(a.system.user)
	sync.lock(&fixture.log_lock)
	defer sync.unlock(&fixture.log_lock)
	append(&fixture.events, fmt.aprintf(f, ..args))
}

// register_test_actions registers walk, which runs for its steps and succeeds, and flee, which runs until it is
// stopped. Without scripts, bark is a native action that succeeds at once.
@(private = "file")
register_test_actions :: proc(s: ^State, scripts := false) {
	register_module(s, .Behavior_Tree, {think = test_think, scores = test_scores, plan = test_plan})
	if !scripts {
		register_action(s, {name = "bark", params = {{"line", .String}, {"at", .Entity}}})
	}
	register_action(
		s,
		{
			name = "walk",
			params = {{"steps", .Int}},
			state_size = 4,
			start = proc(a: ^Action_Context) {
				steps, _ := arg(a, "steps")
				(^i32)(&a.state[0])^ = steps.(i32)
				log_event(a, "walk start %v %d", a.entity, steps.(i32))
			},
			tick = proc(a: ^Action_Context) -> Action_Status {
				left := &(^i32)(&a.state[0])^
				left^ -= 1
				return .Succeeded if left^ <= 0 else .Running
			},
			stop = proc(a: ^Action_Context) {
				log_event(a, "walk stop %v %d", a.entity, (^i32)(&a.state[0])^)
			},
		},
	)
	register_action(
		s,
		{
			name = "flee",
			params = {{"speed", .Float}},
			start = proc(a: ^Action_Context) {
				speed, _ := arg(a, "speed")
				log_event(a, "flee start %v %v", a.entity, speed.(f32))
			},
			tick = proc(a: ^Action_Context) -> Action_Status {
				return .Running
			},
			stop = proc(a: ^Action_Context) {
				log_event(a, "flee stop %v", a.entity)
			},
		},
	)
}

// setup makes a world with the AI's components and systems, the test module and actions, over a loose cache with the
// test blobs. serial runs every job at once on the calling thread, as one job would; otherwise the scheduler has
// workers threads.
@(private = "file")
setup :: proc(t: ^testing.T, serial := false, workers := 0, scripts := false) -> ^Fixture {
	sync.lock(&test_lock)
	f := new(Fixture)
	f.serial = serial
	f.events = make([dynamic]string)
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
	register_world_components(f)
	cache, err := os.make_directory_temp("", "ai_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	init(&f.ai, &f.platform, &f.assets, &f.runtime if scripts else nil)
	register(&f.ai, &f.world)
	register_test_actions(&f.ai, scripts)
	if scripts {
		f.scripts = true
		f.reports = make([dynamic]f64)
		context.user_ptr = f
		testing.expect(t, script.init(&f.runtime, &f.platform, &f.world, nil, register_test_scripts))
	}
	write_blob(t, f, BOARD, format.blackboard_write(board_contents(), context.temp_allocator))
	write_blob(t, f, DECISION, format.decision_write(decision_contents(), context.temp_allocator))
	return f
}

@(private = "file")
register_world_components :: proc(f: ^Fixture) {
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	script.register_components(&f.world.registry)
}

@(private = "file")
register_test_scripts :: proc(r: ^script.Runtime) {
	f := (^Fixture)(context.user_ptr)
	register_scripts(r, &f.ai)
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
	destroy(&f.ai)
	asset.destroy(&f.assets)
	os.remove_all(f.cache)
	delete(f.cache)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	if !f.serial {
		testing.expect(t, jobs.drain_frame())
		jobs.shutdown()
	}
	for e in f.events {
		delete(e)
	}
	delete(f.events)
	free(f)
	sync.unlock(&test_lock)
}

@(private = "file")
write_blob :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, data: []byte) {
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(guid, &buffer))
	testing.expect(t, os.write_entire_file(path, data) == nil)
}

// cook ends a cook as the cooker does: it writes the cache's generation file, and the blobs' and its times move on.
// Then the frame's end polls.
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

// frame runs frames of one fixed tick each as the frame code does: prepare, the tick's systems, the scripts' fixed
// step, and the frame's end. The views are read again after, so the test can look at the agents.
@(private = "file")
frame :: proc(f: ^Fixture, n := 1) {
	context.user_ptr = f
	for _ in 0 ..< n {
		free_all(f.platform.frame_allocator)
		prepare(&f.ai, &f.world)
		clock := &f.world.clock
		it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
		for ecs.next_tick(&it) {
			ecs.run_tick_systems(&it, f)
			if f.scripts {
				script.fixed_update(&f.runtime, &it, {})
			}
			ecs.update_transforms(&f.world)
			if f.scripts {
				script.fixed_events(&f.runtime)
			}
		}
		end_frame(&f.ai)
	}
	free_all(f.platform.frame_allocator)
	prepare(&f.ai, &f.world)
}

@(private = "file")
at :: proc(x, y, z: f32) -> ecs.World_Position {
	return ecs.position_offset({}, {x, y, z})
}

@(private = "file")
spawn_agent :: proc(f: ^Fixture, x: f32 = 0, interval: f32 = 0, priority: i32 = 0) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{position = at(x, 0, 0), rotation = 1, scale = 1})
	ecs.add(&f.world, e, Agent{blackboard = BOARD, decision = DECISION, interval = interval, priority = priority})
	return e
}

@(private = "file")
ready_agent :: proc(f: ^Fixture, e: ecs.Entity) -> ^Agent_Ready {
	_, ready := ready_of(&f.ai, &f.world, e)
	return ready
}

@(private = "file")
thinks_of :: proc(f: ^Fixture, e: ecs.Entity) -> u32 {
	ready := ready_agent(f, e)
	return (^u32)(&ready.state[0])^ if ready != nil else 0
}

@(private = "file")
has_event :: proc(f: ^Fixture, event: string) -> bool {
	return slice.contains(f.events[:], event)
}

// An agent starts from its blackboard's defaults, at the slots and offsets that the blob gives, once its blobs load,
// and frame code reads and writes its keys by name.
@(test)
an_agent_starts_from_its_blackboards_defaults :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f)
	testing.expect(t, ecs.has(&f.world, e, Agent_State))
	frame(f)
	testing.expect(t, ready_agent(f, e) != nil)
	health, _ := get_key(&f.ai, e, "health")
	testing.expect_value(t, health.(f32), 1)
	ammo, _ := get_key(&f.ai, e, "ammo")
	testing.expect_value(t, ammo.(i32), 3)
	home, _ := get_key(&f.ai, e, "home")
	testing.expect_value(t, home.(ecs.World_Position), at(1, 0, 0))
	heading, _ := get_key(&f.ai, e, "heading")
	testing.expect_value(t, heading.([3]f32), [3]f32{0, 0, 1})
	_, found := get_key(&f.ai, e, "nothing")
	testing.expect(t, !found)

	set_key(&f.ai, e, "mood", Enum_Index(1))
	set_key(&f.ai, e, "ammo", f32(7))
	mood, _ := get_key(&f.ai, e, "mood")
	testing.expect_value(t, mood.(Enum_Index), 1)
	ammo, _ = get_key(&f.ai, e, "ammo")
	testing.expect_value(t, ammo.(i32), 7)
	context.logger = testlog.expected_errors()
	set_key(&f.ai, e, "health", true)
	health, _ = get_key(&f.ai, e, "health")
	testing.expect_value(t, health.(f32), 1)
}

// A decision's conditions read the blackboard and the world: numbers, entities that are none, distances between
// places, and their and.
@(test)
conditions_read_the_blackboard_and_the_world :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	e := spawn_agent(f)
	other := ecs.spawn(&f.world)
	ecs.add(&f.world, other, ecs.Transform{position = at(2, 0, 0), rotation = 1, scale = 1})
	frame(f, 2)
	slot, ready := ready_of(&f.ai, &f.world, e)
	testing.expect(t, ready != nil)
	board, _ := board_of(&f.ai, slot.blackboard)
	decision, _ := decision_of(&f.ai, slot.decision)
	think_context :: proc(f: ^Fixture, e: ecs.Entity, board: Board, decision: Decision, ready: ^Agent_Ready) -> Think_Context {
		return {world = &f.world, entity = e, board = board, decision = decision, values = ready.values, state = ready.state}
	}
	tc := think_context(f, e, board, decision, ready)
	testing.expect(t, !condition_holds(&tc, 0), "health is 1")
	testing.expect(t, !condition_holds(&tc, 1), "no target")
	testing.expect(t, condition_holds(&tc, format.DECISION_NONE))
	set_key(&f.ai, e, "health", f32(0.25))
	set_key(&f.ai, e, "target", other)
	testing.expect(t, condition_holds(&tc, 0), "health is 0.25")
	testing.expect(t, condition_holds(&tc, 1), "the target is 2 m away")
	ecs.get_write(&f.world, other, ecs.Transform).position = at(4, 0, 0)
	testing.expect(t, !condition_holds(&tc, 1), "the target is 4 m away")
	ecs.despawn(&f.world, other)
	testing.expect(t, !condition_holds(&tc, 1), "the target is gone")
}

// A native action starts with its arguments in the tick after the think that chose it, ticks until it succeeds, and is
// stopped; a higher priority's action stops the one that runs.
@(test)
a_native_action_starts_ticks_and_stops :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	e := spawn_agent(f, interval = 10)
	frame(f, 2)
	// The think chose walk, which starts in the next tick.
	testing.expect_value(t, current_action(&f.ai, e), "walk")
	testing.expect(t, !has_event(f, fmt.tprintf("walk start %v 3", e)))
	alarmed, _ := get_key(&f.ai, e, "alarmed")
	testing.expect_value(t, alarmed.(bool), true)
	// It starts and ticks once in a tick, and its three steps take three.
	frame(f)
	testing.expect(t, has_event(f, fmt.tprintf("walk start %v 3", e)))
	frame(f)
	testing.expect(t, !has_event(f, fmt.tprintf("walk stop %v 0", e)))
	frame(f)
	testing.expect(t, has_event(f, fmt.tprintf("walk stop %v 0", e)))
	testing.expect_value(t, current_action(&f.ai, e), "")
	ready := ready_agent(f, e)
	testing.expect_value(t, action_view(ready.action), Action_View{2, .Succeeded})

	// A low health makes the next think flee, which keeps running until another action replaces it.
	set_key(&f.ai, e, "health", f32(0.1))
	ready.next_think = f.world.clock.tick
	frame(f, 3)
	testing.expect(t, has_event(f, fmt.tprintf("flee start %v 2", e)))
	testing.expect_value(t, current_action(&f.ai, e), "flee")
	mood, _ := get_key(&f.ai, e, "mood")
	testing.expect_value(t, mood.(Enum_Index), 1)
	set_key(&f.ai, e, "health", f32(1))
	ready = ready_agent(f, e)
	ready.next_think = f.world.clock.tick
	frame(f, 2)
	testing.expect(t, has_event(f, fmt.tprintf("flee stop %v", e)))
	testing.expect_value(t, current_action(&f.ai, e), "walk")
}

// The think budget spreads the agents that are due over the ticks: the higher priority first, then those that thought
// longest ago.
@(test)
the_think_budget_spreads_agents_over_ticks :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	set_budget(&f.ai, 4)
	high: [2]ecs.Entity
	low: [8]ecs.Entity
	for &e in high {
		e = spawn_agent(f, priority = 1)
	}
	for &e in low {
		e = spawn_agent(f)
	}
	frame(f, 2)
	before: [8]u32
	for e, i in low {
		before[i] = thinks_of(f, e)
	}
	high_before := thinks_of(f, high[0])
	frame(f, 8)
	// The high priority ones think in every tick, and the eight others share the two that are left, two thinks each.
	testing.expect_value(t, thinks_of(f, high[0]) - high_before, 8)
	testing.expect_value(t, thinks_of(f, high[1]) - high_before, 8)
	for e, i in low {
		testing.expectf(t, thinks_of(f, e) - before[i] == 2, "agent %d thought %d times", i, thinks_of(f, e) - before[i])
	}
}

// Agents that start together think first in ticks spread over their interval.
@(test)
agents_that_start_together_are_staggered :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	agents: [8]ecs.Entity
	for &e in agents {
		e = spawn_agent(f, interval = 1)
	}
	frame(f, 2)
	ticks := make([dynamic]u64, context.temp_allocator)
	start := f.world.clock.tick
	for e in agents {
		ready := ready_agent(f, e)
		testing.expect(t, ready.next_think < start + 60)
		testing.expect(t, !slice.contains(ticks[:], ready.next_think), "two agents think first in the same tick")
		append(&ticks, ready.next_think)
	}
}

// The thinks, the actions and the blackboards come out the same on one job and on many, with any budget.
@(test)
thinks_are_the_same_on_one_job_and_many :: proc(t: ^testing.T) {
	Outcome :: struct {
		thinks: u32,
		node:   u32,
		action: Action_View,
		ammo:   i32,
		mood:   Enum_Index,
	}
	run :: proc(t: ^testing.T, serial: bool, budget: int) -> [dynamic]Outcome {
		f := setup(t, serial = serial, workers = 0 if serial else 8)
		defer teardown(t, f)
		set_budget(&f.ai, budget)
		agents := make([dynamic]ecs.Entity, context.temp_allocator)
		for i in 0 ..< 100 {
			append(&agents, spawn_agent(f, x = f32(i), interval = f32(i % 5) * 0.05, priority = i32(i % 3)))
		}
		frame(f, 2)
		for e, i in agents {
			if i % 4 == 0 {
				set_key(&f.ai, e, "health", f32(0.2))
			}
			if i % 7 == 0 {
				set_key(&f.ai, e, "target", agents[(i + 1) % len(agents)])
			}
		}
		outcomes := make([dynamic]Outcome)
		for _ in 0 ..< 12 {
			frame(f)
			for e in agents {
				ready := ready_agent(f, e)
				ammo, _ := get_key(&f.ai, e, "ammo")
				mood, _ := get_key(&f.ai, e, "mood")
				append(&outcomes, Outcome{(^u32)(&ready.state[0])^, (^u32)(&ready.state[4])^, action_view(ready.action), ammo.(i32), mood.(Enum_Index)})
			}
		}
		return outcomes
	}
	for budget in ([?]int{7, 1000}) {
		one := run(t, true, budget)
		defer delete(one)
		many := run(t, false, budget)
		defer delete(many)
		testing.expectf(t, slice.equal(one[:], many[:]), "budget %d: the outcomes differ", budget)
	}
}

@(private = "file")
Writer_A :: struct {
	tag: u32,
}

@(private = "file")
Writer_B :: struct {
	tag: u32,
}

// Two Fixed systems write one key in a tick: the writes apply in system order, whichever job ran first.
@(test)
writes_land_in_system_order :: proc(t: ^testing.T) {
	f := setup(t, workers = 4)
	defer teardown(t, f)
	ecs.register_component(&f.world.registry, Writer_A, 9001)
	ecs.register_component(&f.world.registry, Writer_B, 9002)
	write_a :: proc(ctx: ^ecs.System_Context) {
		s := (^State)(ctx.data)
		it := ecs.query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
		for view in ecs.query_next(&it) {
			for e in ecs.entities(view) {
				write_key(job_writer(s, ctx), e, "ammo", i32(10))
			}
		}
	}
	write_b :: proc(ctx: ^ecs.System_Context) {
		s := (^State)(ctx.data)
		it := ecs.query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
		for view in ecs.query_next(&it) {
			for e in ecs.entities(view) {
				write_key(job_writer(s, ctx), e, "ammo", i32(20))
			}
		}
	}
	ecs.register_system(&f.world, {name = "a", stage = .Fixed, procedure = write_a, terms = {ecs.read(&f.world, Writer_A)}, data = &f.ai})
	ecs.register_system(&f.world, {name = "b", stage = .Fixed, procedure = write_b, terms = {ecs.read(&f.world, Writer_B)}, data = &f.ai})
	e := spawn_agent(f, interval = 100)
	ecs.add(&f.world, e, Writer_B{})
	ecs.add(&f.world, e, Writer_A{})
	frame(f, 3)
	ammo, _ := get_key(&f.ai, e, "ammo")
	testing.expect_value(t, ammo.(i32), 20)
}

// A code reload keeps an agent's blackboard and its running action, whose native procedures are found again by name.
@(test)
a_code_reload_keeps_the_blackboard_and_running_action :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	e := spawn_agent(f, interval = 100)
	frame(f, 3)
	set_key(&f.ai, e, "ammo", i32(42))
	testing.expect_value(t, current_action(&f.ai, e), "walk")
	before, _ := ready_agent(f, e).action.(Native_Running)
	left := (^i32)(&before.memory[0])^

	// What on_reload does: the world's and the AI's registrations are made again.
	ecs.reload(&f.world, &f.platform)
	register_world_components(f)
	reload(&f.ai, &f.platform)
	register(&f.ai, &f.world)
	register_test_actions(&f.ai)
	frame(f)

	ammo, _ := get_key(&f.ai, e, "ammo")
	testing.expect_value(t, ammo.(i32), 42)
	testing.expect_value(t, current_action(&f.ai, e), "walk")
	running, still := ready_agent(f, e).action.(Native_Running)
	testing.expect(t, still)
	testing.expect_value(t, (^i32)(&running.memory[0])^, left - 1)
}

// A recooked blackboard stops the agent's action and starts it again from its new defaults.
@(test)
a_recooked_blackboard_restarts_the_agent :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	e := spawn_agent(f, interval = 100)
	frame(f, 3)
	set_key(&f.ai, e, "ammo", i32(42))
	testing.expect_value(t, current_action(&f.ai, e), "walk")
	write_blob(t, f, BOARD, format.blackboard_write(board_contents(key = 78, health = 0.75), context.temp_allocator))
	write_blob(t, f, DECISION, format.decision_write(decision_contents(board_key = 78), context.temp_allocator))
	cook(t, f, BOARD, DECISION)
	frame(f, 2)
	testing.expect(t, has_event(f, fmt.tprintf("walk stop %v 2", e)))
	health, _ := get_key(&f.ai, e, "health")
	testing.expect_value(t, health.(f32), 0.75)
	ammo, _ := get_key(&f.ai, e, "ammo")
	testing.expect_value(t, ammo.(i32), 3)
	testing.expect_value(t, ready_agent(f, e).board_key, 78)
}

// A blackboard cooked without its decision does not fit it, so the agent waits for the decision's cook.
@(test)
an_agent_waits_for_a_decision_that_fits_its_blackboard :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 2)
	context.logger = testlog.expected_errors()
	write_blob(t, f, BOARD, format.blackboard_write(board_contents(key = 78), context.temp_allocator))
	cook(t, f, BOARD)
	frame(f)
	testing.expect(t, ready_agent(f, e) == nil)
	write_blob(t, f, DECISION, format.decision_write(decision_contents(board_key = 78), context.temp_allocator))
	cook(t, f, DECISION)
	frame(f)
	testing.expect(t, ready_agent(f, e) != nil)
}

// An action that no native action or script defines is warned about when its decision loads, and fails.
@(test)
a_missing_action_fails :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	write_blob(t, f, DECISION, format.decision_write(decision_contents(walk = "dance"), context.temp_allocator))
	context.logger = testlog.expected_errors()
	e := spawn_agent(f, interval = 100)
	frame(f, 3)
	ready := ready_agent(f, e)
	testing.expect_value(t, action_view(ready.action), Action_View{2, .Failed})
}

// An agent's slot goes with its entity, and its action is stopped.
@(test)
agents_are_freed_with_their_entities :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	e := spawn_agent(f, interval = 100)
	frame(f, 3)
	testing.expect_value(t, current_action(&f.ai, e), "walk")
	ecs.despawn(&f.world, e)
	frame(f, 2)
	testing.expect(t, has_event(f, fmt.tprintf("walk stop %v 2", e)))
	testing.expect_value(t, len(f.ai.agents.free), 1)
	again := spawn_agent(f)
	frame(f)
	testing.expect_value(t, len(f.ai.agents.free), 0)
	testing.expect_value(t, ecs.get(&f.world, again, Agent_State).agent.generation, 2)
}

// A copy of an agent, with its Agent_State, gets a slot of its own, and the original keeps its.
@(test)
a_duplicated_agent_gets_its_own_slot :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	e := spawn_agent(f, interval = 100)
	frame(f, 3)
	set_key(&f.ai, e, "ammo", i32(42))
	copy := ecs.spawn(&f.world)
	ecs.add(&f.world, copy, ecs.get(&f.world, e, ecs.Transform)^)
	ecs.add(&f.world, copy, ecs.get(&f.world, e, Agent)^)
	ecs.add(&f.world, copy, ecs.get(&f.world, e, Agent_State)^)
	frame(f, 2)
	testing.expect(t, ecs.get(&f.world, copy, Agent_State).agent != ecs.get(&f.world, e, Agent_State).agent)
	ammo, _ := get_key(&f.ai, e, "ammo")
	testing.expect_value(t, ammo.(i32), 42)
	copy_ammo, _ := get_key(&f.ai, copy, "ammo")
	testing.expect_value(t, copy_ammo.(i32), 3)
}

// A script action starts with its arguments in the tick that its think chose it, ticks, and is stopped, and its
// coroutines end with it. Scripts read and write the blackboard, and an awake's writes wait for the agent.
@(test)
scripts_act_and_write_the_blackboard :: proc(t: ^testing.T) {
	f := setup(t, serial = true, scripts = true)
	defer teardown(t, f)
	context.user_ptr = f
	f.agent = spawn_agent(f, interval = 100)
	other := ecs.spawn(&f.world)
	ecs.add(&f.world, other, ecs.Transform{position = at(1, 0, 0), rotation = 1, scale = 1})
	_, ok := script.spawn_source(&f.runtime, "=bark", `
		local Bark = Action.define("bark", { line = Param.string(), at = Param.entity(), loud = Param.boolean(true) })
		function Bark:start()
			Test.report(#self.line)
			Test.report(if self.loud then 1 else 0)
			self.ticks = 0
			self:start_coroutine(function()
				while true do
					wait_fixed()
					Test.report(100)
				end
			end)
		end
		function Bark:tick(dt)
			self.ticks += 1
			Test.report(10 + self.ticks)
			if self.ticks == 2 then
				return "succeeded"
			end
			return "running"
		end
		function Bark:stop()
			Test.report(-1)
		end
		-- Before the agent is ready, the writes wait for it.
		Blackboard.set(Test.agent(), "target", nil)
		Blackboard.set(Test.agent(), "mood", "alert")
		Blackboard.set(Test.agent(), "ammo", 5)
	`)
	testing.expect(t, ok)
	frame(f, 2)
	mood, _ := get_key(&f.ai, f.agent, "mood")
	testing.expect_value(t, mood.(Enum_Index), 1)
	ammo, _ := get_key(&f.ai, f.agent, "ammo")
	testing.expect_value(t, ammo.(i32), 5)

	set_key(&f.ai, f.agent, "target", other)
	ready_agent(f, f.agent).next_think = f.world.clock.tick
	clear(&f.reports)
	frame(f)
	// Started and ticked in the think's tick: the line's length, loud's default, the first tick, and the coroutine at the
	// tick's end.
	testing.expect_value(t, current_action(&f.ai, f.agent), "bark")
	testing.expectf(t, slice.equal(f.reports[:], []f64{3, 1, 11, 100}), "%v", f.reports)
	clear(&f.reports)
	frame(f)
	// The second tick succeeds and stops it, and its coroutine ends before the tick's end.
	testing.expectf(t, slice.equal(f.reports[:], []f64{12, -1}), "%v", f.reports)
	clear(&f.reports)
	frame(f, 2)
	testing.expectf(t, !slice.contains(f.reports[:], 100), "the coroutine ends with the action: %v", f.reports)
	testing.expect_value(t, action_view(ready_agent(f, f.agent).action), Action_View{1, .Succeeded})

	_, ok = script.spawn_source(&f.runtime, "=read", `
		Test.report(Blackboard.get(Test.agent(), "ammo"))
		Test.report(if Blackboard.get(Test.agent(), "mood") == "alert" then 1 else 0)
		Blackboard.set(Test.agent(), "health", 0.25)
		Test.report(Blackboard.get(Test.agent(), "health"))
		Test.report(if Agent.current_action(Test.agent()) == nil then 1 else 0)
	`)
	testing.expect(t, ok)
	testing.expectf(t, slice.equal(f.reports[:], []f64{5, 1, 0.25, 1}), "%v", f.reports)

	context.logger = testlog.expected_errors()
	_, ok = script.spawn_source(&f.runtime, "=bad", `Blackboard.set(Test.agent(), "nothing", 1)`)
	testing.expect(t, !ok)
	_, ok = script.spawn_source(&f.runtime, "=bad", `Blackboard.set(Test.agent(), "mood", "furious")`)
	testing.expect(t, !ok)
}

// A write notes the tick that its key changed in, and a write of the same value does not.
@(test)
a_key_notes_the_tick_that_it_changed_in :: proc(t: ^testing.T) {
	f := setup(t, serial = true)
	defer teardown(t, f)
	e := spawn_agent(f, interval = 100)
	frame(f, 2)
	ready := ready_agent(f, e)
	testing.expect(t, ready != nil)
	if ready == nil {
		return
	}
	started := ready.changed[1]
	frame(f, 3)
	set_key(&f.ai, e, "ammo", i32(3))
	testing.expect_value(t, ready.changed[1], started)
	set_key(&f.ai, e, "ammo", i32(4))
	testing.expect_value(t, ready.changed[1], f.world.clock.tick)
	testing.expect_value(t, ready.changed[0], started)
}

// Each agent's generator is seeded by the state's seed and its slot, so agents draw unlike sequences, and one seed
// gives the same sequences again.
@(test)
each_agent_draws_from_its_own_seeded_generator :: proc(t: ^testing.T) {
	states :: proc(t: ^testing.T, seed: u64) -> (a, b: random.State) {
		f := setup(t, serial = true)
		defer teardown(t, f)
		set_seed(&f.ai, seed)
		first := spawn_agent(f, interval = 100)
		second := spawn_agent(f, interval = 100)
		frame(f, 2)
		if ready := ready_agent(f, first); ready != nil {
			a = ready.random
		}
		if ready := ready_agent(f, second); ready != nil {
			b = ready.random
		}
		return
	}
	a1, b1 := states(t, 5)
	a2, b2 := states(t, 5)
	a3, _ := states(t, 6)
	testing.expect(t, a1 != {} && b1 != {})
	testing.expect(t, a1 != b1)
	testing.expect_value(t, a1, a2)
	testing.expect_value(t, b1, b2)
	testing.expect(t, a1 != a3)
}

// Agent.scores gives what the agent's module scored, by option and consideration, and nil before the agent is ready.
@(test)
agent_scores_reads_the_modules_scores :: proc(t: ^testing.T) {
	f := setup(t, serial = true, scripts = true)
	defer teardown(t, f)
	context.user_ptr = f
	f.agent = spawn_agent(f, interval = 0)
	_, ok := script.spawn_source(&f.runtime, "=early", `Test.report(if Agent.scores(Test.agent()) == nil then 1 else 0)`)
	testing.expect(t, ok)
	frame(f, 4)
	_, ok = script.spawn_source(&f.runtime, "=scores", `
		local scores = Agent.scores(Test.agent())
		Test.report(#scores)
		local s = scores[1]
		Test.report(s.option)
		Test.report(if s.action == "flee" then 1 else 0)
		Test.report(s.score)
		Test.report(if s.target == nil then 1 else 0)
		Test.report(#s.considerations)
		Test.report(s.considerations[1].consideration)
		Test.report(s.considerations[1].input)
		Test.report(s.considerations[1].score)
	`)
	testing.expect(t, ok)
	thinks := f64(thinks_of(f, f.agent))
	expected := []f64{1, 1, 1, 1, f64(f32(thinks) / 10), 1, 1, 7, 0.25, 0.75}
	testing.expectf(t, slice.equal(f.reports[:], expected), "%v, expected %v", f.reports, expected)
}

// Agent.plan gives the agent's goal, the goals' priorities, the plan and its step from 1, the last search's nodes and
// whether it searches, and nil before the agent is ready.
@(test)
agent_plan_reads_the_modules_plan :: proc(t: ^testing.T) {
	f := setup(t, serial = true, scripts = true)
	defer teardown(t, f)
	context.user_ptr = f
	f.agent = spawn_agent(f, interval = 0)
	_, ok := script.spawn_source(&f.runtime, "=early", `Test.report(if Agent.plan(Test.agent()) == nil then 1 else 0)`)
	testing.expect(t, ok)
	frame(f, 4)
	_, ok = script.spawn_source(&f.runtime, "=plan", `
		local plan = Agent.plan(Test.agent())
		Test.report(plan.goal)
		Test.report(#plan.goals)
		Test.report(plan.goals[1].goal)
		Test.report(plan.goals[1].priority)
		Test.report(#plan.steps)
		Test.report(plan.steps[1].node)
		Test.report(if plan.steps[2].action == "flee" then 1 else 0)
		Test.report(plan.step)
		Test.report(plan.nodes)
		Test.report(if plan.searching then 1 else 0)
	`)
	testing.expect(t, ok)
	thinks := f64(thinks_of(f, f.agent))
	expected := []f64{1, 3, 1, 3, thinks, 2, 4, 1, 2, 9, 0}
	testing.expectf(t, slice.equal(f.reports[:], expected), "%v, expected %v", f.reports, expected)
}
