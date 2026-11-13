package htn

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
import "cinnabar:engine/ai/behavior_tree"
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
@(private = "file")
TREE :: format.Guid{0 = 0xd9}

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
	{"sees", .Bool},
	{"blocked", .Bool},
	{"trace", .Int},
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
PLANNING :: []string{"armed", "near", "down", "ammo", "mood", "sees"}
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
SEES :: 5

@(private = "file")
is :: proc(key: u32, v: i32 = 1) -> format.Plan_Test {
	return {key = key, lo = v, hi = v}
}

@(private = "file")
at_least :: proc(key: u32, v: i32) -> format.Plan_Test {
	return {key = key, lo = v, hi = max(i32)}
}

@(private = "file")
below :: proc(key: u32, v: i32) -> format.Plan_Test {
	return {key = key, lo = min(i32), hi = v - 1}
}

@(private = "file")
set :: proc(key: u32, v: i32 = 1) -> format.Plan_Effect {
	return {key = key, op = .Set, value = v}
}

@(private = "file")
add :: proc(key: u32, v: i32) -> format.Plan_Effect {
	return {key = key, op = .Add, value = v}
}

// act and task are subtasks: the action and the compound task of an index.
@(private = "file")
act :: proc(i: u32) -> format.Htn_Subtask {
	return {.Action, i}
}

@(private = "file")
task :: proc(i: u32) -> format.Htn_Subtask {
	return {.Task, i}
}

// A is a test action, a primitive task: a native test action with its label n, a bool key's name as its guard, `!`
// negating it, and its preconditions and effects.
@(private = "file")
A :: struct {
	action:  string,
	n:       i32,
	guard:   string,
	tests:   []format.Plan_Test,
	effects: []format.Plan_Effect,
}

// M is a test method: its guard, as an action's, its preconditions and its subtasks.
@(private = "file")
M :: struct {
	guard:    string,
	tests:    []format.Plan_Test,
	subtasks: []format.Htn_Subtask,
}

// T is a test compound task: its methods, in their order.
@(private = "file")
T :: struct {
	methods: []M,
}

// D is a test decision, whose root is its first task, with its plan's size, 0 being 8.
@(private = "file")
D :: struct {
	tasks:    []T,
	actions:  []A,
	max_plan: u32,
}

// build is the decision blob of an HTN decision, with its state as the cooker lays it out. The tasks are nodes 1 on,
// the actions 100 on, and the methods 200 on, in their tasks' order. refused makes its state too small, which the check
// refuses.
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
	tasks := make([dynamic]format.Htn_Task, context.temp_allocator)
	methods := make([dynamic]format.Htn_Method, context.temp_allocator)
	subtasks := make([dynamic]format.Htn_Subtask, context.temp_allocator)
	plan_actions := make([dynamic]format.Plan_Action, context.temp_allocator)
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
	for _, i in d.tasks {
		append(&nodes, format.Decision_Node_Contents{id = u32(i + 1), kind = "task", condition = format.DECISION_NONE, action = format.DECISION_NONE})
	}
	for t, i in d.tasks {
		record := format.Htn_Task {
			node         = u32(i),
			first_method = u32(len(methods)),
			method_count = u32(len(t.methods)),
		}
		for m in t.methods {
			append(&nodes, format.Decision_Node_Contents{id = u32(200 + len(methods)), kind = "method", condition = guard(&ops, &conditions, m.guard), action = format.DECISION_NONE})
			append(
				&methods,
				format.Htn_Method {
					node = u32(len(nodes) - 1),
					first_test = u32(len(tests)),
					test_count = u32(len(m.tests)),
					first_subtask = u32(len(subtasks)),
					subtask_count = u32(len(m.subtasks)),
				},
			)
			append(&tests, ..m.tests)
			append(&subtasks, ..m.subtasks)
		}
		append(&tasks, record)
	}
	for a, i in d.actions {
		append(&nodes, format.Decision_Node_Contents{id = u32(100 + i), kind = "action", condition = guard(&ops, &conditions, a.guard), action = u32(len(actions))})
		append(&constants, format.Decision_Constant_Contents{type = .Int, value = value(a.n)})
		append(&args, format.Decision_Arg_Contents{name = "n", source = .Constant, index = u32(len(constants) - 1), type = .Int})
		append(&actions, format.Decision_Action_Contents{name = a.action, first_arg = u32(len(args) - 1), arg_count = 1})
		append(
			&plan_actions,
			format.Plan_Action {
				node = u32(len(nodes) - 1),
				cost = {value = 1},
				first_test = u32(len(tests)),
				test_count = u32(len(a.tests)),
				first_effect = u32(len(effects)),
				effect_count = u32(len(a.effects)),
			},
		)
		append(&tests, ..a.tests)
		append(&effects, ..a.effects)
	}
	keys := make([dynamic]u32, context.temp_allocator)
	for name in PLANNING {
		append(&keys, slot_of(name))
	}
	contents := format.Htn_Contents {
		root     = 0,
		max_plan = d.max_plan if d.max_plan != 0 else 8,
		keys     = keys[:],
		actions  = plan_actions[:],
		tasks    = tasks[:],
		methods  = methods[:],
		subtasks = subtasks[:],
		tests    = tests[:],
		effects  = effects[:],
	}
	size := format.htn_state(u32(len(keys)), u32(len(plan_actions)), u32(len(methods)), contents.max_plan).size
	if refused {
		size -= 8
	}
	decision := format.Decision_Contents {
		guid           = guid,
		key            = key,
		technique      = .Htn,
		state_size     = u32(size),
		blackboard     = BOARD,
		blackboard_key = 77,
		nodes          = nodes[:],
		conditions     = conditions[:],
		ops            = ops[:],
		constants      = constants[:],
		actions        = actions[:],
		args           = args[:],
		technique_data = format.htn_write(contents, context.temp_allocator),
		source_path    = "game/ai/test.decision",
	}
	return format.decision_write(decision, context.temp_allocator)
}

// build_tree is a behavior tree over the same blackboard and actions: a sequence of walk 2, a write of 7 to trace, and a
// long wait.
@(private = "file")
build_tree :: proc() -> []byte {
	tree := []format.Tree_Node {
		{node = 0, end = 4, kind = .Sequence, test = format.DECISION_NONE, state = 0},
		{node = 1, end = 2, kind = .Action, test = format.DECISION_NONE, state = 16},
		{node = 2, end = 3, kind = .Set, test = format.DECISION_NONE, state = 32},
		{node = 3, end = 4, kind = .Wait, test = format.DECISION_NONE, seconds = {seconds = 1000}, state = 48, timers = 64},
	}
	contents := format.Decision_Contents {
		guid           = TREE,
		key            = 5,
		technique      = .Behavior_Tree,
		state_size     = 72,
		blackboard     = BOARD,
		blackboard_key = 77,
		nodes          = {
			{id = 1, kind = "sequence", condition = format.DECISION_NONE, action = format.DECISION_NONE},
			{id = 2, kind = "action", condition = format.DECISION_NONE, action = 0},
			{id = 3, kind = "set", condition = format.DECISION_NONE, action = format.DECISION_NONE, first_write = 0, write_count = 1},
			{id = 4, kind = "wait", condition = format.DECISION_NONE, action = format.DECISION_NONE},
		},
		constants      = {{type = .Int, value = value(i32(2))}, {type = .Int, value = value(i32(7))}},
		actions        = {{name = "walk", first_arg = 0, arg_count = 1}},
		args           = {{name = "n", source = .Constant, index = 0, type = .Int}},
		writes         = {{key = slot_of("trace"), source = .Constant, index = 1}},
		technique_data = format.tree_write(tree, context.temp_allocator),
		source_path    = "game/ai/tree.decision",
	}
	return format.decision_write(contents, context.temp_allocator)
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

// register_test registers the module, the behavior tree's module and the test actions, each with its label n, which
// only start reads, so the actions that stop keep it in their state: step, which succeeds when it starts; walk, which
// runs for 3 ticks and succeeds; hold, which runs until it is stopped; and fail, which fails.
@(private = "file")
register_test :: proc(s: ^ai.State) {
	register(s)
	behavior_tree.register(s)
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

// setup makes a world with the AI, the modules and the test actions, over a loose cache with the test blackboard, the
// decision and the tree. serial runs every job at once on the calling thread; otherwise the scheduler has workers
// threads.
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
	cache, err := os.make_directory_temp("", "htn_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	ai.init(&f.ai, &f.platform, &f.assets)
	ai.register(&f.ai, &f.world)
	register_test(&f.ai)
	write_blob(t, f, BOARD, format.blackboard_write(board_contents(), context.temp_allocator))
	write_blob(t, f, DECISION, build(d))
	write_blob(t, f, TREE, build_tree())
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

// phase is the agent's HTN phase.
@(private = "file")
phase :: proc(f: ^Fixture, e: ecs.Entity) -> format.Htn_Phase {
	ready := ready_of(f, e)
	if ready == nil {
		return .Idle
	}
	return (^format.Htn_Agent)(raw_data(ready.state)).phase
}

// runs is whether the agent runs a plan, whether or not it decomposes for a better one.
@(private = "file")
runs :: proc(f: ^Fixture, e: ecs.Entity) -> bool {
	p := phase(f, e)
	return p == .Running || p == .Checking
}

// run_until runs frames until the agent's phase is the one asked for, at most limit, and gives the frames that it ran,
// or -1.
@(private = "file")
run_until :: proc(f: ^Fixture, e: ecs.Entity, p: format.Htn_Phase, limit := 50) -> int {
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
has_event :: proc(f: ^Fixture, event: string) -> bool {
	return slice.contains(f.events[:], event)
}

@(private = "file")
key_value :: proc(f: ^Fixture, e: ecs.Entity, key: string) -> ai.Value {
	v, _ := ai.get_key(&f.ai, e, key)
	return v
}

// backtracking is a root whose first method holds once the target is down, and whose second gets the agent near and
// downs the target. Its task 1 arms the agent by its first method, which leaves it far, so the attack fails, and the
// decomposition backtracks into task 1, which it had finished, to its second method, which closes in. The
// decomposition takes eight steps: the root, task 1, arm, the attack that fails, the root again, task 1's second
// method, the approach, and the attack.
@(private = "file")
backtracking :: proc() -> D {
	return D {
		tasks = slice.clone(
			[]T {
				{
					methods = slice.clone(
						[]M {
							{tests = slice.clone([]format.Plan_Test{is(DOWN)}, context.temp_allocator), subtasks = slice.clone([]format.Htn_Subtask{act(3)}, context.temp_allocator)},
							{subtasks = slice.clone([]format.Htn_Subtask{task(1), act(2)}, context.temp_allocator)},
						},
						context.temp_allocator,
					),
				},
				{
					methods = slice.clone(
						[]M{{subtasks = slice.clone([]format.Htn_Subtask{act(0)}, context.temp_allocator)}, {subtasks = slice.clone([]format.Htn_Subtask{act(1)}, context.temp_allocator)}},
						context.temp_allocator,
					),
				},
			},
			context.temp_allocator,
		),
		actions = slice.clone(
			[]A {
				{action = "step", n = 1, effects = slice.clone([]format.Plan_Effect{set(ARMED)}, context.temp_allocator)},
				{action = "step", n = 2, effects = slice.clone([]format.Plan_Effect{set(NEAR)}, context.temp_allocator)},
				{
					action = "step",
					n = 3,
					tests = slice.clone([]format.Plan_Test{is(NEAR)}, context.temp_allocator),
					effects = slice.clone([]format.Plan_Effect{set(DOWN)}, context.temp_allocator),
				},
				{action = "hold", n = 9},
			},
			context.temp_allocator,
		),
	}
}

// The root's methods are tried in their order: the first whose preconditions hold runs, and when its plan is done, the
// root is decomposed again on the world as the plan left it.
@(test)
methods_are_tried_in_order :: proc(t: ^testing.T) {
	d := D {
		tasks   = {{methods = {{tests = {is(DOWN)}, subtasks = {act(2)}}, {tests = {is(ARMED)}, subtasks = {act(1)}}, {subtasks = {act(0)}}}}},
		actions = {{action = "walk", n = 1, effects = {set(ARMED)}}, {action = "step", n = 3, effects = {set(DOWN)}}, {action = "hold", n = 9}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	testing.expect(t, run_until(f, e, .Running) >= 0, "a plan is found")
	view, ok := ai.plan(&f.ai, e)
	testing.expect(t, ok)
	testing.expect_value(t, view.goal, 0)
	testing.expect_value(t, len(view.goals), 0)
	testing.expect_value(t, len(view.steps), 1)
	if len(view.steps) == 1 {
		testing.expect_value(t, view.steps[0], ai.Plan_Step{100, "walk"})
	}
	testing.expect_value(t, len(view.methods), 1)
	if len(view.methods) == 1 {
		testing.expect_value(t, view.methods[0], ai.Plan_Method{1, 202})
	}
	frame(f, 15)
	expect_starts(t, f, {"start walk 1", "start step 3", "start hold 9"})
	testing.expect_value(t, key_value(f, e, "armed"), true)
	testing.expect_value(t, key_value(f, e, "down"), true)
	view, _ = ai.plan(&f.ai, e)
	if len(view.methods) == 1 {
		testing.expect_value(t, view.methods[0], ai.Plan_Method{1, 200})
	}
	_, ok = ai.plan(&f.ai, ecs.spawn(&f.world))
	testing.expect(t, !ok)
}

// A primitive task whose preconditions fail backtracks to the last choice, here into a compound task that the
// decomposition had finished, and the view gives each task's method and the decomposition's steps.
@(test)
a_failed_method_backtracks :: proc(t: ^testing.T) {
	f := setup(t, backtracking())
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	testing.expect(t, run_until(f, e, .Running) >= 0, "a plan is found")
	view, _ := ai.plan(&f.ai, e)
	testing.expect_value(t, view.nodes, 8)
	testing.expect_value(t, len(view.steps), 2)
	if len(view.steps) == 2 {
		testing.expect_value(t, view.steps[0], ai.Plan_Step{101, "step"})
		testing.expect_value(t, view.steps[1], ai.Plan_Step{102, "step"})
	}
	testing.expect_value(t, len(view.methods), 2)
	if len(view.methods) == 2 {
		testing.expect_value(t, view.methods[0], ai.Plan_Method{1, 201})
		testing.expect_value(t, view.methods[1], ai.Plan_Method{2, 203})
	}
	frame(f, 10)
	expect_starts(t, f, {"start step 2", "start step 3", "start hold 9"})
	testing.expect_value(t, key_value(f, e, "armed"), false)
	testing.expect_value(t, key_value(f, e, "down"), true)
}

// While a plan runs, the agent decomposes again on each think, and an earlier method that becomes possible replaces the
// running plan: a guard who searches drops the search when it sees the player.
@(test)
a_better_method_cuts_in_by_the_record :: proc(t: ^testing.T) {
	d := D {
		tasks   = {{methods = {{tests = {is(SEES)}, subtasks = {act(1)}}, {subtasks = {act(0)}}}}},
		actions = {{action = "hold", n = 1}, {action = "hold", n = 2}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 8)
	expect_starts(t, f, {"start hold 1"})
	testing.expect(t, runs(f, e))
	ai.set_key(&f.ai, e, "sees", true)
	frame(f, 4)
	testing.expect(t, has_event(f, "stop hold 1"), "the running action stops")
	expect_starts(t, f, {"start hold 1", "start hold 2"})
	view, _ := ai.plan(&f.ai, e)
	if len(view.methods) == 1 {
		testing.expect_value(t, view.methods[0], ai.Plan_Method{1, 200})
	}
	// A later method that becomes possible is not better, and the plan goes on.
	ai.set_key(&f.ai, e, "sees", false)
	frame(f, 6)
	expect_starts(t, f, {"start hold 1", "start hold 2"})
}

// The record that the agent finds again on each think is equal to the running plan's, and the plan goes on. A better
// plan whose first action is the action that runs keeps it running: here the plan's own effect makes the first method
// possible, and its hold is the one that runs.
@(test)
an_equal_record_keeps_the_running_action :: proc(t: ^testing.T) {
	d := D {
		tasks   = {{methods = {{tests = {is(ARMED)}, subtasks = {act(1)}}, {subtasks = {act(0), act(1)}}}}},
		actions = {{action = "step", n = 2, effects = {set(ARMED)}}, {action = "hold", n = 1}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 20)
	testing.expectf(t, slice.equal(f.events[:], []string{"start step 2", "start hold 1"}), "events %v", f.events[:])
	testing.expect(t, runs(f, e))
	view, _ := ai.plan(&f.ai, e)
	testing.expect_value(t, len(view.steps), 1)
	if len(view.methods) == 1 {
		testing.expect_value(t, view.methods[0], ai.Plan_Method{1, 200})
	}
	testing.expect_value(t, ai.current_action(&f.ai, e), "hold")
}

// When the next action's guard does not hold when its turn comes, the agent decomposes the root again, here without
// that action, so the root's next method runs.
@(test)
a_failed_precondition_replans_from_the_root :: proc(t: ^testing.T) {
	d := D {
		tasks   = {{methods = {{tests = {is(DOWN, 0)}, subtasks = {act(0), act(1)}}, {subtasks = {act(2)}}}}},
		actions = {{action = "walk", n = 1, effects = {set(ARMED)}}, {action = "step", n = 3, guard = "!blocked", tests = {is(ARMED)}, effects = {set(DOWN)}}, {action = "hold", n = 9}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	run_until(f, e, .Running)
	ai.set_key(&f.ai, e, "blocked", true)
	frame(f, 12)
	expect_starts(t, f, {"start walk 1", "start hold 9"})
	testing.expect_value(t, key_value(f, e, "armed"), true)
	testing.expect_value(t, key_value(f, e, "down"), false)
}

// An action that fails makes the agent decompose the root again, and the plan changes with the world: here a guard
// turns the failing method off.
@(test)
a_failed_action_replans :: proc(t: ^testing.T) {
	d := D {
		tasks   = {{methods = {{guard = "!blocked", subtasks = {act(0)}}, {subtasks = {act(1)}}}}},
		actions = {{action = "fail", n = 1}, {action = "hold", n = 2}},
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
	ai.set_key(&f.ai, e, "blocked", true)
	frame(f, 6)
	testing.expect(t, has_event(f, "start hold 2"))
}

// With a plan budget of 1 step, the decomposition of eight steps takes eight thinks, which come in the ticks after
// each other whatever the agent's interval. With 3, it takes three.
@(test)
a_decomposition_is_spread_over_ticks_by_the_budget :: proc(t: ^testing.T) {
	f := setup(t, backtracking())
	defer teardown(t, f)
	ai.set_plan_budget(&f.ai, .Htn, 1)
	e := spawn_agent(f, interval = 10)
	start(f, e)
	testing.expect(t, run_until(f, e, .Planning, 1000) >= 0)
	testing.expect_value(t, run_until(f, e, .Running), 8)
	ai.set_plan_budget(&f.ai, .Htn, 3)
	quick := spawn_agent(f)
	start(f, quick)
	run_until(f, quick, .Planning)
	testing.expect_value(t, run_until(f, quick, .Running), 3)
}

// A task that recurses without an action fills the stack of methods, so its method fails, and the root's next method
// runs.
@(test)
recursion_is_bounded_by_the_depth :: proc(t: ^testing.T) {
	d := D {
		tasks   = {{methods = {{subtasks = {task(1)}}, {subtasks = {act(0)}}}}, {methods = {{subtasks = {task(1), act(0)}}}}},
		actions = {{action = "hold", n = 2}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 10)
	expect_starts(t, f, {"start hold 2"})
	view, _ := ai.plan(&f.ai, e)
	if len(view.methods) == 1 {
		testing.expect_value(t, view.methods[0], ai.Plan_Method{1, 201})
	}
	testing.expect(t, view.nodes > format.MAX_HTN_DEPTH, "the decomposition went as deep as the stack")
}

// The plan, its record and the decomposition are in the agent's module state, so a code reload keeps them and the
// running action.
@(test)
the_plan_is_kept_across_a_code_reload :: proc(t: ^testing.T) {
	f := setup(t, {tasks = {{methods = {{subtasks = {act(0)}}}}}, actions = {{action = "hold", n = 1}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 6)
	testing.expect(t, runs(f, e))
	ecs.reload(&f.world, &f.platform)
	register_world_components(f)
	ai.reload(&f.ai, &f.platform)
	ai.register(&f.ai, &f.world)
	register_test(&f.ai)
	frame(f, 6)
	testing.expect(t, runs(f, e))
	testing.expectf(t, slice.equal(f.events[:], []string{"start hold 1"}), "events %v", f.events[:])
}

// Data that its check refuses makes the agent wait.
@(test)
a_refused_htn_waits :: proc(t: ^testing.T) {
	f := setup(t, backtracking())
	defer teardown(t, f)
	write_blob(t, f, DECISION, build(backtracking(), refused = true))
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

// One blackboard and one set of actions serve a behavior tree and an HTN decision.
@(test)
an_htn_decision_and_a_behavior_tree_share_a_blackboard_and_actions :: proc(t: ^testing.T) {
	d := D {
		tasks   = {{methods = {{tests = {is(ARMED, 0)}, subtasks = {act(0)}}, {subtasks = {act(1)}}}}},
		actions = {{action = "walk", n = 3, effects = {set(ARMED)}}, {action = "hold", n = 1}},
	}
	f := setup(t, d)
	defer teardown(t, f)
	tree := spawn_agent(f, TREE)
	plan := spawn_agent(f)
	start(f, tree)
	start(f, plan)
	frame(f, 12)
	testing.expect_value(t, key_value(f, tree, "trace"), i32(7))
	testing.expect_value(t, ai.current_action(&f.ai, tree), "")
	testing.expect_value(t, key_value(f, plan, "armed"), true)
	testing.expect_value(t, ai.current_action(&f.ai, plan), "hold")
	testing.expect(t, has_event(f, "start walk 2"), "the tree walks")
	testing.expect(t, has_event(f, "start walk 3"), "the plan walks")
}

// The thinks give the same states and values on one job and on eight workers, with a budget that the decomposing
// agents share, backtracking, failures, better methods and replanning.
@(test)
htn_is_the_same_on_one_job_and_many :: proc(t: ^testing.T) {
	Outcome :: struct {
		state: [2048]byte,
		ammo:  i32,
		down:  bool,
		armed: bool,
	}
	run :: proc(t: ^testing.T, serial: bool) -> [dynamic]Outcome {
		d := D {
			tasks = {
				{
					methods = {
						{guard = "blocked", tests = {is(DOWN, 0)}, subtasks = {task(1), act(0)}},
						{tests = {below(AMMO, 6)}, subtasks = {act(3)}},
						{tests = {is(SEES)}, subtasks = {act(4)}},
						{subtasks = {act(5)}},
					},
				},
				{methods = {{tests = {is(NEAR)}, subtasks = {act(1)}}, {subtasks = {act(2), act(1)}}}},
			},
			actions = {
				{action = "step", n = 3, tests = {is(ARMED), is(NEAR), at_least(AMMO, 1)}, effects = {set(DOWN), add(AMMO, -1)}},
				{action = "walk", n = 1, effects = {set(ARMED)}},
				{action = "walk", n = 2, tests = {is(NEAR, 0)}, effects = {set(NEAR)}},
				{action = "step", n = 4, effects = {add(AMMO, 2)}},
				{action = "fail", n = 5, guard = "!blocked", effects = {set(MOOD, 1)}},
				{action = "hold", n = 6},
			},
			max_plan = 4,
		}
		f := setup(t, d, serial = serial, workers = 0 if serial else 8)
		defer teardown(t, f)
		ai.set_plan_budget(&f.ai, .Htn, 7)
		agents := make([dynamic]ecs.Entity, context.temp_allocator)
		for i in 0 ..< 60 {
			e := spawn_agent(f, interval = f32(i % 3) * 0.05)
			ai.set_key(&f.ai, e, "blocked", i % 2 == 0)
			ai.set_key(&f.ai, e, "sees", i % 3 == 0)
			ai.set_key(&f.ai, e, "ammo", i32(i % 8))
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
					ai.set_key(&f.ai, e, "down", false)
					ai.set_key(&f.ai, e, "sees", (step + i) % 4 == 0)
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
