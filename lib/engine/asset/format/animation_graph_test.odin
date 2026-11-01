package asset_format

import "core:testing"

// test_graph is a blob of two states, idle and a blend of walk and run, at the runtime's alignment.
@(private = "file")
test_graph :: proc() -> []byte {
	walk, _ := guid_parse(TEST_GUID)
	contents := Animation_Graph_Contents {
		key = 7,
		entry = 0,
		root_motion = "Root",
		parameters = {{name = "speed", kind = .Float}, {name = "look", kind = .Trigger}, {name = "grounded", kind = .Bool, default = 1}},
		clips = {{name = "walk", clip = walk, markers = {{time = 0.2, event = 0}, {time = 0.6, event = 1}}}, {name = "run", clip = walk}},
		events = {
			{name = "footstep", args = {{kind = .Text, text = "left"}, {}}},
			{name = "footstep", args = {{kind = .Text, text = "right"}, {kind = .Number, number = 2}}},
			{name = "started"},
		},
		states = {
			{name = "idle", motion = .Clip, parameter = ANIMATION_GRAPH_NONE, points = {{clip = 0}}, speed = 1, loop = true, enter_event = ANIMATION_GRAPH_NONE, exit_event = ANIMATION_GRAPH_NONE, node = 1},
			{name = "move", motion = .Blend_1D, parameter = 0, points = {{clip = 0, threshold = 0.5}, {clip = 1, threshold = 3}}, speed = 1, loop = true, enter_event = 2, exit_event = ANIMATION_GRAPH_NONE, node = 2},
		},
		// Out of their groups' order, which the writer puts right.
		transitions = {
			{from = ANIMATION_GRAPH_NONE, to = 0, conditions = {{parameter = 1, op = .Trigger}}, exit_time = -1, duration = 0.1, node = 12},
			{from = 1, to = 0, conditions = {{parameter = 0, op = .Less, value = 0.1}}, exit_time = -1, duration = 0.3, node = 11},
			{from = 0, to = 1, conditions = {{parameter = 0, op = .Greater, value = 0.1}, {parameter = 2, op = .True}}, exit_time = -1, duration = 0.25, node = 10},
		},
		source_path = "game/animations/fox.animation_graph",
	}
	return aligned(animation_graph_write(contents, context.temp_allocator))
}

@(test)
animation_graph_blobs_round_trip :: proc(t: ^testing.T) {
	data := test_graph()
	blob, ok := animation_graph_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.header.key, 7)
	testing.expect_value(t, blob_string(data, blob.root_motion), "Root")
	testing.expect_value(t, blob_string(data, blob.source_path), "game/animations/fox.animation_graph")

	parameters := animation_graph_parameters(data, blob)
	testing.expect_value(t, len(parameters), 3)
	testing.expect_value(t, blob_string(data, parameters[1].name), "look")
	testing.expect_value(t, parameters[1].hash, animation_graph_hash("look"))
	testing.expect_value(t, parameters[2].default, 1)

	clips := animation_graph_clips(data, blob)
	markers := animation_graph_markers(data, blob)
	events := animation_graph_events(data, blob)
	testing.expect_value(t, clips[0].marker_count, 2)
	testing.expect_value(t, clips[1].marker_count, 0)
	second := events[markers[clips[0].first_marker + 1].event]
	testing.expect_value(t, blob_string(data, second.name), "footstep")
	testing.expect_value(t, blob_string(data, second.args[0].text), "right")
	testing.expect_value(t, second.args[1].number, 2)
	testing.expect_value(t, events[2].args[0].kind, Animation_Graph_Value_Kind.None)

	// Each state's transitions are its own, in their order, and those from any state are last.
	states := animation_graph_states(data, blob)
	transitions := animation_graph_transitions(data, blob)
	testing.expect_value(t, blob.first_any, 2)
	testing.expect_value(t, transitions[states[0].first_transition].node, 10)
	testing.expect_value(t, transitions[states[1].first_transition].node, 11)
	testing.expect_value(t, transitions[2].from, ANIMATION_GRAPH_NONE)
	conditions := animation_graph_conditions(data, blob)
	from_idle := transitions[states[0].first_transition]
	testing.expect_value(t, from_idle.condition_count, 2)
	testing.expect_value(t, conditions[from_idle.first_condition + 1].op, Animation_Graph_Condition_Op.True)

	points := animation_graph_points(data, blob)
	testing.expect_value(t, states[1].point_count, 2)
	testing.expect_value(t, points[states[1].first_point + 1].threshold, 3)
	testing.expect_value(t, states[1].enter_event, 2)
	testing.expect(t, bool(states[0].loop))
}

@(test)
animation_graph_blobs_with_bad_indices_are_refused :: proc(t: ^testing.T) {
	data := test_graph()
	blob, ok := animation_graph_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	states := animation_graph_states(data, blob)
	transitions := animation_graph_transitions(data, blob)

	saved := transitions[0].to
	transitions[0].to = 2
	_, ok = animation_graph_view(data)
	testing.expect(t, !ok, "a transition to a state that is not there")
	transitions[0].to = saved

	saved = states[1].parameter
	states[1].parameter = 1
	_, ok = animation_graph_view(data)
	testing.expect(t, !ok, "a blend by a trigger")
	states[1].parameter = saved

	saved = states[0].point_count
	states[0].point_count = 2
	_, ok = animation_graph_view(data)
	testing.expect(t, !ok, "a clip state with two clips")
	states[0].point_count = saved

	saved = transitions[2].from
	transitions[2].from = 0
	_, ok = animation_graph_view(data)
	testing.expect(t, !ok, "a transition from a state among those from any")
	transitions[2].from = saved

	_, ok = animation_graph_view(data)
	testing.expect(t, ok)
	_, ok = animation_graph_view(data[:size_of(Animation_Graph_Blob) - 1])
	testing.expect(t, !ok)
}
