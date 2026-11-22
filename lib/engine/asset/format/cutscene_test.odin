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
	pitch := []Cutscene_Key{{time = 0, value = 0.5, interp = .Linear}}
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
				constraints = {{kind = .Focus, target = 0}},
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
				gain = 0.75,
				time_scale = .Free,
				sections = {
					{
						id = 13,
						start = 12000,
						end = 18000,
						weight = 1,
						asset = SOUND,
						offset = 3000,
						speed = 1,
						flags = {.Loop, .Plays_Through_Skip},
						bus = 2,
						min_distance = 1,
						max_distance = 30,
						channels = {{name = "gain", keys = gain}, {name = "pitch", keys = pitch}},
					},
				},
			},
			{
				id = 4,
				kind = .Sub_Sequence,
				name = "Opening shot",
				binding = CUTSCENE_NONE,
				sections = {
					{
						id = 14,
						start = 0,
						end = 30000,
						weight = 1,
						asset = SHOT,
						offset = 6000,
						trim_end = 24000,
						speed = 2,
						flags = {.Loop},
						bindings = {{child = 3, parent = 0}, {child = 5, parent = 2}},
					},
				},
			},
			{
				id = 5,
				kind = .Camera_Cut,
				name = "",
				binding = CUTSCENE_NONE,
				sections = {
					{
						id = 15,
						start = 0,
						end = 120000,
						weight = 1,
						camera = 1,
						blend_in = 6000,
						blend_out = 3000,
						blend_curves = {.Smooth, .Ease_Out},
						flags = {.Blend_On_Skip},
						constraints = {
							{kind = .Look_At, target = 0, offset = {0, 1.5, 0}, damping = 12000},
							{kind = .Follow, target = 2, offset = {1, 2, -3}},
						},
					},
				},
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
	sub := cutscene_track_sections(data, blob, tracks[3])[0]
	testing.expect_value(t, sub.offset, 6000)
	testing.expect_value(t, sub.trim_end, 24000)
	testing.expect_value(t, sub.speed, 2)
	testing.expect_value(t, sub.flags, Cutscene_Section_Flags{.Loop})
	shot_maps := cutscene_section_maps(data, blob, tracks[3].first_section)
	testing.expect_value(t, len(shot_maps), 2)
	testing.expect_value(t, shot_maps[1], Cutscene_Binding_Map{tracks[3].first_section, 5, 2})
	testing.expect_value(t, len(cutscene_section_maps(data, blob, 0)), 0)
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
	testing.expect_value(t, blob_string(data, gain[1].name), "pitch")
	testing.expect_value(t, len(cutscene_keys(data, blob)), 10)
	testing.expect_value(t, tracks[2].gain, 0.75)
	testing.expect_value(t, tracks[2].time_scale, Cutscene_Audio_Scale.Free)
	testing.expect_value(t, tracks[0].gain, 0)
	testing.expect_value(t, bark.offset, 3000)
	testing.expect_value(t, bark.speed, 1)
	testing.expect_value(t, bark.flags, Cutscene_Section_Flags{.Loop, .Plays_Through_Skip})
	testing.expect_value(t, bark.bus, 2)
	testing.expect_value(t, bark.min_distance, 1)
	testing.expect_value(t, bark.max_distance, 30)
	testing.expect_value(t, clips[0].bus, 0)
	testing.expect_value(t, clips[0].max_distance, 0)

	lamp := tracks[5]
	testing.expect_value(t, lamp.component, 9101)
	testing.expect_value(t, blob_string(data, lamp.field), "light.material")
	testing.expect_value(t, lamp.field_hash, scene_field_hash("light.material"))
	testing.expect_value(t, tracks[0].component, 0)
	testing.expect_value(t, tracks[0].field_hash, 0)

	cut, has_cut := cutscene_cut_track(data, blob)
	testing.expect(t, has_cut)
	testing.expect_value(t, cut.id, 5)
	shot := cutscene_track_sections(data, blob, cut)[0]
	testing.expect_value(t, shot.camera, 1)
	testing.expect_value(t, shot.blend_in, 6000)
	testing.expect_value(t, shot.blend_out, 3000)
	testing.expect_value(t, shot.blend_curves, [2]Cutscene_Blend_Curve{.Smooth, .Ease_Out})
	testing.expect_value(t, shot.flags, Cutscene_Section_Flags{.Blend_On_Skip})
	testing.expect_value(t, clips[0].camera, CUTSCENE_NONE)
	constraints := cutscene_constraints(data, blob)
	testing.expect_value(t, len(constraints), 3)
	// The bindings' constraints come first, then the sections'.
	testing.expect_value(
		t,
		constraints[0],
		Cutscene_Constraint{kind = .Focus, section = CUTSCENE_NONE, binding = 1, target = 0},
	)
	testing.expect_value(
		t,
		constraints[1],
		Cutscene_Constraint {
			kind = .Look_At,
			section = 5,
			binding = CUTSCENE_NONE,
			target = 0,
			offset = {0, 1.5, 0},
			damping = 12000,
		},
	)
	testing.expect_value(t, constraints[2].kind, Cutscene_Constraint_Kind.Follow)
	testing.expect_value(t, constraints[2].target, 2)
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

	// Camera cut sections.
	sections[5].camera = 3
	refused(t, data, "a cut section whose camera is past the table")
	sections[5].camera = 1
	sections[0].camera = 1
	refused(t, data, "a transform section with a camera")
	sections[0].camera = CUTSCENE_NONE
	sections[0].blend_in = 1
	refused(t, data, "a transform section with a blend")
	sections[0].blend_in = 0
	sections[0].flags = {.Blend_On_Skip}
	refused(t, data, "a transform section that blends on a skip")
	sections[0].flags = {}
	sections[5].weight = 0.5
	refused(t, data, "a cut section with a weight below 1")
	sections[5].weight = 1
	sections[5].ease_in = 10
	refused(t, data, "a cut section with an ease")
	sections[5].ease_in = 0
	sections[5].pre_roll = 10
	refused(t, data, "a cut section with a pre-roll")
	sections[5].pre_roll = 0
	sections[5].flags = {.Additive, .Blend_On_Skip}
	refused(t, data, "an additive cut section")
	sections[5].flags = {.Blend_On_Skip}
	sections[5].blend_in = 120001
	refused(t, data, "a blend in longer than its section")
	sections[5].blend_in = -1
	refused(t, data, "a negative blend in")
	sections[5].blend_in = 6000
	sections[5].blend_curves[1] = Cutscene_Blend_Curve(4)
	refused(t, data, "an unknown blend curve")
	sections[5].blend_curves[1] = .Ease_Out
	sections[5].blend_out = 0
	refused(t, data, "a blend on skip without a blend out")
	sections[5].blend_out = 3000
	sections[5].reserved = 1
	refused(t, data, "a section's reserved word that is not 0")
	sections[5].reserved = 0
	tracks[3].kind = .Camera_Cut
	sections[4].asset = {}
	sections[4].camera = 0
	refused(t, data, "a second camera cut track")
	tracks[3].kind = .Sub_Sequence
	sections[4].asset = SHOT
	sections[4].camera = CUTSCENE_NONE

	// Sub-sequence sections and the maps of their children's bindings.
	sections[4].trim_end = 6000
	refused(t, data, "a trim that ends at its start")
	sections[4].trim_end = -1
	refused(t, data, "a trim's end below 0")
	sections[4].trim_end = 24000
	sections[4].speed = 0
	refused(t, data, "a sub-sequence with a scale of 0")
	sections[4].speed = 2
	sections[0].trim_end = 1
	refused(t, data, "a trim's end on a section that is not a sub-sequence's")
	sections[0].trim_end = 0
	maps := cutscene_binding_maps(data, blob)
	maps[1].parent = 3
	refused(t, data, "a map to a binding that the cutscene does not have")
	maps[1].parent = 2
	maps[1].child = 3
	refused(t, data, "a child's binding that a section maps twice")
	maps[1].child = 5
	maps[0].section = 0
	refused(t, data, "a map on a section that is not a sub-sequence's")
	maps[0].section = 99
	refused(t, data, "a map on a section that the cutscene does not have")
	maps[0].section = 4
	blob.reserved2 = 1
	refused(t, data, "a blob's reserved word that is not 0")
	blob.reserved2 = 0


	// Audio tracks and sections.
	tracks[2].gain = -1
	refused(t, data, "an audio track with a gain below 0")
	tracks[2].gain = math.inf_f32(1)
	refused(t, data, "an audio track with a gain that is not finite")
	tracks[2].gain = 0.75
	tracks[2].time_scale = Cutscene_Audio_Scale(2)
	refused(t, data, "an unknown time scale policy")
	tracks[2].time_scale = .Free
	tracks[0].gain = 1
	refused(t, data, "a transform track with a gain")
	tracks[0].gain = 0
	tracks[0].time_scale = .Free
	refused(t, data, "a transform track with a time scale policy")
	tracks[0].time_scale = .Follow
	sections[3].speed = 2
	refused(t, data, "an audio section with a speed")
	sections[3].speed = 1
	sections[3].pre_roll = 10
	refused(t, data, "an audio section with a pre-roll")
	sections[3].pre_roll = 0
	sections[3].bus = MAX_CUTSCENE_BUS + 1
	refused(t, data, "an audio section's bus past the buses")
	sections[3].bus = 2
	sections[3].max_distance = 1
	refused(t, data, "an audio section's max distance at its min distance")
	sections[3].max_distance = 30
	sections[3].min_distance = -1
	refused(t, data, "an audio section's min distance below 0")
	sections[3].min_distance = 1
	sections[0].bus = 1
	refused(t, data, "a transform section with a bus")
	sections[0].bus = 0
	sections[0].max_distance = 10
	refused(t, data, "a transform section with distances")
	sections[0].max_distance = 0
	sections[0].flags = {.Plays_Through_Skip}
	refused(t, data, "a transform section that plays through a skip")
	sections[0].flags = {}
	// The audio section's channels are gain and pitch, the third and the fourth.
	pitch_name := channels[3].name
	channels[3].name = channels[0].name
	refused(t, data, "an audio channel that is not gain or pitch")
	channels[3].name = pitch_name
	keys[5].value = -0.5
	refused(t, data, "a gain key below 0")
	keys[5].value = 0.5
	keys[6].value = 0.05
	refused(t, data, "a pitch key below the lowest pitch")
	keys[6].value = 4.5
	refused(t, data, "a pitch key above the highest pitch")
	keys[6].value = 0.5
	_, ok = cutscene_view(data)
	testing.expect(t, ok, "the audio track again")

	// Constraints.
	constraints := cutscene_constraints(data, blob)
	constraints[1].kind = Cutscene_Constraint_Kind(3)
	refused(t, data, "an unknown constraint kind")
	constraints[1].kind = .Look_At
	constraints[1].binding = 1
	refused(t, data, "a constraint on a section and a binding")
	constraints[1].section = CUTSCENE_NONE
	constraints[1].binding = CUTSCENE_NONE
	refused(t, data, "a constraint on neither")
	constraints[1].section = 4
	refused(t, data, "a constraint on a section that is not a cut")
	constraints[1].section = 5
	constraints[1].target = 1
	refused(t, data, "a constraint whose target is its camera")
	constraints[1].target = 3
	refused(t, data, "a constraint whose target is past the table")
	constraints[1].target = 0
	constraints[1].damping = -1
	refused(t, data, "a negative damping")
	constraints[1].damping = 12000
	constraints[1].offset.y = math.inf_f32(1)
	refused(t, data, "an offset that is not finite")
	constraints[1].offset.y = 1.5
	constraints[0].offset = {1, 0, 0}
	refused(t, data, "a focus with an offset")
	constraints[0].offset = {}
	constraints[0].binding = 3
	refused(t, data, "a constraint on a binding past the table")
	constraints[0].binding = 1
	_, ok = cutscene_view(data)
	testing.expect(t, ok, "the constraints again")

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

// event_cutscene has a binding, a global event track with a trigger and a range, and an event track of the binding with
// a trigger that carries a value of each kind.
@(private = "file")
event_cutscene :: proc() -> []byte {
	contents := Cutscene_Contents {
		length    = 120000,
		rate      = 30,
		range_end = 120000,
		bindings  = {
			{
				id = 1,
				kind = .Possessed,
				name = "Gate",
				parent = CUTSCENE_NONE,
				asset = SCENE,
				entity = 1,
				rotation = {0, 0, 0, 1},
				scale = {1, 1, 1},
			},
		},
		tracks    = {
			{
				id = 1,
				kind = .Transform,
				name = "Walk",
				binding = 0,
				sections = {{id = 1, start = 0, end = 60000, weight = 1}},
			},
			{
				id = 2,
				kind = .Event,
				name = "Story",
				binding = CUTSCENE_NONE,
				events = {
					{id = 1, start = 0, end = 0, name = "begun", flags = {.Fire_When_Skipped}},
					{
						id = 2,
						start = 30000,
						end = 90000,
						name = "alarm",
						flags = {.Range, .Fire_On_Seek},
						values = {{kind = .String, text = "red"}},
					},
				},
			},
			{
				id = 3,
				kind = .Event,
				name = "Gate",
				binding = 0,
				events = {
					{
						id = 3,
						start = 60000,
						end = 60000,
						name = "door_open",
						values = {
							{kind = .Number, number = 2.5},
							{kind = .Bool, index = 1},
							{kind = .Vector, vector = {0, 1, 0}},
							{kind = .Entity, index = 0},
						},
					},
					{
						id = 4,
						start = 120000,
						end = 120000,
						name = "the_end",
						values = {
							{kind = .Position, position = {1, -2, 3}},
							{kind = .Asset, index = 0},
						},
					},
				},
			},
		},
		guids     = {SOUND},
	}
	return aligned(cutscene_write(contents, context.temp_allocator))
}

@(test)
event_tracks_round_trip :: proc(t: ^testing.T) {
	data := event_cutscene()
	blob, ok := cutscene_view(data)
	if !testing.expect(t, ok) {
		return
	}
	tracks := cutscene_tracks(data, blob)
	testing.expect_value(t, tracks[0].event_count, 0)
	testing.expect_value(t, tracks[1].first_event, 0)
	testing.expect_value(t, tracks[1].event_count, 2)
	testing.expect_value(t, tracks[2].first_event, 2)
	story := cutscene_track_events(data, blob, tracks[1])
	testing.expect_value(t, blob_string(data, story[0].name), "begun")
	testing.expect_value(t, story[0].flags, Cutscene_Event_Flags{.Fire_When_Skipped})
	testing.expect_value(t, story[1].end, 90000)
	alarm := cutscene_values_of(data, blob, story[1])
	testing.expect_value(t, blob_string(data, alarm[0].text), "red")
	gate := cutscene_track_events(data, blob, tracks[2])
	door := cutscene_values_of(data, blob, gate[0])
	testing.expect_value(t, len(door), 4)
	testing.expect_value(t, door[0].number, 2.5)
	testing.expect_value(t, door[1].index, 1)
	testing.expect_value(t, door[2].vector, [3]f32{0, 1, 0})
	testing.expect_value(t, door[3].kind, Cutscene_Value_Kind.Entity)
	end := cutscene_values_of(data, blob, gate[1])
	testing.expect_value(t, end[0].position, [3]i64{1, -2, 3})
	testing.expect_value(t, end[1].kind, Cutscene_Value_Kind.Asset)
	references, references_ok := blob_references(data, context.temp_allocator)
	testing.expect(t, references_ok)
	found := false
	for r in references {
		found ||= r == SOUND
	}
	testing.expect(t, found, "an asset value is a reference")
}

@(test)
event_tracks_with_bad_events_are_refused :: proc(t: ^testing.T) {
	data := event_cutscene()
	blob, ok := cutscene_view(data)
	if !testing.expect(t, ok) {
		return
	}
	refused :: proc(t: ^testing.T, data: []byte, what: string) {
		_, ok := cutscene_view(data)
		testing.expect(t, !ok, what)
	}
	tracks := cutscene_tracks(data, blob)
	events := cutscene_events(data, blob)
	values := cutscene_event_values(data, blob)

	tracks[0].event_count = 1
	refused(t, data, "a transform track with events")
	tracks[0].event_count = 0
	tracks[1].finish = .Keep
	refused(t, data, "an event track that keeps")
	tracks[1].finish = .Restore
	tracks[1].first_event = 1
	refused(t, data, "an event track whose events do not follow the track before it")
	tracks[1].first_event = 0
	tracks[2].event_count = 3
	refused(t, data, "an event track whose events are past the table")
	tracks[2].event_count = 2
	tracks[0].kind = .Event
	refused(t, data, "an event track with sections")
	tracks[0].kind = .Transform

	events[0].end = 10
	refused(t, data, "a trigger whose end is not its start")
	events[0].end = 0
	events[1].end = events[1].start
	refused(t, data, "a range that ends at its start")
	events[1].end = 90000
	events[1].flags -= {.Range}
	refused(t, data, "a range without the Range flag")
	events[1].flags += {.Range}
	events[3].end = 120001
	events[3].start = 120001
	refused(t, data, "a trigger past the length")
	events[3].start = 120000
	events[3].end = 120000
	events[0].start = 40000
	events[0].end = 40000
	refused(t, data, "a track's events out of start order")
	events[0].start = 0
	events[0].end = 0
	events[0].flags = transmute(Cutscene_Event_Flags)u32(1 << 5 | 1 << 2)
	refused(t, data, "an unknown event flag")
	events[0].flags = {.Fire_When_Skipped}
	events[0].name.size = 0
	refused(t, data, "an event without a name")
	events[0].name.size = 5
	events[2].value_count = MAX_CUTSCENE_EVENT_VALUES + 1
	refused(t, data, "an event with too many values")
	events[2].value_count = 4

	// The values: alarm's string, then door_open's number, bool, vector and entity, then the_end's position and asset.
	values[1].number = math.inf_f64(1)
	refused(t, data, "a number that is not finite")
	values[1].number = 2.5
	values[2].index = 2
	refused(t, data, "a bool that is not 0 or 1")
	values[2].index = 1
	values[4].index = 1
	refused(t, data, "an entity past the bindings")
	values[4].index = 0
	values[6].index = 1
	refused(t, data, "an asset past the GUIDs")
	values[6].index = 0
	values[5].position.x = WORLD_POSITION_LIMIT + 1
	refused(t, data, "a position past the limit")
	values[5].position.x = 1
	values[3].number = 1
	refused(t, data, "a vector with a number")
	values[3].number = 0
	values[0].text.size = u32(len(data))
	refused(t, data, "a string past the end")
	values[0].text.size = 3
	values[0].kind = Cutscene_Value_Kind(7)
	refused(t, data, "an unknown kind of value")
	values[0].kind = .String
	values[0].reserved = 1
	refused(t, data, "a value's reserved word that is not 0")
	values[0].reserved = 0

	_, ok = cutscene_view(data)
	testing.expect(t, ok, "the blob as it was")
}

// presentation_cutscene has an audio track with a line, and a presentation track with a fade, a letterbox and a subtitle
// of that line.
@(private = "file")
presentation_cutscene :: proc() -> []byte {
	opacity := []Cutscene_Key {
		{time = 0, value = 1, interp = .Linear},
		{time = 30000, value = 0, interp = .Linear},
	}
	aspect := []Cutscene_Key{{time = 0, value = 2.39, interp = .Constant}}
	contents := Cutscene_Contents {
		length     = 120000,
		rate       = 30,
		range_end  = 120000,
		skip_color = {16, 32, 48},
		tracks     = {
			{
				id = 1,
				kind = .Audio,
				name = "Dialogue",
				binding = CUTSCENE_NONE,
				gain = 1,
				sections = {
					{
						id = 1,
						start = 30000,
						end = 90000,
						weight = 1,
						asset = SOUND,
						speed = 1,
						max_distance = 50,
					},
				},
			},
			{
				id = 2,
				kind = .Presentation,
				name = "Presentation",
				binding = CUTSCENE_NONE,
				flags = {.Follow_Camera},
				sections = {
					{
						id = 2,
						start = 0,
						end = 30000,
						weight = 1,
						presentation = {kind = .Fade, color = {255, 0, 0}},
						channels = {{name = CUTSCENE_FADE_OPACITY, keys = opacity}},
					},
					{
						id = 3,
						start = 0,
						end = 120000,
						weight = 1,
						presentation = {kind = .Letterbox},
						channels = {{name = CUTSCENE_LETTERBOX_ASPECT, keys = aspect}},
					},
					{
						id = 4,
						start = 30000,
						end = 90000,
						weight = 1,
						presentation = {
							kind = .Subtitle,
							speaker = "Fox",
							text = "Over here.",
							key = "intro.fox",
							audio = 0,
						},
					},
				},
			},
		},
		guids      = {SOUND},
	}
	return aligned(cutscene_write(contents, context.temp_allocator))
}

@(test)
presentation_tracks_round_trip :: proc(t: ^testing.T) {
	data := presentation_cutscene()
	blob, ok := cutscene_view(data)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, blob.skip_color, Ui_Color{16, 32, 48, 255})
	rows := cutscene_presentations(data, blob)
	testing.expect_value(t, len(rows), 3)
	fade, found := cutscene_presentation_of(data, blob, 1)
	testing.expect(t, found)
	testing.expect_value(t, fade.kind, Cutscene_Presentation_Kind.Fade)
	testing.expect_value(t, fade.color, Ui_Color{255, 0, 0, 255})
	testing.expect_value(t, fade.audio, CUTSCENE_NONE)
	line, _ := cutscene_presentation_of(data, blob, 3)
	testing.expect_value(t, line.kind, Cutscene_Presentation_Kind.Subtitle)
	testing.expect_value(t, blob_string(data, line.speaker), "Fox")
	testing.expect_value(t, blob_string(data, line.text), "Over here.")
	testing.expect_value(t, blob_string(data, line.key), "intro.fox")
	testing.expect_value(t, line.audio, 0)
	_, found = cutscene_presentation_of(data, blob, 0)
	testing.expect(t, !found, "an audio section has no row")
}

@(test)
presentation_tracks_with_bad_rows_are_refused :: proc(t: ^testing.T) {
	data := presentation_cutscene()
	blob, ok := cutscene_view(data)
	if !testing.expect(t, ok) {
		return
	}
	refused :: proc(t: ^testing.T, data: []byte, what: string) {
		_, ok := cutscene_view(data)
		testing.expect(t, !ok, what)
	}
	tracks := cutscene_tracks(data, blob)
	rows := cutscene_presentations(data, blob)
	channels := cutscene_channels(data, blob)

	blob.skip_color.a = 0
	refused(t, data, "a skip color that is not opaque")
	blob.skip_color.a = 255
	tracks[0].flags = {.Follow_Camera}
	refused(t, data, "an audio track that follows the camera")
	tracks[0].flags = {}
	rows[0].section = 2
	refused(t, data, "a row of another section")
	rows[0].section = 1
	rows[0].color.a = 128
	refused(t, data, "a fade that is not opaque")
	rows[0].color.a = 255
	rows[1].color = {1, 1, 1, 255}
	refused(t, data, "a letterbox with a color")
	rows[1].color = {}
	rows[1].text = rows[2].text
	refused(t, data, "a letterbox with text")
	rows[1].text = {}
	rows[2].text.size = u32(len(data))
	refused(t, data, "a subtitle's text past the end")
	rows[2].text.size = 10
	rows[2].audio = 2
	refused(t, data, "a subtitle of a presentation section")
	rows[2].audio = 7
	refused(t, data, "a subtitle of a section past the sections")
	rows[2].audio = 0
	rows[2].kind = Cutscene_Presentation_Kind(3)
	refused(t, data, "an unknown kind")
	rows[2].kind = .Subtitle
	rows[0].kind = .Letterbox
	refused(t, data, "a letterbox with an opacity channel")
	rows[0].kind = .Fade
	saved := channels[1].name
	channels[1].name = channels[0].name
	refused(t, data, "a letterbox with an opacity channel's name")
	channels[1].name = saved
	blob.presentations.size -= size_of(Cutscene_Presentation)
	refused(t, data, "a presentation section without a row")
	blob.presentations.size += size_of(Cutscene_Presentation)

	_, ok = cutscene_view(data)
	testing.expect(t, ok, "the blob as it was")
}

@(test)
markers_cook_in_time_order_and_bad_ones_are_refused :: proc(t: ^testing.T) {
	data := cutscene_write(
		{
			length = 60000,
			rate = 30,
			range_end = 60000,
			markers = {
				{id = 2, time = 30000, name = "Late", color = {1, 2, 3}},
				{id = 3, time = 0, name = "First"},
				{id = 1, time = 30000, name = "Tie"},
			},
		},
		context.temp_allocator,
	)
	blob, ok := cutscene_view(data)
	if !testing.expect(t, ok) {
		return
	}
	markers := cutscene_markers(data, blob)
	testing.expect_value(t, len(markers), 3)
	if len(markers) != 3 {
		return
	}
	// In time order, and at one time, in ID order.
	testing.expect_value(t, markers[0].id, 3)
	testing.expect_value(t, markers[1].id, 1)
	testing.expect_value(t, markers[2].id, 2)
	testing.expect_value(t, blob_string(data, markers[2].name), "Late")
	testing.expect_value(t, markers[2].color, Ui_Color{1, 2, 3, 255})

	refused :: proc(t: ^testing.T, data: []byte, what: string) {
		_, ok := cutscene_view(data)
		testing.expect(t, !ok, what)
	}
	markers[2].time = 60001
	refused(t, data, "a marker past the length")
	markers[2].time = 30000
	markers[0].time = -1
	refused(t, data, "a marker before 0")
	markers[0].time = 0
	markers[1].id = 3
	markers[1].time = 0
	refused(t, data, "two markers with one time out of ID order")
	markers[1].time = 30000
	markers[1].id = 1
	markers[0].time = 45000
	refused(t, data, "markers out of time order")
	markers[0].time = 0
	markers[0].color.a = 0
	refused(t, data, "a marker that is not opaque")
	markers[0].color.a = 255
	markers[0].name.size = 0
	refused(t, data, "a marker without a name")
	markers[0].name.size = 5
	markers[0].name.offset = u32(len(data))
	refused(t, data, "a marker's name outside the blob")
	markers[0].name.offset = u32(blob.markers.offset)
	blob.markers.size += 1
	refused(t, data, "a marker table of part of a record")
	blob.markers.size -= 1
	blob.markers.offset = u32(len(data))
	refused(t, data, "a marker table outside the blob")
}
