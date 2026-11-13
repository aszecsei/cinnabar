package goap

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/testlog"
import "cinnabar:engine/ai"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The scheduler is a singleton, and the test runner runs tests on several threads, so every test of the package takes
// this lock.
@(private = "file")
test_lock: sync.Mutex

@(private = "file")
Fixture :: struct {
	frame:    virtual.Arena,
	platform: core.Platform_API,
	world:    ecs.World,
	cache:    string,
	assets:   asset.Assets,
	ai:       ai.State,
	serial:   bool,
	// What the native actions did, in their order, which a lock keeps, since they run on jobs.
	log_lock: sync.Mutex,
	events:   [dynamic]string,
}

@(private = "file")
BOARD :: format.Guid{0 = 0xb9}
@(private = "file")
DECISION :: format.Guid{0 = 0xda}
@(private = "file")
OTHER :: format.Guid{0 = 0xdb}

// The test blackboard's keys, at their slots.
@(private = "file")
KEYS :: [?]struct {
	name: string,
	type: format.Blackboard_Type,
} {
	{"health", .Float},
	{"ammo", .Int},
	{"armed", .Bool},
	{"near", .Bool},
	{"down", .Bool},
	{"mood", .Enum},
	{"cost", .Float},
	{"blocked", .Bool},
}

@(private = "file")
value :: proc(v: $T) -> (bytes: [format.BLACKBOARD_VALUE_SIZE]byte) {
	v := v
	(^T)(&bytes)^ = v
	return
}

@(private = "file")
board_contents :: proc() -> format.Blackboard_Contents {
	names := KEYS
	keys := make([]format.Blackboard_Key_Contents, len(names), context.temp_allocator)
	for k, i in names {
		keys[i] = {name = k.name, type = k.type}
	}
	keys[0].default = value(f32(0.5))
	keys[1].default = value(i32(3))
	keys[5].enum_names = {"calm", "alert"}
	keys[6].default = value(f32(1))
	return {guid = BOARD, key = 77, keys = keys}
}

@(private = "file")
slot_of :: proc(name: string) -> u32 {
	keys := KEYS
	for k, i in keys {
		if k.name == name {
			return u32(i)
		}
	}
	panic("no such key")
}

// The planning keys of every test decision, by index.
@(private = "file")
PLANNING :: []string{"armed", "near", "down", "ammo", "mood"}
@(private = "file")
ARMED :: 0
@(private = "file")
NEAR :: 1
@(private = "file")
DOWN :: 2
@(private = "file")
AMMO :: 3
@(private = "file")
MOOD :: 4

@(private = "file")
is :: proc(key: u32, v: i32 = 1) -> format.Plan_Test {
	return {key = key, lo = v, hi = v}
}

@(private = "file")
at_least :: proc(key: u32, v: i32) -> format.Plan_Test {
	return {key = key, lo = v, hi = max(i32)}
}

@(private = "file")
set :: proc(key: u32, v: i32 = 1) -> format.Plan_Effect {
	return {key = key, op = .Set, value = v}
}

@(private = "file")
add :: proc(key: u32, v: i32) -> format.Plan_Effect {
	return {key = key, op = .Add, value = v}
}

// A is a test action: a native test action with its label n, a bool key's name as its guard, `!` negating it, its
// preconditions and effects, and its cost, 0 being 1, or a cost key.
@(private = "file")
A :: struct {
	action:   string,
	n:        i32,
	guard:    string,
	tests:    []format.Plan_Test,
	effects:  []format.Plan_Effect,
	cost:     f32,
	cost_key: string,
}

// G is a test goal: its guard, its desired state, its priority, 0 being 1, and whether a consideration of health,
// linear over [0, 1], scales it.
@(private = "file")
G :: struct {
	guard:    string,
	tests:    []format.Plan_Test,
	priority: f32,
	health:   bool,
}

// D is a test decision, with its search's size, 0 being 64 nodes and a plan of 8.
@(private = "file")
D :: struct {
	goals:     []G,
	actions:   []A,
	max_nodes: u32,
	max_plan:  u32,
}

// build is the decision blob of a GOAP decision, with its state as the cooker lays it out. The goals are nodes 1 on,
// the actions 10 on, and the considerations 100 on. refused makes its state too small, which the check refuses.
@(private = "file")
build :: proc(d: D, guid := DECISION, key: u64 = 1, refused := false) -> []byte {
	nodes := make([dynamic]format.Decision_Node_Contents, context.temp_allocator)
	conditions := make([dynamic]format.Decision_Condition, context.temp_allocator)
	ops := make([dynamic]format.Decision_Op, context.temp_allocator)
	constants := make([dynamic]format.Decision_Constant_Contents, context.temp_allocator)
	actions := make([dynamic]format.Decision_Action_Contents, context.temp_allocator)
	args := make([dynamic]format.Decision_Arg_Contents, context.temp_allocator)
	tests := make([dynamic]format.Plan_Test, context.temp_allocator)
	effects := make([dynamic]format.Plan_Effect, context.temp_allocator)
	goals := make([dynamic]format.Goap_Goal, context.temp_allocator)
	plan_actions := make([dynamic]format.Plan_Action, context.temp_allocator)
	considerations := make([dynamic]format.Utility_Consideration, context.temp_allocator)
	links := make([dynamic]u32, context.temp_allocator)
	guard :: proc(ops: ^[dynamic]format.Decision_Op, conditions: ^[dynamic]format.Decision_Condition, text: string) -> u32 {
		if text == "" {
			return format.DECISION_NONE
		}
		negated := text[0] == '!'
		first := u32(len(ops))
		append(ops, format.Decision_Op{code = .Key, operand = slot_of(text[1:] if negated else text)})
		if negated {
			append(ops, format.Decision_Op{code = .Not})
		}
		append(conditions, format.Decision_Condition{first_op = first, op_count = u32(len(ops)) - first})
		return u32(len(conditions) - 1)
	}
	for g, i in d.goals {
		append(&nodes, format.Decision_Node_Contents{id = u32(i + 1), kind = "goal", condition = guard(&ops, &conditions, g.guard), action = format.DECISION_NONE})
		record := format.Goap_Goal {
			node       = u32(len(nodes) - 1),
			priority   = g.priority if g.priority != 0 else 1,
			first_test = u32(len(tests)),
			test_count = u32(len(g.tests)),
			first_link = u32(len(links)),
		}
		append(&tests, ..g.tests)
		if g.health {
			append(&links, u32(len(considerations)))
			append(&considerations, format.Utility_Consideration{input = .Number, curve = .Linear, a = slot_of("health"), max = 1, slope = 1, exponent = 1})
			record.link_count = 1
		}
		append(&goals, record)
	}
	for a, i in d.actions {
		append(&nodes, format.Decision_Node_Contents{id = u32(10 + i), kind = "action", condition = guard(&ops, &conditions, a.guard), action = u32(len(actions))})
		append(&constants, format.Decision_Constant_Contents{type = .Int, value = value(a.n)})
		append(&args, format.Decision_Arg_Contents{name = "n", source = .Constant, index = u32(len(constants) - 1), type = .Int})
		append(&actions, format.Decision_Action_Contents{name = a.action, first_arg = u32(len(args) - 1), arg_count = 1})
		record := format.Plan_Action {
			node         = u32(len(nodes) - 1),
			cost         = {value = a.cost if a.cost != 0 else 1},
			first_test   = u32(len(tests)),
			test_count   = u32(len(a.tests)),
			first_effect = u32(len(effects)),
			effect_count = u32(len(a.effects)),
		}
		if a.cost_key != "" {
			record.cost = {key = slot_of(a.cost_key), source = .Key}
		}
		append(&tests, ..a.tests)
		append(&effects, ..a.effects)
		append(&plan_actions, record)
	}
	for &c, i in considerations {
		c.node = u32(len(nodes))
		append(&nodes, format.Decision_Node_Contents{id = u32(100 + i), kind = "consideration", condition = format.DECISION_NONE, action = format.DECISION_NONE})
	}
	keys := make([dynamic]u32, context.temp_allocator)
	for name in PLANNING {
		append(&keys, slot_of(name))
	}
	contents := format.Goap_Contents {
		max_nodes      = d.max_nodes if d.max_nodes != 0 else 64,
		max_plan       = d.max_plan if d.max_plan != 0 else 8,
		keys           = keys[:],
		actions        = plan_actions[:],
		goals          = goals[:],
		tests          = tests[:],
		effects        = effects[:],
		considerations = considerations[:],
		links          = links[:],
	}
	size := format.goap_state(u32(len(keys)), u32(len(plan_actions)), u32(len(goals)), contents.max_nodes, contents.max_plan).size
	if refused {
		size -= 8
	}
	decision := format.Decision_Contents {
		guid           = guid,
		key            = key,
		technique      = .Goap,
		state_size     = u32(size),
		blackboard     = BOARD,
		blackboard_key = 77,
		nodes          = nodes[:],
		conditions     = conditions[:],
		ops            = ops[:],
		constants      = constants[:],
		actions        = actions[:],
		args           = args[:],
		technique_data = format.goap_write(contents, context.temp_allocator),
		source_path    = "game/ai/test.decision",
	}
	return format.decision_write(decision, context.temp_allocator)
}

@(private = "file")
log_event :: proc(a: ^ai.Action_Context, f: string, args: ..any) {
	fixture := (^Fixture)(a.system.user)
	sync.lock(&fixture.log_lock)
	defer sync.unlock(&fixture.log_lock)
	append(&fixture.events, fmt.aprintf(f, ..args))
}

@(private = "file")
label :: proc(a: ^ai.Action_Context) -> i32 {
	n, _ := ai.arg(a, "n")
	return n.(i32)
}

// register_test registers the module and the test actions, each with its label n, which only start reads, so the
// actions that stop keep it in their state: step, which succeeds when it starts;
// walk, which runs for 3 ticks and succeeds; hold, which runs until it is stopped; and fail, which fails.
@(private = "file")
register_test :: proc(s: ^ai.State) {
	register(s)
	ai.register_action(s, {name = "step", params = {{"n", .Int}}, start = proc(a: ^ai.Action_Context) {log_event(a, "start step %d", label(a))}})
	ai.register_action(
		s,
		{
			name = "walk",
			params = {{"n", .Int}},
			state_size = 8,
			start = proc(a: ^ai.Action_Context) {
				(^i32)(&a.state[0])^ = 3
				(^i32)(&a.state[4])^ = label(a)
				log_event(a, "start walk %d", label(a))
			},
			tick = proc(a: ^ai.Action_Context) -> ai.Action_Status {
				left := (^i32)(&a.state[0])
				left^ -= 1
				return .Succeeded if left^ <= 0 else .Running
			},
			stop = proc(a: ^ai.Action_Context) {log_event(a, "stop walk %d", (^i32)(&a.state[4])^)},
		},
	)
	ai.register_action(
		s,
		{
			name = "hold",
			params = {{"n", .Int}},
			state_size = 4,
			start = proc(a: ^ai.Action_Context) {
				(^i32)(&a.state[0])^ = label(a)
				log_event(a, "start hold %d", label(a))
			},
			tick = proc(a: ^ai.Action_Context) -> ai.Action_Status {return .Running},
			stop = proc(a: ^ai.Action_Context) {log_event(a, "stop hold %d", (^i32)(&a.state[0])^)},
		},
	)
	ai.register_action(
		s,
		{
			name = "fail",
			params = {{"n", .Int}},
			start = proc(a: ^ai.Action_Context) {log_event(a, "start fail %d", label(a))},
			tick = proc(a: ^ai.Action_Context) -> ai.Action_Status {return .Failed},
		},
	)
}

@(private = "file")
register_world_components :: proc(f: ^Fixture) {
	ecs.register_engine_components(&f.world.registry)
	ai.register_components(&f.world.registry)
}

// setup makes a world with the AI, the module and the test actions, over a loose cache with the test blackboard and the
// decision. serial runs every job at once on the calling thread; otherwise the scheduler has workers threads.
@(private = "file")
setup :: proc(t: ^testing.T, d: D, serial := true, workers := 0) -> ^Fixture {
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
	cache, err := os.make_directory_temp("", "goap_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	ai.init(&f.ai, &f.platform, &f.assets)
	ai.register(&f.ai, &f.world)
	register_test(&f.ai)
	write_blob(t, f, BOARD, format.blackboard_write(board_contents(), context.temp_allocator))
	write_blob(t, f, DECISION, build(d))
	return f
}

@(private = "file")
teardown :: proc(t: ^testing.T, f: ^Fixture) {
	ai.destroy(&f.ai)
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

// frame runs frames of one fixed tick each, as the frame code does, and reads the views again after, so the test can
// look at the agents.
@(private = "file")
frame :: proc(f: ^Fixture, n := 1) {
	for _ in 0 ..< n {
		free_all(f.platform.frame_allocator)
		ai.prepare(&f.ai, &f.world)
		clock := &f.world.clock
		it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
		for ecs.next_tick(&it) {
			ecs.run_tick_systems(&it, f)
			ecs.update_transforms(&f.world)
		}
		ai.end_frame(&f.ai)
	}
	free_all(f.platform.frame_allocator)
	ai.prepare(&f.ai, &f.world)
}

// spawn_agent spawns an agent of a decision, which thinks in every tick by default.
@(private = "file")
spawn_agent :: proc(f: ^Fixture, decision := DECISION, interval: f32 = 0) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{rotation = 1, scale = 1})
	ecs.add(&f.world, e, ai.Agent{blackboard = BOARD, decision = decision, interval = interval})
	return e
}

@(private = "file")
ready_of :: proc(f: ^Fixture, e: ecs.Entity) -> ^ai.Agent_Ready {
	state := ecs.get(&f.world, e, ai.Agent_State)
	if state == nil {
		return nil
	}
	ready, _ := &f.ai.agents.slots[state.agent.index].phase.(ai.Agent_Ready)
	return ready
}

// start runs frames until the agent is ready.
@(private = "file")
start :: proc(f: ^Fixture, e: ecs.Entity) -> ^ai.Agent_Ready {
	for _ in 0 ..< 10 {
		if ready := ready_of(f, e); ready != nil {
			return ready
		}
		frame(f)
	}
	return nil
}

// agent_of is the agent's GOAP state.
@(private = "file")
agent_of :: proc(f: ^Fixture, e: ecs.Entity) -> format.Goap_Agent {
	ready := ready_of(f, e)
	if ready == nil {
		return {}
	}
	return (^format.Goap_Agent)(raw_data(ready.state))^
}

@(private = "file")
phase :: proc(f: ^Fixture, e: ecs.Entity) -> format.Goap_Phase {
	return agent_of(f, e).phase
}

// run_until runs frames until the agent's phase is the one asked for, at most limit, and gives the frames that it ran,
// or -1.
@(private = "file")
run_until :: proc(f: ^Fixture, e: ecs.Entity, p: format.Goap_Phase, limit := 50) -> int {
	for n in 0 ..< limit {
		if phase(f, e) == p {
			return n
		}
		frame(f)
	}
	return -1
}

// starts is the actions that started, in their order.
@(private = "file")
starts :: proc(f: ^Fixture) -> []string {
	result := make([dynamic]string, context.temp_allocator)
	for e in f.events {
		if strings.has_prefix(e, "start") {
			append(&result, e)
		}
	}
	return result[:]
}

@(private = "file")
expect_starts :: proc(t: ^testing.T, f: ^Fixture, expected: []string, loc := #caller_location) {
	got := starts(f)
	testing.expectf(t, slice.equal(got, expected), "starts %v, expected %v", got, expected, loc = loc)
}

@(private = "file")
clear_events :: proc(f: ^Fixture) {
	for e in f.events {
		delete(e)
	}
	clear(&f.events)
}

@(private = "file")
has_event :: proc(f: ^Fixture, event: string) -> bool {
	return slice.contains(f.events[:], event)
}

@(private = "file")
key_value :: proc(f: ^Fixture, e: ecs.Entity, key: string) -> ai.Value {
	v, _ := ai.get_key(&f.ai, e, key)
	return v
}

// down_plan is a goal to have the target down, which takes three actions, whose regressive search makes five nodes and
// ends when it takes the fifth: attack needs armed and near, and arm and approach give them, in either order.
@(private = "file")
down_plan :: proc() -> D {
	return D {
		goals = slice.clone([]G{{tests = slice.clone([]format.Plan_Test{is(DOWN)}, context.temp_allocator)}}, context.temp_allocator),
		actions = slice.clone(
			[]A {
				{action = "step", n = 3, tests = slice.clone([]format.Plan_Test{is(ARMED), is(NEAR)}, context.temp_allocator), effects = slice.clone([]format.Plan_Effect{set(DOWN)}, context.temp_allocator)},
				{action = "step", n = 1, effects = slice.clone([]format.Plan_Effect{set(ARMED)}, context.temp_allocator)},
				{action = "step", n = 2, effects = slice.clone([]format.Plan_Effect{set(NEAR)}, context.temp_allocator)},
			},
			context.temp_allocator,
		),
	}
}

// A plan of several actions runs in order, each writing its effects when it succeeds, and the plan's view gives its
// goal, its actions and its step.
@(test)
a_plan_of_several_actions_runs_in_order :: proc(t: ^testing.T) {
	f := setup(t, down_plan())
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	testing.expect(t, run_until(f, e, .Running) >= 0, "a plan is found")
	view, ok := ai.plan(&f.ai, e)
	testing.expect(t, ok)
	testing.expect_value(t, view.goal, 1)
	testing.expect_value(t, len(view.steps), 3)
	if len(view.steps) == 3 {
		testing.expect_value(t, view.steps[0], ai.Plan_Step{12, "step"})
		testing.expect_value(t, view.steps[1], ai.Plan_Step{11, "step"})
		testing.expect_value(t, view.steps[2], ai.Plan_Step{10, "step"})
	}
	testing.expect_value(t, view.step, 0)
	testing.expect_value(t, view.nodes, 5)
	testing.expect(t, !view.searching)
	testing.expect_value(t, len(view.goals), 1)
	if len(view.goals) == 1 {
		testing.expect_value(t, view.goals[0], ai.Goal_Priority{1, 1})
	}
	frame(f, 3)
	view, _ = ai.plan(&f.ai, e)
	testing.expect_value(t, view.step, 1)
	frame(f, 10)
	expect_starts(t, f, {"start step 2", "start step 1", "start step 3"})
	testing.expect_value(t, key_value(f, e, "armed"), true)
	testing.expect_value(t, key_value(f, e, "near"), true)
	testing.expect_value(t, key_value(f, e, "down"), true)
	// The goal holds, so the agent has nothing to do.
	testing.expect_value(t, phase(f, e), format.Goap_Phase.Idle)
	view, _ = ai.plan(&f.ai, e)
	testing.expect_value(t, view.goal, 0)
	_, ok = ai.plan(&f.ai, ecs.spawn(&f.world))
	testing.expect(t, !ok)
}

// The effects set bools and enums and add to ints, when the action succeeds.
@(test)
effects_are_written_when_an_action_succeeds :: proc(t: ^testing.T) {
	f := setup(t, {goals = {{tests = {is(MOOD, 1)}}}, actions = {{action = "walk", n = 1, effects = {set(ARMED), add(AMMO, 2), set(MOOD, 1)}}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	run_until(f, e, .Running)
	frame(f)
	testing.expect_value(t, key_value(f, e, "armed"), false)
	frame(f, 6)
	testing.expect_value(t, key_value(f, e, "armed"), true)
	testing.expect_value(t, key_value(f, e, "ammo"), i32(5))
	testing.expect_value(t, key_value(f, e, "mood"), ai.Enum_Index(1))
}

// Of two plans, the cheaper runs, with costs that are constants or keys.
@(test)
the_cheaper_of_two_plans_is_picked :: proc(t: ^testing.T) {
	d := D {
		goals   = {{tests = {is(DOWN)}}},
		actions = {
			{action = "step", n = 1, effects = {set(DOWN)}, cost = 5},
			{action = "step", n = 2, effects = {set(ARMED)}},
			{action = "step", n = 3, tests = {is(ARMED)}, effects = {set(DOWN)}, cost_key = "cost"},
		},
	}
	f := setup(t, d)
	defer teardown(t, f)
	cheap := spawn_agent(f)
	start(f, cheap)
	frame(f, 15)
	expect_starts(t, f, {"start step 2", "start step 3"})
	clear_events(f)
	dear := spawn_agent(f)
	ai.set_key(&f.ai, dear, "cost", f32(10))
	start(f, dear)
	frame(f, 15)
	expect_starts(t, f, {"start step 1"})
}

// Of two plans of one cost, the one of the earlier action runs.
@(test)
ties_break_by_the_actions_order :: proc(t: ^testing.T) {
	f := setup(t, {goals = {{tests = {is(DOWN)}}}, actions = {{action = "step", n = 1, effects = {set(DOWN)}}, {action = "step", n = 2, effects = {set(DOWN)}}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 10)
	expect_starts(t, f, {"start step 1"})
}

// A goal that no plan reaches fails, and the goal of the next priority runs. The failed goal is tried again only when a
// planning key changes.
@(test)
an_impossible_goal_has_no_plan_and_the_next_goal_runs :: proc(t: ^testing.T) {
	d := D {
		goals   = {{tests = {is(DOWN)}, priority = 10}, {tests = {is(ARMED)}}},
		actions = {{action = "hold", n = 1, effects = {set(ARMED)}}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 10)
	expect_starts(t, f, {"start hold 1"})
	view, _ := ai.plan(&f.ai, e)
	testing.expect_value(t, view.goal, 2)
	testing.expect_value(t, agent_of(f, e).failed, 1)
	frame(f, 5)
	testing.expect_value(t, phase(f, e), format.Goap_Phase.Running)
	// A change to a planning key tries the failed goal again, which replaces the running plan while it searches.
	ai.set_key(&f.ai, e, "ammo", i32(9))
	frame(f)
	testing.expect_value(t, phase(f, e), format.Goap_Phase.Searching)
	frame(f, 3)
	testing.expect(t, has_event(f, "stop hold 1"))
	testing.expect_value(t, agent_of(f, e).failed, 1)
	testing.expect_value(t, phase(f, e), format.Goap_Phase.Running)
}

// A search that fills its nodes fails, and so does one whose plan would be longer than the most.
@(test)
a_search_that_fills_its_state_fails :: proc(t: ^testing.T) {
	small := down_plan()
	small.max_nodes = 3
	f := setup(t, small)
	defer teardown(t, f)
	short := down_plan()
	short.max_plan = 2
	write_blob(t, f, OTHER, build(short, OTHER))
	full := spawn_agent(f)
	long := spawn_agent(f, OTHER)
	start(f, full)
	start(f, long)
	frame(f, 10)
	expect_starts(t, f, {})
	testing.expect_value(t, agent_of(f, full).failed, 1)
	testing.expect_value(t, agent_of(f, full).nodes, 3)
	testing.expect_value(t, agent_of(f, long).failed, 1)
	view, _ := ai.plan(&f.ai, full)
	testing.expect_value(t, view.nodes, 3)
	testing.expect_value(t, len(view.steps), 0)
}

// With a plan budget of 1 node, the search of five nodes takes five thinks, which come in the ticks after each other
// whatever the agent's interval. With 2, it takes three.
@(test)
a_search_is_spread_over_ticks_by_the_budget :: proc(t: ^testing.T) {
	f := setup(t, down_plan())
	defer teardown(t, f)
	ai.set_plan_budget(&f.ai, .Goap, 1)
	e := spawn_agent(f, interval = 10)
	start(f, e)
	testing.expect(t, run_until(f, e, .Searching, 1000) >= 0)
	testing.expect_value(t, run_until(f, e, .Running), 5)
	ai.set_plan_budget(&f.ai, .Goap, 2)
	quick := spawn_agent(f)
	start(f, quick)
	run_until(f, quick, .Searching)
	testing.expect_value(t, run_until(f, quick, .Running), 3)
}

// The budget is shared among the agents that search, in the order of the agents that think: of three agents, with a
// budget of 2, the first two get a node each and the third none, until the others are done.
@(test)
the_budget_is_shared_among_searching_agents :: proc(t: ^testing.T) {
	f := setup(t, down_plan())
	defer teardown(t, f)
	ai.set_plan_budget(&f.ai, .Goap, 2)
	agents := [3]ecs.Entity{spawn_agent(f), spawn_agent(f), spawn_agent(f)}
	for e in agents {
		start(f, e)
	}
	run_until(f, agents[0], .Searching)
	for e in agents {
		testing.expect_value(t, phase(f, e), format.Goap_Phase.Searching)
	}
	frame(f, 5)
	testing.expect_value(t, phase(f, agents[0]), format.Goap_Phase.Running)
	testing.expect_value(t, phase(f, agents[1]), format.Goap_Phase.Running)
	testing.expect_value(t, phase(f, agents[2]), format.Goap_Phase.Searching)
	frame(f, 3)
	testing.expect_value(t, phase(f, agents[2]), format.Goap_Phase.Running)
}

// An action that fails makes the agent plan again, and the plan changes with the world: here a guard turns the
// failing action off.
@(test)
a_failed_action_replans :: proc(t: ^testing.T) {
	d := D {
		goals   = {{tests = {is(ARMED)}}},
		actions = {{action = "fail", n = 1, guard = "!blocked", effects = {set(ARMED)}}, {action = "step", n = 2, effects = {set(ARMED)}, cost = 3}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 12)
	failures := 0
	for s in starts(f) {
		failures += int(s == "start fail 1")
	}
	testing.expect(t, failures >= 2, "the failed action is planned again")
	testing.expect_value(t, key_value(f, e, "armed"), false)
	ai.set_key(&f.ai, e, "blocked", true)
	frame(f, 12)
	testing.expect(t, has_event(f, "start step 2"))
	testing.expect_value(t, key_value(f, e, "armed"), true)
}

// When the next action's guard does not hold, the agent plans again before it starts it, here without that action, so
// the goal fails.
@(test)
a_failed_precondition_replans :: proc(t: ^testing.T) {
	d := D {
		goals   = {{tests = {is(DOWN)}}},
		actions = {{action = "step", n = 3, guard = "!blocked", tests = {is(ARMED)}, effects = {set(DOWN)}}, {action = "walk", n = 1, effects = {set(ARMED)}}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	run_until(f, e, .Running)
	ai.set_key(&f.ai, e, "blocked", true)
	frame(f, 12)
	expect_starts(t, f, {"start walk 1"})
	testing.expect_value(t, key_value(f, e, "armed"), true)
	testing.expect_value(t, agent_of(f, e).failed, 1)
}

// A planning key that the rest of the plan depends on and that changes stops the running action, and the agent plans
// again from the world as it is: here it must reload before it attacks.
@(test)
a_changed_planning_key_replans :: proc(t: ^testing.T) {
	d := D {
		goals   = {{tests = {is(DOWN)}}},
		actions = {
			{action = "step", n = 3, tests = {is(ARMED), at_least(AMMO, 1)}, effects = {set(DOWN), add(AMMO, -1)}},
			{action = "walk", n = 1, effects = {set(ARMED)}},
			{action = "step", n = 2, effects = {add(AMMO, 3)}},
		},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	run_until(f, e, .Running)
	ai.set_key(&f.ai, e, "ammo", i32(0))
	frame(f, 20)
	testing.expect(t, has_event(f, "stop walk 1"), "the running action stops")
	expect_starts(t, f, {"start walk 1", "start step 2", "start walk 1", "start step 3"})
	testing.expect_value(t, key_value(f, e, "down"), true)
	testing.expect_value(t, key_value(f, e, "ammo"), i32(2))
}

// A goal of a higher priority that becomes current stops the running plan, and the agent plans for it.
@(test)
a_higher_priority_goal_replaces_the_plan :: proc(t: ^testing.T) {
	d := D {
		goals   = {{guard = "blocked", tests = {is(DOWN)}, priority = 10}, {tests = {is(ARMED)}}},
		actions = {{action = "step", n = 1, effects = {set(DOWN)}}, {action = "hold", n = 2, effects = {set(ARMED)}}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 8)
	expect_starts(t, f, {"start hold 2"})
	ai.set_key(&f.ai, e, "blocked", true)
	frame(f, 8)
	testing.expect(t, has_event(f, "stop hold 2"))
	testing.expect(t, has_event(f, "start step 1"))
	testing.expect_value(t, key_value(f, e, "down"), true)
}

// A goal's considerations scale its priority as a utility option's score is scaled, and the view gives each goal's
// priority.
@(test)
considerations_score_a_goals_priority :: proc(t: ^testing.T) {
	d := D {
		goals   = {{tests = {is(DOWN)}, health = true}, {tests = {is(ARMED)}, priority = 0.5}},
		actions = {{action = "hold", n = 1, effects = {set(DOWN)}}, {action = "hold", n = 2, effects = {set(ARMED)}}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	ai.set_key(&f.ai, e, "health", f32(0.9))
	start(f, e)
	frame(f, 8)
	expect_starts(t, f, {"start hold 1"})
	view, _ := ai.plan(&f.ai, e)
	testing.expect_value(t, view.goal, 1)
	testing.expect_value(t, len(view.goals), 2)
	if len(view.goals) == 2 {
		testing.expect_value(t, view.goals[0], ai.Goal_Priority{1, 0.9})
		testing.expect_value(t, view.goals[1], ai.Goal_Priority{2, 0.5})
	}
	ai.set_key(&f.ai, e, "health", f32(0.2))
	frame(f, 8)
	testing.expect(t, has_event(f, "stop hold 1"))
	testing.expect(t, has_event(f, "start hold 2"))
	view, _ = ai.plan(&f.ai, e)
	testing.expect_value(t, view.goal, 2)
}

// The plan and the search are in the agent's module state, so a code reload keeps them and the running action.
@(test)
the_plan_is_kept_across_a_code_reload :: proc(t: ^testing.T) {
	f := setup(t, {goals = {{tests = {is(ARMED)}}}, actions = {{action = "hold", n = 1, effects = {set(ARMED)}}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 6)
	testing.expect_value(t, phase(f, e), format.Goap_Phase.Running)
	ecs.reload(&f.world, &f.platform)
	register_world_components(f)
	ai.reload(&f.ai, &f.platform)
	ai.register(&f.ai, &f.world)
	register_test(&f.ai)
	frame(f, 6)
	testing.expect_value(t, phase(f, e), format.Goap_Phase.Running)
	testing.expectf(t, slice.equal(f.events[:], []string{"start hold 1"}), "events %v", f.events[:])
}

// Data that its check refuses makes the agent wait.
@(test)
a_refused_goap_waits :: proc(t: ^testing.T) {
	f := setup(t, down_plan())
	defer teardown(t, f)
	write_blob(t, f, DECISION, build(down_plan(), refused = true))
	context.logger = testlog.expected_errors()
	e := spawn_agent(f)
	frame(f, 3)
	state := ecs.get(&f.world, e, ai.Agent_State)
	testing.expect(t, state != nil)
	if state != nil {
		waiting, is_waiting := f.ai.agents.slots[state.agent.index].phase.(ai.Agent_Waiting)
		testing.expect(t, is_waiting)
		testing.expect_value(t, waiting.warned, ai.Wait_Reason.Refused)
	}
}

// The thinks give the same states and values on one job and on eight workers, with a budget that the searching agents
// share, failures, replanning and goals that change.
@(test)
goap_is_the_same_on_one_job_and_many :: proc(t: ^testing.T) {
	Outcome :: struct {
		state: [1024]byte,
		ammo:  i32,
		down:  bool,
		armed: bool,
	}
	run :: proc(t: ^testing.T, serial: bool) -> [dynamic]Outcome {
		d := D {
			goals = {{guard = "blocked", tests = {is(DOWN)}, priority = 5, health = true}, {tests = {at_least(AMMO, 6)}, priority = 2}, {tests = {is(MOOD, 1)}}},
			actions = {
				{action = "step", n = 3, tests = {is(ARMED), is(NEAR), at_least(AMMO, 1)}, effects = {set(DOWN), add(AMMO, -1)}},
				{action = "walk", n = 1, effects = {set(ARMED)}, cost_key = "cost"},
				{action = "walk", n = 2, tests = {is(NEAR, 0)}, effects = {set(NEAR)}},
				{action = "step", n = 4, effects = {add(AMMO, 2)}, cost = 2},
				{action = "fail", n = 5, guard = "!blocked", effects = {set(MOOD, 1)}},
				{action = "step", n = 6, effects = {set(MOOD, 1)}, cost = 4},
			},
			max_nodes = 12,
		}
		f := setup(t, d, serial = serial, workers = 0 if serial else 8)
		defer teardown(t, f)
		ai.set_plan_budget(&f.ai, .Goap, 7)
		agents := make([dynamic]ecs.Entity, context.temp_allocator)
		for i in 0 ..< 60 {
			e := spawn_agent(f, interval = f32(i % 3) * 0.05)
			ai.set_key(&f.ai, e, "health", f32(i % 5) * 0.2)
			ai.set_key(&f.ai, e, "cost", f32(i % 4))
			ai.set_key(&f.ai, e, "blocked", i % 2 == 0)
			append(&agents, e)
		}
		for e in agents {
			start(f, e)
		}
		outcomes := make([dynamic]Outcome)
		for step in 0 ..< 40 {
			frame(f)
			for e, i in agents {
				if (step + i) % 9 == 0 {
					ai.set_key(&f.ai, e, "blocked", (step + i) % 2 == 0)
					ai.set_key(&f.ai, e, "near", false)
				}
				o := Outcome {
					ammo  = key_value(f, e, "ammo").(i32),
					down  = key_value(f, e, "down").(bool),
					armed = key_value(f, e, "armed").(bool),
				}
				if ready := ready_of(f, e); ready != nil {
					copy(o.state[:], ready.state)
				}
				append(&outcomes, o)
			}
		}
		return outcomes
	}
	one := run(t, true)
	defer delete(one)
	many := run(t, false)
	defer delete(many)
	testing.expect(t, slice.equal(one[:], many[:]), "the outcomes differ")
}
