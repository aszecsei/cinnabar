package anim_graph

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
NO :: format.ANIMATION_GRAPH_NONE

@(private = "file")
near :: proc(a, b: f32) -> bool {
	return abs(a - b) < 1e-4
}

@(private = "file")
aligned :: proc(data: []byte) -> []byte {
	copied, _ := mem.alloc_bytes(len(data), format.BLOB_ALIGN, context.temp_allocator)
	copy(copied, data)
	return copied
}

// moving_clip is a clip of one joint that moves from the origin to a place and turns about y by an angle, linearly,
// over a duration.
@(private = "file")
moving_clip :: proc(duration: f32, to: [3]f32 = {}, turn: f32 = 0) -> Clip {
	q := linalg.quaternion_angle_axis_f32(turn, {0, 1, 0})
	data := aligned(format.animation_write({
		joint_count = 1,
		duration = duration,
		channels = {
			{joint = 0, path = .Translation, interpolation = .Linear, first_key = 0, key_count = 2, first_value = 0},
			{joint = 0, path = .Rotation, interpolation = .Linear, first_key = 2, key_count = 2, first_value = 6},
		},
		times = {0, duration, 0, duration},
		values = {0, 0, 0, to.x, to.y, to.z, 0, 0, 0, 1, imag(q), jmag(q), kmag(q), real(q)},
	}, context.temp_allocator))
	blob, ok := format.animation_view(data)
	assert(ok)
	return {data, blob}
}

// make_graph is a graph of a blob of contents and its clips, with no root motion.
@(private = "file")
make_graph :: proc(contents: format.Animation_Graph_Contents, clips: []Clip) -> Graph {
	data := aligned(format.animation_graph_write(contents, context.temp_allocator))
	blob, ok := format.animation_graph_view(data)
	assert(ok)
	return {data = data, blob = blob, clips = clips, root = -1, root_parent = 1, root_parent_rotation = 1, root_rest = {rotation = 1, scale = 1}}
}

@(private = "file")
clip_state :: proc(name: string, clip: u32, loop := true, enter := NO, exit := NO) -> format.Animation_Graph_State_Contents {
	points := make([]format.Animation_Graph_Point, 1, context.temp_allocator)
	points[0] = {clip = clip}
	return {name = name, motion = .Clip, parameter = NO, points = points, speed = 1, loop = loop, enter_event = enter, exit_event = exit}
}

@(private = "file")
transition :: proc(from, to: u32, conditions: []format.Animation_Graph_Condition = nil, exit_time: f32 = -1, duration: f32 = 0, node: u32 = 0) -> format.Animation_Graph_Transition_Contents {
	return {from = from, to = to, conditions = conditions, exit_time = exit_time, duration = duration, node = node}
}

@(private = "file")
find_sample :: proc(inst: ^Instance, state: u16, frozen := false) -> (Sample, bool) {
	for s in inst.samples[:inst.sample_count] {
		if s.state == state && (.Frozen in s.flags) == frozen {
			return s, true
		}
	}
	return {}, false
}

// Three states, idle, move and look, each of a clip of a second; speed > 0.1 goes from idle to move, look from any
// state to look, and look returns to idle after one play.
@(private = "file")
three_states :: proc(fade: f32 = 0) -> Graph {
	clips := make([]Clip, 3, context.temp_allocator)
	for &c in clips {
		c = moving_clip(1)
	}
	parameters := make([]format.Animation_Graph_Parameter_Contents, 2, context.temp_allocator)
	parameters[0] = {name = "speed", kind = .Float}
	parameters[1] = {name = "look", kind = .Trigger}
	states := make([]format.Animation_Graph_State_Contents, 3, context.temp_allocator)
	states[0] = clip_state("idle", 0, exit = 0)
	states[1] = clip_state("move", 1, enter = 1)
	states[2] = clip_state("look", 2, loop = false)
	faster := make([]format.Animation_Graph_Condition, 1, context.temp_allocator)
	faster[0] = {parameter = 0, op = .Greater, value = 0.1}
	looked := make([]format.Animation_Graph_Condition, 1, context.temp_allocator)
	looked[0] = {parameter = 1, op = .Trigger}
	transitions := make([]format.Animation_Graph_Transition_Contents, 3, context.temp_allocator)
	transitions[0] = transition(NO, 2, looked, duration = fade, node = 30)
	transitions[1] = transition(0, 1, faster, duration = fade, node = 31)
	transitions[2] = transition(2, 0, exit_time = 1, duration = fade, node = 32)
	events := make([]format.Animation_Graph_Event_Contents, 2, context.temp_allocator)
	events[0] = {name = "left_idle"}
	events[1] = {name = "started"}
	clip_contents := make([]format.Animation_Graph_Clip_Contents, 3, context.temp_allocator)
	return make_graph({entry = 0, parameters = parameters, clips = clip_contents, states = states, transitions = transitions, events = events}, clips)
}

@(test)
a_clip_without_a_graph_loops_or_holds :: proc(t: ^testing.T) {
	clips := []Clip{moving_clip(1)}
	g := Graph{clips = clips, loop = true, root = -1}
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	for _ in 0 ..< 5 {
		advance(&g, &inst, 0.25, &out)
	}
	testing.expect_value(t, inst.sample_count, 1)
	testing.expect(t, near(inst.samples[0].time, 0.25) && near(inst.samples[0].step, 0.25), "it wraps")

	g.loop = false
	init(&g, &inst, 0)
	for _ in 0 ..< 5 {
		advance(&g, &inst, 0.25, &out)
	}
	testing.expect(t, near(inst.samples[0].time, 1) && near(inst.samples[0].step, 0), "it holds at its end")
}

@(test)
a_float_condition_takes_its_transition_with_its_events :: proc(t: ^testing.T) {
	g := three_states()
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, inst.state, 0)

	inst.parameters[0] = 0.5
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, inst.state, 1)
	testing.expect_value(t, out.event_count, 2)
	testing.expect_value(t, out.events[0], Fired{.Exit, 0, 0})
	testing.expect_value(t, out.events[1], Fired{.Enter, 1, 1})
	// The new state starts at its clip's start, and moves by the tick.
	testing.expect(t, near(inst.progress, 0.25))
}

@(test)
an_instance_names_the_last_transition_that_it_took :: proc(t: ^testing.T) {
	g := three_states(0.5)
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	advance(&g, &inst, 0.1, &out)
	testing.expect_value(t, inst.transition, 0)

	inst.parameters[0] = 0.5
	advance(&g, &inst, 0.1, &out)
	testing.expect_value(t, inst.transition, 31)

	// A transition from any state has its node too, and one that interrupts a fade names itself.
	inst.triggers = 1 << 1
	advance(&g, &inst, 0.1, &out)
	testing.expect_value(t, inst.state, 2)
	testing.expect_value(t, inst.source, NONE)
	testing.expect_value(t, inst.transition, 30)

	// It stays after its fade is over.
	for _ in 0 ..< 6 {
		advance(&g, &inst, 0.1, &out)
	}
	testing.expect(t, inst.fade >= inst.fade_duration, "the fade is over")
	testing.expect_value(t, inst.transition, 30)

	init(&g, &inst, 0)
	testing.expect_value(t, inst.transition, 0)
}

@(test)
a_trigger_is_seen_by_one_tick :: proc(t: ^testing.T) {
	g := three_states()
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	inst.triggers |= 1 << 1
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, inst.state, 2)
	testing.expect_value(t, inst.triggers, 0)

	// In look, nothing takes the trigger, and it is cleared all the same, so it does not wait for a later state.
	inst.triggers |= 1 << 1
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, inst.triggers, 0)
	testing.expect_value(t, inst.state, 2)
}

@(test)
an_exit_time_waits_for_the_plays :: proc(t: ^testing.T) {
	g := three_states()
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	inst.triggers |= 1 << 1
	advance(&g, &inst, 0.25, &out)
	// look played a quarter in the tick that entered it; three more ticks reach one play, and the next leaves.
	for _ in 0 ..< 3 {
		advance(&g, &inst, 0.25, &out)
		testing.expect_value(t, inst.state, 2)
	}
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, inst.state, 0)
}

@(test)
transitions_from_any_state_come_after_a_states_own :: proc(t: ^testing.T) {
	g := three_states()
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	// Both hold in idle: idle's own goes first.
	inst.parameters[0] = 1
	inst.triggers |= 1 << 1
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, inst.state, 1)
	// In look, the trigger's transition from any state goes nowhere, since it would go to look itself.
	inst.triggers |= 1 << 1
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, inst.state, 2)
	inst.triggers |= 1 << 1
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, inst.state, 2)
	testing.expect(t, near(inst.progress, 0.5), "look did not start again")
}

@(test)
a_fade_moves_the_weight_and_the_old_state_fades_out_over_a_tick :: proc(t: ^testing.T) {
	g := three_states(fade = 0.5)
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	inst.parameters[0] = 1
	advance(&g, &inst, 0.25, &out)
	idle, _ := find_sample(&inst, 0)
	move, _ := find_sample(&inst, 1)
	testing.expect(t, near(idle.weight, 0.5) && near(idle.previous_weight, 1))
	testing.expect(t, near(move.weight, 0.5) && near(move.previous_weight, 0))
	testing.expect(t, near(idle.step, 0.25), "the state that it fades from plays on")

	advance(&g, &inst, 0.25, &out)
	idle, _ = find_sample(&inst, 0)
	move, _ = find_sample(&inst, 1)
	testing.expect_value(t, inst.source, NONE)
	testing.expect(t, near(move.weight, 1))
	testing.expect(t, near(idle.weight, 0) && near(idle.previous_weight, 0.5), "a sample that is gone stays a tick at 0")
	advance(&g, &inst, 0.25, &out)
	_, found := find_sample(&inst, 0)
	testing.expect(t, !found)
}

@(test)
an_interrupted_fade_freezes_what_played :: proc(t: ^testing.T) {
	g := three_states(fade = 1)
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	inst.parameters[0] = 1
	advance(&g, &inst, 0.25, &out)
	inst.triggers |= 1 << 1
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, inst.state, 2)
	idle, idle_frozen := find_sample(&inst, 0, frozen = true)
	move, move_frozen := find_sample(&inst, 1, frozen = true)
	testing.expect(t, idle_frozen && move_frozen)
	testing.expect(t, near(idle.base, 0.75) && near(move.base, 0.25))
	testing.expect(t, near(idle.step, 0) && near(move.step, 0), "frozen samples stand still")
	time := idle.time
	advance(&g, &inst, 0.5, &out)
	idle, _ = find_sample(&inst, 0, frozen = true)
	look, _ := find_sample(&inst, 2)
	testing.expect(t, near(idle.time, time))
	testing.expect(t, near(look.weight, 0.75) && near(idle.weight, 0.75 * 0.25))
}

@(test)
samples_past_the_most_drop_the_lightest :: proc(t: ^testing.T) {
	g := three_states(fade = 1)
	inst: Instance
	init(&g, &inst, 0)
	inst.fade, inst.fade_duration = 0.5, 1
	// Eight frozen samples and the current state's are nine; the lightest frozen one goes.
	for i in 0 ..< MAX_SAMPLES {
		base := f32(0.01) if i == 3 else 0.05 + f32(i) * 0.01
		inst.samples[i] = {state = 1, point = u8(i), flags = {.Frozen}, weight = base, base = base}
	}
	inst.sample_count = MAX_SAMPLES
	build_samples(&g, &inst, 0, 0)
	testing.expect_value(t, int(inst.sample_count), MAX_SAMPLES)
	for s in inst.samples[:inst.sample_count] {
		testing.expect(t, s.point != 3 || .Frozen not_in s.flags)
	}
}

// A blend of walk, a second long, at 0 and run, half a second, at 1, by speed.
@(private = "file")
blend_graph :: proc() -> Graph {
	clips := make([]Clip, 2, context.temp_allocator)
	clips[0] = moving_clip(1)
	clips[1] = moving_clip(0.5)
	parameters := make([]format.Animation_Graph_Parameter_Contents, 1, context.temp_allocator)
	parameters[0] = {name = "speed", kind = .Float}
	points := make([]format.Animation_Graph_Point, 2, context.temp_allocator)
	points[0] = {clip = 0, threshold = 0}
	points[1] = {clip = 1, threshold = 1}
	markers := make([]format.Animation_Graph_Marker, 1, context.temp_allocator)
	markers[0] = {time = 0.5, event = 0}
	run_markers := make([]format.Animation_Graph_Marker, 1, context.temp_allocator)
	run_markers[0] = {time = 0.25, event = 1}
	clip_contents := make([]format.Animation_Graph_Clip_Contents, 2, context.temp_allocator)
	clip_contents[0] = {name = "walk", markers = markers}
	clip_contents[1] = {name = "run", markers = run_markers}
	events := make([]format.Animation_Graph_Event_Contents, 2, context.temp_allocator)
	events[0] = {name = "walk_step"}
	events[1] = {name = "run_step"}
	states := make([]format.Animation_Graph_State_Contents, 1, context.temp_allocator)
	states[0] = {name = "move", motion = .Blend_1D, parameter = 0, points = points, speed = 1, loop = true, enter_event = NO, exit_event = NO}
	return make_graph({parameters = parameters, clips = clip_contents, events = events, states = states}, clips)
}

@(test)
a_blend_weighs_its_clips_by_the_parameter_and_keeps_them_in_step :: proc(t: ^testing.T) {
	g := blend_graph()
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	inst.parameters[0] = 0.5
	// Its play lasts 0.75 s, the durations by their weights, so 0.375 s is half of it, and half of each clip.
	advance(&g, &inst, 0.375, &out)
	testing.expect_value(t, inst.sample_count, 2)
	walk, run := inst.samples[0], inst.samples[1]
	testing.expect(t, near(walk.weight, 0.5) && near(run.weight, 0.5))
	testing.expect(t, near(walk.time, 0.5) && near(run.time, 0.25))

	// Beyond the last threshold, the last clip plays alone.
	inst.parameters[0] = 4
	advance(&g, &inst, 0.1, &out)
	run, _ = find_sample(&inst, 0)
	for s in inst.samples[:inst.sample_count] {
		testing.expect(t, s.point == 1 ? near(s.weight, 1) : near(s.weight, 0))
	}
}

@(test)
only_the_heaviest_clip_raises_its_markers :: proc(t: ^testing.T) {
	g := blend_graph()
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	inst.parameters[0] = 0.25
	// Both clips reach their markers at half a play; walk weighs more, so only its event is raised.
	advance(&g, &inst, 0.4375, &out)
	testing.expect_value(t, out.event_count, 1)
	testing.expect_value(t, out.events[0].event, 0)
}

// A clip of a second with markers at 0, 0.5 and 0.9, in a graph of one looping state.
@(private = "file")
marked_graph :: proc() -> Graph {
	clips := make([]Clip, 1, context.temp_allocator)
	clips[0] = moving_clip(1)
	markers := make([]format.Animation_Graph_Marker, 3, context.temp_allocator)
	markers[0] = {time = 0, event = 0}
	markers[1] = {time = 0.5, event = 1}
	markers[2] = {time = 0.9, event = 2}
	clip_contents := make([]format.Animation_Graph_Clip_Contents, 1, context.temp_allocator)
	clip_contents[0] = {name = "c", markers = markers}
	events := make([]format.Animation_Graph_Event_Contents, 3, context.temp_allocator)
	states := make([]format.Animation_Graph_State_Contents, 1, context.temp_allocator)
	states[0] = clip_state("s", 0)
	return make_graph({clips = clip_contents, events = events, states = states}, clips)
}

@(private = "file")
raised :: proc(out: ^Tick_Output) -> (events: [dynamic]u32) {
	events = make([dynamic]u32, context.temp_allocator)
	for e in out.events[:out.event_count] {
		if e.kind == .Marker {
			append(&events, e.event)
		}
	}
	return
}

@(test)
markers_are_raised_once_in_the_tick_that_reaches_them :: proc(t: ^testing.T) {
	g := marked_graph()
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	// The first tick starts at the clip's start, so the marker at 0 is raised.
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, len(raised(&out)), 1)
	testing.expect_value(t, raised(&out)[0], 0)
	// A marker exactly at the tick's end is raised in it, and not again in the next.
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, len(raised(&out)), 1)
	testing.expect_value(t, raised(&out)[0], 1)
	advance(&g, &inst, 0.25, &out)
	testing.expect_value(t, len(raised(&out)), 0)
	// Across the wrap: the end of the clip, then its start.
	advance(&g, &inst, 0.5, &out)
	r := raised(&out)
	testing.expect_value(t, len(r), 2)
	if len(r) == 2 {
		testing.expect(t, r[0] == 2 && r[1] == 0)
	}
}

@(test)
root_motion_is_the_roots_move_in_its_heading :: proc(t: ^testing.T) {
	clips := []Clip{moving_clip(1, to = {0, 1, 2})}
	g := Graph{clips = clips, loop = true, root = 0, root_parent = 1, root_parent_rotation = 1, root_rest = {rotation = 1, scale = 1}}
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	advance(&g, &inst, 0.25, &out)
	testing.expect(t, near(out.translation.z, 0.5) && near(out.translation.x, 0), "a quarter of the move")
	testing.expect(t, near(out.translation.y, 0), "only along x and z")
	advance(&g, &inst, 0.25, &out)
	advance(&g, &inst, 0.25, &out)
	// Across the wrap the root does not jump back: the end of the move and then its start.
	advance(&g, &inst, 0.25, &out)
	testing.expect(t, near(out.translation.z, 0.5))
	advance(&g, &inst, 0.5, &out)
	testing.expect(t, near(out.translation.z, 1))

	// A root that turns as it moves reports the turn, and its move in the heading it had.
	turning := []Clip{moving_clip(1, to = {2, 0, 0}, turn = math.PI / 2)}
	g.clips = turning
	init(&g, &inst, 0)
	advance(&g, &inst, 0.5, &out)
	testing.expect(t, near(out.yaw, math.PI / 4))
	testing.expect(t, near(out.translation.x, 1))
	advance(&g, &inst, 0.25, &out)
	// Turned by π/4, the move along the model's x is partly along the root's z.
	testing.expect(t, near(out.translation.x, 0.5 * math.cos(f32(math.PI / 4))) && near(out.translation.z, 0.5 * math.sin(f32(math.PI / 4))))
}

@(test)
removing_root_motion_keeps_the_roots_height_and_rest_heading :: proc(t: ^testing.T) {
	g := Graph{root = 0, root_parent = 1, root_parent_rotation = 1, root_rest = {translation = {0, 1, 0}, rotation = 1, scale = 1}}
	locals := []Joint_Pose{{translation = {3, 2, 4}, rotation = linalg.quaternion_angle_axis_f32(1, {0, 1, 0}), scale = 1}}
	remove_root_motion(&g, locals)
	testing.expect(t, near(locals[0].translation.x, 0) && near(locals[0].translation.y, 2) && near(locals[0].translation.z, 0))
	testing.expect(t, near(abs(real(locals[0].rotation)), 1), "the heading is the rest one")
}

@(test)
presentation_interpolates_each_sample_between_ticks :: proc(t: ^testing.T) {
	clips := []Clip{moving_clip(1, to = {0, 0, 4})}
	g := Graph{clips = clips, loop = true, root = -1}
	inst: Instance
	init(&g, &inst, 0)
	out: Tick_Output
	advance(&g, &inst, 0.25, &out)
	advance(&g, &inst, 0.25, &out)
	rest := []Joint_Pose{{rotation = 1, scale = 1}}
	scratch := make([]Joint_Pose, 1, context.temp_allocator)
	locals := make([]Joint_Pose, 1, context.temp_allocator)
	present(&g, &inst, 0.5, rest, scratch, locals)
	// Between 0.25 s and 0.5 s: 0.375 s, so 1.5 m along z.
	testing.expect(t, near(locals[0].translation.z, 1.5))
	present(&g, &inst, 1, rest, scratch, locals)
	testing.expect(t, near(locals[0].translation.z, 2))
}
