package cook

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
SCENE_GUID :: "0123456789abcdef0123456789abcdef"
@(private = "file")
PREFAB_GUID :: "11111111111111111111111111111111"
@(private = "file")
MODEL_GUID :: "22222222222222222222222222222222"
@(private = "file")
CLIP_GUID :: "33333333333333333333333333333333"
@(private = "file")
SOUND_GUID :: "44444444444444444444444444444444"
@(private = "file")
SHOT_GUID :: "55555555555555555555555555555555"
@(private = "file")
INTRO_GUID :: "66666666666666666666666666666666"

@(private = "file")
SHOT :: `cutscene 1
length = 60000
`

// BOUND_SHOT is a shot with a binding of its own, which the intro's sub-sequence binds to the fox.
@(private = "file")
BOUND_SHOT ::
	`cutscene 1
length = 60000
binding 7 "Actor"
	possess = @` +
	SCENE_GUID +
	`/0000000000000001
	policy = optional
`

@(private = "file")
INTRO ::
	`cutscene 1
# A fox that walks beside a guard that the cutscene spawns, to a bark, after a shot.
length = 600000
rate = 24
clock = real
range = [6000, 594000]

binding 1 "Walking Fox"
	possess = @` +
	SCENE_GUID +
	`/79cea6d7586e3f48
	policy = optional
binding 2 "Extra Guard"
	spawn = $` +
	PREFAB_GUID +
	`
	position = [150000000000, 0, -0.5]
	rotation = [0, 0.6, 0, 0.8]
	scale = [1, 2, 1]
binding 3 "Lantern"
	spawn = $` +
	PREFAB_GUID +
	`
	parent = 2

track 1 transform "Fox walk"
	binding = 1
	when_finished = keep
	section 1 0 600000
		ease_in = 6000
		ease_out = 3000
		pre_roll = 1500
		post_roll = 2500
		channel position_x
			key 0 0 linear
			key 300000 2 bezier 0.5 -0.25 weights 0.25 0.5
			key 600000 4 constant
		channel rotation_y
			key 0 90 constant
track 2 animation "Fox clip"
	binding = 1
	section 2 0 600000
		weight = 0.5
		asset = $` +
	CLIP_GUID +
	`
track 3 audio "Bark"
	muted = true
	section 3 120000 180000
		asset = $` +
	SOUND_GUID +
	`
		channel gain
			key 0 1 linear
track 4 sub_sequence "Opening shot"
	section 4 0 60000
		asset = $` +
	SHOT_GUID +
	`
		trim = 6000 30000
		scale = 2
		loop = true
		bind 7 = 1
track 5 camera_cut ""
	section 5 0 600000
		camera = 2
`

@(test)
cutscenes_parse_their_header_bindings_tracks_sections_and_keys :: proc(t: ^testing.T) {
	parsed, problems := cutscene_parse(INTRO, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	c := parsed.contents
	testing.expect_value(t, c.length, 600000)
	testing.expect_value(t, c.rate, 24)
	testing.expect_value(t, c.clock, format.Cutscene_Clock.Real)
	testing.expect_value(t, c.range_start, 6000)
	testing.expect_value(t, c.range_end, 594000)
	if len(c.bindings) != 3 || len(c.tracks) != 5 {
		testing.expectf(t, false, "%d bindings and %d tracks", len(c.bindings), len(c.tracks))
		return
	}
	scene, _ := format.guid_parse(SCENE_GUID)
	prefab, _ := format.guid_parse(PREFAB_GUID)
	fox := c.bindings[0]
	testing.expect_value(t, fox.id, 1)
	testing.expect_value(t, fox.name, "Walking Fox")
	testing.expect_value(t, fox.kind, format.Cutscene_Binding_Kind.Possessed)
	testing.expect_value(t, fox.policy, format.Cutscene_Policy.Optional)
	testing.expect_value(t, fox.asset, scene)
	testing.expect_value(t, fox.entity, 0x79cea6d7586e3f48)
	testing.expect_value(t, fox.parent, format.CUTSCENE_NONE)
	guard := c.bindings[1]
	testing.expect_value(t, guard.kind, format.Cutscene_Binding_Kind.Spawned)
	testing.expect_value(t, guard.asset, prefab)
	testing.expect_value(t, guard.position, [3]i64{150_000_000_000 << 24, 0, -(1 << 23)})
	testing.expect_value(t, guard.rotation, [4]f32{0, 0.6, 0, 0.8})
	testing.expect_value(t, guard.scale, [3]f32{1, 2, 1})
	lantern := c.bindings[2]
	testing.expect_value(t, lantern.parent, 1)
	testing.expect_value(t, lantern.rotation, [4]f32{0, 0, 0, 1})
	testing.expect_value(t, lantern.scale, [3]f32{1, 1, 1})
	testing.expect_value(t, lantern.position, [3]i64{})

	walk := c.tracks[0]
	testing.expect_value(t, walk.kind, format.Cutscene_Track_Kind.Transform)
	testing.expect_value(t, walk.name, "Fox walk")
	testing.expect_value(t, walk.binding, 0)
	testing.expect_value(t, walk.finish, format.Cutscene_Finish.Keep)
	testing.expect_value(t, len(walk.sections), 1)
	section := walk.sections[0]
	testing.expect_value(t, section.ease_in, 6000)
	testing.expect_value(t, section.ease_out, 3000)
	testing.expect_value(t, section.pre_roll, 1500)
	testing.expect_value(t, section.post_roll, 2500)
	testing.expect_value(t, section.weight, 1)
	testing.expect_value(t, len(section.channels), 2)
	keys := section.channels[0].keys
	testing.expect_value(t, len(keys), 3)
	testing.expect_value(t, keys[1].time, 300000)
	testing.expect_value(t, keys[1].interp, format.Cutscene_Interp.Bezier)
	testing.expect_value(t, keys[1].flags, format.Cutscene_Key_Flags{.Broken, .Weighted})
	testing.expect_value(t, keys[1].in_slope, 0.5)
	testing.expect_value(t, keys[1].out_slope, -0.25)
	testing.expect_value(t, keys[1].in_weight, 0.25)
	testing.expect_value(t, keys[1].out_weight, 0.5)
	testing.expect_value(t, keys[2].interp, format.Cutscene_Interp.Constant)
	testing.expect_value(t, c.tracks[1].sections[0].weight, 0.5)
	testing.expect_value(t, c.tracks[1].finish, format.Cutscene_Finish.Restore)
	testing.expect_value(t, c.tracks[2].flags, format.Cutscene_Track_Flags{.Muted})
	testing.expect_value(t, c.tracks[2].binding, format.CUTSCENE_NONE)
	testing.expect_value(t, c.tracks[2].sections[0].start, 120000)
	testing.expect_value(t, c.tracks[4].name, "")
	shot := c.tracks[3].sections[0]
	testing.expect_value(t, shot.offset, 6000)
	testing.expect_value(t, shot.trim_end, 30000)
	testing.expect_value(t, shot.speed, 2)
	testing.expect_value(t, shot.flags, format.Cutscene_Section_Flags{.Loop})
	testing.expect_value(t, len(shot.bindings), 1)
	testing.expect_value(t, shot.bindings[0], format.Cutscene_Binding_Map_Contents{7, 0})

	testing.expect_value(t, len(parsed.references), 6)
	wants := [?]format.Asset_Kind{.Scene, .Prefab, .Prefab, .Animation, .Audio, .Cutscene}
	for r, i in parsed.references {
		testing.expect_value(t, r.want, wants[i])
	}
	testing.expect_value(t, parsed.references[0].line, 9)

	// Without settings, the header's defaults.
	plain, plain_problems := cutscene_parse(CUTSCENE_TEMPLATE, context.temp_allocator)
	testing.expectf(t, len(plain_problems) == 0, "the template: %v", plain_problems)
	testing.expect_value(t, plain.contents.rate, 30)
	testing.expect_value(t, plain.contents.clock, format.Cutscene_Clock.Game)
	testing.expect_value(t, plain.contents.range_start, 0)
	testing.expect_value(t, plain.contents.range_end, 600000)
	// A new cutscene's one track is its camera cut track, with no sections yet.
	if testing.expect_value(t, len(plain.contents.tracks), 1) {
		testing.expect_value(
			t,
			plain.contents.tracks[0].kind,
			format.Cutscene_Track_Kind.Camera_Cut,
		)
		testing.expect_value(t, len(plain.contents.tracks[0].sections), 0)
	}
	// The editor's tests read the template from testdata, which a checkout may give other line endings.
	shared_text, _ := strings.replace_all(
		#load("testdata/cutscenes/template.cutscene", string),
		"\r\n",
		"\n",
		context.temp_allocator,
	)
	testing.expect_value(t, shared_text, CUTSCENE_TEMPLATE)
}

@(test)
each_mistake_in_a_cutscene_is_reported_at_its_line :: proc(t: ^testing.T) {
	S :: "@" + SCENE_GUID + "/0000000000000001"
	P :: "$" + PREFAB_GUID
	// A binding and a property track of it, which names its field, on lines 3 to 8.
	LAMP ::
		"binding 1 \"A\"\n\tpossess = " +
		S +
		"\ntrack 1 property \"L\"\n\tbinding = 1\n\tcomponent = 9101\n\tfield = \"intensity\"\n"
	// Two bindings and a transform track of the first, on lines 3 to 8.
	MOVE ::
		"binding 1 \"A\"\n\tpossess = " +
		S +
		"\nbinding 2 \"B\"\n\tpossess = " +
		S +
		"\ntrack 1 transform \"M\"\n\tbinding = 1\n"
	// Two bindings and a camera cut track, on lines 3 to 7. The track's sections show binding 1.
	CUT ::
		"binding 1 \"A\"\n\tpossess = " +
		S +
		"\nbinding 2 \"B\"\n\tpossess = " +
		S +
		"\ntrack 1 camera_cut \"C\"\n"
	// A binding and an animation track of it, with a section of a clip, on lines 3 to 8.
	ACTS ::
		"binding 1 \"A\"\n\tpossess = " +
		S +
		"\ntrack 1 animation \"N\"\n\tbinding = 1\n\tsection 1 0 10\n\t\tasset = $" +
		CLIP_GUID +
		"\n"
	// An audio track with a section of a sound, on lines 3 to 5.
	SOUNDS ::
		"cutscene 1\nlength = 10\ntrack 1 audio \"A\"\n\tsection 1 0 10\n\t\tasset = $" +
		SOUND_GUID +
		"\n"
	// A binding that suspends nothing and a global event track, on lines 3 to 6.
	EVENTS ::
		"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
		S +
		"\n\tsuspend = []\ntrack 1 event \"E\"\n"
	// The same with a trigger, on lines 3 to 7.
	TRIGGER :: EVENTS + "\ttrigger 1 5 a\n"
	// A binding and a sub-sequence track with a section of a shot, on lines 3 to 7.
	SUB ::
		"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
		S +
		"\ntrack 1 sub_sequence \"S\"\n\tsection 1 0 10\n\t\tasset = $" +
		SHOT_GUID +
		"\n"
	// A presentation track with a section, on lines 3 and 4.
	PRESENT :: "cutscene 1\nlength = 10\ntrack 1 presentation \"P\"\n\tsection 1 0 10\n"
	cases := [?]struct {
		text:     string,
		line:     int,
		fragment: string,
	} {
		{"scene 1\n", 1, "starts with `cutscene 1`"},
		{"", 1, "starts with `cutscene 1`"},
		{"cutscene 1\n", 1, "has a length"},
		{"cutscene 1\nlength = 0\n", 2, "length is a whole number"},
		{"cutscene 1\nlength = 1.5\n", 2, "length is a whole number"},
		{"cutscene 1\nlength = -1\n", 2, "length is a whole number"},
		{"cutscene 1\nlength = 2147483648\n", 2, "length is a whole number"},
		{"cutscene 1\nlength = 10\nlength = 10\n", 3, "set twice"},
		{"cutscene 1\nlength = 10\nrate = 29\n", 3, "rate is 24"},
		{"cutscene 1\nlength = 10\nclock = wall\n", 3, "clock is game or real"},
		{"cutscene 1\nlength = 10\nrange = [5]\n", 3, "range is two"},
		{"cutscene 1\nlength = 10\nrange = [5, 11]\n", 3, "inside the length"},
		{"cutscene 1\nlength = 10\nrange = [5, 5]\n", 3, "inside the length"},
		{"cutscene 1\nlength = 10\nspeed = 2\n", 3, "not a setting of the cutscene"},
		{"cutscene 1\nlength = 10\nsuspend = [ai, sleep]\n", 3, "suspend is a list"},
		{"cutscene 1\nlength = 10\nsuspend = [ai, ai]\n", 3, "suspend is a list"},
		{"cutscene 1\nlength = 10\nsuspend = ai\n", 3, "suspend is a list"},
		{"cutscene 1\nlength = 10\nsuspend = [ai,]\n", 3, "suspend is a list"},
		{"cutscene 1\nlength = 10\ninput_context = cutscene\n", 3, "input_context is the quoted"},
		{
			"cutscene 1\nlength = 10\ninput_context = \"a_context_name_of_25_byte\"\n",
			3,
			"at most 24 bytes",
		},
		{"cutscene 1\nlength = 10\nhide_ui = [" + P + ", 3]\n", 3, "hide_ui is a list"},
		{"cutscene 1\nlength = 10\nhide_ui = " + P + "\n", 3, "hide_ui is a list"},
		{"cutscene 1\nlength = 10\nskip = always\n", 3, "skip is anywhere, none, or a list"},
		{"cutscene 1\nlength = 10\nskip = []\n", 3, "skip is anywhere, none, or a list"},
		{"cutscene 1\nlength = 10\nskip = [0, 5]\n", 3, "skip is anywhere, none, or a list"},
		{
			"cutscene 1\nlength = 10\nskip = [[0, 5] [6, 7]]\n",
			3,
			"skip is anywhere, none, or a list",
		},
		{"cutscene 1\nlength = 10\nskip = [[0, 1.5]]\n", 3, "skip is anywhere, none, or a list"},
		{"cutscene 1\nlength = 10\nskip = [[0, 11]]\n", 3, "inside the length"},
		{"cutscene 1\nlength = 10\nskip = [[5, 5]]\n", 3, "inside the length"},
		{"cutscene 1\nlength = 10\nskip = [[0, 5], [4, 8]]\n", 3, "do not overlap"},
		{"cutscene 1\nlength = 10\nskip_fade = -1\n", 3, "skip_fade is a whole number"},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
			S +
			"\n\tsuspend = [walls]\n",
			5,
			"suspend is a list",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
			S +
			"\n\tkeep_velocity = yes\n",
			5,
			"keep_velocity is true or false",
		},
		{"cutscene 1\nlength = 10\nwhat\n", 3, "a line is binding"},
		{"cutscene 1\nlength = 10\nbinding 0 \"A\"\n\tpossess = " + S + "\n", 3, "a binding is"},
		{"cutscene 1\nlength = 10\nbinding 1 A\n\tpossess = " + S + "\n", 3, "a binding is"},
		{"cutscene 1\nlength = 10\nbinding 1 \"\"\n\tpossess = " + S + "\n", 3, "a binding is"},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
			S +
			"\nbinding 1 \"B\"\n\tpossess = " +
			S +
			"\n",
			5,
			"a binding with the ID 1",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
			S +
			"\nbinding 2 \"A\"\n\tpossess = " +
			S +
			"\n",
			5,
			"a binding named \"A\"",
		},
		{"cutscene 1\nlength = 10\nbinding 1 \"A\"\n", 3, "possesses an entity with possess"},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
			S +
			"\n\tspawn = " +
			P +
			"\n",
			5,
			"not both",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = @0001\n",
			4,
			"an entity of a scene",
		},
		{"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = @xyz/1\n", 4, "possess: "},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " + S + "\n\tpolicy = maybe\n",
			5,
			"policy is required",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
			S +
			"\n\tscale = [1, 1, 1]\n",
			5,
			"scale is for a spawned binding",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tspawn = " + P + "\n\tpolicy = optional\n",
			5,
			"policy is for a possessed",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tspawn = $abc\n",
			4,
			"spawn is $<prefab guid>",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tspawn = " + P + "\n\tparent = 1\n",
			5,
			"a binding before this one",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
			S +
			"\nbinding 2 \"B\"\n\tspawn = " +
			P +
			"\n\tparent = 1\n",
			7,
			"parent is a spawned binding",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tspawn = " +
			P +
			"\n\tposition = [1e300, 0, 0]\n",
			5,
			"position is three",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tspawn = " +
			P +
			"\n\trotation = [0, 0, 0, 0]\n",
			5,
			"rotation is a quaternion",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tspawn = " + P + "\n\tscale = [1, 0, 1]\n",
			5,
			"none of them 0",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tspawn = " + P + "\n\tcolor = 1\n",
			5,
			"not a setting of a binding",
		},
		{"cutscene 1\nlength = 10\ntrack 1 dance \"A\"\n", 3, "not a track's kind"},
		{"cutscene 1\nlength = 10\ntrack x event \"A\"\n", 3, "a track is"},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\ntrack 1 event \"B\"\n",
			4,
			"a track with the ID 1",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 transform \"A\"\n",
			3,
			"a transform track needs a binding",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 camera_cut \"A\"\n\tbinding = 1\n",
			4,
			"a camera_cut track has no binding",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 camera_cut \"A\"\ntrack 2 camera_cut \"B\"\n",
			4,
			"a camera_cut track at line 3 already",
		},
		{"cutscene 1\nlength = 10\n" + CUT + "\tsection 1 0 10\n", 8, "camera = <binding id>"},
		{
			"cutscene 1\nlength = 10\n" + CUT + "\tsection 1 0 10\n\t\tcamera = 3\n",
			9,
			"camera is the ID of a binding",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 10\n\t\tcamera = 1\n\t\tease_in = 2\n",
			10,
			"it has no ease_in",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 10\n\t\tcamera = 1\n\t\tweight = 0.5\n",
			10,
			"it has no weight",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 10\n\t\tcamera = 1\n\t\tblend = additive\n",
			10,
			"cannot be additive",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 10\n\t\tcamera = 1\n\t\tchannel x\n\t\t\tkey 0 0 linear\n",
			10,
			"has no channels",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 6\n\t\tcamera = 1\n\tsection 2 5 10\n\t\tcamera = 1\n",
			10,
			"do not overlap",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 5\n\t\tcamera = 1\n\tsection 2 5 10\n\t\tcamera = 1\n\t\tblend_in = 2\n",
			12,
			"blends in only from gameplay",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 5\n\t\tcamera = 1\n\t\tblend_out = 2\n\tsection 2 5 10\n\t\tcamera = 1\n",
			10,
			"blends out only to gameplay",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 5\n\t\tcamera = 1\n\t\tblend_in = 6\n",
			10,
			"at most the section's duration (5)",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 5\n\t\tcamera = 1\n\t\tblend_in = 2 bouncy\n",
			10,
			"linear (the default), smooth",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 5\n\t\tcamera = 1\n\t\tblend_on_skip = true\n",
			10,
			"blend_on_skip is for a section with a blend_out",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 5\n\t\tcamera = 1\n\t\tlook_at = 1\n",
			10,
			"look_at names the camera itself",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 5\n\t\tcamera = 1\n\t\tfollow = 9\n",
			10,
			"follow is the ID of a binding",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 5\n\t\tcamera = 1\n\t\tlook_at_damping = 3\n",
			10,
			"look_at_damping is for look_at = <binding id>",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 5\n\t\tcamera = 1\n\t\tfocus_offset = [0, 0, 0]\n",
			10,
			"is not a setting of a section",
		},
		{
			"cutscene 1\nlength = 10\n" +
			CUT +
			"\tsection 1 0 5\n\t\tcamera = 1\n\t\tchannel x\n\t\t\tkey 0 0 linear\n\t\tcamera = 1\n",
			12,
			"camera comes before the section's channels",
		},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\tsection 1 0 5\n\t\tcamera = 2\n",
			10,
			"only a camera_cut section has a camera",
		},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\tsection 1 0 5\n\t\tfocus = 2\n",
			10,
			"only a camera_cut section, or a camera binding, has constraints",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " + S + "\n\tlook_at = 1\n",
			5,
			"constraints are on a camera binding",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tbinding = 4\n",
			4,
			"the ID of a binding",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tmuted = yes\n",
			4,
			"muted is true or false",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\twhen_finished = undo\n",
			4,
			"when_finished is restore",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tweight = 1\n",
			4,
			"not a setting of a track",
		},
		{"cutscene 1\nlength = 10\nsection 1 0 10\n", 3, "a section comes after a track"},
		{"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 1.5\n", 4, "a section is"},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 5 5\n",
			4,
			"starts before it ends",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 11\n",
			4,
			"at most at the length",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 5\ntrack 2 event \"B\"\n\tsection 1 5 10\n",
			6,
			"a section with the ID 1",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\tbinding = 1\n",
			5,
			"comes before the track's sections",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tease_in = 6\n\t\tease_out = 5\n",
			4,
			"together are at most",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tease_in = -1\n",
			5,
			"ease_in is a whole number",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tpost_roll = 1.5\n",
			5,
			"post_roll is a whole number",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tweight = 2\n",
			5,
			"weight is a number from 0 to 1",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tasset = " +
			P +
			"\n",
			5,
			"an event section has no asset",
		},
		{"cutscene 1\nlength = 10\ntrack 1 audio \"A\"\n\tsection 1 0 10\n", 4, "names its sound"},
		{
			"cutscene 1\nlength = 10\ntrack 1 audio \"A\"\n\tsection 1 0 10\n\t\tasset = 12\n",
			5,
			"asset is $<guid>",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tvolume = 1\n",
			5,
			"not a setting of a section",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tchannel x\n",
			4,
			"a channel comes after a section",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel 1x\n\t\t\tkey 0 0 linear\n",
			5,
			"a channel is",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n",
			5,
			"has no keys",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 linear\n\t\tchannel x\n\t\t\tkey 0 0 linear\n",
			7,
			"a channel named x already",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 linear\n\t\tweight = 1\n",
			7,
			"comes before the section's channels",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tkey 0 0 linear\n",
			5,
			"a key comes after a channel",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0\n",
			6,
			"a key is",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 11 0 linear\n",
			6,
			"duration (10)",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 1.5 0 linear\n",
			6,
			"a key's time",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 inf linear\n",
			6,
			"a finite number",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 smooth\n",
			6,
			"not an interpolation",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 cubic\n",
			6,
			"not an interpolation",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 bezier\n",
			6,
			"one slope, or an in and an out slope",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 bezier 1 2 3\n",
			6,
			"one slope, or an in and an out slope",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 bezier 1 nan\n",
			6,
			"slopes are finite numbers",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 bezier 1 weights 0.5\n",
			6,
			"weights is followed by an in and an out weight",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 bezier 1 weights 0.5 1.5\n",
			6,
			"weights are numbers from 0 to 1",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 auto 1\n",
			6,
			"an auto key has no tangents",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 16777217 constant\n",
			6,
			"not exact as a key's value",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 $12 constant\n",
			6,
			"a key's asset is $<guid>",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 " +
			P +
			" linear\n",
			6,
			"a key of an asset is constant",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 " +
			P +
			" constant\n",
			5,
			"only a property track keys assets",
		},
		{
			"cutscene 1\nlength = 10\n" +
			LAMP +
			"\tsection 1 0 10\n\t\tchannel value\n\t\t\tkey 0 " +
			P +
			" constant\n\t\t\tkey 5 1 constant\n",
			10,
			"all assets or all numbers",
		},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
			S +
			"\ntrack 1 property \"L\"\n\tbinding = 1\n\tfield = \"intensity\"\n",
			5,
			"names its field with component",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tcomponent = 5\n",
			4,
			"only a property track names a field",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tfield = \"x\"\n",
			4,
			"only a property track names a field",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 property \"A\"\n\tcomponent = light\n",
			4,
			"component is a component's stable ID",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 property \"A\"\n\tfield = \"light..intensity\"\n",
			4,
			"field is the quoted name of a field",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\tcomponent = 5\n",
			5,
			"comes before the track's sections",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tblend = over\n",
			5,
			"blend is absolute or additive",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tblend = additive\n",
			5,
			"an event section cannot be additive",
		},
		{
			"cutscene 1\nlength = 10\n" +
			LAMP +
			"\tsection 1 0 10\n\t\tchannel w\n\t\t\tkey 0 0 linear\n",
			10,
			"a property track's channel is value",
		},
		{
			"cutscene 1\nlength = 10\n" +
			LAMP +
			"\tsection 1 0 10\n\t\tchannel value\n\t\t\tkey 0 0 linear\n\t\tchannel x\n\t\t\tkey 0 0 linear\n",
			12,
			"keys value alone",
		},
		{
			"cutscene 1\nlength = 10\n" +
			LAMP +
			"\tsection 1 0 10\n\t\tchannel r\n\t\t\tkey 0 0 linear\n\t\tchannel y\n\t\t\tkey 0 0 linear\n",
			12,
			"keys value alone",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 linear 1 1\n",
			6,
			"a linear key has no tangents",
		},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\tspace = sideways\n",
			9,
			"space is absolute, relative",
		},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\tspace = relative B\n",
			9,
			"space is absolute, relative",
		},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\tspace = relative 9\n",
			9,
			"names a binding of the cutscene",
		},
		{"cutscene 1\nlength = 10\n" + MOVE + "\tspace = relative 1\n", 9, "has space = relative"},
		{"cutscene 1\nlength = 10\n" + MOVE + "\torigin = [1, 2]\n", 9, "origin is three numbers"},
		{"cutscene 1\nlength = 10\n" + MOVE + "\torigin = [1, 2, 1e30]\n", 9, "inside the bounds"},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\torigin = [1, 2, 3]\n",
			9,
			"origin is for space = absolute",
		},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\tsection 1 0 10\n\t\tspace = absolute\n",
			10,
			"comes before the track's sections",
		},
		{
			"cutscene 1\nlength = 10\n" +
			MOVE +
			"\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 linear\n",
			10,
			"a transform track's channel is position_x",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tspace = absolute\n",
			4,
			"only a transform track",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\torigin = [0, 0, 0]\n",
			4,
			"only a transform track",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 linear\n\t\t\tkey 5 1 linear teleport\n",
			7,
			"only a transform track's keys teleport",
		},
		{
			"cutscene 1\nlength = 10\n" +
			MOVE +
			"\tspace = relative 2\ntrack 2 transform \"N\"\n\tbinding = 2\n\tspace = relative 1\n",
			9,
			"relative bindings form a cycle: A -> B -> A",
		},
		{
			"cutscene 1\nlength = 10\n" +
			MOVE +
			"\tspace = relative 2\ntrack 2 transform \"N\"\n\tbinding = 2\n\tspace = relative 1\n",
			12,
			"relative bindings form a cycle: B -> A -> B",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 5 0 linear\n\t\t\tkey 5 1 linear\n",
			7,
			"keys are in order of time",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 linear\n\t\t\tease_in = 1\n",
			7,
			"comes before the section's channels",
		},
		{"cutscene 1\nlength = 10\n" + ACTS + "\t\tspeed = 0\n", 9, "speed is a number above 0"},
		{"cutscene 1\nlength = 10\n" + ACTS + "\t\tspeed = -2\n", 9, "speed is a number above 0"},
		{
			"cutscene 1\nlength = 10\n" + ACTS + "\t\tspeed = 1e39\n",
			9,
			"speed is a number above 0",
		},
		{"cutscene 1\nlength = 10\n" + ACTS + "\t\toffset = 1.5\n", 9, "offset is a whole number"},
		{"cutscene 1\nlength = 10\n" + ACTS + "\t\tloop = yes\n", 9, "loop is true or false"},
		{
			"cutscene 1\nlength = 10\n" + ACTS + "\t\troot_motion = walk\n",
			9,
			"root_motion is bake, apply or in_place",
		},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\tsection 1 0 10\n\t\troot_motion = apply\n",
			10,
			"only an animation section",
		},
		{SOUNDS + "\t\tspeed = 2\n", 6, "an audio section has no speed or root motion"},
		{SOUNDS + "\t\troot_motion = apply\n", 6, "an audio section has no speed or root motion"},
		{SOUNDS + "\t\tpre_roll = 10\n", 6, "an audio section has no pre_roll or post_roll"},
		{SOUNDS + "\t\tbus = 17\n", 6, "bus is a whole number from 0"},
		{SOUNDS + "\t\tbus = 1.5\n", 6, "bus is a whole number from 0"},
		{SOUNDS + "\t\tmin_distance = -1\n", 6, "min_distance is a number of meters"},
		{
			SOUNDS + "\t\tmin_distance = 5\n\t\tmax_distance = 5\n",
			7,
			"max_distance is farther than min_distance",
		},
		{SOUNDS + "\t\tmin_distance = 60\n", 6, "max_distance is farther than min_distance"},
		{SOUNDS + "\t\tplays_through_skip = yes\n", 6, "plays_through_skip is true or false"},
		{SOUNDS + "\t\tchannel volume\n\t\t\tkey 0 1 linear\n", 6, "channel is gain or pitch"},
		{SOUNDS + "\t\tchannel gain\n\t\t\tkey 0 -1 linear\n", 6, "a gain key is a number from 0"},
		{SOUNDS + "\t\tchannel pitch\n\t\t\tkey 0 5 linear\n", 6, "a pitch key is a number from"},
		{SOUNDS + "\t\tchannel pitch\n\t\t\tkey 0 0 linear\n", 6, "a pitch key is a number from"},
		{
			SOUNDS + "\t\tchannel gain\n\t\t\tkey 0 1 linear\n\t\t\tbus = 1\n",
			8,
			"comes before the section's channels",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 audio \"A\"\n\tgain = -1\n",
			4,
			"gain is a number from 0",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 audio \"A\"\n\ttime_scale = slow\n",
			4,
			"time_scale is follow or free",
		},
		{"cutscene 1\nlength = 10\n" + MOVE + "\tgain = 1\n", 9, "only an audio track has a gain"},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\tsection 1 0 10\n\t\tbus = 1\n",
			10,
			"only an audio section has a bus",
		},
		{
			"cutscene 1\nlength = 10\n" +
			MOVE +
			"\tsection 1 0 10\n\t\tplays_through_skip = true\n",
			10,
			"only an audio section has a bus",
		},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\tsection 1 0 10\n\t\tloop = true\n",
			10,
			"only an animation or an audio section has an offset",
		},
		{
			SOUNDS + "\tsection 2 0 10\n\t\tasset = $" + SOUND_GUID + "\n\t\tgain = 1\n",
			8,
			"comes before the track's sections",
		},
		{
			"cutscene 1\nlength = 10\n" +
			ACTS +
			"track 2 animation \"O\"\n\tbinding = 1\n\tsection 2 0 10\n\t\tasset = $" +
			CLIP_GUID +
			"\n",
			9,
			"has an animation track at line 5 already",
		},
		{
			"cutscene 1\nlength = 10\n" +
			ACTS +
			"\t\tchannel x\n\t\t\tkey 0 0 linear\n\t\t\tspeed = 2\n",
			11,
			"comes before the section's channels",
		},
		{EVENTS + "\ttrigger 1 5\n", 7, "a trigger is `trigger <id> <time> <name>`"},
		{EVENTS + "\ttrigger 1 5 a-b\n", 7, "a trigger is `trigger <id> <time> <name>`"},
		{EVENTS + "\trange 1 5 r\n", 7, "a range is `range <id> <start> <end> <name>`"},
		{EVENTS + "\trange 1 5 3 r\n", 7, "a range starts before it ends"},
		{TRIGGER + "\ttrigger 1 6 b\n", 8, "a trigger or a range with the ID 1 already"},
		{EVENTS + "\ttrigger 1 11 a\n", 7, "inside the length (10)"},
		{EVENTS + "\trange 1 5 11 a\n", 7, "inside the length (10)"},
		{EVENTS + "\tsection 1 0 10\n", 7, "an event track has no sections"},
		{EVENTS + "\twhen_finished = keep\n", 7, "an event track has no when_finished"},
		{TRIGGER + "\t\tvalue = number x\n", 8, "a number value is"},
		{TRIGGER + "\t\tvalue = number [1, 2]\n", 8, "a number value is"},
		{TRIGGER + "\t\tvalue = bool yes\n", 8, "a bool value is"},
		{TRIGGER + "\t\tvalue = string red\n", 8, "a string value is"},
		{TRIGGER + "\t\tvalue = vector [1, 2]\n", 8, "a vector value is"},
		{TRIGGER + "\t\tvalue = entity 9\n", 8, "an entity value is the ID of a binding"},
		{TRIGGER + "\t\tvalue = entity x\n", 8, "an entity value is"},
		{TRIGGER + "\t\tvalue = position [1, 2]\n", 8, "a position value is"},
		{TRIGGER + "\t\tvalue = asset $12\n", 8, "an asset value is"},
		{TRIGGER + "\t\tvalue = color 1\n", 8, "a value is `<kind> <value>`"},
		{
			TRIGGER +
			"\t\tvalue = number 1\n\t\tvalue = number 2\n\t\tvalue = number 3\n\t\tvalue = number 4\n\t\tvalue = number 5\n",
			12,
			"at most 4 values",
		},
		{TRIGGER + "\t\tfire_on_seek = yes\n", 8, "fire_on_seek is true or false"},
		{
			TRIGGER + "\t\tfire_when_skipped = true\n\t\tfire_when_skipped = false\n",
			9,
			"fire_when_skipped is set twice",
		},
		{TRIGGER + "\t\tbinding = 1\n", 8, "comes before the track's triggers and ranges"},
		{TRIGGER + "\t\tspeed = 1\n", 8, "is not a setting of a trigger or a range"},
		{EVENTS + "\tvalue = number 1\n", 7, "value is a setting of a trigger or a range"},
		{
			"cutscene 1\nlength = 10\n" + MOVE + "\ttrigger 1 5 a\n",
			9,
			"only an event track has triggers and ranges",
		},
		{"cutscene 1\nlength = 10\ntrigger 1 5 a\n", 3, "a trigger comes after a track line"},
		{
			"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " +
			S +
			"\ntrack 1 event \"E\"\n\tbinding = 1\n",
			6,
			"the binding suspends its behaviours",
		},
		{SUB + "\t\toffset = 5\n", 8, "a sub_sequence section has a trim and a scale"},
		{SUB + "\t\tspeed = 2\n", 8, "a sub_sequence section has a trim and a scale"},
		{SUB + "\t\troot_motion = apply\n", 8, "a sub_sequence section has a trim and a scale"},
		{SUB + "\t\ttrim = 5 5\n", 8, "trim is the sub-sequence's start"},
		{SUB + "\t\ttrim = 5 4\n", 8, "trim is the sub-sequence's start"},
		{SUB + "\t\ttrim = -1\n", 8, "trim is the sub-sequence's start"},
		{SUB + "\t\ttrim = 1.5\n", 8, "trim is the sub-sequence's start"},
		{SUB + "\t\tscale = 0\n", 8, "scale is a number above 0"},
		{SUB + "\t\tscale = fast\n", 8, "scale is a number above 0"},
		{SUB + "\t\tbind 7\n", 8, "a bind is"},
		{SUB + "\t\tbind 7 = x\n", 8, "a bind is"},
		{SUB + "\t\tbind 7 = 2\n", 8, "has no binding with the ID 2"},
		{SUB + "\t\tbind 7 = 1\n\t\tbind 7 = 1\n", 9, "binds the binding 7 already"},
		{SUB + "\t\tchannel x\n\t\t\tkey 0 0 linear\n", 8, "has no channels"},
		{SUB + "\t\tchannel x\n\t\t\tkey 0 0 linear\n\t\tbind 7 = 1\n", 10, "a bind comes after"},
		{SUB + "\tsection 2 5 10\n\t\tasset = $" + SHOT_GUID + "\n", 8, "do not overlap"},
		{
			"cutscene 1\nlength = 10\n" + ACTS + "\t\ttrim = 0\n",
			9,
			"only a sub_sequence section has a trim",
		},
		{
			"cutscene 1\nlength = 10\n" + ACTS + "\t\tscale = 2\n",
			9,
			"only a sub_sequence section has a trim",
		},
		{
			"cutscene 1\nlength = 10\n" + ACTS + "\t\tbind 1 = 1\n",
			9,
			"only a sub_sequence section binds",
		},
		{"cutscene 1\nlength = 10\nbind 1 = 1\n", 3, "a bind comes after a section line"},
		// Presentation tracks: a section on line 4, and its settings from line 5.
		{PRESENT, 4, "a presentation section has a kind"},
		{PRESENT + "\t\tkind = wipe\n", 5, "kind is fade, letterbox or subtitle"},
		{PRESENT + "\t\tkind = fade\n\t\tcolor = #000000\n", 6, "color is a quoted color"},
		{PRESENT + "\t\tkind = fade\n\t\tcolor = \"#00000080\"\n", 6, "without alpha"},
		{PRESENT + "\t\tkind = letterbox\n\t\tcolor = \"#000\"\n", 6, "only a fade has a color"},
		{PRESENT + "\t\tkind = fade\n\t\ttext = \"Hi\"\n", 6, "only a subtitle has a speaker"},
		{PRESENT + "\t\tkind = subtitle\n", 4, "a subtitle section has its text"},
		{PRESENT + "\t\tkind = subtitle\n\t\ttext = Hi\n", 6, "text is quoted text"},
		{
			PRESENT + "\t\tkind = subtitle\n\t\ttext = \"Hi\"\n\t\taudio = 1\n",
			7,
			"audio is the ID of a section of an audio track",
		},
		{
			PRESENT + "\t\tkind = fade\n\t\tchannel amount\n\t\t\tkey 0 1 linear\n",
			6,
			"a fade's channel is opacity",
		},
		{
			PRESENT + "\t\tkind = fade\n\t\tchannel opacity\n\t\t\tkey 0 1.5 linear\n",
			6,
			"opacity keys are numbers from 0 to 1",
		},
		{
			PRESENT + "\t\tkind = letterbox\n\t\tchannel aspect\n\t\t\tkey 0 5 linear\n",
			6,
			"aspect keys are numbers from 1 to 4",
		},
		{
			PRESENT + "\t\tkind = letterbox\n\t\tchannel opacity\n\t\t\tkey 0 1 linear\n",
			6,
			"a letterbox's channels are aspect and amount",
		},
		{
			PRESENT +
			"\t\tkind = subtitle\n\t\ttext = \"Hi\"\n\t\tchannel amount\n\t\t\tkey 0 1 linear\n",
			7,
			"a subtitle has no channels",
		},
		{
			PRESENT +
			"\t\tkind = fade\n\t\tchannel opacity\n\t\t\tkey 0 1 linear\n\t\t\tcolor = \"#fff\"\n",
			8,
			"color comes before the section's channels",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 presentation \"P\"\n\tletterbox_aspect = sensor\n",
			4,
			"letterbox_aspect is camera or sections",
		},
		{SOUNDS + "\t\tkind = fade\n", 6, "only a presentation section has a kind"},
		{
			"cutscene 1\nlength = 10\ntrack 1 audio \"A\"\n\tletterbox_aspect = camera\n",
			4,
			"only a presentation track has a letterbox_aspect",
		},
		{"cutscene 1\nlength = 10\nskip_color = \"black\"\n", 3, "skip_color is a quoted color"},
	}
	for c in cases {
		_, problems := cutscene_parse(c.text, context.temp_allocator)
		hit := false
		for p in problems {
			hit ||= p.line == c.line && strings.contains(p.message, c.fragment)
		}
		testing.expectf(
			t,
			hit,
			"%q: no problem at line %d with %q: %v",
			c.text,
			c.line,
			c.fragment,
			problems,
		)
	}
}

@(test)
bindings_take_the_cutscenes_suspension_unless_they_name_their_own :: proc(t: ^testing.T) {
	S :: "@" + SCENE_GUID + "/0000000000000001"
	UI_GUID :: "77777777777777777777777777777777"
	text :=
		"cutscene 1\nlength = 10\nsuspend = [behaviours, navigation]\ninput_context = \"cinematic\"\nhide_ui = [$" +
		UI_GUID +
		", $" +
		PREFAB_GUID +
		"]\nbinding 1 \"A\"\n\tpossess = " +
		S +
		"\nbinding 2 \"B\"\n\tpossess = " +
		S +
		"\n\tsuspend = [physics, ai]\n\tkeep_velocity = true\nbinding 3 \"C\"\n\tpossess = " +
		S +
		"\n\tsuspend = []\n"
	parsed, problems := cutscene_parse(text, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	c := parsed.contents
	if len(c.bindings) != 3 {
		testing.expectf(t, false, "%d bindings", len(c.bindings))
		return
	}
	testing.expect_value(
		t,
		c.bindings[0].suspend,
		format.Cutscene_Suspend_Set{.Behaviours, .Navigation},
	)
	testing.expect_value(t, c.bindings[0].flags, format.Cutscene_Binding_Flags{})
	testing.expect_value(t, c.bindings[1].suspend, format.Cutscene_Suspend_Set{.AI, .Physics})
	testing.expect_value(t, c.bindings[1].flags, format.Cutscene_Binding_Flags{.Keep_Velocity})
	testing.expect_value(t, c.bindings[2].suspend, format.Cutscene_Suspend_Set{})
	testing.expect_value(t, c.input_context, "cinematic")
	ui, _ := format.guid_parse(UI_GUID)
	prefab, _ := format.guid_parse(PREFAB_GUID)
	testing.expect_value(t, len(c.hide_ui), 2)
	if len(c.hide_ui) == 2 {
		testing.expect_value(t, c.hide_ui[0], ui)
		testing.expect_value(t, c.hide_ui[1], prefab)
	}
	// Each hidden document is a reference that must be a UI document.
	uis := 0
	for r in parsed.references {
		if r.want == .Ui {
			uis += 1
			testing.expect_value(t, r.line, 5)
		}
	}
	testing.expect_value(t, uis, 2)

	// Without settings: every system, the default context, and nothing hidden.
	plain, plain_problems := cutscene_parse(
		"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = " + S + "\n",
		context.temp_allocator,
	)
	testing.expectf(t, len(plain_problems) == 0, "problems: %v", plain_problems)
	testing.expect_value(t, plain.contents.bindings[0].suspend, format.CUTSCENE_SUSPEND_ALL)
	testing.expect_value(t, plain.contents.input_context, format.CUTSCENE_INPUT_CONTEXT)
	testing.expect_value(t, len(plain.contents.hide_ui), 0)

	none, none_problems := cutscene_parse(
		"cutscene 1\nlength = 10\ninput_context = \"\"\n",
		context.temp_allocator,
	)
	testing.expectf(t, len(none_problems) == 0, "problems: %v", none_problems)
	testing.expect_value(t, none.contents.input_context, "")
}

// The skip policy is anywhere by default, with no fade, and a list of ranges in time order makes it ranges.
@(test)
the_skip_policy_is_anywhere_none_or_ranges :: proc(t: ^testing.T) {
	plain, plain_problems := cutscene_parse("cutscene 1\nlength = 10\n", context.temp_allocator)
	testing.expectf(t, len(plain_problems) == 0, "problems: %v", plain_problems)
	testing.expect_value(t, plain.contents.skip, format.Cutscene_Skip.Anywhere)
	testing.expect_value(t, plain.contents.skip_fade, 0)
	testing.expect_value(t, len(plain.contents.skip_ranges), 0)

	none, none_problems := cutscene_parse(
		"cutscene 1\nlength = 10\nskip = none\nskip_fade = 3\n",
		context.temp_allocator,
	)
	testing.expectf(t, len(none_problems) == 0, "problems: %v", none_problems)
	testing.expect_value(t, none.contents.skip, format.Cutscene_Skip.None)
	testing.expect_value(t, none.contents.skip_fade, 3)

	ranged, ranged_problems := cutscene_parse(
		"cutscene 1\nlength = 10\nskip = [[0, 4], [ 4 , 10 ]]\n",
		context.temp_allocator,
	)
	testing.expectf(t, len(ranged_problems) == 0, "problems: %v", ranged_problems)
	testing.expect_value(t, ranged.contents.skip, format.Cutscene_Skip.Ranges)
	testing.expect_value(t, len(ranged.contents.skip_ranges), 2)
	if len(ranged.contents.skip_ranges) == 2 {
		testing.expect_value(t, ranged.contents.skip_ranges[0], format.Cutscene_Skip_Range{0, 4})
		testing.expect_value(t, ranged.contents.skip_ranges[1], format.Cutscene_Skip_Range{4, 10})
	}
}

@(test)
audio_sections_play_their_sound_from_an_offset_on_a_bus :: proc(t: ^testing.T) {
	text :=
		"cutscene 1\nlength = 600000\nbinding 1 \"A\"\n\tpossess = @" +
		SCENE_GUID +
		"/1\ntrack 1 audio \"Music\"\n\tgain = 0.5\n\ttime_scale = free\n\tsection 1 0 300000\n\t\tasset = $" +
		SOUND_GUID +
		"\n\t\toffset = 6000\n\t\tloop = true\n\t\tbus = 1\n\t\tplays_through_skip = true\n\t\tease_out = 30000\n" +
		"\t\tchannel gain\n\t\t\tkey 0 1 linear\n\t\t\tkey 60000 0.5 linear\n\t\tchannel pitch\n\t\t\tkey 0 1 auto\n" +
		"track 2 audio \"Bark\"\n\tbinding = 1\n\tsection 2 60000 120000\n\t\tasset = $" +
		SOUND_GUID +
		"\n\t\tmin_distance = 2\n\t\tmax_distance = 20\n" +
		"track 3 audio \"Line\"\n\tsection 3 0 60000\n\t\tasset = $" +
		SOUND_GUID +
		"\n"
	parsed, problems := cutscene_parse(text, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	if len(parsed.contents.tracks) != 3 {
		return
	}
	music := parsed.contents.tracks[0]
	testing.expect_value(t, music.gain, 0.5)
	testing.expect_value(t, music.time_scale, format.Cutscene_Audio_Scale.Free)
	s := music.sections[0]
	testing.expect_value(t, s.offset, 6000)
	testing.expect_value(t, s.speed, 1)
	testing.expect_value(t, s.flags, format.Cutscene_Section_Flags{.Loop, .Plays_Through_Skip})
	testing.expect_value(t, s.bus, 1)
	testing.expect_value(t, len(s.channels), 2)
	bark := parsed.contents.tracks[1]
	testing.expect_value(t, bark.binding, 0)
	testing.expect_value(t, bark.sections[0].min_distance, 2)
	testing.expect_value(t, bark.sections[0].max_distance, 20)
	// Without settings, a gain of 1, the distances of an Audio_Source, Master and Follow.
	line := parsed.contents.tracks[2]
	testing.expect_value(t, line.gain, 1)
	testing.expect_value(t, line.time_scale, format.Cutscene_Audio_Scale.Follow)
	testing.expect_value(t, line.sections[0].min_distance, 1)
	testing.expect_value(t, line.sections[0].max_distance, 50)
	testing.expect_value(t, line.sections[0].bus, 0)
	// The blob checks.
	blob := format.cutscene_write(parsed.contents, context.temp_allocator)
	aligned := make([]byte, len(blob) + 16, context.temp_allocator)
	start := int(-uintptr(raw_data(aligned)) & 15)
	copy(aligned[start:], blob)
	_, ok := format.cutscene_view(aligned[start:][:len(blob)])
	testing.expect(t, ok, "the blob checks")
}

@(test)
event_tracks_have_triggers_and_ranges_with_values :: proc(t: ^testing.T) {
	text :=
		"cutscene 1\nlength = 600000\nbinding 1 \"Gate\"\n\tpossess = @" +
		SCENE_GUID +
		"/1\n\tsuspend = [ai]\n" +
		"track 1 event \"Gate\"\n\tbinding = 1\n" +
		"\trange 2 200000 300000 alarm\n\t\tfire_on_seek = true\n\t\tvalue = string \"red\"\n" +
		"\ttrigger 1 150000 door_open\n\t\tfire_when_skipped = true\n" +
		"\t\tvalue = number 3.5\n\t\tvalue = bool true\n\t\tvalue = vector [0, 1, 0]\n\t\tvalue = entity 1\n" +
		"track 2 event \"Story\"\n" +
		"\ttrigger 3 600000 the_end\n\t\tvalue = position [1, 2, 3]\n\t\tvalue = asset $" +
		SOUND_GUID +
		"\n"
	parsed, problems := cutscene_parse(text, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	if len(parsed.contents.tracks) != 2 {
		return
	}
	gate := parsed.contents.tracks[0]
	testing.expect_value(t, gate.binding, 0)
	// The track's events are in start order, whatever the text's order.
	if !testing.expect_value(t, len(gate.events), 2) {
		return
	}
	door, alarm := gate.events[0], gate.events[1]
	testing.expect_value(t, door.id, 1)
	testing.expect_value(t, door.name, "door_open")
	testing.expect_value(t, door.start, 150000)
	testing.expect_value(t, door.end, 150000)
	testing.expect_value(t, door.flags, format.Cutscene_Event_Flags{.Fire_When_Skipped})
	if testing.expect_value(t, len(door.values), 4) {
		testing.expect_value(t, door.values[0].kind, format.Cutscene_Value_Kind.Number)
		testing.expect_value(t, door.values[0].number, 3.5)
		testing.expect_value(t, door.values[1].kind, format.Cutscene_Value_Kind.Bool)
		testing.expect_value(t, door.values[1].index, 1)
		testing.expect_value(t, door.values[2].vector, [3]f32{0, 1, 0})
		testing.expect_value(t, door.values[3].kind, format.Cutscene_Value_Kind.Entity)
		testing.expect_value(t, door.values[3].index, 0)
	}
	testing.expect_value(t, alarm.flags, format.Cutscene_Event_Flags{.Range, .Fire_On_Seek})
	testing.expect_value(t, alarm.end, 300000)
	if testing.expect_value(t, len(alarm.values), 1) {
		testing.expect_value(t, alarm.values[0].text, "red")
	}
	story := parsed.contents.tracks[1]
	testing.expect_value(t, story.binding, format.CUTSCENE_NONE)
	if testing.expect_value(t, len(story.events), 1) &&
	   testing.expect_value(t, len(story.events[0].values), 2) {
		end := story.events[0]
		raw, _ := format.world_raw_from_meters(2)
		testing.expect_value(t, end.values[0].position.y, raw)
		testing.expect_value(t, end.values[1].kind, format.Cutscene_Value_Kind.Asset)
		testing.expect_value(t, parsed.contents.guids[end.values[1].index], guid_of(SOUND_GUID))
	}
	found := false
	for r in parsed.references {
		found ||= r.guid == guid_of(SOUND_GUID)
	}
	testing.expect(t, found, "an asset value is a reference of the cutscene")
	// The blob checks.
	blob := format.cutscene_write(parsed.contents, context.temp_allocator)
	aligned := make([]byte, len(blob) + 16, context.temp_allocator)
	start := int(-uintptr(raw_data(aligned)) & 15)
	copy(aligned[start:], blob)
	_, ok := format.cutscene_view(aligned[start:][:len(blob)])
	testing.expect(t, ok, "the blob checks")
}

@(private = "file")
guid_of :: proc(text: string) -> format.Guid {
	guid, _ := format.guid_parse(text)
	return guid
}

@(test)
each_kind_of_track_suits_its_binding :: proc(t: ^testing.T) {
	kinds := [?]struct {
		name:    string,
		use:     format.Cutscene_Binding_Use,
		track:   string,
		section: string,
	} {
		{"transform", .Required, "", ""},
		{"property", .Required, "\tcomponent = 1\n\tfield = \"f\"\n", ""},
		{"animation", .Required, "", "\t\tasset = $" + CLIP_GUID + "\n"},
		{"camera_cut", .None, "", "\t\tcamera = 1\n"},
		{"audio", .Optional, "", "\t\tasset = $" + SOUND_GUID + "\n"},
		{"event", .Optional, "", "trigger"},
		{"sub_sequence", .None, "", "\t\tasset = $" + SHOT_GUID + "\n"},
		{"presentation", .None, "", "\t\tkind = fade\n"},
	}
	for k in kinds {
		for bound in ([?]bool{false, true}) {
			// An event track has triggers, not sections, and sends to a binding that does not suspend its behaviours.
			text := fmt.tprintf(
				"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = @%s/1\n\tsuspend = []\ntrack 1 %s \"T\"\n%s%s%s",
				SCENE_GUID,
				k.name,
				"\tbinding = 1\n" if bound else "",
				k.track,
				"\ttrigger 1 0 t\n" if k.section == "trigger" else fmt.tprintf("\tsection 1 0 10\n%s", k.section),
			)
			_, problems := cutscene_parse(text, context.temp_allocator)
			good := k.use == .Optional || (k.use == .Required) == bound
			testing.expectf(
				t,
				(len(problems) == 0) == good,
				"%s with a binding %v: %v",
				k.name,
				bound,
				problems,
			)
		}
	}
}

@(test)
a_cutscene_has_at_most_the_most_bindings :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "cutscene 1\nlength = 10\n")
	for i in 0 ..= format.MAX_CUTSCENE_BINDINGS {
		fmt.sbprintf(&b, "binding %d \"B%d\"\n\tspawn = $%s\n", i + 1, i, PREFAB_GUID)
	}
	_, problems := cutscene_parse(strings.to_string(b), context.temp_allocator)
	testing.expectf(t, len(problems) == 1, "problems: %v", problems)
	if len(problems) == 1 {
		testing.expect_value(t, problems[0].line, 3 + 2 * format.MAX_CUTSCENE_BINDINGS)
	}
}

// cutscene_tree has a scene, a prefab, a glTF with a clip, a sound, a shot and a cutscene that names them all.
@(private = "file")
cutscene_tree :: proc(t: ^testing.T, intro := INTRO, extra: []struct {
		path, text: string,
	} = nil) -> Tree {
	files := make([dynamic]struct {
			path, text: string,
		}, context.temp_allocator)
	append(&files, struct {
		path, text: string,
	}{"content/town.scene", "scene 1\n"}, struct {
		path, text: string,
	}{"content/town.scene.meta", "guid = " + SCENE_GUID + "\n"}, struct {
		path, text: string,
	}{"content/guard.prefab", "scene 1\n"}, struct {
		path, text: string,
	}{"content/guard.prefab.meta", "guid = " + PREFAB_GUID + "\n"}, struct {
		path, text: string,
	}{"content/fox.gltf", "{}"}, struct {
		path, text: string,
	} {
		"content/fox.gltf.meta",
		"guid = " + MODEL_GUID + "\nanimation.Walk = " + CLIP_GUID + "\n",
	}, struct {
		path, text: string,
	}{"content/bark.wav", "RIFF"}, struct {
		path, text: string,
	}{"content/bark.wav.meta", "guid = " + SOUND_GUID + "\n"}, struct {
		path, text: string,
	}{"content/shot.cutscene", BOUND_SHOT}, struct {
		path, text: string,
	}{"content/shot.cutscene.meta", "guid = " + SHOT_GUID + "\n"}, struct {
		path, text: string,
	}{"content/intro.cutscene", intro}, struct {
		path, text: string,
	}{"content/intro.cutscene.meta", "guid = " + INTRO_GUID + "\n"})
	append(&files, ..extra)
	return make_tree(t, files[:])
}

@(test)
cutscenes_cook_into_blobs :: proc(t: ^testing.T) {
	tree := cutscene_tree(t)
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Cutscene}, log_problems = false)
	testing.expectf(t, pass.ok, "%v", pass.problems.list)
	testing.expect_value(t, pass.cooked[.Cutscene], 2)
	intro, _ := format.guid_parse(INTRO_GUID)
	data := tree_blob(t, tree, intro)
	blob, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, format.blob_string(data, blob.source_path), "game/intro.cutscene")
	testing.expect_value(t, blob.length, 600000)
	testing.expect_value(t, len(format.cutscene_bindings(data, blob)), 3)
	testing.expect_value(t, len(format.cutscene_tracks(data, blob)), 5)
	testing.expect_value(t, len(format.cutscene_sections(data, blob)), 5)
	testing.expect_value(t, len(format.cutscene_channels(data, blob)), 3)
	testing.expect_value(t, len(format.cutscene_keys(data, blob)), 5)
	testing.expect_value(t, len(format.cutscene_section_maps(data, blob, 3)), 1)
	refs, refs_ok := format.blob_references(data, context.temp_allocator)
	testing.expect(t, refs_ok)
	testing.expect_value(t, len(refs), 4)
	scene, _ := format.guid_parse(SCENE_GUID)
	testing.expect(t, !slice.contains(refs, scene), "a possessed scene is not a reference")
	for a in pass.assets {
		if a.name == "game/intro.cutscene" {
			// The scene, the prefab, the clip, the sound and the shot.
			testing.expect_value(t, len(a.dependencies), 5)
			testing.expect(t, slice.contains(a.dependencies[:], scene))
		}
	}

	// A second cook finds them up to date.
	pass = cook(options, {.Cutscene}, log_problems = false)
	testing.expect_value(t, pass.current[.Cutscene], 2)
	key := blob.header.key

	// A cutscene with a problem keeps its old blob.
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/content/intro.cutscene", tree.dir),
			string(INTRO + "track 9 dance \"Oops\"\n"),
		) ==
		nil,
	)
	pass = cook(options, {.Cutscene}, log_problems = false)
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Cutscene], 0)
	kept := tree_blob(t, tree, intro)
	kept_blob, kept_ok := format.cutscene_view(kept)
	testing.expect(t, kept_ok && kept_blob.header.key == key)
}

@(test)
a_cutscene_names_assets_of_the_right_kind :: proc(t: ^testing.T) {
	text :=
		`cutscene 1
length = 10
binding 1 "A"
	possess = @` +
		PREFAB_GUID +
		`/1
binding 2 "B"
	spawn = $` +
		SCENE_GUID +
		`
track 1 animation "C"
	binding = 2
	section 1 0 10
		asset = $` +
		SOUND_GUID +
		`
track 2 audio "D"
	section 2 0 10
		asset = $77777777777777777777777777777777
`
	tree := cutscene_tree(t, text)
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Cutscene}, log_problems = false)
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Cutscene], 1)
	expected := [?]struct {
		line:     int,
		fragment: string,
	} {
		{4, "game/guard.prefab is not a scene, but prefab"},
		{6, "game/town.scene is not a prefab, but scene"},
		{10, "game/bark.wav is not an animation, but audio"},
		{13, "no asset has the GUID 77777777777777777777777777777777"},
	}
	for e in expected {
		found := false
		for p in pass.problems.list {
			found ||= p.line == e.line && strings.contains(p.text, e.fragment)
		}
		testing.expectf(t, found, "%d %q: %v", e.line, e.fragment, pass.problems.list)
	}
}

// A property track names its field by its component's stable ID and its dotted name. Its sections can be additive, and
// its keys can name assets of any kind, which the blob lists once each and the bundle carries.
@(test)
transform_tracks_have_a_space_an_origin_and_keys_that_teleport :: proc(t: ^testing.T) {
	text :=
		`cutscene 1
length = 60000
binding 1 "Fox"
	possess = @` +
		SCENE_GUID +
		`/1
binding 2 "Ship"
	possess = @` +
		SCENE_GUID +
		`/2
track 1 transform "Ship flies"
	binding = 2
	space = absolute
	origin = [1073741824, 0, -0.5]
	section 1 0 60000
		channel position_z
			key 0 0 linear
			key 30000 10 linear teleport
			key 60000 12 bezier 1 2 weights 0.5 0.5 teleport
track 2 transform "Fox rides"
	binding = 1
	space = relative 2
	section 2 0 60000
		blend = additive
		channel rotation_y
			key 0 0 auto
track 3 transform "Fox stands"
	binding = 1
	section 3 0 60000
		channel scale_x
			key 0 1 constant
`
	parsed, problems := cutscene_parse(text, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	c := parsed.contents
	if len(c.tracks) != 3 {
		return
	}
	ship := c.tracks[0]
	testing.expect_value(t, ship.space, format.Cutscene_Space.Absolute)
	testing.expect_value(t, ship.origin, [3]i64{1 << 54, 0, -(1 << 23)})
	keys := ship.sections[0].channels[0].keys
	testing.expect_value(t, keys[0].flags, format.Cutscene_Key_Flags{})
	testing.expect_value(t, keys[1].flags, format.Cutscene_Key_Flags{.Teleport})
	testing.expect_value(
		t,
		keys[2].flags,
		format.Cutscene_Key_Flags{.Broken, .Weighted, .Teleport},
	)
	testing.expect_value(t, keys[2].out_slope, 2)
	testing.expect_value(t, c.tracks[1].space, format.Cutscene_Space.Relative_To)
	testing.expect_value(t, c.tracks[1].relative, 1)
	testing.expect_value(t, c.tracks[2].space, format.Cutscene_Space.Relative)

	// The blob keeps them.
	data := format.cutscene_write(c, context.temp_allocator)
	blob, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	tracks := format.cutscene_tracks(data, blob)
	testing.expect_value(t, tracks[0].origin, [3]i64{1 << 54, 0, -(1 << 23)})
	testing.expect_value(t, tracks[0].relative, format.CUTSCENE_NONE)
	testing.expect_value(t, tracks[1].relative, 1)
	testing.expect_value(t, tracks[2].relative, format.CUTSCENE_NONE)
}

@(test)
animation_sections_play_their_clip_from_an_offset_at_a_speed :: proc(t: ^testing.T) {
	text :=
		`cutscene 1
length = 120000
binding 1 "Fox"
	possess = @` +
		SCENE_GUID +
		`/1
track 1 animation "Fox acts"
	binding = 1
	section 1 0 60000
		asset = $` +
		CLIP_GUID +
		`
	section 2 30000 120000
		asset = $` +
		CLIP_GUID +
		`
		offset = 15000
		speed = 0.5
		loop = true
		root_motion = apply
	section 4 60000 120000
		asset = $` +
		CLIP_GUID +
		`
		root_motion = in_place
track 2 transform "Fox walks"
	binding = 1
	section 3 0 60000
		channel position_x
			key 0 0 linear
`
	parsed, problems := cutscene_parse(text, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	c := parsed.contents
	if len(c.tracks) != 2 {
		return
	}
	held := c.tracks[0].sections[0]
	testing.expect_value(t, held.offset, 0)
	testing.expect_value(t, held.speed, 1)
	testing.expect_value(t, held.flags, format.Cutscene_Section_Flags{})
	looped := c.tracks[0].sections[1]
	testing.expect_value(t, looped.offset, 15000)
	testing.expect_value(t, looped.speed, 0.5)
	testing.expect_value(t, looped.flags, format.Cutscene_Section_Flags{.Loop})
	testing.expect_value(t, looped.root_motion, format.Cutscene_Root_Motion.Apply)
	testing.expect_value(
		t,
		c.tracks[0].sections[2].root_motion,
		format.Cutscene_Root_Motion.In_Place,
	)
	testing.expect_value(t, c.tracks[1].sections[0].speed, 0)
	testing.expect_value(t, c.tracks[1].sections[0].root_motion, format.Cutscene_Root_Motion.Bake)

	// The blob keeps them.
	data := format.cutscene_write(c, context.temp_allocator)
	blob, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	sections := format.cutscene_sections(data, blob)
	testing.expect_value(t, sections[1].offset, 15000)
	testing.expect_value(t, sections[1].speed, 0.5)
	testing.expect_value(t, sections[1].flags, format.Cutscene_Section_Flags{.Loop})
	testing.expect_value(t, sections[1].root_motion, format.Cutscene_Root_Motion.Apply)
	testing.expect_value(t, sections[2].root_motion, format.Cutscene_Root_Motion.In_Place)
	testing.expect_value(t, sections[3].root_motion, format.Cutscene_Root_Motion.Bake)
	testing.expect_value(t, sections[3].speed, 0)
}

@(test)
camera_cut_sections_show_a_camera_blend_with_gameplay_and_carry_constraints :: proc(
	t: ^testing.T,
) {
	text :=
		`cutscene 1
length = 120000
binding 1 "Fox"
	possess = @` +
		SCENE_GUID +
		`/1
binding 2 "Wide"
	spawn = $` +
		PREFAB_GUID +
		`
	look_at = 1
	look_at_offset = [0, 0.5, 0]
binding 3 "Close"
	spawn = $` +
		PREFAB_GUID +
		`
track 1 camera_cut "Cuts"
	section 1 0 40000
		camera = 2
		blend_in = 30000 smooth
		focus = 1
	section 2 40000 80000
		camera = 3
		look_at = 1
		look_at_damping = 12000
	section 3 90000 120000
		camera = 2
		follow = 1
		follow_offset = [1.5, 1.2, -3]
		follow_damping = 6000
		blend_out = 60000 ease_out
		blend_on_skip = true
`
	parsed, problems := cutscene_parse(text, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	c := parsed.contents
	if len(c.tracks) != 1 || len(c.tracks[0].sections) != 3 {
		return
	}
	shots := c.tracks[0].sections
	testing.expect_value(t, shots[0].camera, 1)
	testing.expect_value(t, shots[0].blend_in, 30000)
	testing.expect_value(t, shots[0].blend_curves[0], format.Cutscene_Blend_Curve.Smooth)
	testing.expect_value(t, len(shots[0].constraints), 1)
	testing.expect_value(
		t,
		shots[0].constraints[0],
		format.Cutscene_Constraint_Contents{kind = .Focus, target = 0},
	)
	testing.expect_value(t, shots[1].camera, 2)
	testing.expect_value(
		t,
		shots[1].constraints[0],
		format.Cutscene_Constraint_Contents{kind = .Look_At, target = 0, damping = 12000},
	)
	testing.expect_value(t, shots[2].blend_out, 60000)
	testing.expect_value(t, shots[2].blend_curves[1], format.Cutscene_Blend_Curve.Ease_Out)
	testing.expect_value(t, shots[2].flags, format.Cutscene_Section_Flags{.Blend_On_Skip})
	testing.expect_value(
		t,
		shots[2].constraints[0],
		format.Cutscene_Constraint_Contents {
			kind = .Follow,
			target = 0,
			offset = {1.5, 1.2, -3},
			damping = 6000,
		},
	)
	testing.expect_value(t, len(c.bindings[1].constraints), 1)
	testing.expect_value(
		t,
		c.bindings[1].constraints[0],
		format.Cutscene_Constraint_Contents{kind = .Look_At, target = 0, offset = {0, 0.5, 0}},
	)

	// The blob keeps them.
	data := format.cutscene_write(c, context.temp_allocator)
	blob, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, len(format.cutscene_constraints(data, blob)), 4)
	testing.expect_value(t, format.cutscene_sections(data, blob)[2].camera, 1)
}

@(test)
property_tracks_name_their_field_and_key_numbers_or_assets :: proc(t: ^testing.T) {
	text :=
		`cutscene 1
length = 60000
binding 1 "Lamp"
	possess = @` +
		SCENE_GUID +
		`/1
track 1 property "Glow"
	binding = 1
	component = 9101
	field = "light.intensity"
	section 1 0 60000
		blend = additive
		channel value
			key 0 0 auto
			key 30000 2.5 bezier 1
track 2 property "Bulb"
	binding = 1
	component = 18446744073709551615
	field = "bulb"
	section 2 0 30000
		channel value
			key 0 $` +
		SOUND_GUID +
		` constant
			key 15000 $` +
		CLIP_GUID +
		` constant
			key 20000 $` +
		SOUND_GUID +
		` constant
	section 3 30000 60000
		blend = absolute
		channel value
			key 0 $` +
		CLIP_GUID +
		` constant
`
	parsed, problems := cutscene_parse(text, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	c := parsed.contents
	if len(c.tracks) != 2 {
		testing.expectf(t, false, "%d tracks", len(c.tracks))
		return
	}
	sound, _ := format.guid_parse(SOUND_GUID)
	clip, _ := format.guid_parse(CLIP_GUID)
	glow := c.tracks[0]
	testing.expect_value(t, glow.component, 9101)
	testing.expect_value(t, glow.field, "light.intensity")
	testing.expect_value(t, glow.sections[0].flags, format.Cutscene_Section_Flags{.Additive})
	testing.expect_value(t, glow.sections[0].channels[0].flags, format.Cutscene_Channel_Flags{})
	keys := glow.sections[0].channels[0].keys
	testing.expect_value(t, keys[0].interp, format.Cutscene_Interp.Auto)
	testing.expect_value(t, keys[1].flags, format.Cutscene_Key_Flags{})
	testing.expect_value(t, keys[1].in_slope, 1)
	testing.expect_value(t, keys[1].out_slope, 1)
	bulb := c.tracks[1]
	testing.expect_value(t, bulb.component, max(u64))
	testing.expect_value(t, bulb.sections[1].flags, format.Cutscene_Section_Flags{})
	swap := bulb.sections[0].channels[0]
	testing.expect_value(t, swap.flags, format.Cutscene_Channel_Flags{.Guids})
	testing.expect_value(t, len(c.guids), 2)
	testing.expect_value(t, c.guids[0], sound)
	testing.expect_value(t, c.guids[1], clip)
	testing.expect_value(t, swap.keys[0].value, 0)
	testing.expect_value(t, swap.keys[1].value, 1)
	testing.expect_value(t, swap.keys[2].value, 0)
	testing.expect_value(t, bulb.sections[1].channels[0].keys[0].value, 1)
	keyed := 0
	for r in parsed.references {
		if r.want == .None {
			keyed += 1
		}
	}
	testing.expect_value(t, keyed, 2)

	tree := cutscene_tree(t, text)
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Cutscene}, log_problems = false)
	testing.expectf(t, pass.ok, "%v", pass.problems.list)
	intro, _ := format.guid_parse(INTRO_GUID)
	data := tree_blob(t, tree, intro)
	blob, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	tracks := format.cutscene_tracks(data, blob)
	testing.expect_value(t, tracks[0].component, 9101)
	testing.expect_value(t, tracks[0].field_hash, format.scene_field_hash("light.intensity"))
	testing.expect_value(t, format.blob_string(data, tracks[0].field), "light.intensity")
	refs, refs_ok := format.blob_references(data, context.temp_allocator)
	testing.expect(t, refs_ok)
	testing.expect(t, slice.contains(refs, sound) && slice.contains(refs, clip))

	// A key that names no asset is a problem at its line.
	missing := strings.concatenate(
		{text, "\t\t\tkey 5000 $77777777777777777777777777777777 constant\n"},
		context.temp_allocator,
	)
	missing_tree := cutscene_tree(t, missing)
	defer remove_tree(missing_tree)
	pass = cook(tree_options(missing_tree), {.Cutscene}, log_problems = false)
	testing.expect(t, !pass.ok)
	found := false
	for p in pass.problems.list {
		found ||= p.line == 27 && strings.contains(p.text, "no asset has the GUID 7777")
	}
	testing.expectf(t, found, "%v", pass.problems.list)
}

// sub_sequence_text is a cutscene whose one sub-sequence section names another, or none.
@(private = "file")
sub_sequence_text :: proc(child: string) -> string {
	if child == "" {
		return SHOT
	}
	return fmt.tprintf(
		"cutscene 1\nlength = 60000\ntrack 1 sub_sequence \"S\"\n\tsection 1 0 60000\n\t\tasset = $%s\n",
		child,
	)
}

@(private = "file")
sequence_guid :: proc(i: int) -> string {
	return fmt.tprintf("%032x", 0xa000 + i)
}

@(test)
a_cycle_of_sub_sequences_fails_every_cutscene_in_it_at_its_line :: proc(t: ^testing.T) {
	a, b, c, self, outside :=
		sequence_guid(1), sequence_guid(2), sequence_guid(3), sequence_guid(4), sequence_guid(5)
	tree := cutscene_tree(
		t,
		extra = {
			{"content/a.cutscene", sub_sequence_text(b)},
			{"content/a.cutscene.meta", fmt.tprintf("guid = %s\n", a)},
			{"content/b.cutscene", sub_sequence_text(c)},
			{"content/b.cutscene.meta", fmt.tprintf("guid = %s\n", b)},
			{"content/c.cutscene", sub_sequence_text(a)},
			{"content/c.cutscene.meta", fmt.tprintf("guid = %s\n", c)},
			{"content/self.cutscene", sub_sequence_text(self)},
			{"content/self.cutscene.meta", fmt.tprintf("guid = %s\n", self)},
			{"content/outside.cutscene", sub_sequence_text(a)},
			{"content/outside.cutscene.meta", fmt.tprintf("guid = %s\n", outside)},
		},
	)
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Cutscene}, log_problems = false)
	testing.expect(t, !pass.ok)
	// The shot, the intro and the cutscene outside the cycle cook.
	testing.expect_value(t, pass.cooked[.Cutscene], 3)
	for name in ([?]string{"a", "b", "c", "self"}) {
		found := false
		for p in pass.problems.list {
			found ||=
				strings.has_suffix(p.file, fmt.tprintf("/%s.cutscene", name)) &&
				p.line == 5 &&
				strings.contains(p.text, "sub-sequence cycle: ")
		}
		testing.expectf(t, found, "%s: %v", name, pass.problems.list)
	}
	// The path of the cycle, from whichever cutscene the search met first.
	for step in ([?]string{"a.cutscene -> game/b", "b.cutscene -> game/c", "c.cutscene -> game/a"}) {
		found := false
		for p in pass.problems.list {
			found ||= strings.has_suffix(p.file, "/b.cutscene") && strings.contains(p.text, step)
		}
		testing.expectf(t, found, "the cycle's path has %q: %v", step, pass.problems.list)
	}
}

@(test)
every_cutscene_of_a_cycle_fails_whatever_the_order_of_the_search :: proc(t: ^testing.T) {
	// u names w and then v, v names w, and w names u: a search from u that meets w first still fails v.
	u, v, w := sequence_guid(1), sequence_guid(2), sequence_guid(3)
	two := fmt.tprintf(
		`cutscene 1
length = 60000
track 1 sub_sequence "S"
	section 1 0 60000
		asset = $%s
track 2 sub_sequence "T"
	section 2 0 60000
		asset = $%s
`,
		w,
		v,
	)
	tree := make_tree(
		t,
		{
			{"content/u.cutscene", two},
			{"content/u.cutscene.meta", fmt.tprintf("guid = %s\n", u)},
			{"content/v.cutscene", sub_sequence_text(w)},
			{"content/v.cutscene.meta", fmt.tprintf("guid = %s\n", v)},
			{"content/w.cutscene", sub_sequence_text(u)},
			{"content/w.cutscene.meta", fmt.tprintf("guid = %s\n", w)},
		},
	)
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Cutscene}, log_problems = false)
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Cutscene], 0)
	for name in ([?]string{"u", "v", "w"}) {
		found := false
		for p in pass.problems.list {
			found ||=
				strings.has_suffix(p.file, fmt.tprintf("/%s.cutscene", name)) &&
				strings.contains(p.text, "sub-sequence cycle: ")
		}
		testing.expectf(t, found, "%s: %v", name, pass.problems.list)
	}
	found := false
	for p in pass.problems.list {
		found ||=
			strings.has_suffix(p.file, "/v.cutscene") &&
			p.line == 5 &&
			strings.contains(
				p.text,
				"game/v.cutscene -> game/w.cutscene -> game/u.cutscene -> game/v.cutscene",
			)
	}
	testing.expectf(t, found, "v's cycle and its line: %v", pass.problems.list)
}

@(test)
sub_sequences_nest_at_most_eight_deep :: proc(t: ^testing.T) {
	for count in ([?]int{format.CUTSCENE_MAX_DEPTH + 1, format.CUTSCENE_MAX_DEPTH + 2}) {
		files := make([dynamic]struct {
				path, text: string,
			}, context.temp_allocator)
		for i in 0 ..< count {
			child := sequence_guid(i + 1) if i + 1 < count else ""
			append(&files, struct {
				path, text: string,
			}{fmt.tprintf("content/n%d.cutscene", i), sub_sequence_text(child)}, struct {
				path, text: string,
			} {
				fmt.tprintf("content/n%d.cutscene.meta", i),
				fmt.tprintf("guid = %s\n", sequence_guid(i)),
			})
		}
		tree := make_tree(t, files[:])
		defer remove_tree(tree)
		pass := cook(tree_options(tree), {.Cutscene}, log_problems = false)
		if count == format.CUTSCENE_MAX_DEPTH + 1 {
			testing.expectf(t, pass.ok, "%d deep: %v", count - 1, pass.problems.list)
			testing.expect_value(t, pass.cooked[.Cutscene], count)
			continue
		}
		testing.expect(t, !pass.ok)
		testing.expect_value(t, pass.cooked[.Cutscene], count - 1)
		testing.expect_value(t, len(pass.problems.list), 1)
		if len(pass.problems.list) == 1 {
			p := pass.problems.list[0]
			testing.expect(t, strings.has_suffix(p.file, "/n0.cutscene"))
			testing.expect_value(t, p.line, 5)
			testing.expectf(t, strings.contains(p.text, "nest 9 deep, past 8"), "%s", p.text)
		}
	}
}

@(test)
a_cycle_that_an_edit_makes_keeps_the_old_blobs :: proc(t: ^testing.T) {
	a, b := sequence_guid(1), sequence_guid(2)
	tree := make_tree(
		t,
		{
			{"content/a.cutscene", sub_sequence_text(b)},
			{"content/a.cutscene.meta", fmt.tprintf("guid = %s\n", a)},
			{"content/b.cutscene", SHOT},
			{"content/b.cutscene.meta", fmt.tprintf("guid = %s\n", b)},
		},
	)
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Cutscene}, log_problems = false)
	testing.expectf(t, pass.ok, "%v", pass.problems.list)
	b_guid, _ := format.guid_parse(b)
	before := slice.clone(tree_blob(t, tree, b_guid), context.temp_allocator)
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/content/b.cutscene", tree.dir),
			sub_sequence_text(a),
		) ==
		nil,
	)
	pass = cook(options, {.Cutscene}, log_problems = false)
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Cutscene], 0)
	testing.expect(t, slice.equal(tree_blob(t, tree, b_guid), before), "b keeps its old blob")
}

// A sub-sequence section's binds name bindings that its child has, of a kind that fits, and its trim is within the
// child's range: the cook checks them against the child's text, at the lines that set them.
@(test)
a_sub_sequence_binds_what_its_child_has_and_trims_within_its_range :: proc(t: ^testing.T) {
	S :: "@" + SCENE_GUID + "/0000000000000001"
	child :=
		`cutscene 1
length = 60000
range = [0, 30000]
binding 7 "Camera"
	possess = ` +
		S +
		`
binding 8 "Walker"
	possess = ` +
		S +
		`
track 1 camera_cut "Cuts"
	section 1 0 30000
		camera = 7
track 2 animation "Walk"
	binding = 8
	section 2 0 30000
		asset = $` +
		CLIP_GUID +
		`
`
	parent :=
		`cutscene 1
length = 60000
binding 1 "Fox"
	possess = ` +
		S +
		`
binding 2 "Wide"
	possess = ` +
		S +
		`
track 1 animation "Fox walk"
	binding = 1
	section 1 0 60000
		asset = $` +
		CLIP_GUID +
		`
track 2 camera_cut "Cuts"
	section 2 30000 60000
		camera = 2
track 3 sub_sequence "Shot"
	section 3 0 30000
		asset = $` +
		SHOT_GUID +
		`
		trim = 0 40000
		bind 7 = 1
		bind 8 = 2
		bind 9 = 1
`
	tree := cutscene_tree(t, parent, {{"content/shot.cutscene", child}})
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Cutscene}, log_problems = false)
	testing.expect(t, !pass.ok)
	cases := [?]struct {
		line:     int,
		fragment: string,
	} {
		{17, "the trim is within game/shot.cutscene's range, [0, 30000]"},
		{18, "the binding 7 of game/shot.cutscene and the binding 1 here are not of one kind"},
		{19, "the binding 8 of game/shot.cutscene and the binding 2 here are not of one kind"},
		{20, "game/shot.cutscene has no binding with the ID 9"},
	}
	for c in cases {
		found := false
		for p in pass.problems.list {
			found ||=
				strings.has_suffix(p.file, "/intro.cutscene") &&
				p.line == c.line &&
				strings.contains(p.text, c.fragment)
		}
		testing.expectf(t, found, "line %d: %q: %v", c.line, c.fragment, pass.problems.list)
	}
}

@(test)
presentation_sections_fade_letterbox_and_subtitle :: proc(t: ^testing.T) {
	text :=
		"cutscene 1\nlength = 600000\nskip_color = \"#102030\"\n" +
		"track 1 audio \"Dialogue\"\n\tsection 7 60000 120000\n\t\tasset = $" +
		SOUND_GUID +
		"\n" +
		"track 2 presentation \"Presentation\"\n\tletterbox_aspect = camera\n\twhen_finished = keep\n" +
		"\tsection 1 0 30000\n\t\tkind = fade\n\t\tcolor = \"#f00\"\n" +
		"\t\tchannel opacity\n\t\t\tkey 0 1 linear\n\t\t\tkey 30000 0 linear\n" +
		"\tsection 2 0 600000\n\t\tkind = letterbox\n\t\tease_in = 30000\n" +
		"\t\tchannel aspect\n\t\t\tkey 0 2.39 constant\n" +
		"\tsection 3 60000 120000\n\t\tkind = subtitle\n\t\tspeaker = \"Fox\"\n" +
		"\t\ttext = \"Over # here.\"\n\t\tkey = \"intro.fox\"\n\t\taudio = 7\n" +
		"\tsection 4 500000 600000\n\t\tkind = fade\n"
	parsed, problems := cutscene_parse(text, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	if len(parsed.contents.tracks) != 2 {
		return
	}
	testing.expect_value(t, parsed.contents.skip_color, [3]u8{0x10, 0x20, 0x30})
	present := parsed.contents.tracks[1]
	testing.expect_value(t, present.flags, format.Cutscene_Track_Flags{.Follow_Camera})
	testing.expect_value(t, present.finish, format.Cutscene_Finish.Keep)
	fade := present.sections[0].presentation
	testing.expect_value(t, fade.kind, format.Cutscene_Presentation_Kind.Fade)
	testing.expect_value(t, fade.color, [3]u8{255, 0, 0})
	testing.expect_value(
		t,
		present.sections[1].presentation.kind,
		format.Cutscene_Presentation_Kind.Letterbox,
	)
	line := present.sections[2].presentation
	testing.expect_value(t, line.kind, format.Cutscene_Presentation_Kind.Subtitle)
	testing.expect_value(t, line.speaker, "Fox")
	testing.expect_value(t, line.text, "Over # here.")
	testing.expect_value(t, line.key, "intro.fox")
	testing.expect_value(t, line.audio.? or_else 99, 0)
	// A fade without a color is black.
	testing.expect_value(t, present.sections[3].presentation.color, [3]u8{})
	blob := format.cutscene_write(parsed.contents, context.temp_allocator)
	aligned := make([]byte, len(blob) + 16, context.temp_allocator)
	start := int(-uintptr(raw_data(aligned)) & 15)
	copy(aligned[start:], blob)
	_, ok := format.cutscene_view(aligned[start:][:len(blob)])
	testing.expect(t, ok, "the blob checks")
}

// line_of is the line, from 1, of the first line of text that has part.
@(private = "file")
line_of :: proc(text, part: string) -> u32 {
	return u32(strings.count(text[:strings.index(text, part)], "\n") + 1)
}

// The editor's unsaved text of a cutscene is checked as a cook would check it. A good text goes in the preview area, and
// a text with problems gives them by line and leaves the last good preview. Sub-sequences are checked with the other
// cutscenes' sources on disk, and the unsaved text in place of the cutscene's own.
@(test)
a_preview_of_a_cutscene_checks_it_and_keeps_the_last_good_blob :: proc(t: ^testing.T) {
	// The index has the sub-assets that a file made when it cooked, and the test's glTF is not a real file, so the intro
	// here has no animation track.
	full := INTRO
	intro_text := strings.concatenate(
		{
			full[:strings.index(full, "track 2 animation")],
			full[strings.index(full, "track 3 audio"):],
		},
		context.temp_allocator,
	)
	tree := cutscene_tree(t, intro = intro_text)
	defer remove_tree(tree)
	d: Daemon
	d.options = tree_options(tree)
	// Every kind, so the index has each asset. The test's model and sound are not real files, and fail.
	pass := cook(d.options, ALL_KINDS, log_problems = false)
	testing.expect_value(t, pass.cooked[.Cutscene], 2)
	index_build(&d.index, pass, d.options.roots[:])
	defer index_destroy(&d.index)
	intro, _ := format.guid_parse(INTRO_GUID)
	cooked := tree_blob(t, tree, intro)
	buffer: [32]u8
	preview_path := fmt.tprintf(
		"%s/preview/%s.blob",
		config_dir(d.options),
		format.guid_format(intro, &buffer),
	)

	result := preview(&d, {guid = INTRO_GUID, text = intro_text})
	testing.expectf(t, len(result.problems) == 0 && result.error == "", "%v", result)
	good, good_err := os.read_entire_file(preview_path, context.temp_allocator)
	if !testing.expect(t, good_err == nil) {
		return
	}
	aligned, _ := mem.alloc_bytes(len(good), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, good)
	blob, ok := format.cutscene_view(aligned)
	testing.expect(t, ok)
	testing.expect_value(t, format.blob_string(aligned, blob.source_path), "game/intro.cutscene")
	testing.expect_value(t, len(format.cutscene_tracks(aligned, blob)), 4)

	// A rate that is not a display rate, and a bind to a binding that the shot on disk does not have.
	bad, _ := strings.replace(intro_text, "rate = 24", "rate = 23", 1, context.temp_allocator)
	bad, _ = strings.replace(bad, "bind 7 = 1", "bind 9 = 1", 1, context.temp_allocator)
	result = preview(&d, {guid = INTRO_GUID, text = bad})
	testing.expect(t, result.error != "")
	lines: [dynamic]u32
	defer delete(lines)
	for p in result.problems {
		append(&lines, p.line)
		testing.expect(t, strings.has_suffix(p.file, "/intro.cutscene"))
	}
	testing.expectf(
		t,
		slice.equal(lines[:], []u32{line_of(bad, "rate = 23"), line_of(bad, "bind 9 = 1")}),
		"%v",
		result.problems,
	)
	kept, _ := os.read_entire_file(preview_path, context.temp_allocator)
	testing.expect(t, slice.equal(kept, good), "a text with problems keeps the last good preview")

	// The shot, unsaved, names the intro, which on disk names the shot.
	cycle := fmt.tprintf(
		"cutscene 1\nlength = 60000\ntrack 1 sub_sequence \"S\"\n\tsection 1 0 60000\n\t\tasset = $%s\n",
		INTRO_GUID,
	)
	result = preview(&d, {guid = SHOT_GUID, text = cycle})
	cycled := false
	for p in result.problems {
		cycled ||=
			p.line == 5 &&
			strings.contains(p.text, "sub-sequence cycle: game/shot.cutscene -> game/intro")
	}
	testing.expectf(t, cycled, "%v", result.problems)
	// A preview leaves the cutscene's own blob as the cook wrote it.
	testing.expect(t, slice.equal(tree_blob(t, tree, intro), cooked))
}

@(test)
markers_have_a_time_a_name_and_a_color_and_cook_in_time_order :: proc(t: ^testing.T) {
	parsed, problems := cutscene_parse(
		"cutscene 1\nlength = 100\nmarker 2 80 \"Late\"\n\tcolor = \"#102030\"\nmarker 1 20 \"Early\"\ntrack 1 camera_cut \"Cameras\"\n",
		context.temp_allocator,
	)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, len(parsed.contents.markers), 2)
	if len(parsed.contents.markers) == 2 {
		late, early := parsed.contents.markers[0], parsed.contents.markers[1]
		testing.expect_value(t, late.name, "Late")
		testing.expect_value(t, late.time, 80)
		testing.expect_value(t, late.color, [3]u8{0x10, 0x20, 0x30})
		testing.expect_value(t, early.color, CUTSCENE_MARKER_COLOR)
	}
	data := format.cutscene_write(parsed.contents, context.temp_allocator)
	blob, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	markers := format.cutscene_markers(data, blob)
	testing.expect_value(t, len(markers), 2)
	if len(markers) == 2 {
		testing.expect_value(t, markers[0].id, 1)
		testing.expect_value(t, format.blob_string(data, markers[0].name), "Early")
		testing.expect_value(t, markers[1].time, 80)
		testing.expect_value(t, markers[1].color, format.Ui_Color{0x10, 0x20, 0x30, 255})
	}

	Case :: struct {
		text:     string,
		line:     int,
		fragment: string,
	}
	cases := []Case {
		{"cutscene 1\nlength = 10\nmarker 1 4\n", 3, "a marker is `marker <id> <time>"},
		{"cutscene 1\nlength = 10\nmarker 1 4 \"\"\n", 3, "a marker is `marker <id> <time>"},
		{
			"cutscene 1\nlength = 10\nmarker 1 4 \"A\"\nmarker 1 5 \"B\"\n",
			4,
			"a marker with the ID 1 already",
		},
		{"cutscene 1\nlength = 10\nmarker 1 11 \"A\"\n", 3, "a marker is inside the length (10)"},
		{
			"cutscene 1\nlength = 10\nmarker 1 4 \"A\"\n\tcolor = red\n",
			4,
			"color is a quoted color",
		},
		{
			"cutscene 1\nlength = 10\nmarker 1 4 \"A\"\n\tcolor = \"#fff\"\n\tcolor = \"#000\"\n",
			5,
			"color is set twice",
		},
		{
			"cutscene 1\nlength = 10\nmarker 1 4 \"A\"\n\trate = 30\n",
			4,
			"\"rate\" is not a setting of a marker",
		},
		{
			"cutscene 1\nlength = 10\nmarker 1 4 \"A\"\n\ttrigger 1 4 go\n",
			4,
			"a trigger comes after a track line",
		},
	}
	for c in cases {
		_, found := cutscene_parse(c.text, context.temp_allocator)
		hit := false
		for p in found {
			hit ||= p.line == c.line && strings.contains(p.message, c.fragment)
		}
		testing.expectf(
			t,
			hit,
			"%q: no problem at line %d with %q: %v",
			c.text,
			c.line,
			c.fragment,
			found,
		)
	}
}
