package asset_format

import "core:testing"

// test_decision is a decision of two nodes over a blackboard of a float and an entity: `when = health < 0.5` and
// `action = flee(from = target, speed = 4)` with `set health = 1`.
@(private = "file")
test_decision :: proc() -> []byte {
	board, _ := guid_parse(TEST_GUID)
	speed: [BLACKBOARD_VALUE_SIZE]byte
	(^f32)(&speed)^ = 4
	half: [BLACKBOARD_VALUE_SIZE]byte
	(^f32)(&half)^ = 0.5
	contents := Decision_Contents {
		key = 5,
		technique = .Utility,
		state_size = 12,
		blackboard = board,
		blackboard_key = 9,
		nodes = {
			{id = 1, kind = "root", condition = DECISION_NONE, action = DECISION_NONE},
			{id = 2, kind = "leaf", condition = 0, action = 0, first_write = 0, write_count = 1},
		},
		conditions = {{first_op = 0, op_count = 3}},
		ops = {{code = .Key, operand = 0}, {code = .Constant, operand = 1}, {code = .Less, type = u8(Blackboard_Type.Float)}},
		constants = {{type = .Float, value = speed}, {type = .Float, value = half}, {type = .String, text = "run"}},
		actions = {{name = "flee", first_arg = 0, arg_count = 2}},
		args = {{name = "from", source = .Key, index = 1, type = .Entity}, {name = "speed", source = .Constant, index = 0, type = .Float}},
		writes = {{key = 0, source = .Constant, index = 0}},
		technique_data = {1, 2, 3},
		source_path = "game/ai/guard.decision",
	}
	return aligned(decision_write(contents, context.temp_allocator))
}

@(test)
decision_blobs_round_trip :: proc(t: ^testing.T) {
	data := test_decision()
	blob, ok := decision_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.header.key, 5)
	testing.expect_value(t, blob.technique, Decision_Technique.Utility)
	testing.expect_value(t, blob.state_size, 12)
	testing.expect_value(t, blob.blackboard_key, 9)
	testing.expect_value(t, blob_string(data, blob.source_path), "game/ai/guard.decision")
	nodes := decision_nodes(data, blob)
	testing.expect_value(t, len(nodes), 2)
	testing.expect_value(t, blob_string(data, nodes[1].kind), "leaf")
	testing.expect_value(t, nodes[0].condition, DECISION_NONE)
	actions := decision_actions(data, blob)
	testing.expect_value(t, blob_string(data, actions[0].name), "flee")
	testing.expect_value(t, actions[0].hash, animation_graph_hash("flee"))
	args := decision_args(data, blob)
	testing.expect_value(t, args[1].hash, animation_graph_hash("speed"))
	testing.expect_value(t, args[0].source, Decision_Source.Key)
	constants := decision_constants(data, blob)
	testing.expect_value(t, blob_string(data, constants[2].text), "run")
	testing.expect_value(t, (^f32)(&constants[1].value)^, 0.5)
	testing.expect_value(t, decision_ops(data, blob)[2].code, Decision_Op_Code.Less)
	technique := decision_technique_data(data, blob)
	testing.expect_value(t, len(technique), 3)
	testing.expect_value(t, technique[2], 3)
	testing.expect_value(t, blob.technique_data.offset % 16, 0)
}

@(test)
decision_blobs_with_bad_indices_are_refused :: proc(t: ^testing.T) {
	data := test_decision()
	blob, ok := decision_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	nodes := decision_nodes(data, blob)
	saved := nodes[1].action
	nodes[1].action = 1
	_, ok = decision_view(data)
	testing.expect(t, !ok, "a node with an action that is not there")
	nodes[1].action = saved

	conditions := decision_conditions(data, blob)
	conditions[0].op_count = 4
	_, ok = decision_view(data)
	testing.expect(t, !ok, "a condition past the ops")
	conditions[0].op_count = 3

	ops := decision_ops(data, blob)
	ops[1].operand = 3
	_, ok = decision_view(data)
	testing.expect(t, !ok, "a constant that is not there")
	ops[1].operand = 1

	args := decision_args(data, blob)
	args[1].index = 3
	_, ok = decision_view(data)
	testing.expect(t, !ok, "an argument's constant that is not there")
	args[1].index = 0

	_, ok = decision_view(data)
	testing.expect(t, ok)
	_, ok = decision_view(data[:size_of(Decision_Blob) - 1])
	testing.expect(t, !ok)
}

@(test)
decisions_fit_only_their_blackboard :: proc(t: ^testing.T) {
	data := test_decision()
	blob, _ := decision_view(data)
	guid, _ := guid_parse(TEST_GUID)
	board := aligned(
		blackboard_write({guid = guid, key = 9, keys = {{name = "health", type = .Float}, {name = "target", type = .Entity}}}, context.temp_allocator),
	)
	board_blob, ok := blackboard_view(board)
	testing.expect(t, ok)
	testing.expect(t, decision_check(data, blob, board, board_blob))
	board_blob.header.key = 10
	testing.expect(t, !decision_check(data, blob, board, board_blob), "a blackboard cooked again without its decision")
	board_blob.header.key = 9

	swapped := aligned(
		blackboard_write({guid = guid, key = 9, keys = {{name = "health", type = .Float}, {name = "target", type = .Vector}}}, context.temp_allocator),
	)
	swapped_blob, _ := blackboard_view(swapped)
	testing.expect(t, !decision_check(data, blob, swapped, swapped_blob), "an argument of another type")
	short := aligned(blackboard_write({guid = guid, key = 9, keys = {{name = "health", type = .Float}}}, context.temp_allocator))
	short_blob, _ := blackboard_view(short)
	testing.expect(t, !decision_check(data, blob, short, short_blob), "a slot that the blackboard does not have")
}
