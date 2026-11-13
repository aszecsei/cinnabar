package behavior_tree

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:time"

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
	cooks:    int,
	// The decision's version, its blob's key.
	version:  u64,
	// What the native actions did, in their order, with the tick of each, which a lock keeps, since they run on jobs.
	log_lock: sync.Mutex,
	events:   [dynamic]string,
	ticks:    [dynamic]u64,
}

@(private = "file")
BOARD :: format.Guid{0 = 0xb7}
@(private = "file")
DECISION :: format.Guid{0 = 0xd7}

// The test blackboard's keys, at their slots.
@(private = "file")
KEYS :: [?]struct {
	name: string,
	type: format.Blackboard_Type,
} {
	{"a", .Bool},
	{"b", .Bool},
	{"delay", .Float},
	{"trace", .Int},
	{"count", .Int},
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
	keys[2].default = value(f32(0.25))
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

// N is a node of a test tree, which build writes in depth-first order. guard and test are a bool key's name, or its
// name after ! for its negation. action is a test action, with walk's steps. set_key's node writes set_value.
@(private = "file")
N :: struct {
	kind:        format.Tree_Kind,
	children:    []N,
	action:      string,
	steps:       i32,
	guard:       string,
	abort:       format.Tree_Abort,
	test:        string,
	seconds:     f32,
	seconds_key: string,
	set_key:     string,
	set_value:   i32,
	invert:      bool,
	force:       format.Tree_Force,
	policy:      format.Tree_Policy,
	repeat:      u32,
	cooldown:    f32,
	time_limit:  f32,
}

@(private = "file")
Builder :: struct {
	tree:       [dynamic]format.Tree_Node,
	nodes:      [dynamic]format.Decision_Node_Contents,
	conditions: [dynamic]format.Decision_Condition,
	ops:        [dynamic]format.Decision_Op,
	constants:  [dynamic]format.Decision_Constant_Contents,
	actions:    [dynamic]format.Decision_Action_Contents,
	args:       [dynamic]format.Decision_Arg_Contents,
	writes:     [dynamic]format.Decision_Write,
}

@(private = "file")
condition :: proc(b: ^Builder, text: string) -> u32 {
	if text == "" {
		return format.DECISION_NONE
	}
	first := u32(len(b.ops))
	negated := text[0] == '!'
	append(&b.ops, format.Decision_Op{code = .Key, operand = slot_of(text[1:] if negated else text)})
	if negated {
		append(&b.ops, format.Decision_Op{code = .Not})
	}
	append(&b.conditions, format.Decision_Condition{first_op = first, op_count = u32(len(b.ops)) - first})
	return u32(len(b.conditions) - 1)
}

@(private = "file")
flatten :: proc(b: ^Builder, n: N) {
	at := len(b.tree)
	names := format.TREE_KIND_NAMES
	shared := format.Decision_Node_Contents {
		id        = u32(at + 1),
		kind      = names[n.kind],
		condition = condition(b, n.guard),
		action    = format.DECISION_NONE,
	}
	if n.action != "" {
		shared.action = u32(len(b.actions))
		action := format.Decision_Action_Contents {
			name      = n.action,
			first_arg = u32(len(b.args)),
		}
		if n.steps != 0 {
			append(&b.constants, format.Decision_Constant_Contents{type = .Int, value = value(n.steps)})
			append(&b.args, format.Decision_Arg_Contents{name = "steps", source = .Constant, index = u32(len(b.constants) - 1), type = .Int})
			action.arg_count = 1
		}
		append(&b.actions, action)
	}
	if n.set_key != "" {
		keys := KEYS
		slot := slot_of(n.set_key)
		constant := format.Decision_Constant_Contents {
			type  = keys[slot].type,
			value = value(n.set_value) if keys[slot].type == .Int else value(u8(n.set_value)),
		}
		append(&b.constants, constant)
		shared.first_write = u32(len(b.writes))
		shared.write_count = 1
		append(&b.writes, format.Decision_Write{key = slot, source = .Constant, index = u32(len(b.constants) - 1)})
	}
	record := format.Tree_Node {
		node    = u32(len(b.nodes)),
		kind    = n.kind,
		abort   = n.abort,
		force   = n.force,
		policy  = n.policy,
		repeat  = n.repeat,
		test    = condition(b, n.test),
		seconds = {seconds = n.seconds},
	}
	if n.seconds_key != "" {
		record.seconds = {key = slot_of(n.seconds_key), source = .Key}
	}
	if n.invert {
		record.flags += {.Invert}
	}
	if n.cooldown != 0 {
		record.flags += {.Cooldown}
		record.cooldown = {seconds = n.cooldown}
	}
	if n.time_limit != 0 {
		record.flags += {.Time_Limit}
		record.time_limit = {seconds = n.time_limit}
	}
	append(&b.nodes, shared)
	append(&b.tree, record)
	for c in n.children {
		flatten(b, c)
	}
	b.tree[at].end = u32(len(b.tree))
}

// build is the decision blob of a tree, with each node's state after the one before and the timers after the states.
@(private = "file")
build :: proc(root: N, key: u64) -> []byte {
	b := Builder {
		tree       = make([dynamic]format.Tree_Node, context.temp_allocator),
		nodes      = make([dynamic]format.Decision_Node_Contents, context.temp_allocator),
		conditions = make([dynamic]format.Decision_Condition, context.temp_allocator),
		ops        = make([dynamic]format.Decision_Op, context.temp_allocator),
		constants  = make([dynamic]format.Decision_Constant_Contents, context.temp_allocator),
		actions    = make([dynamic]format.Decision_Action_Contents, context.temp_allocator),
		args       = make([dynamic]format.Decision_Arg_Contents, context.temp_allocator),
		writes     = make([dynamic]format.Decision_Write, context.temp_allocator),
	}
	flatten(&b, root)
	timers := u32(len(b.tree) * format.TREE_STATE_SIZE)
	for &n, i in b.tree {
		n.state = u32(i * format.TREE_STATE_SIZE)
		n.timers = timers
		timers += u32(card(format.tree_timers(n))) * 8
	}
	contents := format.Decision_Contents {
		guid           = DECISION,
		key            = key,
		technique      = .Behavior_Tree,
		state_size     = timers,
		blackboard     = BOARD,
		blackboard_key = 77,
		nodes          = b.nodes[:],
		conditions     = b.conditions[:],
		ops            = b.ops[:],
		constants      = b.constants[:],
		actions        = b.actions[:],
		args           = b.args[:],
		writes         = b.writes[:],
		technique_data = format.tree_write(b.tree[:], context.temp_allocator),
		source_path    = "game/ai/test.decision",
	}
	return format.decision_write(contents, context.temp_allocator)
}

@(private = "file")
log_event :: proc(a: ^ai.Action_Context, event: string) {
	f := (^Fixture)(a.system.user)
	sync.lock(&f.log_lock)
	defer sync.unlock(&f.log_lock)
	append(&f.events, event)
	append(&f.ticks, a.world.clock.tick)
}

// register_test registers the module and the test actions: ok, which succeeds when it starts; no, which fails in its
// first tick; walk, which runs for its steps and succeeds; and run, which runs until it is stopped.
@(private = "file")
register_test :: proc(s: ^ai.State) {
	register(s)
	ai.register_action(s, {name = "ok", start = proc(a: ^ai.Action_Context) {log_event(a, "start ok")}})
	ai.register_action(
		s,
		{
			name = "no",
			start = proc(a: ^ai.Action_Context) {log_event(a, "start no")},
			tick = proc(a: ^ai.Action_Context) -> ai.Action_Status {return .Failed},
		},
	)
	ai.register_action(
		s,
		{
			name = "walk",
			params = {{"steps", .Int}},
			state_size = 4,
			start = proc(a: ^ai.Action_Context) {
				steps, _ := ai.arg(a, "steps")
				(^i32)(&a.state[0])^ = steps.(i32)
				log_event(a, "start walk")
			},
			tick = proc(a: ^ai.Action_Context) -> ai.Action_Status {
				left := (^i32)(&a.state[0])
				left^ -= 1
				return .Succeeded if left^ <= 0 else .Running
			},
			stop = proc(a: ^ai.Action_Context) {log_event(a, "stop walk")},
		},
	)
	ai.register_action(
		s,
		{
			name = "run",
			start = proc(a: ^ai.Action_Context) {log_event(a, "start run")},
			tick = proc(a: ^ai.Action_Context) -> ai.Action_Status {return .Running},
			stop = proc(a: ^ai.Action_Context) {log_event(a, "stop run")},
		},
	)
}

@(private = "file")
register_world_components :: proc(f: ^Fixture) {
	ecs.register_engine_components(&f.world.registry)
	ai.register_components(&f.world.registry)
}

// setup makes a world with the AI, the module and the test actions, over a loose cache with the test blackboard and the
// tree's decision. serial runs every job at once on the calling thread; otherwise the scheduler has workers threads.
@(private = "file")
setup :: proc(t: ^testing.T, root: N, serial := true, workers := 0) -> ^Fixture {
	sync.lock(&test_lock)
	f := new(Fixture)
	f.serial = serial
	f.events = make([dynamic]string)
	f.ticks = make([dynamic]u64)
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
	cache, err := os.make_directory_temp("", "behavior_tree_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	ai.init(&f.ai, &f.platform, &f.assets)
	ai.register(&f.ai, &f.world)
	register_test(&f.ai)
	write_blob(t, f, BOARD, format.blackboard_write(board_contents(), context.temp_allocator))
	f.version = 1
	write_blob(t, f, DECISION, build(root, f.version))
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
	delete(f.events)
	delete(f.ticks)
	free(f)
	sync.unlock(&test_lock)
}

@(private = "file")
write_blob :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, data: []byte) {
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(guid, &buffer))
	testing.expect(t, os.write_entire_file(path, data) == nil)
}

// recook writes another tree as the decision, as a cook does, and the agents start again with it.
@(private = "file")
recook :: proc(t: ^testing.T, f: ^Fixture, root: N) {
	f.version += 1
	write_blob(t, f, DECISION, build(root, f.version))
	f.cooks += 1
	later := time.time_add(time.now(), time.Duration(f.cooks) * time.Minute)
	generation := fmt.tprintf("%s/%s", f.cache, format.GENERATION_FILE)
	testing.expect(t, os.write_entire_file(generation, transmute([]byte)fmt.tprintf("%d", f.cooks)) == nil)
	testing.expect(t, os.change_times(generation, later, later) == nil)
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(DECISION, &buffer))
	testing.expect(t, os.change_times(path, later, later) == nil)
	asset.poll(&f.assets)
	clear(&f.events)
	clear(&f.ticks)
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

@(private = "file")
spawn_agent :: proc(f: ^Fixture) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{rotation = 1, scale = 1})
	ecs.add(&f.world, e, ai.Agent{blackboard = BOARD, decision = DECISION})
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

// status is a node's status, by its index in the tree's depth-first order.
@(private = "file")
status :: proc(f: ^Fixture, e: ecs.Entity, node: int) -> Status {
	ready := ready_of(f, e)
	if ready == nil {
		return .Idle
	}
	return (^Node_State)(&ready.state[node * format.TREE_STATE_SIZE]).status
}

@(private = "file")
int_key :: proc(f: ^Fixture, e: ecs.Entity, key: string) -> i32 {
	v, ok := ai.get_key(&f.ai, e, key)
	return v.(i32) if ok else -1
}

// think_until runs frames until the agent has thought n times, at most limit frames.
@(private = "file")
think_until :: proc(f: ^Fixture, e: ecs.Entity, n: u32, limit := 100) {
	for _ in 0 ..< limit {
		if ready := ready_of(f, e); ready != nil && ready.thinks >= n {
			return
		}
		frame(f)
	}
}

@(private = "file")
count_events :: proc(f: ^Fixture, event: string) -> (count: int) {
	for e in f.events {
		count += int(e == event)
	}
	return
}

@(private = "file")
expect_events :: proc(t: ^testing.T, f: ^Fixture, expected: []string, loc := #caller_location) {
	testing.expectf(t, slice.equal(f.events[:], expected), "events %v, expected %v", f.events[:], expected, loc = loc)
}

// HOLD is a wait so long that the tree stays in it, so a test sees where the tree got to.
@(private = "file")
HOLD :: N {
	kind    = .Wait,
	seconds = 1000,
}

// A sequence runs its children in order until one fails, and then fails.
@(test)
a_sequence_runs_its_children_until_one_fails :: proc(t: ^testing.T) {
	f := setup(
		t,
		{
			kind = .Selector,
			children = {
				{
					kind = .Sequence,
					children = {{kind = .Action, action = "ok"}, {kind = .Set, set_key = "trace", set_value = 1}, {kind = .Action, action = "no"}, {kind = .Set, set_key = "trace", set_value = 2}},
				},
				HOLD,
			},
		},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 20)
	expect_events(t, f, {"start ok", "start no"})
	testing.expect_value(t, int_key(f, e, "trace"), 1)
	testing.expect_value(t, status(f, e, 1), Status.Failed)
	testing.expect_value(t, status(f, e, 6), Status.Running)
}

// A selector runs its children in order until one succeeds, and fails when every one fails.
@(test)
a_selector_runs_its_children_until_one_succeeds :: proc(t: ^testing.T) {
	f := setup(
		t,
		{
			kind = .Selector,
			children = {
				{
					kind = .Sequence,
					children = {
						{kind = .Selector, children = {{kind = .Action, action = "no"}, {kind = .Action, action = "ok"}, {kind = .Set, set_key = "count", set_value = 9}}},
						{kind = .Set, set_key = "trace", set_value = 1},
						{kind = .Selector, children = {{kind = .Action, action = "no"}, {kind = .Condition, test = "a"}}},
						{kind = .Set, set_key = "trace", set_value = 2},
					},
				},
				HOLD,
			},
		},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 20)
	expect_events(t, f, {"start no", "start ok", "start no"})
	testing.expect_value(t, int_key(f, e, "trace"), 1)
	testing.expect_value(t, int_key(f, e, "count"), 0)
}

// A parallel runs its children together: with policy one it succeeds when one does, with all when all do and fails when
// one fails, and it stops the children that still run when it ends.
@(test)
a_parallel_succeeds_by_one_or_all_and_stops_the_others :: proc(t: ^testing.T) {
	f := setup(
		t,
		{
			kind = .Selector,
			children = {
				{
					kind = .Sequence,
					children = {
						{kind = .Parallel, policy = .One, children = {{kind = .Action, action = "run"}, {kind = .Wait, seconds = 0.05}}},
						{kind = .Set, set_key = "trace", set_value = 1},
						{kind = .Parallel, policy = .All, children = {{kind = .Action, action = "walk", steps = 2}, {kind = .Wait, seconds = 0.05}}},
						{kind = .Set, set_key = "trace", set_value = 2},
						{
							kind = .Parallel,
							policy = .All,
							children = {{kind = .Action, action = "run"}, {kind = .Sequence, children = {{kind = .Wait, seconds = 0.05}, {kind = .Condition, test = "a"}}}},
						},
						{kind = .Set, set_key = "trace", set_value = 3},
					},
				},
				HOLD,
			},
		},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 40)
	expect_events(t, f, {"start run", "stop run", "start walk", "stop walk", "start run", "stop run"})
	testing.expect_value(t, int_key(f, e, "trace"), 2)
}

// An action runs over several thinks, and its node runs until the action ends.
@(test)
an_action_runs_over_several_thinks :: proc(t: ^testing.T) {
	f := setup(t, {kind = .Sequence, children = {{kind = .Action, action = "walk", steps = 4}, {kind = .Set, set_key = "trace", set_value = 1}, HOLD}})
	defer teardown(t, f)
	e := spawn_agent(f)
	think_until(f, e, 1)
	running := 0
	for _ in 0 ..< 20 {
		if status(f, e, 1) == .Running {
			running += 1
			testing.expect_value(t, int_key(f, e, "trace"), 0)
		}
		frame(f)
	}
	testing.expectf(t, running >= 4, "the action ran over %d thinks", running)
	expect_events(t, f, {"start walk", "stop walk"})
	testing.expect_value(t, int_key(f, e, "trace"), 1)
	testing.expect_value(t, status(f, e, 1), Status.Succeeded)
}

// A wait runs for its seconds, a constant or a key's, in ticks.
@(test)
wait_runs_for_a_constant_or_a_key :: proc(t: ^testing.T) {
	f := setup(
		t,
		{
			kind = .Sequence,
			children = {
				{kind = .Wait, seconds = 0.5},
				{kind = .Set, set_key = "trace", set_value = 1},
				{kind = .Wait, seconds_key = "delay"},
				{kind = .Set, set_key = "trace", set_value = 2},
				HOLD,
			},
		},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	ai.set_key(&f.ai, e, "delay", f32(0.1))
	think_until(f, e, 1)
	start := f.world.clock.tick
	first, second: u64
	for _ in 0 ..< 60 {
		frame(f)
		trace := int_key(f, e, "trace")
		if trace >= 1 && first == 0 {
			first = f.world.clock.tick
		}
		if trace >= 2 && second == 0 {
			second = f.world.clock.tick
		}
	}
	// The sets' writes land in the tick that the waits end in.
	testing.expect_value(t, first - start, 30)
	testing.expect_value(t, second - first, 6)
}

// A set writes its keys and succeeds, and the writes land after the tick.
@(test)
set_writes_and_succeeds :: proc(t: ^testing.T) {
	f := setup(
		t,
		{
			kind = .Selector,
			children = {
				{kind = .Sequence, children = {{kind = .Set, set_key = "a", set_value = 1}, {kind = .Set, set_key = "count", set_value = 7}, {kind = .Condition, test = "a"}}},
				HOLD,
			},
		},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	think_until(f, e, 1)
	a, _ := ai.get_key(&f.ai, e, "a")
	testing.expect_value(t, a.(bool), true)
	testing.expect_value(t, int_key(f, e, "count"), 7)
	// The condition read the blackboard as it was in the think, before the writes.
	testing.expect_value(t, status(f, e, 1), Status.Failed)
	testing.expect_value(t, status(f, e, 2), Status.Succeeded)
	testing.expect_value(t, status(f, e, 4), Status.Failed)
}

// A condition succeeds when its condition holds, and fails otherwise.
@(test)
a_condition_succeeds_when_it_holds :: proc(t: ^testing.T) {
	f := setup(
		t,
		{
			kind = .Selector,
			children = {
				{kind = .Sequence, children = {{kind = .Condition, test = "a"}, {kind = .Set, set_key = "trace", set_value = 1}}},
				{kind = .Sequence, children = {{kind = .Condition, test = "!a"}, {kind = .Set, set_key = "trace", set_value = 2}}},
			},
		},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 5)
	testing.expect_value(t, int_key(f, e, "trace"), 2)
	ai.set_key(&f.ai, e, "a", true)
	frame(f, 2)
	testing.expect_value(t, int_key(f, e, "trace"), 1)
}

// invert swaps a node's success and failure, and force gives one whatever the node's was.
@(test)
invert_and_force_change_the_result :: proc(t: ^testing.T) {
	f := setup(
		t,
		{
			kind = .Selector,
			children = {
				{
					kind = .Sequence,
					children = {
						{kind = .Condition, test = "a", invert = true},
						{kind = .Action, action = "no", force = .Succeed},
						{kind = .Set, set_key = "trace", set_value = 1},
						{kind = .Action, action = "ok", force = .Fail},
						{kind = .Set, set_key = "trace", set_value = 2},
					},
				},
				HOLD,
			},
		},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 20)
	expect_events(t, f, {"start no", "start ok"})
	testing.expect_value(t, int_key(f, e, "trace"), 1)
	testing.expect_value(t, status(f, e, 2), Status.Succeeded)
	testing.expect_value(t, status(f, e, 3), Status.Succeeded)
	testing.expect_value(t, status(f, e, 5), Status.Failed)
}

// A node with a cooldown fails without running until its cooldown after it ended has passed.
@(test)
a_cooldown_fails_the_node_until_it_ends :: proc(t: ^testing.T) {
	f := setup(t, {kind = .Selector, children = {{kind = .Action, action = "ok", cooldown = 0.5}, {kind = .Wait, seconds = 0.05}}})
	defer teardown(t, f)
	spawn_agent(f)
	frame(f, 100)
	testing.expectf(t, len(f.events) >= 2, "events %v", f.events[:])
	for i in 1 ..< len(f.ticks) {
		// The node ends in the think after the action's tick, and its cooldown starts then; the waits that it fails into
		// end on their own ticks, so the next start is at most one wait later.
		between := f.ticks[i] - f.ticks[i - 1]
		testing.expectf(t, between >= 31 && between <= 35, "ok started %d ticks after the one before", between)
	}
}

// A node that repeats runs its count of times while it succeeds, or forever, and one that ends in the think that it
// started in starts again at the next think.
@(test)
repeat_runs_a_count_and_forever :: proc(t: ^testing.T) {
	f := setup(t, {kind = .Sequence, children = {{kind = .Action, action = "ok", repeat = 3}, {kind = .Set, set_key = "trace", set_value = 1}, HOLD}})
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 30)
	expect_events(t, f, {"start ok", "start ok", "start ok"})
	testing.expect_value(t, int_key(f, e, "trace"), 1)

	recook(t, f, {kind = .Action, action = "ok", repeat = format.TREE_FOREVER})
	frame(f, 30)
	testing.expectf(t, count_events(f, "start ok") >= 8, "events %v", f.events[:])
	testing.expect(t, status(f, e, 0) == .Running || status(f, e, 0) == .Again)

	// A set that repeats forever writes once in each think.
	recook(t, f, {kind = .Set, set_key = "trace", set_value = 5, repeat = format.TREE_FOREVER})
	frame(f, 3)
	testing.expect_value(t, int_key(f, e, "trace"), 5)
	testing.expect_value(t, status(f, e, 0), Status.Again)
}

// A node that runs longer than its time limit is aborted, and fails.
@(test)
a_time_limit_aborts_the_node :: proc(t: ^testing.T) {
	f := setup(t, {kind = .Selector, children = {{kind = .Action, action = "run", time_limit = 0.1}, {kind = .Set, set_key = "trace", set_value = 1}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	think_until(f, e, 1)
	start := f.world.clock.tick
	for int_key(f, e, "trace") != 1 && f.world.clock.tick - start < 30 {
		frame(f)
	}
	testing.expect_value(t, f.world.clock.tick - start, 6)
	frame(f)
	testing.expect_value(t, f.events[0], "start run")
	testing.expect_value(t, f.events[1], "stop run")
}

// A guard without an abort is checked when its node starts, and not while it runs.
@(test)
a_guard_without_abort_is_checked_on_entry :: proc(t: ^testing.T) {
	f := setup(t, {kind = .Selector, children = {{kind = .Action, action = "run", guard = "a"}, HOLD}})
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 5)
	ai.set_key(&f.ai, e, "a", true)
	frame(f, 5)
	expect_events(t, f, {})
	testing.expect_value(t, status(f, e, 2), Status.Running)

	// The agent starts again with a false, so this guard holds, and it is not checked again when a becomes true.
	recook(t, f, {kind = .Selector, children = {{kind = .Action, action = "run", guard = "!a"}, HOLD}})
	frame(f, 5)
	expect_events(t, f, {"start run"})
	ai.set_key(&f.ai, e, "a", true)
	frame(f, 5)
	expect_events(t, f, {"start run"})
	testing.expect_value(t, ai.current_action(&f.ai, e), "run")
}

// abort = self stops a running branch, and the action that runs over several thinks in it, when its guard becomes
// false.
@(test)
abort_self_stops_its_branch :: proc(t: ^testing.T) {
	f := setup(
		t,
		{kind = .Selector, children = {{kind = .Sequence, guard = "a", abort = .Self, children = {{kind = .Action, action = "walk", steps = 1000}}}, HOLD}},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	ai.set_key(&f.ai, e, "a", true)
	frame(f, 10)
	expect_events(t, f, {"start walk"})
	testing.expect_value(t, status(f, e, 2), Status.Running)
	ai.set_key(&f.ai, e, "a", false)
	frame(f, 3)
	expect_events(t, f, {"start walk", "stop walk"})
	testing.expect_value(t, status(f, e, 1), Status.Failed)
	testing.expect_value(t, status(f, e, 2), Status.Idle)
	testing.expect_value(t, status(f, e, 3), Status.Running)
	testing.expect_value(t, ai.current_action(&f.ai, e), "")
}

// abort = lower lets a node cut in when its guard becomes true, and stops the lower priority that ran, but its own
// branch goes on when the guard becomes false.
@(test)
abort_lower_cuts_in :: proc(t: ^testing.T) {
	f := setup(t, {kind = .Selector, children = {{kind = .Action, action = "walk", steps = 1000, guard = "a", abort = .Lower}, {kind = .Action, action = "run"}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 5)
	expect_events(t, f, {"start run"})
	ai.set_key(&f.ai, e, "a", true)
	frame(f, 5)
	expect_events(t, f, {"start run", "stop run", "start walk"})
	ai.set_key(&f.ai, e, "a", false)
	frame(f, 5)
	expect_events(t, f, {"start run", "stop run", "start walk"})
	testing.expect_value(t, ai.current_action(&f.ai, e), "walk")
}

// abort = both cuts in when the guard becomes true, and stops its own branch when it becomes false.
@(test)
abort_both_does_both :: proc(t: ^testing.T) {
	f := setup(t, {kind = .Selector, children = {{kind = .Action, action = "walk", steps = 1000, guard = "a", abort = .Both}, {kind = .Action, action = "run"}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 5)
	ai.set_key(&f.ai, e, "a", true)
	frame(f, 5)
	ai.set_key(&f.ai, e, "a", false)
	frame(f, 5)
	expect_events(t, f, {"start run", "stop run", "start walk", "stop walk", "start run"})
	testing.expect_value(t, ai.current_action(&f.ai, e), "run")
}

// A code reload keeps each node's state: the sequence goes on from its running action, which is neither started again
// nor stopped.
@(test)
node_state_is_kept_across_a_code_reload :: proc(t: ^testing.T) {
	f := setup(
		t,
		{
			kind = .Sequence,
			children = {
				{kind = .Action, action = "walk", steps = 5},
				{kind = .Set, set_key = "trace", set_value = 1},
				{kind = .Action, action = "walk", steps = 5},
				{kind = .Set, set_key = "trace", set_value = 2},
				HOLD,
			},
		},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	for int_key(f, e, "trace") != 1 {
		frame(f)
	}
	frame(f, 2)
	expect_events(t, f, {"start walk", "stop walk", "start walk"})
	testing.expect_value(t, status(f, e, 3), Status.Running)
	before := (^Node_State)(&ready_of(f, e).state[0])^

	// What on_reload does: the world's and the AI's registrations are made again.
	ecs.reload(&f.world, &f.platform)
	register_world_components(f)
	ai.reload(&f.ai, &f.platform)
	ai.register(&f.ai, &f.world)
	register_test(&f.ai)
	frame(f)
	testing.expect_value(t, (^Node_State)(&ready_of(f, e).state[0])^, before)
	frame(f, 10)
	expect_events(t, f, {"start walk", "stop walk", "start walk", "stop walk"})
	testing.expect_value(t, int_key(f, e, "trace"), 2)
}

// A tree that the module's check refuses never runs: its agent waits.
@(test)
a_refused_tree_waits :: proc(t: ^testing.T) {
	f := setup(t, {kind = .Wait, seconds_key = "a"})
	defer teardown(t, f)
	context.logger = testlog.expected_errors()
	e := spawn_agent(f)
	frame(f, 5)
	testing.expect(t, ready_of(f, e) == nil)
	recook(t, f, {kind = .Wait, seconds_key = "count"})
	frame(f, 2)
	testing.expect(t, ready_of(f, e) != nil)
}

// Agents' trees give the same results on one job and on many.
@(test)
trees_are_the_same_on_one_job_and_many :: proc(t: ^testing.T) {
	Outcome :: struct {
		state: [256]byte,
		count: i32,
		trace: i32,
	}
	run :: proc(t: ^testing.T, serial: bool) -> [dynamic]Outcome {
		tree := N {
			kind = .Selector,
			children = {
				{
					kind = .Sequence,
					guard = "a",
					abort = .Both,
					children = {{kind = .Action, action = "walk", steps = 3}, {kind = .Set, set_key = "count", set_value = 1}, {kind = .Wait, seconds_key = "delay"}},
				},
				{
					kind = .Parallel,
					policy = .One,
					children = {{kind = .Action, action = "run", time_limit = 0.2}, {kind = .Sequence, children = {{kind = .Wait, seconds = 0.1}, {kind = .Condition, test = "b"}}}},
				},
				{kind = .Set, set_key = "trace", set_value = 3, cooldown = 0.15},
			},
		}
		f := setup(t, tree, serial = serial, workers = 0 if serial else 8)
		defer teardown(t, f)
		agents := make([dynamic]ecs.Entity, context.temp_allocator)
		for i in 0 ..< 60 {
			e := spawn_agent(f)
			ai.set_key(&f.ai, e, "delay", f32(i % 4) * 0.05)
			ai.set_key(&f.ai, e, "b", i % 3 == 0)
			append(&agents, e)
		}
		outcomes := make([dynamic]Outcome)
		for step in 0 ..< 40 {
			frame(f)
			for e, i in agents {
				if (step + i) % 9 == 0 {
					ai.set_key(&f.ai, e, "a", step % 2 == 0)
				}
				o := Outcome {
					count = int_key(f, e, "count"),
					trace = int_key(f, e, "trace"),
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

@(private = "file")
last :: proc(f: ^Fixture, e: ecs.Entity, node: int) -> ai.Node_Result {
	ready := ready_of(f, e)
	if ready == nil {
		return .None
	}
	return (^Node_State)(&ready.state[node * format.TREE_STATE_SIZE]).last
}

// A node keeps how it last ended, and the module gives the nodes that run or ended, by their IDs in the text.
@(test)
last_results_show_for_a_finished_sequence :: proc(t: ^testing.T) {
	f := setup(t, {kind = .Selector, children = {{kind = .Sequence, children = {{kind = .Action, action = "ok"}, {kind = .Action, action = "no"}}}, HOLD}})
	defer teardown(t, f)
	e := spawn_agent(f)
	frame(f, 20)
	testing.expect_value(t, last(f, e, 2), ai.Node_Result.Succeeded)
	testing.expect_value(t, last(f, e, 3), ai.Node_Result.Failed)
	testing.expect_value(t, last(f, e, 1), ai.Node_Result.Failed)
	testing.expect_value(t, last(f, e, 4), ai.Node_Result.None)

	debug, ok := ai.agent_debug(&f.ai, e)
	testing.expect(t, ok)
	testing.expect_value(t, debug.decision, DECISION)
	testing.expect_value(t, len(debug.keys), len(KEYS))
	testing.expect_value(t, debug.keys[2].name, "delay")
	testing.expect_value(t, debug.keys[2].value, ai.Value(f32(0.25)))
	// The IDs are the nodes' indices plus one. The wait runs, and the selector, which has not ended.
	expected := []ai.Node_View{{id = 1, running = true}, {id = 2, last = .Failed}, {id = 3, last = .Succeeded}, {id = 4, last = .Failed}, {id = 5, running = true}}
	testing.expect(t, slice.equal(debug.nodes, expected), "the nodes differ")
}

// An abort leaves Aborted in the nodes that ran, which stays.
@(test)
last_results_are_kept_after_an_abort :: proc(t: ^testing.T) {
	f := setup(
		t,
		{kind = .Selector, children = {{kind = .Sequence, guard = "a", abort = .Self, children = {{kind = .Action, action = "walk", steps = 1000}}}, HOLD}},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	ai.set_key(&f.ai, e, "a", true)
	frame(f, 10)
	testing.expect_value(t, last(f, e, 2), ai.Node_Result.None)
	ai.set_key(&f.ai, e, "a", false)
	frame(f, 3)
	testing.expect_value(t, status(f, e, 2), Status.Idle)
	testing.expect_value(t, last(f, e, 2), ai.Node_Result.Aborted)
	testing.expect_value(t, last(f, e, 1), ai.Node_Result.Failed)

	// It stays until the node ends again.
	frame(f, 10)
	testing.expect_value(t, last(f, e, 2), ai.Node_Result.Aborted)
}
