package anim

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

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
setup :: proc(t: ^testing.T) -> ^Fixture {
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
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	cache, err := os.make_directory_temp("", "anim_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	register(&f.animation, &f.world, &f.assets)

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

@(private = "file")
teardown :: proc(t: ^testing.T, f: ^Fixture) {
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
		ecs.update_transforms(&f.world)
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
