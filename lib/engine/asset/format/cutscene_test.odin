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
@(private = "file")
MATERIAL :: Guid{6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6}

// test_cutscene possesses one entity and spawns two, the second a child of the first, and has a track of each kind
// that names an asset, a transform track with two channels, a camera cut track, and a property track with an additive
// section and a section that keys GUIDs.
@(private = "file")
test_cutscene :: proc() -> []byte {
	walk := []Cutscene_Key {
		{time = 0, value = 0, interp = .Linear, flags = {.Teleport}},
		{
			time = 30000,
			value = 2,
			interp = .Bezier,
			flags = {.Broken, .Weighted},
			in_slope = 0.5,
			in_weight = 0.25,
			out_slope = 0.25,
			out_weight = 0.75,
		},
		{time = 60000, value = 4, interp = .Constant},
	}
	turn := []Cutscene_Key{{time = 0, value = 90, interp = .Constant}}
	gain := []Cutscene_Key {
		{time = 0, value = 1, interp = .Linear},
		{time = 6000, value = 0.5, interp = .Linear},
	}
	sway := []Cutscene_Key{{time = 0, value = 0.5, interp = .Auto}}
	swap := []Cutscene_Key {
		{time = 0, value = 1, interp = .Constant},
		{time = 1000, value = 0, interp = .Constant},
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
				space = .Absolute,
				origin = {1 << 54, 0, -5},
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
					{id = 11, start = 0, end = 60000, weight = 0.5, asset = CLIP, speed = 1},
					{
						id = 12,
						start = 60000,
						end = 120000,
						weight = 1,
						asset = CLIP,
						offset = 15000,
						speed = 0.5,
						flags = {.Loop},
						root_motion = .Apply,
					},
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
			{
				id = 6,
				kind = .Property,
				name = "Lamp",
				binding = 0,
				component = 9101,
				field = "light.material",
				sections = {
					{
						id = 16,
						start = 0,
						end = 60000,
						weight = 1,
						flags = {.Additive},
						channels = {{name = "value", keys = sway}},
					},
					{
						id = 17,
						start = 60000,
						end = 120000,
						weight = 1,
						channels = {{name = "value", flags = {.Guids}, keys = swap}},
					},
				},
			},
		},
		source_path   = "game/cutscenes/intro.cutscene",
		input_context = "cinematic",
		hide_ui       = {SCENE, PREFAB},
		skip          = .Ranges,
		skip_ranges   = {{6000, 30000}, {60000, 120000}},
		skip_fade     = 15000,
		guids         = {SOUND, MATERIAL},
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
	testing.expect_value(t, blob.skip, Cutscene_Skip.Ranges)
	testing.expect_value(t, blob.skip_fade, 15000)
	skip_ranges := cutscene_skip_ranges(data, blob)
	testing.expect_value(t, len(skip_ranges), 2)
	testing.expect_value(t, skip_ranges[1], Cutscene_Skip_Range{60000, 120000})
	testing.expect_value(t, bindings[1].asset, PREFAB)
	testing.expect_value(t, bindings[1].position, [3]i64{1 << 24, 0, -(1 << 23)})
	testing.expect_value(t, bindings[1].scale, [3]f32{1, 2, 1})
	testing.expect_value(t, bindings[2].parent, 1)

	tracks := cutscene_tracks(data, blob)
	testing.expect_value(t, len(tracks), 6)
	testing.expect_value(t, blob_string(data, tracks[0].name), "Fox walk")
	testing.expect_value(t, tracks[0].finish, Cutscene_Finish.Keep)
	testing.expect_value(t, tracks[0].binding, 0)
	testing.expect_value(t, tracks[2].flags, Cutscene_Track_Flags{.Muted})
	testing.expect_value(t, tracks[2].binding, CUTSCENE_NONE)
	testing.expect_value(t, blob_string(data, tracks[4].name), "")
	testing.expect_value(t, tracks[0].space, Cutscene_Space.Absolute)
	testing.expect_value(t, tracks[0].origin, [3]i64{1 << 54, 0, -5})
	testing.expect_value(t, tracks[0].relative, CUTSCENE_NONE)
	testing.expect_value(t, tracks[1].space, Cutscene_Space.Relative)
	testing.expect_value(t, tracks[1].origin, [3]i64{})
	testing.expect_value(t, tracks[1].relative, CUTSCENE_NONE)

	testing.expect_value(t, len(cutscene_sections(data, blob)), 8)
	clips := cutscene_track_sections(data, blob, tracks[1])
	testing.expect_value(t, len(clips), 2)
	testing.expect_value(t, clips[1].id, 12)
	testing.expect_value(t, clips[0].weight, 0.5)
	testing.expect_value(t, clips[0].asset, CLIP)
	testing.expect_value(t, clips[0].speed, 1)
	testing.expect_value(t, clips[1].offset, 15000)
	testing.expect_value(t, clips[1].speed, 0.5)
	testing.expect_value(t, clips[1].flags, Cutscene_Section_Flags{.Loop})
	testing.expect_value(t, clips[1].root_motion, Cutscene_Root_Motion.Apply)
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
	testing.expect_value(t, keys[0].flags, Cutscene_Key_Flags{.Teleport})
	testing.expect_value(t, keys[1].time, 30000)
	testing.expect_value(t, keys[1].interp, Cutscene_Interp.Bezier)
	testing.expect_value(t, keys[1].flags, Cutscene_Key_Flags{.Broken, .Weighted})
	testing.expect_value(t, keys[1].in_slope, 0.5)
	testing.expect_value(t, keys[1].in_weight, 0.25)
	testing.expect_value(t, keys[1].out_slope, 0.25)
	testing.expect_value(t, keys[1].out_weight, 0.75)
	testing.expect_value(t, cutscene_channel_keys(data, blob, channels[1])[0].value, 90)
	bark := cutscene_track_sections(data, blob, tracks[2])[0]
	gain := cutscene_section_channels(data, blob, bark)
	testing.expect_value(t, blob_string(data, gain[0].name), "gain")
	testing.expect_value(t, cutscene_channel_keys(data, blob, gain[0])[1].value, 0.5)
	testing.expect_value(t, len(cutscene_keys(data, blob)), 9)

	lamp := tracks[5]
	testing.expect_value(t, lamp.component, 9101)
	testing.expect_value(t, blob_string(data, lamp.field), "light.material")
	testing.expect_value(t, lamp.field_hash, scene_field_hash("light.material"))
	testing.expect_value(t, tracks[0].component, 0)
	testing.expect_value(t, tracks[0].field_hash, 0)
	lamp_sections := cutscene_track_sections(data, blob, lamp)
	testing.expect_value(t, lamp_sections[0].flags, Cutscene_Section_Flags{.Additive})
	testing.expect_value(t, lamp_sections[1].flags, Cutscene_Section_Flags{})
	swap := cutscene_section_channels(data, blob, lamp_sections[1])[0]
	testing.expect_value(t, swap.flags, Cutscene_Channel_Flags{.Guids})
	guids := cutscene_guids(data, blob)
	testing.expect_value(t, len(guids), 2)
	testing.expect_value(t, guids[int(cutscene_channel_keys(data, blob, swap)[0].value)], MATERIAL)
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
	blob.skip = Cutscene_Skip(3)
	refused(t, data, "an unknown skip policy")
	blob.skip = .Anywhere
	refused(t, data, "skip ranges for a policy that has none")
	blob.skip = .Ranges
	blob.skip_fade = -1
	refused(t, data, "a fade of less than 0")
	blob.skip_fade = 15000
	skip_ranges := cutscene_skip_ranges(data, blob)
	skip_ranges[1].start = 20000
	refused(t, data, "skip ranges that overlap")
	skip_ranges[1].start = 120000
	refused(t, data, "a skip range that ends at its start")
	skip_ranges[1] = {60000, 120001}
	refused(t, data, "a skip range past the length")
	skip_ranges[1] = {60000, 120000}
	blob.skip_ranges.size += 4
	refused(t, data, "skip ranges that are not whole records")
	blob.skip_ranges.size -= 4

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
	tracks[5].component = 0
	refused(t, data, "a property track without a component")
	tracks[5].component = 9101
	tracks[5].field_hash = 0
	refused(t, data, "a property track without a field's hash")
	tracks[5].field_hash = scene_field_hash("light.material")
	tracks[0].component = 9101
	refused(t, data, "a transform track with a component")
	tracks[0].component = 0
	tracks[0].field_hash = 1
	refused(t, data, "a transform track with a field")
	tracks[0].field_hash = 0
	tracks[0].space = Cutscene_Space(3)
	refused(t, data, "an unknown space")
	tracks[0].space = .Relative
	refused(t, data, "an origin for a space that is not absolute")
	tracks[0].space = .Absolute
	tracks[0].origin.x = WORLD_POSITION_LIMIT + 1
	refused(t, data, "an origin outside the bounds of a World_Position")
	tracks[0].origin.x = 1 << 54
	tracks[0].reserved = 1
	refused(t, data, "a track's reserved word that is not 0")
	tracks[0].reserved = 0
	tracks[1].space = .Absolute
	refused(t, data, "an animation track with a space")
	tracks[1].space = .Relative
	tracks[0].origin = {}
	tracks[0].space = .Relative_To
	refused(t, data, "a track relative to another binding that names none")
	tracks[0].relative = 0
	refused(t, data, "a track relative to its own binding")
	tracks[0].relative = 3
	refused(t, data, "a track relative to a binding past the table")
	tracks[0].relative = 1
	_, ok = cutscene_view(data)
	testing.expect(t, ok, "a track relative to another binding")
	tracks[0].space = .Absolute
	refused(t, data, "an absolute track that names a binding")
	tracks[0].relative = CUTSCENE_NONE
	tracks[0].origin = {1 << 54, 0, -5}

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
	sections[0].flags = transmute(Cutscene_Section_Flags)u32(2)
	refused(t, data, "an unknown section flag")
	sections[1].flags = {.Additive}
	refused(t, data, "an additive animation section")
	sections[1].flags = {}
	sections[1].speed = 0
	refused(t, data, "an animation section that does not play its clip")
	sections[1].speed = math.inf_f32(1)
	refused(t, data, "an animation section at an infinite speed")
	sections[1].speed = math.nan_f32()
	refused(t, data, "an animation section at a speed that is NaN")
	sections[1].speed = 1
	sections[1].offset = -1
	refused(t, data, "an animation section before its clip's start")
	sections[1].offset = 0
	sections[0].speed = 1
	refused(t, data, "a transform section with a speed")
	sections[0].speed = 0
	sections[0].offset = 5
	refused(t, data, "a transform section with an offset")
	sections[0].offset = 0
	sections[0].flags = {.Loop}
	refused(t, data, "a transform section that loops")
	sections[0].flags = {}
	sections[0].root_motion = .In_Place
	refused(t, data, "a transform section with a root motion")
	sections[0].root_motion = .Bake
	sections[1].root_motion = Cutscene_Root_Motion(3)
	refused(t, data, "an unknown root motion")
	sections[1].root_motion = .Bake
	sections[0].flags = {.Additive}
	_, ok = cutscene_view(data)
	testing.expect(t, ok, "an additive transform section")
	sections[0].flags = {}

	channels[0].name.size += u32(len(data))
	refused(t, data, "a channel's name past the end")
	channels[0].name.size -= u32(len(data))
	channels[1].first_key = 2
	refused(t, data, "a channel whose keys are another's")
	channels[1].first_key = 3
	channels[2].key_count = 1
	refused(t, data, "keys that no channel has")
	channels[2].key_count = 2
	channels[2].flags = {.Guids}
	refused(t, data, "GUID keys on an audio track")
	channels[2].flags = transmute(Cutscene_Channel_Flags)u32(2)
	refused(t, data, "an unknown channel flag")
	channels[2].flags = {}

	keys[0].interp = Cutscene_Interp(4)
	refused(t, data, "an unknown interpolation")
	keys[0].interp = .Linear
	keys[0].value = math.inf_f32(1)
	refused(t, data, "a value that is not finite")
	keys[0].value = 0
	keys[0].out_slope = 1
	refused(t, data, "a linear key with a slope")
	keys[0].out_slope = 0
	keys[0].flags = {.Weighted}
	refused(t, data, "a linear key with weights")
	keys[0].flags = {}
	keys[1].out_slope = math.nan_f32()
	refused(t, data, "a slope that is NaN")
	keys[1].out_slope = 0.25
	keys[1].out_weight = 1.5
	refused(t, data, "a weight above 1")
	keys[1].out_weight = 0.75
	keys[1].flags = {.Weighted}
	refused(t, data, "a key whose tangents are one but whose slopes differ")
	keys[1].flags = {.Broken}
	refused(t, data, "weights on a key that is not weighted")
	keys[1].flags = {.Broken, .Weighted}
	keys[1].flags += transmute(Cutscene_Key_Flags)u8(8)
	refused(t, data, "an unknown key flag")
	keys[1].flags = {.Broken, .Weighted}
	// The audio track's keys come after the transform track's four.
	keys[4].flags = {.Teleport}
	refused(t, data, "a key of an audio track that teleports")
	keys[4].flags = {}
	// The GUID keys are the last two.
	guid_key := &keys[len(keys) - 1]
	guid_key.value = 2
	refused(t, data, "a GUID key past the GUIDs")
	guid_key.value = 0.5
	refused(t, data, "a GUID key that is not a whole index")
	guid_key.value = 0
	guid_key.interp = .Linear
	refused(t, data, "a GUID key that is not constant")
	guid_key.interp = .Constant
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
cutscene_blob_references_name_prefabs_clips_sounds_sub_sequences_and_keyed_assets :: proc(
	t: ^testing.T,
) {
	references, ok := blob_references(test_cutscene(), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(references), 5)
	if len(references) == 5 {
		testing.expect_value(t, references[0], PREFAB)
		testing.expect_value(t, references[1], CLIP)
		testing.expect_value(t, references[2], SOUND)
		testing.expect_value(t, references[3], SHOT)
		testing.expect_value(t, references[4], MATERIAL)
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

// A skip goes to the end of the range anywhere, nowhere for none, and to the end of the range that holds the time for
// ranges, never past the end of the cutscene's range and never to the time itself.
@(test)
a_skip_target_follows_the_policy :: proc(t: ^testing.T) {
	data := test_cutscene()
	blob, ok := cutscene_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	Case :: struct {
		time:   i32,
		target: i32,
		ok:     bool,
	}
	for c in ([?]Case{{6000, 30000, true}, {29999, 30000, true}, {30000, 0, false}, {70000, 114000, true}}) {
		target, skips := cutscene_skip_target(data, blob, c.time)
		testing.expect_value(t, skips, c.ok)
		if c.ok {
			testing.expect_value(t, target, c.target)
		}
	}
	_, past := cutscene_skip_target(data, blob, 114000)
	testing.expect(t, !past, "the end of the range cannot be skipped")
	blob.skip = .Anywhere
	blob.skip_ranges = {}
	target, anywhere := cutscene_skip_target(data, blob, 30000)
	testing.expect(t, anywhere)
	testing.expect_value(t, target, 114000)
	blob.skip = .None
	_, none := cutscene_skip_target(data, blob, 30000)
	testing.expect(t, !none)
}
