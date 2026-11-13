package editor

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:engine/ai"
import "cinnabar:engine/ai/behavior_tree"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"

@(private = "file")
BOARD :: format.Guid{0 = 0xb8}
@(private = "file")
DECISION :: format.Guid{0 = 0xd8}
@(private = "file")
PLANNER :: format.Guid{0 = 0xd9}

@(private = "file")
Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	editor:   Editor,
	assets:   asset.Assets,
	ai:       ai.State,
	cache:    string,
	out:      [dynamic]byte,
}

@(private = "file")
clock: f64

@(private = "file")
value :: proc(v: $T) -> (bytes: [format.BLACKBOARD_VALUE_SIZE]byte) {
	v := v
	(^T)(&bytes)^ = v
	return
}

// The test blackboard: health, mood, target, home, heading and count, at slots 0 to 5.
@(private = "file")
board_blob :: proc() -> []byte {
	keys := make([]format.Blackboard_Key_Contents, 6, context.temp_allocator)
	keys[0] = {name = "health", type = .Float, default = value(f32(0.25))}
	keys[1] = {name = "mood", type = .Enum, enum_names = slice.clone([]string{"calm", "alert"}, context.temp_allocator)}
	keys[2] = {name = "target", type = .Entity}
	keys[3] = {name = "home", type = .Position, default = value(ecs.position_offset({}, {1, 2.5, 0}))}
	keys[4] = {name = "heading", type = .Vector, default = value([3]f32{0, 0, 1})}
	keys[5] = {name = "count", type = .Int, default = value(i32(3))}
	return format.blackboard_write({guid = BOARD, key = 77, keys = keys}, context.temp_allocator)
}

// The test decision, a selector of node 1: the action "no" of node 2, which fails, and a long wait of node 3.
@(private = "file")
decision_blob :: proc() -> []byte {
	names := format.TREE_KIND_NAMES
	none := format.DECISION_NONE
	tree := []format.Tree_Node {
		{node = 0, end = 3, kind = .Selector, test = none},
		{node = 1, end = 2, kind = .Action, test = none},
		{node = 2, end = 3, kind = .Wait, test = none, seconds = {seconds = 1000}},
	}
	timers := u32(len(tree) * format.TREE_STATE_SIZE)
	for &n, i in tree {
		n.state = u32(i * format.TREE_STATE_SIZE)
		n.timers = timers
		timers += u32(card(format.tree_timers(n))) * 8
	}
	return format.decision_write(
		{
			guid = DECISION,
			key = 5,
			technique = .Behavior_Tree,
			state_size = timers,
			blackboard = BOARD,
			blackboard_key = 77,
			nodes = slice.clone([]format.Decision_Node_Contents{
				{id = 1, kind = names[.Selector], condition = none, action = none},
				{id = 2, kind = names[.Action], condition = none, action = 0},
				{id = 3, kind = names[.Wait], condition = none, action = none},
			}, context.temp_allocator),
			actions = slice.clone([]format.Decision_Action_Contents{{name = "no"}}, context.temp_allocator),
			technique_data = format.tree_write(tree, context.temp_allocator),
			source_path = "game/ai/test.decision",
		},
		context.temp_allocator,
	)
}

// The planner decision is the test module's, which scores and plans as the utility, GOAP and HTN modules do, from its
// count of thinks.
@(private = "file")
planner_blob :: proc() -> []byte {
	none := format.DECISION_NONE
	return format.decision_write(
		{
			guid = PLANNER,
			key = 6,
			technique = .Goap,
			state_size = 8,
			blackboard = BOARD,
			blackboard_key = 77,
			nodes = slice.clone([]format.Decision_Node_Contents{{id = 1, kind = "goal", condition = none, action = none}}, context.temp_allocator),
			source_path = "game/ai/planner.decision",
		},
		context.temp_allocator,
	)
}

@(private = "file")
planner_think :: proc(t: ^ai.Think_Context) {
	(^u32)(&t.state[0])^ += 1
}

// planner_scores is one option, which runs, whose score is a third of the thinks, and one consideration.
@(private = "file")
planner_scores :: proc(decision: ai.Decision, board: ai.Board, state: []byte, allocator: runtime.Allocator) -> []ai.Option_Score {
	considerations := make([]ai.Consideration_Score, 1, allocator)
	considerations[0] = {id = 7, input = 0.25, score = 0.123456}
	result := make([]ai.Option_Score, 1, allocator)
	result[0] = {id = 1, action = "flee", score = f32((^u32)(&state[0])^) / 3, chosen = true, considerations = considerations}
	return result
}

// planner_plan is a plan of two steps, the second of which runs, for goal 3, by one method of a task.
@(private = "file")
planner_plan :: proc(decision: ai.Decision, board: ai.Board, state: []byte, allocator: runtime.Allocator) -> ai.Plan_View {
	goals := make([]ai.Goal_Priority, 1, allocator)
	goals[0] = {id = 3, priority = 2.5}
	steps := make([]ai.Plan_Step, 2, allocator)
	steps[0] = {id = 4, action = "walk"}
	steps[1] = {id = 5, action = "flee"}
	methods := make([]ai.Plan_Method, 1, allocator)
	methods[0] = {task = 6, method = 7}
	return {goal = 3, goals = goals, steps = steps, methods = methods, step = 1, nodes = 9}
}

@(private = "file")
setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {
			clock += 1
			return clock
		},
		jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		},
		jobs_wait = proc(counter: ^jobs.Counter) {},
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
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	ai.register_components(&f.world.registry)

	cache, err := os.make_directory_temp("", "editor_agents_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	write_blob :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, data: []byte) {
		buffer: [32]u8
		path := fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(guid, &buffer))
		testing.expect(t, os.write_entire_file(path, data) == nil)
	}
	write_blob(t, f, BOARD, board_blob())
	write_blob(t, f, DECISION, decision_blob())
	write_blob(t, f, PLANNER, planner_blob())
	ai.init(&f.ai, &f.platform, &f.assets)
	ai.register(&f.ai, &f.world)
	behavior_tree.register(&f.ai)
	ai.register_module(&f.ai, .Goap, {think = planner_think, check = proc(_: ai.Decision, _: ai.Board) -> bool {return true}, scores = planner_scores, plan = planner_plan})
	ai.register_action(&f.ai, {name = "no", tick = proc(a: ^ai.Action_Context) -> ai.Action_Status {return .Failed}})
	ai.register_action(&f.ai, {name = "walk", params = {{"steps", .Int}, {"line", .String}}})

	init(&f.editor, &f.platform, &f.assets, nil, nil, nil, &f.ai)
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	destroy(&f.editor)
	ai.destroy(&f.ai)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	_ = os.remove_all(f.cache)
	delete(f.cache)
	delete(f.out)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// run runs frames of one fixed tick each, as the frame code does, and ends the last one, so nothing but the assets
// is left for the editor to read, as when it polls.
@(private = "file")
run :: proc(f: ^Fixture, n := 1) {
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
}

// set writes a key of the agent, in frame code.
@(private = "file")
set :: proc(f: ^Fixture, e: ecs.Entity, key: string, v: ai.Value) {
	ai.prepare(&f.ai, &f.world)
	ai.set_key(&f.ai, e, key, v)
	ai.end_frame(&f.ai)
}

// polled polls once, with the given messages from the editor, and returns what the game sent.
@(private = "file")
polled :: proc(f: ^Fixture, incoming: ..link.Message) -> []link.Message {
	encoded := make([dynamic]core.Editor_Message, context.temp_allocator)
	for m in incoming {
		bytes := make([dynamic]byte, context.temp_allocator)
		link.write_message(&bytes, m)
		header, _ := link.read_header(bytes[:])
		append(&encoded, core.Editor_Message{kind = header.kind, payload = bytes[link.HEADER_SIZE:]})
	}
	clear(&f.out)
	poll(&f.editor, &f.world, nil, 1, encoded[:], &f.out)
	found := make([dynamic]link.Message, context.temp_allocator)
	rest := f.out[:]
	for len(rest) > 0 {
		header, _ := link.read_header(rest)
		message, ok := link.decode_message(header.kind, rest[link.HEADER_SIZE:][:header.length], context.temp_allocator)
		if ok {
			append(&found, message)
		}
		rest = rest[link.HEADER_SIZE + int(header.length):]
	}
	return found[:]
}

// views polls once and returns the Agent views that the game sent.
@(private = "file")
views :: proc(f: ^Fixture, incoming: ..link.Message) -> []link.Agent_View {
	found := make([dynamic]link.Agent_View, context.temp_allocator)
	for m in polled(f, ..incoming) {
		if view, is_view := m.(link.Agent_View); is_view {
			append(&found, view)
		}
	}
	return found[:]
}

// thinking is an entity whose agent has thought a few times: its action failed, and its wait runs.
@(private = "file")
thinking :: proc(f: ^Fixture) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{rotation = 1, scale = 1})
	ecs.add(&f.world, e, ai.Agent{blackboard = BOARD, decision = DECISION})
	run(f, 12)
	return e
}

@(private = "file")
value_of :: proc(view: link.Agent_View, name: string) -> link.Agent_Value {
	for v in view.values {
		if v.name == name {
			return v
		}
	}
	return {}
}

@(test)
a_watched_agents_view_goes_out_when_it_changes :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := thinking(f)

	list := views(f, link.Watch_Entity{u64(e)})
	if !testing.expect_value(t, len(list), 1) {
		return
	}
	view := list[0]
	testing.expect_value(t, ecs.Entity(view.entity), e)
	testing.expect_value(t, format.Guid(view.decision), DECISION)
	// By the nodes' IDs in the text. The selector and the wait run, and the action failed.
	expected := []link.Agent_Node{{id = 1, running = true}, {id = 2, last = .Failed}, {id = 3, running = true}}
	testing.expect(t, slice.equal(view.nodes, expected), "the nodes differ")
	testing.expect_value(t, len(view.values), 6)
	testing.expect_value(t, value_of(view, "health"), link.Agent_Value{"health", .Float, "0.25"})
	testing.expect_value(t, value_of(view, "mood"), link.Agent_Value{"mood", .Enum, "calm"})
	testing.expect_value(t, value_of(view, "target").text, "none")
	testing.expect_value(t, value_of(view, "home").text, "[1, 2.5, 0]")
	testing.expect_value(t, value_of(view, "heading").text, "[0, 0, 1]")
	testing.expect_value(t, value_of(view, "count"), link.Agent_Value{"count", .Int, "3"})

	testing.expect_value(t, len(views(f)), 0)
	set(f, e, "mood", ai.Enum_Index(1))
	set(f, e, "target", e)
	list = views(f)
	if testing.expect_value(t, len(list), 1) {
		testing.expect_value(t, value_of(list[0], "mood").text, "alert")
		testing.expect_value(t, value_of(list[0], "target").text, fmt.tprintf("#%d:%d", ecs.entity_index(e), ecs.entity_generation(e)))
	}
	testing.expect_value(t, len(views(f)), 0)
}

@(test)
an_agent_that_is_not_watched_sends_nothing :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := thinking(f)
	testing.expect_value(t, len(views(f, link.Watch_Entity{u64(e)})), 1)

	views(f, link.Unwatch_Entity{u64(e)})
	set(f, e, "count", i32(9))
	testing.expect_value(t, len(views(f)), 0)
}

@(test)
an_agent_that_goes_away_says_so_once :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := thinking(f)
	testing.expect_value(t, len(views(f, link.Watch_Entity{u64(e)})), 1)

	ecs.remove(&f.world, e, ai.Agent)
	run(f)
	list := views(f)
	if testing.expect_value(t, len(list), 1) {
		testing.expect_value(t, list[0].decision, [16]u8{})
		testing.expect_value(t, ecs.Entity(list[0].entity), e)
		testing.expect_value(t, len(list[0].nodes), 0)
		testing.expect_value(t, len(list[0].values), 0)
	}
	testing.expect_value(t, len(views(f)), 0)
}

@(test)
an_entity_without_an_agent_sends_one_empty_view :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	plain := ecs.spawn(&f.world)
	list := views(f, link.Watch_Entity{u64(plain)})
	if testing.expect_value(t, len(list), 1) {
		testing.expect_value(t, list[0].decision, [16]u8{})
	}
	testing.expect_value(t, len(views(f)), 0)
}

// The editor keeps a view after an unwatch, so a watch again sends the view as it is now, even an empty one.
@(test)
a_watch_again_sends_the_view_even_when_it_did_not_change :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := thinking(f)
	testing.expect_value(t, len(views(f, link.Watch_Entity{u64(e)})), 1)
	views(f, link.Unwatch_Entity{u64(e)})
	testing.expect_value(t, len(views(f, link.Watch_Entity{u64(e)})), 1)
	views(f, link.Unwatch_Entity{u64(e)})

	ecs.remove(&f.world, e, ai.Agent)
	run(f)
	list := views(f, link.Watch_Entity{u64(e)})
	if testing.expect_value(t, len(list), 1) {
		testing.expect_value(t, list[0].decision, [16]u8{})
	}
}

@(test)
the_native_actions_go_out_when_an_editor_links_and_after_a_reload :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	actions :: proc(messages: []link.Message) -> (found: []link.Agent_Action_Info, count: int) {
		for m in messages {
			if a, is_actions := m.(link.Agent_Actions); is_actions {
				found = a.actions
				count += 1
			}
		}
		return
	}

	found, count := actions(polled(f))
	testing.expect_value(t, count, 1)
	if testing.expect_value(t, len(found), 2) {
		testing.expect_value(t, found[0].name, "no")
		testing.expect_value(t, len(found[0].params), 0)
		testing.expect_value(t, found[1].name, "walk")
		testing.expect_value(t, found[1].params[0], link.Agent_Action_Param{"steps", .Int})
		testing.expect_value(t, found[1].params[1], link.Agent_Action_Param{"line", .String})
	}
	_, count = actions(polled(f))
	testing.expect_value(t, count, 0)

	reload(&f.editor, &f.platform)
	_, count = actions(polled(f))
	testing.expect_value(t, count, 1)
}

// A module that scores or plans sends its options and its plan, with the scores rounded to three decimals, and a tree,
// which does neither, sends none.
@(test)
a_scoring_and_planning_agents_view_has_its_options_and_plan :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{rotation = 1, scale = 1})
	ecs.add(&f.world, e, ai.Agent{blackboard = BOARD, decision = PLANNER})
	run(f, 12)
	list := views(f, link.Watch_Entity{u64(e)})
	if !testing.expect_value(t, len(list), 1) {
		return
	}
	view := list[0]
	testing.expect_value(t, format.Guid(view.decision), PLANNER)
	if testing.expect_value(t, len(view.options), 1) {
		o := view.options[0]
		testing.expect_value(t, o.id, 1)
		testing.expect(t, o.chosen)
		thinks := f32(math.round(f64(o.score) * 3))
		testing.expect_value(t, o.score, f32(math.round(f64(thinks / 3) * 1000) / 1000))
		testing.expect_value(t, len(o.considerations), 1)
		testing.expect_value(t, o.considerations[0], link.Agent_Consideration{id = 7, input = 0.25, score = 0.123})
	}
	if testing.expect_value(t, len(view.plan), 1) {
		p := view.plan[0]
		testing.expect_value(t, p.goal, 3)
		testing.expect(t, slice.equal(p.goals, []link.Agent_Goal{{3, 2.5}}))
		testing.expect(t, slice.equal(p.steps, []u32{4, 5}))
		testing.expect_value(t, p.step, 1)
		testing.expect(t, slice.equal(p.methods, []link.Agent_Method{{6, 7}}))
		testing.expect(t, !p.searching)
	}

	tree := thinking(f)
	found := false
	for v in views(f, link.Watch_Entity{u64(tree)}) {
		if ecs.Entity(v.entity) == tree {
			found = true
			testing.expect_value(t, len(v.options), 0)
			testing.expect_value(t, len(v.plan), 0)
		}
	}
	testing.expect(t, found, "the tree's view went out")
}
