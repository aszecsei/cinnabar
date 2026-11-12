package asset_format

import "core:testing"

// test_perception notices two tags, and has a row of each source.
@(private = "file")
test_perception :: proc() -> []byte {
	contents := Perception_Contents {
		key         = 5,
		notices     = {"Player", "Noise_Maker"},
		rows        = {
			{key = "target", source = .Nearest, tag = "Player", of = PERCEPTION_NONE},
			{key = "threat", source = .Nearest_Seen, of = PERCEPTION_NONE},
			{key = "target_position", source = .Position, of = 0},
			{key = "target_visible", source = .Visible, of = 0},
			{key = "target_since", source = .Since, of = 0},
			{key = "heard", source = .Heard_Noise, of = PERCEPTION_NONE},
			{key = "heard_position", source = .Loudest_Noise, tag = "Noise_Maker", of = PERCEPTION_NONE},
		},
		source_path = "game/ai/guard.perception",
	}
	return aligned(perception_write(contents, context.temp_allocator))
}

@(test)
perception_blobs_round_trip :: proc(t: ^testing.T) {
	data := test_perception()
	blob, ok := perception_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.header.key, 5)
	testing.expect_value(t, blob_string(data, blob.source_path), "game/ai/guard.perception")
	notices := perception_notices(data, blob)
	testing.expect_value(t, len(notices), 2)
	testing.expect_value(t, blob_string(data, notices[1]), "Noise_Maker")
	rows := perception_rows(data, blob)
	testing.expect_value(t, len(rows), 7)
	testing.expect_value(t, blob_string(data, rows[0].key), "target")
	testing.expect_value(t, rows[0].key_hash, animation_graph_hash("target"))
	testing.expect_value(t, rows[0].tag_hash, animation_graph_hash("Player"))
	testing.expect_value(t, blob_string(data, rows[1].tag), "")
	testing.expect_value(t, rows[1].tag_hash, 0)
	testing.expect_value(t, rows[2].of, 0)
	testing.expect_value(t, perception_source_type(rows[2].source), Blackboard_Type.Position)
	testing.expect_value(t, perception_source_type(rows[4].source), Blackboard_Type.Float)
	testing.expect_value(t, perception_source_type(rows[5].source), Blackboard_Type.Bool)
}

@(test)
perception_blobs_with_bad_rows_are_refused :: proc(t: ^testing.T) {
	data := test_perception()
	blob, ok := perception_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	rows := perception_rows(data, blob)

	rows[2].of = 2
	_, ok = perception_view(data)
	testing.expect(t, !ok, "a row that reads itself")
	rows[2].of = 5
	_, ok = perception_view(data)
	testing.expect(t, !ok, "a row that reads one after it")
	rows[4].of = 3
	_, ok = perception_view(data)
	testing.expect(t, !ok, "a row that reads one that chooses no entity")
	rows[2].of, rows[4].of = 0, 0

	rows[5].of = 0
	_, ok = perception_view(data)
	testing.expect(t, !ok, "a noise that reads a row")
	rows[5].of = PERCEPTION_NONE

	rows[1].source = Perception_Source(99)
	_, ok = perception_view(data)
	testing.expect(t, !ok, "an unknown source")
	rows[1].source = .Nearest_Seen

	_, ok = perception_view(data)
	testing.expect(t, ok)
	_, ok = perception_view(data[:size_of(Perception_Blob) - 1])
	testing.expect(t, !ok)
}
