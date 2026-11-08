package anim

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The scheduler is a singleton, and the test runner runs tests on several threads.
@(private = "file")
lock: sync.Mutex

@(private = "file")
SKIN :: "11111111111111111111111111111111"
@(private = "file")
WALK :: "22222222222222222222222222222222"
@(private = "file")
IDLE :: "33333333333333333333333333333333"
@(private = "file")
GRAPH :: "44444444444444444444444444444444"

@(private = "file")
Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	cache:     string,
	assets:    asset.Assets,
	animation: State,
	// With scripts: the runtime, the entity that Test.entity gives, and what Test.report reported, with the tick.
	scripts:   bool,
	runtime:   script.Runtime,
	entity:    ecs.Entity,
	reports:   [dynamic]string,
}

@(private = "file")
guid :: proc(text: string) -> format.Guid {
	g, _ := format.guid_parse(text)
	return g
}

@(private = "file")
near :: proc(a, b: f32) -> bool {
	return abs(a - b) < 1e-4
}

// setup makes a world with the animation's components and system, and a cache of a skin of one joint, Root; a walk,
// a clip of a second that moves Root 2 m along z with markers at 0.5 s; an idle that stands; and a graph of the
// two, idle then walk while speed > 0.1.
@(private = "file")
setup :: proc(t: ^testing.T, scripts := false) -> ^Fixture {
	sync.lock(&lock)
	testing.expect(t, jobs.init())
	f := new(Fixture)
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
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	cache, err := os.make_directory_temp("", "anim_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	register(&f.animation, &f.world, &f.assets)
	if scripts {
		f.scripts = true
		f.reports = make([dynamic]string)
		script.register_components(&f.world.registry)
		context.user_ptr = f
		testing.expect(t, script.init(&f.runtime, &f.platform, &f.world, nil, register_test_scripts))
	}

	write_blob(t, f, SKIN, format.skin_write({guid = guid(SKIN), key = 1, joints = {{name = "Root", parent = -1, inverse_bind = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}}, rotation = {0, 0, 0, 1}, scale = 1, sphere = {0, 0, 0, 1}}}}, context.temp_allocator))
	write_blob(t, f, WALK, format.animation_write({
		guid = guid(WALK),
		key = 2,
		skin = guid(SKIN),
		joint_count = 1,
		duration = 1,
		channels = {{joint = 0, path = .Translation, interpolation = .Linear, first_key = 0, key_count = 2, first_value = 0}},
		times = {0, 1},
		values = {0, 0, 0, 0, 0, 2},
	}, context.temp_allocator))
	write_blob(t, f, IDLE, format.animation_write({
		guid = guid(IDLE),
		key = 3,
		skin = guid(SKIN),
		joint_count = 1,
		duration = 1,
		channels = {{joint = 0, path = .Translation, interpolation = .Linear, first_key = 0, key_count = 1, first_value = 0}},
		times = {0},
		values = {0, 0, 0},
	}, context.temp_allocator))
	write_blob(t, f, GRAPH, format.animation_graph_write({
		guid = guid(GRAPH),
		key = 4,
		root_motion = "Root",
		parameters = {{name = "speed", kind = .Float}},
		clips = {{name = "idle", clip = guid(IDLE)}, {name = "walk", clip = guid(WALK), markers = {{time = 0.5, event = 0}}}},
		events = {{name = "footstep", args = {{kind = .Text, text = "left"}, {kind = .Number, number = 2}}}},
		states = {
			{name = "idle", motion = .Clip, parameter = format.ANIMATION_GRAPH_NONE, points = {{clip = 0}}, speed = 1, loop = true, enter_event = format.ANIMATION_GRAPH_NONE, exit_event = format.ANIMATION_GRAPH_NONE},
			{name = "walk", motion = .Clip, parameter = format.ANIMATION_GRAPH_NONE, points = {{clip = 1}}, speed = 1, loop = true, enter_event = format.ANIMATION_GRAPH_NONE, exit_event = format.ANIMATION_GRAPH_NONE},
		},
		transitions = {{from = 0, to = 1, conditions = {{parameter = 0, op = .Greater, value = 0.1}}, exit_time = -1}},
	}, context.temp_allocator))
	return f
}

// register_test_scripts defines the Animation library, Test.entity, and Test.report, which keeps its arguments and the
// tick that it ran in.
@(private = "file")
register_test_scripts :: proc(r: ^script.Runtime) {
	f := (^Fixture)(context.user_ptr)
	register_scripts(r, &f.animation)
	script.define(r, "Test.entity", proc(L: ^luau.State) -> c.int {
		script.push_entity(L, (^Fixture)(context.user_ptr).entity)
		return 1
	})
	script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
		f := (^Fixture)(context.user_ptr)
		report := fmt.tprintf("%d", f.world.clock.tick)
		for i in 1 ..= luau.gettop(L) {
			report = fmt.tprintf("%s %s", report, string(cstring(luau.L_tolstring(L, i, nil))))
			luau.pop(L, 1)
		}
		append(&f.reports, report)
		return 0
	})
}

@(private = "file")
teardown :: proc(t: ^testing.T, f: ^Fixture) {
	if f.scripts {
		script.destroy(&f.runtime)
		delete(f.reports)
	}
	destroy(&f.animation)
	asset.destroy(&f.assets)
	os.remove_all(f.cache)
	delete(f.cache)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
	testing.expect(t, jobs.drain_frame())
	jobs.shutdown()
	sync.unlock(&lock)
}

@(private = "file")
write_blob :: proc(t: ^testing.T, f: ^Fixture, name: string, data: []byte) {
	path := fmt.tprintf("%s/%s.blob", f.cache, name)
	testing.expect(t, os.write_entire_file(path, data) == nil)
}

// frame runs a frame of n fixed ticks as the frame code does, ending halfway into the next tick.
@(private = "file")
frame :: proc(f: ^Fixture, n: int) {
	free_all(f.platform.frame_allocator)
	prepare(&f.animation, &f.world)
	begin_frame(&f.animation)
	clock := &f.world.clock
	// To halfway into the tick after the n-th: a tick's length in nanoseconds is rounded.
	end := ecs.tick_start(clock, clock.tick + u64(n)) + (ecs.tick_start(clock, clock.tick + u64(n) + 1) - ecs.tick_start(clock, clock.tick + u64(n))) / 2
	it := ecs.begin_ticks(&f.world, end - clock.time)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, f)
		if f.scripts {
			context.user_ptr = f
			script.fixed_update(&f.runtime, &it, {})
		}
		ecs.update_transforms(&f.world)
		if f.scripts {
			send_events(&f.animation, &f.world, &f.runtime)
			script.fixed_events(&f.runtime)
		}
	}
}

@(private = "file")
spawn :: proc(f: ^Fixture, a: Animator, root_motion := false) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{rotation = 1, scale = 1})
	ecs.add(&f.world, e, a)
	if root_motion {
		ecs.add(&f.world, e, Root_Motion{})
	}
	return e
}

@(private = "file")
tick_seconds :: proc(f: ^Fixture) -> f32 {
	return 1 / f32(f.world.clock.tick_rate)
}

@(test)
a_clip_without_a_graph_plays_in_fixed_ticks :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	a := DEFAULT_ANIMATOR
	a.clip = guid(WALK)
	e := spawn(f, a)
	frame(f, 3)
	animator := ecs.get(&f.world, e, Animator)
	testing.expect(t, near(animator.time, 3 * tick_seconds(f)), "three ticks of the clip")

	// Presented halfway into the next tick, Root is half a tick back from the last tick's place.
	poses := present(&f.animation, &f.world, f.platform.frame_allocator)
	testing.expect_value(t, len(poses), 1)
	if len(poses) == 1 {
		z := poses[0].palette[0][2][3]
		testing.expect(t, near(z, 2 * 2.5 * tick_seconds(f)), "between the last two ticks")
	}

	animator.playing = false
	frame(f, 2)
	testing.expect(t, near(animator.time, 3 * tick_seconds(f)), "a stopped Animator holds")
}

@(test)
a_graph_moves_by_the_parameters_that_gameplay_sets :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	a := DEFAULT_ANIMATOR
	a.graph = guid(GRAPH)
	e := spawn(f, a)
	frame(f, 2)
	animator := ecs.get(&f.world, e, Animator)
	testing.expect_value(t, animator.state, 0)
	testing.expect_value(t, state_name(&f.animation, animator), "idle")

	index, kind, ok := parameter(&f.animation, animator, "speed")
	testing.expect(t, ok && kind == .Float)
	set_parameter(animator, index, 1)
	frame(f, 1)
	testing.expect_value(t, state_name(&f.animation, animator), "walk")
	_, _, missing := parameter(&f.animation, animator, "jump")
	testing.expect(t, !missing)
}

@(test)
events_keep_their_order_for_the_tick_and_the_frame :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	a := DEFAULT_ANIMATOR
	a.graph = guid(GRAPH)
	first := spawn(f, a)
	second := spawn(f, a)
	frame(f, 1)
	for e in ([]ecs.Entity{first, second}) {
		animator := ecs.get(&f.world, e, Animator)
		index, _, _ := parameter(&f.animation, animator, "speed")
		set_parameter(animator, index, 1)
	}
	// Walk starts at the next tick; its marker at 0.5 s is in the tick that reaches it.
	ticks := int(math.ceil(0.5 / tick_seconds(f)))
	for _ in 0 ..< ticks {
		testing.expect_value(t, len(frame_events(&f.animation)), 0)
		frame(f, 1)
	}
	events := frame_events(&f.animation)
	testing.expect_value(t, len(events), 2)
	if len(events) == 2 {
		testing.expect_value(t, events[0].entity, first)
		testing.expect_value(t, events[1].entity, second)
		testing.expect_value(t, events[0].name, "footstep")
		testing.expect_value(t, events[0].state, "walk")
		testing.expect_value(t, events[0].args[0].(string), "left")
		testing.expect_value(t, events[0].args[1].(f64), 2)
	}
	testing.expect_value(t, len(tick_events(&f.animation)), 2)
	// The next tick has none, so the last tick's are no longer the ones that tick_events gives.
	frame(f, 1)
	testing.expect_value(t, len(tick_events(&f.animation)), 0)
	testing.expect_value(t, len(frame_events(&f.animation)), 0)
}

@(test)
root_motion_is_reported_and_the_entity_does_not_move :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	a := DEFAULT_ANIMATOR
	a.clip = guid(WALK)
	a.graph = guid(GRAPH)
	e := spawn(f, a, root_motion = true)
	frame(f, 1)
	animator := ecs.get(&f.world, e, Animator)
	index, _, _ := parameter(&f.animation, animator, "speed")
	set_parameter(animator, index, 1)
	frame(f, 2)
	m := ecs.get(&f.world, e, Root_Motion)
	step := 2 * tick_seconds(f)
	testing.expect(t, near(m.translation.z, step), "a tick of walk moves Root 2 m a second")
	testing.expect(t, near(m.frame_translation.z, 2 * step), "the frame's two ticks")
	transform := ecs.get(&f.world, e, ecs.Transform)
	testing.expect_value(t, transform.position, ecs.World_Position{})

	// The pose leaves the motion out: Root stays at its rest place.
	poses := present(&f.animation, &f.world, f.platform.frame_allocator)
	testing.expect(t, len(poses) == 1 && near(poses[0].palette[0][2][3], 0))

	delta, _, ok := root_motion_world(&f.world, e)
	testing.expect(t, ok && near(delta.z, step))
}

@(test)
a_changed_graph_starts_again_with_the_parameters_that_it_still_has :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	a := DEFAULT_ANIMATOR
	a.graph = guid(GRAPH)
	e := spawn(f, a)
	frame(f, 1)
	animator := ecs.get(&f.world, e, Animator)
	index, _, _ := parameter(&f.animation, animator, "speed")
	set_parameter(animator, index, 0.05)
	// As if the graph's blob had changed: the next prepare starts the instance again.
	animator.instance.key = 99
	animator.instance.state = 1
	frame(f, 1)
	testing.expect_value(t, animator.instance.key, 4)
	testing.expect_value(t, animator.state, 0)
	testing.expect(t, near(animator.instance.parameters[index], 0.05))
}

@(test)
a_behaviour_gets_the_graphs_events_in_the_tick_that_raises_them :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(t, f)
	a := DEFAULT_ANIMATOR
	a.graph = guid(GRAPH)
	f.entity = spawn(f, a)
	context.user_ptr = f
	_, ok := script.spawn_source(&f.runtime, "=listener", `
local Listener = Behaviour.define("Listener")
function Listener:fixed_update(dt)
	if not self.set then
		self.set = true
		Animation.set_float(self.entity, "speed", 1)
		Test.report("set", Animation.get_float(self.entity, "speed"), Animation.state(self.entity))
		Test.report("unknown", (pcall(Animation.set_float, self.entity, "jump", 1)))
		Test.report("kind", (pcall(Animation.trigger, self.entity, "speed")))
	end
end
function Listener:on_animation_event(name, side, count)
	Test.report(name, side, count, Animation.state(self.entity))
end
Test.entity():add(Listener)
`)
	testing.expect(t, ok)
	// The behaviour sets speed in the first tick's fixed step, so walk starts in the second tick, a tick into its clip,
	// and its marker at 0.5 s is in the tick that reaches it.
	start := f.world.clock.tick
	ticks := int(math.ceil(0.5 / tick_seconds(f)))
	for _ in 0 ..< ticks + 2 {
		frame(f, 1)
	}
	testing.expect_value(t, len(f.reports), 4)
	if len(f.reports) == 4 {
		testing.expect_value(t, f.reports[0], fmt.tprintf("%d set 1 idle", start))
		testing.expect_value(t, f.reports[1], fmt.tprintf("%d unknown false", start))
		testing.expect_value(t, f.reports[2], fmt.tprintf("%d kind false", start))
		testing.expect_value(t, f.reports[3], fmt.tprintf("%d footstep left 2 walk", start + u64(ticks)))
	}
}

// Once the frame ends, the graphs that prepare made are gone, since asset.poll can free their blobs: an Animator finds
// no graph until the next prepare, which finds it again.
@(test)
an_animator_has_no_graph_between_frames :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	a := DEFAULT_ANIMATOR
	a.graph = guid(GRAPH)
	e := spawn(f, a)
	frame(f, 1)
	animator := ecs.get(&f.world, e, Animator)
	testing.expect_value(t, state_name(&f.animation, animator), "idle")
	end_frame(&f.animation)
	_, _, found := parameter(&f.animation, animator, "speed")
	testing.expect(t, !found, "an Animator found its graph after the frame ended")
	testing.expect_value(t, state_name(&f.animation, animator), "")
	frame(f, 1)
	_, _, found = parameter(&f.animation, animator, "speed")
	testing.expect(t, found)
}
