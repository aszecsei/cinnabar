package utility

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"
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
BOARD :: format.Guid{0 = 0xb8}
@(private = "file")
DECISION :: format.Guid{0 = 0xd8}
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
	{"target", .Entity},
	{"home", .Position},
	{"trace", .Int},
	{"other", .Float},
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
	return {guid = BOARD, key = 77, keys = keys}
}

@(private = "file")
slot_of :: proc(name: string) -> u32 {
	if name == "self" {
		return format.UTILITY_SELF
	}
	keys := KEYS
	for k, i in keys {
		if k.name == name {
			return u32(i)
		}
	}
	panic("no such key")
}

// C is a consideration of a test option. key is a number's or a since's key, or a distance's first place, and to its
// second. A max of 0 is the range [0, 1], and a slope or an exponent of 0 is 1.
@(private = "file")
C :: struct {
	input:    format.Utility_Input,
	key:      string,
	to:       string,
	min, max: f32,
	curve:    format.Utility_Curve,
	slope:    f32,
	exponent: f32,
	x_shift:  f32,
	y_shift:  f32,
	points:   []format.Utility_Point,
}

// O is a test option: a test action, with run's label or walk's steps in n, its weight (0 is 1), a bool key's name as
// its guard, its considerations, its target key and tag, its cooldown, and a write of set_value to set_key.
@(private = "file")
O :: struct {
	action:         string,
	n:              i32,
	weight:         f32,
	guard:          string,
	considerations: []C,
	target:         string,
	tag:            string,
	cooldown:       f32,
	set_key:        string,
	set_value:      i32,
}

@(private = "file")
U :: struct {
	options:  []O,
	pick:     format.Utility_Pick,
	within:   f32,
	momentum: f32,
}

// build is the decision blob of a utility decision, with its state laid out as the cooker lays it out. refused puts the
// first option's links outside the state, which the check refuses.
@(private = "file")
build :: proc(u: U, key: u64 = 1, refused := false) -> []byte {
	nodes := make([dynamic]format.Decision_Node_Contents, context.temp_allocator)
	conditions := make([dynamic]format.Decision_Condition, context.temp_allocator)
	ops := make([dynamic]format.Decision_Op, context.temp_allocator)
	constants := make([dynamic]format.Decision_Constant_Contents, context.temp_allocator)
	actions := make([dynamic]format.Decision_Action_Contents, context.temp_allocator)
	args := make([dynamic]format.Decision_Arg_Contents, context.temp_allocator)
	writes := make([dynamic]format.Decision_Write, context.temp_allocator)
	options := make([dynamic]format.Utility_Option, context.temp_allocator)
	considerations := make([dynamic]format.Utility_Consideration, context.temp_allocator)
	links := make([dynamic]u32, context.temp_allocator)
	points := make([dynamic]format.Utility_Point, context.temp_allocator)
	for o, i in u.options {
		shared := format.Decision_Node_Contents {
			id        = u32(i + 1),
			kind      = "option",
			condition = format.DECISION_NONE,
			action    = u32(len(actions)),
		}
		if o.guard != "" {
			negated := o.guard[0] == '!'
			first := u32(len(ops))
			append(&ops, format.Decision_Op{code = .Key, operand = slot_of(o.guard[1:] if negated else o.guard)})
			if negated {
				append(&ops, format.Decision_Op{code = .Not})
			}
			shared.condition = u32(len(conditions))
			append(&conditions, format.Decision_Condition{first_op = first, op_count = u32(len(ops)) - first})
		}
		action := format.Decision_Action_Contents {
			name      = o.action,
			first_arg = u32(len(args)),
		}
		if o.n != 0 {
			append(&constants, format.Decision_Constant_Contents{type = .Int, value = value(o.n)})
			append(&args, format.Decision_Arg_Contents{name = "n", source = .Constant, index = u32(len(constants) - 1), type = .Int})
			action.arg_count = 1
		}
		append(&actions, action)
		if o.set_key != "" {
			append(&constants, format.Decision_Constant_Contents{type = .Int, value = value(o.set_value)})
			shared.first_write = u32(len(writes))
			shared.write_count = 1
			append(&writes, format.Decision_Write{key = slot_of(o.set_key), source = .Constant, index = u32(len(constants) - 1)})
		}
		append(&nodes, shared)
		record := format.Utility_Option {
			node       = u32(i),
			weight     = o.weight if o.weight != 0 else 1,
			first_link = u32(len(links)),
			link_count = u32(len(o.considerations)),
			target     = format.DECISION_NONE,
		}
		if o.target != "" {
			record.target = slot_of(o.target)
		}
		if o.tag != "" {
			record.flags += {.Tag}
			record.target_tag = format.animation_graph_hash(o.tag)
		}
		if o.cooldown != 0 {
			record.flags += {.Cooldown}
			record.cooldown = {seconds = o.cooldown}
		}
		for c in o.considerations {
			append(&links, u32(len(considerations)))
			r := format.Utility_Consideration {
				node     = u32(len(u.options) + len(considerations)),
				input    = c.input,
				curve    = c.curve,
				a        = slot_of(c.key),
				min      = c.min,
				max      = c.max if c.max != c.min else 1,
				slope    = c.slope if c.slope != 0 else 1,
				exponent = c.exponent if c.exponent != 0 else 1,
				x_shift  = c.x_shift,
				y_shift  = c.y_shift,
			}
			if c.input == .Distance {
				r.b = slot_of(c.to)
			}
			if c.curve == .Table {
				r.first_point = u32(len(points))
				r.point_count = u32(len(c.points))
				append(&points, ..c.points)
			}
			append(&considerations, r)
		}
		append(&options, record)
	}
	for c in considerations {
		append(&nodes, format.Decision_Node_Contents{id = 100 + c.node, kind = "consideration", condition = format.DECISION_NONE, action = format.DECISION_NONE})
	}
	at := u32(size_of(format.Utility_Running))
	for &o in options {
		o.state = at
		at += size_of(format.Utility_Option_State)
	}
	for &o in options {
		o.links_state = at
		at += o.link_count * size_of(format.Utility_Link_State)
	}
	if refused {
		options[0].links_state = format.MAX_DECISION_STATE
	}
	data := format.utility_write(
		{
			pick = u.pick,
			within = u.within,
			momentum = u.momentum,
			options = options[:],
			considerations = considerations[:],
			links = links[:],
			points = points[:],
		},
		context.temp_allocator,
	)
	contents := format.Decision_Contents {
		guid           = DECISION,
		key            = key,
		technique      = .Utility,
		state_size     = (at + 7) &~ 7,
		blackboard     = BOARD,
		blackboard_key = 77,
		nodes          = nodes[:],
		conditions     = conditions[:],
		ops            = ops[:],
		constants      = constants[:],
		actions        = actions[:],
		args           = args[:],
		writes         = writes[:],
		technique_data = data,
		source_path    = "game/ai/test.decision",
	}
	return format.decision_write(contents, context.temp_allocator)
}

// build_tree is a behavior tree over the same blackboard: a sequence of walk for 2 steps, a write of 7 to trace, and a
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

// register_test registers the utility and behavior tree modules and the test actions: ok, which succeeds when it
// starts; walk, which runs for n steps and succeeds; and run, which runs until it is stopped, with its label n.
@(private = "file")
register_test :: proc(s: ^ai.State) {
	register(s)
	behavior_tree.register(s)
	ai.register_action(s, {name = "ok", start = proc(a: ^ai.Action_Context) {log_event(a, "start ok")}})
	ai.register_action(
		s,
		{
			name = "walk",
			params = {{"n", .Int}},
			state_size = 4,
			start = proc(a: ^ai.Action_Context) {
				n, _ := ai.arg(a, "n")
				(^i32)(&a.state[0])^ = n.(i32)
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
			params = {{"n", .Int}},
			state_size = 4,
			start = proc(a: ^ai.Action_Context) {
				n, _ := ai.arg(a, "n")
				(^i32)(&a.state[0])^ = n.(i32)
				log_event(a, "start run %d", n.(i32))
			},
			tick = proc(a: ^ai.Action_Context) -> ai.Action_Status {return .Running},
			stop = proc(a: ^ai.Action_Context) {log_event(a, "stop run %d", (^i32)(&a.state[0])^)},
		},
	)
}

@(private = "file")
register_world_components :: proc(f: ^Fixture) {
	ecs.register_engine_components(&f.world.registry)
	ai.register_components(&f.world.registry)
}

// setup makes a world with the AI, the modules and the test actions, over a loose cache with the test blackboard, the
// utility decision and the behavior tree. serial runs every job at once on the calling thread; otherwise the scheduler
// has workers threads.
@(private = "file")
setup :: proc(t: ^testing.T, u: U, serial := true, workers := 0, seed: u64 = 0) -> ^Fixture {
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
	cache, err := os.make_directory_temp("", "utility_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	ai.init(&f.ai, &f.platform, &f.assets)
	ai.register(&f.ai, &f.world)
	ai.set_seed(&f.ai, seed)
	register_test(&f.ai)
	write_blob(t, f, BOARD, format.blackboard_write(board_contents(), context.temp_allocator))
	write_blob(t, f, DECISION, build(u))
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

@(private = "file")
at :: proc(x: f32) -> ecs.World_Position {
	return ecs.position_offset({}, {x, 0, 0})
}

// spawn_agent spawns an agent of a decision that thinks in every tick.
@(private = "file")
spawn_agent :: proc(f: ^Fixture, decision := DECISION, x: f32 = 0) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{position = at(x), rotation = 1, scale = 1})
	ecs.add(&f.world, e, ai.Agent{blackboard = BOARD, decision = decision})
	return e
}

@(private = "file")
spawn_thing :: proc(f: ^Fixture, x: f32) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{position = at(x), rotation = 1, scale = 1})
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

// running is the option that runs, by its index, or -1.
@(private = "file")
running :: proc(f: ^Fixture, e: ecs.Entity) -> int {
	ready := ready_of(f, e)
	if ready == nil {
		return -1
	}
	return int((^format.Utility_Running)(&ready.state[0]).option) - 1
}

@(private = "file")
expect_events :: proc(t: ^testing.T, f: ^Fixture, expected: []string, loc := #caller_location) {
	testing.expectf(t, slice.equal(f.events[:], expected), "events %v, expected %v", f.events[:], expected, loc = loc)
}

@(private = "file")
clear_events :: proc(f: ^Fixture) {
	for e in f.events {
		delete(e)
	}
	clear(&f.events)
}

@(private = "file")
near :: proc(a, b: f64, epsilon := 1e-6) -> bool {
	return abs(a - b) <= epsilon
}

// HEALTH is a consideration that is the health key, linear over [0, 1].
@(private = "file")
HEALTH :: C {
	input = .Number,
	key   = "health",
	curve = .Linear,
}

// OTHER is a consideration that is the other key, linear over [0, 1].
@(private = "file")
OTHER :: C {
	input = .Number,
	key   = "other",
	curve = .Linear,
}

// Each curve gives known values: the shape at the input less x_shift, times slope, plus y_shift, clamped to 0 to 1,
// with a result that is not a number 0. The input is normalized over its range first.
@(test)
each_curve_gives_its_known_values :: proc(t: ^testing.T) {
	Case :: struct {
		c:    format.Utility_Consideration,
		x:    f64,
		want: f64,
	}
	TABLE :: []format.Utility_Point{{0, 0}, {0.5, 1}, {1, 0.5}}
	c :: proc(curve: format.Utility_Curve, slope: f32 = 1, exponent: f32 = 1, x_shift: f32 = 0, y_shift: f32 = 0) -> format.Utility_Consideration {
		return {curve = curve, slope = slope, exponent = exponent, x_shift = x_shift, y_shift = y_shift, max = 1}
	}
	cases := []Case {
		{c(.Linear), 0.3, 0.3},
		{c(.Linear, slope = -1, y_shift = 1), 0.3, 0.7},
		{c(.Linear, x_shift = 0.2), 0.3, 0.1},
		{c(.Linear, slope = 2), 0.8, 1},
		{c(.Linear, x_shift = 0.5), 0.3, 0},
		{c(.Polynomial, exponent = 2), 0.5, 0.25},
		{c(.Polynomial, exponent = 3), 0.5, 0.125},
		{c(.Polynomial, slope = -1, exponent = 2, y_shift = 1), 0.5, 0.75},
		{c(.Polynomial, exponent = 0.5, x_shift = 0.2), 0.1, 0},
		{c(.Logistic), 0.5, 0.5},
		{c(.Logistic), 0.6, 1 / (1 + math.exp(-1.0))},
		{c(.Logistic), 0.4, 1 / (1 + math.exp(1.0))},
		{c(.Logistic, x_shift = 0.1), 0.6, 0.5},
		{c(.Logistic, exponent = 2), 0.6, 1 / (1 + math.exp(-2.0))},
		{c(.Logit), 0.5, 0.5},
		{c(.Logit), 1 / (1 + math.exp(-1.0)), 0.6},
		{c(.Logit), 1 / (1 + math.exp(1.0)), 0.4},
		{c(.Logit, exponent = 2), 1 / (1 + math.exp(-1.0)), 0.55},
		{c(.Logit), 0, 0},
		{c(.Logit), 1, 1},
		{c(.Step), 0.49, 0},
		{c(.Step), 0.5, 1},
		{c(.Step, x_shift = 0.2), 0.69, 0},
		{c(.Step, x_shift = 0.2), 0.71, 1},
		{c(.Step, slope = -1, y_shift = 1), 0.7, 0},
		{c(.Table), 0.25, 0.5},
		{c(.Table), 0.75, 0.75},
		{c(.Table), -1, 0},
		{c(.Table), 2, 0.5},
		{c(.Table, exponent = 2), 0.25, 0.25},
		{c(.Table, slope = 0.5, y_shift = 0.1), 0.5, 0.6},
	}
	for k, i in cases {
		points := TABLE if k.c.curve == .Table else nil
		got := curve(k.c, points, k.x)
		testing.expectf(t, near(got, k.want), "case %d: %v at %v gives %v, not %v", i, k.c.curve, k.x, got, k.want)
	}
	// A table's two points at one x is a step.
	step := []format.Utility_Point{{0, 0}, {0.5, 0}, {0.5, 1}, {1, 1}}
	testing.expect(t, near(curve(c(.Table), step, 0.5), 1))
	testing.expect(t, near(curve(c(.Table), step, 0.25), 0))

	r := format.Utility_Consideration {
		min = 0,
		max = 100,
	}
	testing.expect(t, near(normalize(r, 50), 0.5))
	testing.expect(t, near(normalize(r, -5), 0))
	testing.expect(t, near(normalize(r, math.INF_F64), 1))
	r.min, r.max = 100, 0
	testing.expect(t, near(normalize(r, 25), 0.75))
	testing.expect(t, near(normalize(r, math.INF_F64), 0))
}

// The compensation factor makes up each score for the count of considerations, so that an option of more scores is not
// scored lower only for that, and an option's score is its weight times the product of its compensated scores.
@(test)
the_compensation_factor_makes_up_for_more_considerations :: proc(t: ^testing.T) {
	testing.expect(t, near(compensate(0.5, 1), 0.5))
	testing.expect(t, near(compensate(0.5, 2), 0.625))
	testing.expect(t, near(compensate(0.8, 3), 0.8 + 0.2 * (2.0 / 3.0) * 0.8))
	testing.expect(t, near(compensate(1, 4), 1))
	testing.expect(t, near(compensate(0, 4), 0))

	f := setup(t, {options = {{action = "run", n = 1, considerations = {HEALTH}}, {action = "run", n = 2, weight = 2, considerations = {HEALTH, HEALTH, HEALTH}}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	ai.set_key(&f.ai, e, "health", f32(0.8))
	frame(f, 2)
	scores, ok := ai.scores(&f.ai, e)
	testing.expect(t, ok)
	if !ok {
		return
	}
	one := compensate(0.8, 3)
	testing.expectf(t, near(f64(scores[0].score), 0.8, 1e-5), "one consideration scores %v", scores[0].score)
	testing.expectf(t, near(f64(scores[1].score), 2 * one * one * one, 1e-5), "three considerations score %v", scores[1].score)
	testing.expect(t, f64(scores[1].score) > 2 * 0.8 * 0.8 * 0.8)
}

// A consideration reads a float, an int or a bool key, a distance between places, or the seconds since a key changed,
// normalized over its range.
@(test)
inputs_read_numbers_bools_distances_and_time_since_a_change :: proc(t: ^testing.T) {
	f := setup(
		t,
		{
			options = {
				{
					action = "run",
					n = 1,
					considerations = {
						{input = .Number, key = "ammo", max = 10, curve = .Linear},
						{input = .Number, key = "armed", curve = .Linear},
						{input = .Distance, key = "self", to = "home", max = 10, curve = .Linear},
						{input = .Distance, key = "self", to = "target", max = 10, curve = .Linear},
						{input = .Since, key = "trace", max = 1, curve = .Linear},
					},
				},
			},
		},
	)
	defer teardown(t, f)
	e := spawn_agent(f)
	thing := spawn_thing(f, 6)
	ready := start(f, e)
	testing.expect(t, ready != nil)
	ai.set_key(&f.ai, e, "armed", true)
	ai.set_key(&f.ai, e, "home", at(-4))
	ai.set_key(&f.ai, e, "target", thing)
	ai.set_key(&f.ai, e, "trace", i32(1))
	written := f.world.clock.tick
	// A write of the same value is no change.
	frame(f, 5)
	ai.set_key(&f.ai, e, "trace", i32(1))
	frame(f, 5)
	scores, _ := ai.scores(&f.ai, e)
	inputs := scores[0].considerations
	testing.expect_value(t, ready_of(f, e).changed[slot_of("trace")], written)
	testing.expect(t, near(f64(inputs[0].input), 0.3, 1e-6))
	testing.expect(t, near(f64(inputs[1].input), 1))
	testing.expect(t, near(f64(inputs[2].input), 0.4, 1e-5))
	testing.expect(t, near(f64(inputs[3].input), 0.6, 1e-5))
	// The last think was in the last tick or the one before.
	rate := f64(f.world.clock.tick_rate)
	latest := f64(f.world.clock.tick - written) / rate
	since := f64(inputs[4].input)
	testing.expectf(t, since > 0 && since <= latest + 1e-6 && since >= latest - 2 / rate - 1e-6, "since %v, at most %v", since, latest)
	// A target that is none is infinitely far.
	ai.set_key(&f.ai, e, "target", ecs.Entity(0))
	frame(f, 2)
	scores, _ = ai.scores(&f.ai, e)
	testing.expect(t, near(f64(scores[0].considerations[3].input), 1))
}

// An option with a target is scored for each entity that the agent perceives now, of its tag, and writes the best into
// its key when it wins. Without a memory it scores once, with the key as it is.
@(test)
per_target_scoring_picks_the_best_perceived_entity_and_writes_it :: proc(t: ^testing.T) {
	near_by := C {
		input   = .Distance,
		key     = "self",
		to      = "target",
		max     = 10,
		curve   = .Linear,
		slope   = -1,
		y_shift = 1,
	}
	f := setup(t, {options = {{action = "run", n = 1, target = "target", tag = "enemy", considerations = {near_by}}}})
	defer teardown(t, f)
	tags: ai.Tag_Names
	ai.add_tag_name(&tags, "friend")
	ai.add_tag_name(&tags, "enemy")
	ai.set_tags(&f.ai, tags)
	e := spawn_agent(f)
	far_enemy := spawn_thing(f, 6)
	friend := spawn_thing(f, 1)
	gone_enemy := spawn_thing(f, 2)
	close_enemy := spawn_thing(f, 4)
	ready := start(f, e)

	// Without a memory, the option scores once with the key as it is.
	ai.set_key(&f.ai, e, "target", far_enemy)
	frame(f, 2)
	scores, _ := ai.scores(&f.ai, e)
	testing.expect(t, near(f64(scores[0].score), 0.4, 1e-5))
	testing.expect_value(t, scores[0].target, far_enemy)
	target, _ := ai.get_key(&f.ai, e, "target")
	testing.expect_value(t, target.(ecs.Entity), far_enemy)

	ready.perception = new(ai.Perception_Memory, f.platform.heap_allocator)
	m := ready.perception
	m.entries[0] = {entity = far_enemy, tag = 1, seen = true}
	m.entries[1] = {entity = friend, tag = 0, seen = true}
	m.entries[2] = {entity = gone_enemy, tag = 1}
	m.entries[3] = {entity = close_enemy, tag = 1, heard = true}
	m.count = 4
	frame(f, 2)
	scores, _ = ai.scores(&f.ai, e)
	testing.expect_value(t, scores[0].target, close_enemy)
	testing.expect(t, near(f64(scores[0].score), 0.6, 1e-5))
	testing.expect(t, near(f64(scores[0].considerations[0].input), 0.4, 1e-5))
	target, _ = ai.get_key(&f.ai, e, "target")
	testing.expect_value(t, target.(ecs.Entity), close_enemy)

	// None perceived of its tag scores 0, and the running option stops.
	m.entries[0].seen = false
	m.entries[3].heard = false
	frame(f, 2)
	scores, _ = ai.scores(&f.ai, e)
	testing.expect_value(t, scores[0].score, 0)
	testing.expect_value(t, scores[0].target, 0)
	testing.expect_value(t, running(f, e), -1)
	expect_events(t, f, {"start run 1", "stop run 1"})
}

// The running option keeps a bonus of its momentum, so another cuts in only when its score is above the running one's
// with the bonus.
@(test)
momentum_keeps_the_running_option_until_a_higher_score_beats_it :: proc(t: ^testing.T) {
	f := setup(t, {momentum = 0.25, options = {{action = "run", n = 1, considerations = {HEALTH}}, {action = "run", n = 2, considerations = {OTHER}}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	ai.set_key(&f.ai, e, "health", f32(0.6))
	ai.set_key(&f.ai, e, "other", f32(0.5))
	frame(f, 3)
	testing.expect_value(t, running(f, e), 0)
	ai.set_key(&f.ai, e, "other", f32(0.74))
	frame(f, 3)
	testing.expect_value(t, running(f, e), 0)
	ai.set_key(&f.ai, e, "other", f32(0.76))
	frame(f, 3)
	testing.expect_value(t, running(f, e), 1)
	// Now the second runs, and the first needs above 0.76 × 1.25.
	ai.set_key(&f.ai, e, "health", f32(0.9))
	frame(f, 3)
	testing.expect_value(t, running(f, e), 1)
	ai.set_key(&f.ai, e, "health", f32(0.96))
	frame(f, 3)
	testing.expect_value(t, running(f, e), 0)
	expect_events(t, f, {"start run 1", "stop run 1", "start run 2", "stop run 2", "start run 1"})
}

// An option with a cooldown scores 0 from when it ends until the cooldown passes.
@(test)
a_cooldown_keeps_an_option_from_being_picked_after_it_ends :: proc(t: ^testing.T) {
	f := setup(t, {options = {{action = "ok", weight = 2, cooldown = 0.5}, {action = "run", n = 1}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 6)
	expect_events(t, f, {"start ok", "start run 1"})
	testing.expect_value(t, running(f, e), 1)
	scores, _ := ai.scores(&f.ai, e)
	testing.expect_value(t, scores[0].score, 0)
	// After the cooldown, ok cuts in, as 2 is above run's 1 with any momentum below 1.
	frame(f, int(f.world.clock.tick_rate))
	testing.expect(t, len(f.events) >= 4)
	if len(f.events) >= 4 {
		testing.expect_value(t, f.events[2], "stop run 1")
		testing.expect_value(t, f.events[3], "start ok")
	}
}

// When the running action ends, the next think picks again, and an option whose action ended may run again.
@(test)
when_the_action_ends_the_next_think_picks_again :: proc(t: ^testing.T) {
	f := setup(t, {options = {{action = "walk", n = 2, set_key = "trace", set_value = 4}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 8)
	testing.expect(t, len(f.events) >= 4)
	if len(f.events) >= 4 {
		testing.expect(t, slice.equal(f.events[:4], []string{"start walk", "stop walk", "start walk", "stop walk"}))
	}
	trace, _ := ai.get_key(&f.ai, e, "trace")
	testing.expect_value(t, trace.(i32), 4)
}

// A guard that does not hold scores the option 0, and nothing that scores above 0 runs nothing.
@(test)
a_guard_or_no_score_runs_nothing :: proc(t: ^testing.T) {
	f := setup(t, {options = {{action = "run", n = 1, guard = "armed"}, {action = "run", n = 2, considerations = {OTHER}}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 3)
	testing.expect_value(t, running(f, e), -1)
	expect_events(t, f, {})
	ai.set_key(&f.ai, e, "armed", true)
	frame(f, 3)
	testing.expect_value(t, running(f, e), 0)
	expect_events(t, f, {"start run 1"})
}

// A weighted pick draws from the agent's own generator, so the same seed replays the same picks, and another seed
// gives others.
@(test)
a_weighted_pick_replays_the_same_with_the_same_seed :: proc(t: ^testing.T) {
	run :: proc(t: ^testing.T, seed: u64) -> [dynamic]string {
		f := setup(t, {pick = .Weighted, within = 1, options = {{action = "ok"}, {action = "walk", n = 1}, {action = "ok", weight = 0.5}}}, seed = seed)
		defer teardown(t, f)
		e := spawn_agent(f)
		start(f, e)
		picks := make([dynamic]string)
		for _ in 0 ..< 60 {
			frame(f)
			append(&picks, fmt.aprintf("%d", running(f, e)))
		}
		return picks
	}
	free_picks :: proc(picks: [dynamic]string) {
		for p in picks {
			delete(p)
		}
		delete(picks)
	}
	a := run(t, 11)
	defer free_picks(a)
	b := run(t, 11)
	defer free_picks(b)
	c := run(t, 12)
	defer free_picks(c)
	testing.expect(t, slice.equal(a[:], b[:]), "one seed gives other picks")
	testing.expect(t, !slice.equal(a[:], c[:]), "two seeds give the same picks")
	seen: [3]bool
	for p in a {
		switch p {
		case "0":
			seen[0] = true
		case "1":
			seen[1] = true
		case "2":
			seen[2] = true
		}
	}
	testing.expect(t, seen[0] && seen[1] && seen[2], "a weighted pick picks each option")
}

// One blackboard and one set of actions serve a behavior tree and a utility decision.
@(test)
a_behavior_tree_and_a_utility_decision_share_a_blackboard_and_actions :: proc(t: ^testing.T) {
	f := setup(t, {options = {{action = "walk", n = 3, guard = "!armed", set_key = "trace", set_value = 3}, {action = "run", n = 1, guard = "armed"}}})
	defer teardown(t, f)
	tree := spawn_agent(f, TREE)
	choice := spawn_agent(f)
	start(f, tree)
	start(f, choice)
	frame(f, 10)
	tree_trace, _ := ai.get_key(&f.ai, tree, "trace")
	choice_trace, _ := ai.get_key(&f.ai, choice, "trace")
	testing.expect_value(t, tree_trace.(i32), 7)
	testing.expect_value(t, choice_trace.(i32), 3)
	testing.expect_value(t, ai.current_action(&f.ai, tree), "")
	ai.set_key(&f.ai, tree, "armed", true)
	ai.set_key(&f.ai, choice, "armed", true)
	frame(f, 3)
	testing.expect_value(t, ai.current_action(&f.ai, choice), "run")
	walks := 0
	for e in f.events {
		walks += int(e == "start walk")
	}
	testing.expect(t, walks >= 2, "both decisions walk")
}

// What the last think scored is read by option and consideration, with each option's action and target, and whether it
// runs.
@(test)
scores_are_read_by_option_and_consideration :: proc(t: ^testing.T) {
	f := setup(t, {options = {{action = "run", n = 1, considerations = {HEALTH, OTHER}}, {action = "ok", weight = 0.25}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	ai.set_key(&f.ai, e, "other", f32(1))
	frame(f, 2)
	scores, ok := ai.scores(&f.ai, e)
	testing.expect(t, ok)
	testing.expect_value(t, len(scores), 2)
	if len(scores) != 2 {
		return
	}
	testing.expect_value(t, scores[0].id, 1)
	testing.expect_value(t, scores[0].action, "run")
	testing.expect_value(t, len(scores[0].considerations), 2)
	testing.expect_value(t, scores[0].considerations[0].id, 102)
	testing.expect_value(t, scores[0].considerations[1].id, 103)
	testing.expect(t, near(f64(scores[0].considerations[0].input), 0.5))
	testing.expect(t, near(f64(scores[0].considerations[0].score), 0.5))
	testing.expect(t, near(f64(scores[0].considerations[1].score), 1))
	testing.expect(t, near(f64(scores[0].score), compensate(0.5, 2), 1e-6))
	testing.expect_value(t, scores[1].action, "ok")
	testing.expect_value(t, scores[1].score, 0.25)
	// The better option runs.
	testing.expect(t, scores[0].chosen)
	testing.expect(t, !scores[1].chosen)
	_, ok = ai.scores(&f.ai, spawn_thing(f, 0))
	testing.expect(t, !ok)
}

// The running option and its cooldowns are in the agent's module state, so a code reload keeps them and the action.
@(test)
the_running_option_is_kept_across_a_code_reload :: proc(t: ^testing.T) {
	f := setup(t, {options = {{action = "run", n = 1, considerations = {HEALTH}}, {action = "run", n = 2, considerations = {OTHER}}}})
	defer teardown(t, f)
	e := spawn_agent(f)
	start(f, e)
	frame(f, 3)
	testing.expect_value(t, running(f, e), 0)
	ecs.reload(&f.world, &f.platform)
	register_world_components(f)
	ai.reload(&f.ai, &f.platform)
	ai.register(&f.ai, &f.world)
	register_test(&f.ai)
	frame(f, 3)
	testing.expect_value(t, running(f, e), 0)
	expect_events(t, f, {"start run 1"})
}

// Data that its check refuses makes the agent wait.
@(test)
a_refused_utility_waits :: proc(t: ^testing.T) {
	f := setup(t, {options = {{action = "run", n = 1, considerations = {HEALTH}}}})
	defer teardown(t, f)
	write_blob(t, f, DECISION, build({options = {{action = "run", n = 1, considerations = {HEALTH}}}}, refused = true))
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

// The thinks give the same states and values on one job and on eight workers, with weighted picks, momentum,
// cooldowns and targets.
@(test)
utility_is_the_same_on_one_job_and_many :: proc(t: ^testing.T) {
	Outcome :: struct {
		state:  [256]byte,
		trace:  i32,
		target: ecs.Entity,
	}
	run :: proc(t: ^testing.T, serial: bool) -> [dynamic]Outcome {
		u := U {
			pick = .Weighted,
			within = 0.3,
			momentum = 0.1,
			options = {
				{action = "walk", n = 2, considerations = {HEALTH}, set_key = "trace", set_value = 1},
				{action = "run", n = 1, considerations = {OTHER}, cooldown = 0.05},
				{action = "ok", weight = 0.6, set_key = "trace", set_value = 2},
				{action = "run", n = 2, target = "target", considerations = {{input = .Distance, key = "self", to = "target", max = 20, curve = .Logistic, slope = -1, y_shift = 1}}},
			},
		}
		f := setup(t, u, serial = serial, workers = 0 if serial else 8, seed = 3)
		defer teardown(t, f)
		things := [3]ecs.Entity{spawn_thing(f, 2), spawn_thing(f, 9), spawn_thing(f, 15)}
		agents := make([dynamic]ecs.Entity, context.temp_allocator)
		for i in 0 ..< 60 {
			e := spawn_agent(f, x = f32(i % 7))
			ai.set_key(&f.ai, e, "health", f32(i % 5) * 0.2)
			ai.set_key(&f.ai, e, "other", f32(i % 3) * 0.3)
			append(&agents, e)
		}
		for e in agents {
			start(f, e)
		}
		for e, i in agents {
			if ready := ready_of(f, e); ready != nil && i % 2 == 0 {
				ready.perception = new(ai.Perception_Memory, f.platform.heap_allocator)
				for thing, k in things {
					ready.perception.entries[k] = {entity = thing, seen = (i + k) % 2 == 0}
				}
				ready.perception.count = len(things)
			}
		}
		outcomes := make([dynamic]Outcome)
		for step in 0 ..< 40 {
			frame(f)
			for e, i in agents {
				if (step + i) % 7 == 0 {
					ai.set_key(&f.ai, e, "other", f32((step + i) % 4) * 0.25)
				}
				o: Outcome
				trace, _ := ai.get_key(&f.ai, e, "trace")
				o.trace = trace.(i32)
				target, _ := ai.get_key(&f.ai, e, "target")
				o.target = target.(ecs.Entity)
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
