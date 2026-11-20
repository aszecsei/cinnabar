package asset_format

import "core:math"
import "core:testing"

@(private = "file")
SCENE :: Guid{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}
@(private = "file")
PREFAB :: Guid{2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2}
@(private = "file")
CLIP :: Guid{3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3}
@(private = "file")
SOUND :: Guid{4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4}
@(private = "file")
SHOT :: Guid{5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5}

// test_cutscene possesses one entity and spawns two, the second a child of the first, and has a track of each kind
// that names an asset, a transform track with two channels, and a camera cut track.
@(private = "file")
test_cutscene :: proc() -> []byte {
	walk := []Cutscene_Key {
		{time = 0, value = 0, interp = .Linear},
		{time = 30000, value = 2, interp = .Cubic, in_tangent = 0.5, out_tangent = 0.25},
		{time = 60000, value = 4, interp = .Constant},
	}
	turn := []Cutscene_Key{{time = 0, value = 90, interp = .Constant}}
	gain := []Cutscene_Key {
		{time = 0, value = 1, interp = .Linear},
		{time = 6000, value = 0.5, interp = .Linear},
	}
	contents := Cutscene_Contents {
		key           = 9,
		length        = 120000,
		rate          = 24,
		clock         = .Real,
		range_start   = 6000,
		range_end     = 114000,
		bindings      = {
			{
				id = 7,
				kind = .Possessed,
				name = "Walking Fox",
				policy = .Optional,
				parent = CUTSCENE_NONE,
				asset = SCENE,
				entity = 0x79cea6d7586e3f48,
				suspend = {.AI, .Physics},
				flags = {.Keep_Velocity},
			},
			{
				id = 3,
				kind = .Spawned,
				name = "Extra Guard",
				parent = CUTSCENE_NONE,
				asset = PREFAB,
				position = {1 << 24, 0, -(1 << 23)},
				rotation = {0, 0, 0, 1},
				scale = {1, 2, 1},
			},
			{
				id = 4,
				kind = .Spawned,
				name = "Lantern",
				parent = 1,
				asset = PREFAB,
				rotation = {0, 0, 0, 1},
				scale = {1, 1, 1},
			},
		},
		tracks        = {
			{
				id = 1,
				kind = .Transform,
				name = "Fox walk",
				binding = 0,
				finish = .Keep,
				sections = {
					{
						id = 10,
						start = 0,
						end = 60000,
						ease_in = 6000,
						ease_out = 3000,
						weight = 1,
						pre_roll = 1500,
						post_roll = 2500,
						channels = {
							{name = "position_x", keys = walk},
							{name = "rotation_y", keys = turn},
						},
					},
				},
			},
			{
				id = 2,
				kind = .Animation,
				name = "Fox clip",
				binding = 0,
				sections = {
					{id = 11, start = 0, end = 60000, weight = 0.5, asset = CLIP},
					{id = 12, start = 60000, end = 120000, weight = 1, asset = CLIP},
				},
			},
			{
				id = 3,
				kind = .Audio,
				name = "Bark",
				binding = CUTSCENE_NONE,
				flags = {.Muted},
				sections = {
					{
						id = 13,
						start = 12000,
						end = 18000,
						weight = 1,
						asset = SOUND,
						channels = {{name = "gain", keys = gain}},
					},
				},
			},
			{
				id = 4,
				kind = .Sub_Sequence,
				name = "Opening shot",
				binding = CUTSCENE_NONE,
				sections = {{id = 14, start = 0, end = 30000, weight = 1, asset = SHOT}},
			},
			{
				id = 5,
				kind = .Camera_Cut,
				name = "",
				binding = CUTSCENE_NONE,
				sections = {{id = 15, start = 0, end = 120000, weight = 1}},
			},
		},
		source_path   = "game/cutscenes/intro.cutscene",
		input_context = "cinematic",
		hide_ui       = {SCENE, PREFAB},
	}
	return aligned(cutscene_write(contents, context.temp_allocator))
}

@(test)
cutscene_blobs_round_trip :: proc(t: ^testing.T) {
	data := test_cutscene()
	blob, ok := cutscene_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.header.key, 9)
	testing.expect_value(t, blob.length, 120000)
	testing.expect_value(t, blob.rate, 24)
	testing.expect_value(t, blob.clock, Cutscene_Clock.Real)
	testing.expect_value(t, blob.range_start, 6000)
	testing.expect_value(t, blob.range_end, 114000)
	testing.expect_value(t, blob_string(data, blob.source_path), "game/cutscenes/intro.cutscene")

	bindings := cutscene_bindings(data, blob)
	testing.expect_value(t, len(bindings), 3)
	testing.expect_value(t, bindings[0].id, 7)
	testing.expect_value(t, bindings[0].kind, Cutscene_Binding_Kind.Possessed)
	testing.expect_value(t, blob_string(data, bindings[0].name), "Walking Fox")
	testing.expect_value(t, bindings[0].name_hash, animation_graph_hash("Walking Fox"))
	testing.expect_value(t, bindings[0].policy, Cutscene_Policy.Optional)
	testing.expect_value(t, bindings[0].asset, SCENE)
	testing.expect_value(t, bindings[0].entity, 0x79cea6d7586e3f48)
	testing.expect_value(t, bindings[0].suspend, Cutscene_Suspend_Set{.AI, .Physics})
	testing.expect_value(t, bindings[0].flags, Cutscene_Binding_Flags{.Keep_Velocity})
	testing.expect_value(t, bindings[1].suspend, Cutscene_Suspend_Set{})
	testing.expect_value(t, blob_string(data, blob.input_context), "cinematic")
	hidden := cutscene_hide_ui(data, blob)
	testing.expect_value(t, len(hidden), 2)
	testing.expect_value(t, hidden[1], PREFAB)
	testing.expect_value(t, bindings[1].asset, PREFAB)
	testing.expect_value(t, bindings[1].position, [3]i64{1 << 24, 0, -(1 << 23)})
	testing.expect_value(t, bindings[1].scale, [3]f32{1, 2, 1})
	testing.expect_value(t, bindings[2].parent, 1)

	tracks := cutscene_tracks(data, blob)
	testing.expect_value(t, len(tracks), 5)
	testing.expect_value(t, blob_string(data, tracks[0].name), "Fox walk")
	testing.expect_value(t, tracks[0].finish, Cutscene_Finish.Keep)
	testing.expect_value(t, tracks[0].binding, 0)
	testing.expect_value(t, tracks[2].flags, Cutscene_Track_Flags{.Muted})
	testing.expect_value(t, tracks[2].binding, CUTSCENE_NONE)
	testing.expect_value(t, blob_string(data, tracks[4].name), "")

	testing.expect_value(t, len(cutscene_sections(data, blob)), 6)
	clips := cutscene_track_sections(data, blob, tracks[1])
	testing.expect_value(t, len(clips), 2)
	testing.expect_value(t, clips[1].id, 12)
	testing.expect_value(t, clips[0].weight, 0.5)
	testing.expect_value(t, clips[0].asset, CLIP)
	walk := cutscene_track_sections(data, blob, tracks[0])[0]
	testing.expect_value(t, walk.ease_in, 6000)
	testing.expect_value(t, walk.ease_out, 3000)
	testing.expect_value(t, walk.pre_roll, 1500)
	testing.expect_value(t, walk.post_roll, 2500)
	channels := cutscene_section_channels(data, blob, walk)
	testing.expect_value(t, len(channels), 2)
	testing.expect_value(t, blob_string(data, channels[1].name), "rotation_y")
	testing.expect_value(t, channels[1].name_hash, animation_graph_hash("rotation_y"))
	keys := cutscene_channel_keys(data, blob, channels[0])
	testing.expect_value(t, len(keys), 3)
	testing.expect_value(t, keys[1].time, 30000)
	testing.expect_value(t, keys[1].interp, Cutscene_Interp.Cubic)
	testing.expect_value(t, keys[1].in_tangent, 0.5)
	testing.expect_value(t, keys[1].out_tangent, 0.25)
	testing.expect_value(t, cutscene_channel_keys(data, blob, channels[1])[0].value, 90)
	bark := cutscene_track_sections(data, blob, tracks[2])[0]
	gain := cutscene_section_channels(data, blob, bark)
	testing.expect_value(t, blob_string(data, gain[0].name), "gain")
	testing.expect_value(t, cutscene_channel_keys(data, blob, gain[0])[1].value, 0.5)
	testing.expect_value(t, len(cutscene_keys(data, blob)), 6)
}

@(test)
cutscene_blobs_with_bad_records_are_refused :: proc(t: ^testing.T) {
	data := test_cutscene()
	blob, ok := cutscene_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	refused :: proc(t: ^testing.T, data: []byte, what: string) {
		_, ok := cutscene_view(data)
		testing.expect(t, !ok, what)
	}
	bindings := cutscene_bindings(data, blob)
	tracks := cutscene_tracks(data, blob)
	sections := cutscene_sections(data, blob)
	channels := cutscene_channels(data, blob)
	keys := cutscene_keys(data, blob)

	blob.header.kind = .World
	refused(t, data, "a blob of another kind")
	blob.header.kind = .Cutscene
	blob.header.layout += 1
	refused(t, data, "a blob of another layout")
	blob.header.layout -= 1

	blob.keys.size += 4
	refused(t, data, "keys that are not whole records")
	blob.keys.size -= 4
	blob.bindings.offset += 4
	refused(t, data, "bindings that are not aligned")
	blob.bindings.offset -= 4
	blob.source_path.size += u32(len(data))
	refused(t, data, "a path past the end")
	blob.source_path.size -= u32(len(data))
	blob.hide_ui.size += 1
	refused(t, data, "hidden documents that are not whole GUIDs")
	blob.hide_ui.size -= 1

	blob.length = 0
	refused(t, data, "a length of 0")
	blob.length = 120000
	blob.rate = 29
	refused(t, data, "a rate that is not a display rate")
	blob.rate = 24
	blob.clock = Cutscene_Clock(2)
	refused(t, data, "an unknown clock")
	blob.clock = .Game
	blob.range_end = 6000
	refused(t, data, "a range that ends at its start")
	blob.range_end = 120001
	refused(t, data, "a range past the length")
	blob.range_end = 114000
	blob.range_start = -1
	refused(t, data, "a range that starts before 0")
	blob.range_start = 6000

	bindings[0].kind = Cutscene_Binding_Kind(2)
	refused(t, data, "an unknown binding kind")
	bindings[0].kind = .Possessed
	bindings[0].policy = Cutscene_Policy(2)
	refused(t, data, "an unknown policy")
	bindings[0].policy = .Optional
	bindings[0].suspend = transmute(Cutscene_Suspend_Set)u8(1 << 5)
	refused(t, data, "an unknown system to suspend")
	bindings[0].suspend = {.AI, .Physics}
	bindings[0].flags = transmute(Cutscene_Binding_Flags)u8(1 << 3)
	refused(t, data, "an unknown binding flag")
	bindings[0].flags = {.Keep_Velocity}
	bindings[0].name.size += u32(len(data))
	refused(t, data, "a binding's name past the end")
	bindings[0].name.size -= u32(len(data))
	bindings[0].entity = 0
	refused(t, data, "a possessed binding without an entity")
	bindings[0].entity = 0x79cea6d7586e3f48
	bindings[1].asset = {}
	refused(t, data, "a spawned binding without a prefab")
	bindings[1].asset = PREFAB
	bindings[2].parent = 2
	refused(t, data, "a binding that is its own parent")
	bindings[2].parent = 0
	refused(t, data, "a parent that is possessed")
	bindings[1].parent = 2
	bindings[2].parent = CUTSCENE_NONE
	refused(t, data, "a parent after its child")
	bindings[1].parent = CUTSCENE_NONE
	bindings[2].parent = 1

	tracks[0].kind = Cutscene_Track_Kind(8)
	refused(t, data, "an unknown track kind")
	tracks[0].kind = .Transform
	tracks[0].finish = Cutscene_Finish(2)
	refused(t, data, "an unknown finish")
	tracks[0].finish = .Keep
	tracks[0].flags = transmute(Cutscene_Track_Flags)u32(2)
	refused(t, data, "an unknown track flag")
	tracks[0].flags = {}
	tracks[0].name.size += u32(len(data))
	refused(t, data, "a track's name past the end")
	tracks[0].name.size -= u32(len(data))
	tracks[0].binding = CUTSCENE_NONE
	refused(t, data, "a transform track without a binding")
	tracks[0].binding = 3
	refused(t, data, "a track whose binding is past the table")
	tracks[0].binding = 0
	tracks[4].binding = 0
	refused(t, data, "a camera cut track with a binding")
	tracks[4].binding = CUTSCENE_NONE
	tracks[2].binding = 3
	refused(t, data, "an audio track whose binding is past the table")
	tracks[2].binding = CUTSCENE_NONE
	tracks[1].first_section = 0
	refused(t, data, "tracks that share sections")
	tracks[1].first_section = 1
	tracks[4].section_count = 0
	refused(t, data, "sections that no track has")
	tracks[4].section_count = 1

	sections[1].end = 0
	refused(t, data, "a section that ends at its start")
	sections[1].end = 120001
	refused(t, data, "a section past the length")
	sections[1].end = 60000
	sections[0].ease_in = -1
	refused(t, data, "a negative ease")
	sections[0].ease_in = 58000
	refused(t, data, "eases longer than the section")
	sections[0].ease_in = 6000
	sections[0].pre_roll = -1
	refused(t, data, "a negative pre-roll")
	sections[0].pre_roll = 1500
	sections[0].post_roll = -1
	refused(t, data, "a negative post-roll")
	sections[0].post_roll = 2500
	sections[1].weight = 1.5
	refused(t, data, "a weight above 1")
	sections[1].weight = math.nan_f32()
	refused(t, data, "a weight that is NaN")
	sections[1].weight = 0.5
	sections[1].asset = {}
	refused(t, data, "an animation section without a clip")
	sections[1].asset = CLIP
	sections[0].asset = CLIP
	refused(t, data, "a transform section with an asset")
	sections[0].asset = {}
	sections[1].first_channel = 1
	refused(t, data, "a section whose channels are another's")
	sections[1].first_channel = 2
	sections[0].channel_count = 1
	refused(t, data, "channels that no section has")
	sections[0].channel_count = 2

	channels[0].name.size += u32(len(data))
	refused(t, data, "a channel's name past the end")
	channels[0].name.size -= u32(len(data))
	channels[1].first_key = 2
	refused(t, data, "a channel whose keys are another's")
	channels[1].first_key = 3
	channels[2].key_count = 1
	refused(t, data, "keys that no channel has")
	channels[2].key_count = 2

	keys[0].interp = Cutscene_Interp(3)
	refused(t, data, "an unknown interpolation")
	keys[0].interp = .Linear
	keys[0].value = math.inf_f32(1)
	refused(t, data, "a value that is not finite")
	keys[0].value = 0
	keys[1].out_tangent = math.nan_f32()
	refused(t, data, "a tangent that is NaN")
	keys[1].out_tangent = 0.25
	keys[2].time = 60001
	refused(t, data, "a key past its section")
	keys[2].time = 30000
	refused(t, data, "a key at the time of the one before")
	keys[2].time = 60000
	keys[0].time = -1
	refused(t, data, "a key before its section")
	keys[0].time = 0

	_, ok = cutscene_view(data)
	testing.expect(t, ok, "the blob as it was")
	_, ok = cutscene_view(data[:size_of(Cutscene_Blob) - 1])
	testing.expect(t, !ok, "a blob shorter than its header")
}

@(test)
cutscene_blobs_past_a_table_limit_are_refused :: proc(t: ^testing.T) {
	bindings := make(
		[]Cutscene_Binding_Contents,
		MAX_CUTSCENE_BINDINGS + 1,
		context.temp_allocator,
	)
	for &b, i in bindings {
		b = {
			id       = u32(i + 1),
			kind     = .Spawned,
			name     = "B",
			parent   = CUTSCENE_NONE,
			asset    = PREFAB,
			rotation = {0, 0, 0, 1},
			scale    = {1, 1, 1},
		}
	}
	contents := Cutscene_Contents {
		length    = 60000,
		rate      = 30,
		range_end = 60000,
		bindings  = bindings,
	}
	_, ok := cutscene_view(aligned(cutscene_write(contents, context.temp_allocator)))
	testing.expect(t, !ok, "more bindings than MAX_CUTSCENE_BINDINGS")
	contents.bindings = bindings[:MAX_CUTSCENE_BINDINGS]
	_, ok = cutscene_view(aligned(cutscene_write(contents, context.temp_allocator)))
	testing.expect(t, ok, "MAX_CUTSCENE_BINDINGS bindings")
}

@(test)
cutscene_blob_references_name_prefabs_clips_sounds_and_sub_sequences :: proc(t: ^testing.T) {
	references, ok := blob_references(test_cutscene(), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(references), 4)
	if len(references) == 4 {
		testing.expect_value(t, references[0], PREFAB)
		testing.expect_value(t, references[1], CLIP)
		testing.expect_value(t, references[2], SOUND)
		testing.expect_value(t, references[3], SHOT)
	}
}

@(test)
entity_references_read_as_scene_files_write_them :: proc(t: ^testing.T) {
	scene, entity, message := entity_reference_parse("@00ab")
	testing.expect_value(t, message, "")
	testing.expect_value(t, scene, Guid{})
	testing.expect_value(t, entity, 0xab)
	scene, entity, message = entity_reference_parse(
		"@01010101010101010101010101010101/79cea6d7586e3f48",
	)
	testing.expect_value(t, message, "")
	testing.expect_value(t, scene, SCENE)
	testing.expect_value(t, entity, 0x79cea6d7586e3f48)
	_, entity, message = entity_reference_parse(
		"@01010101010101010101010101010101/0000000000000001#0000000000000002",
	)
	testing.expect_value(t, message, "")
	testing.expect_value(t, entity, scene_path_id_of({1, 2}))
	_, _, message = entity_reference_parse("@01010101010101010101010101010101/0")
	testing.expect(t, message != "", "a reference to another scene's entity 0")
	_, _, message = entity_reference_parse("@nothex/12")
	testing.expect(t, message != "", "a scene that is not a GUID")
	_, _, message = entity_reference_parse("@12#3")
	testing.expect(t, message != "", "a path of short IDs")
	_, _, message = entity_reference_parse("12")
	testing.expect(t, message != "", "a reference without @")
}
