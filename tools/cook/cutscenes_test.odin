package cook

import "core:fmt"
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
			key 300000 2 cubic 0.5 -0.25
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
track 5 camera_cut ""
	section 5 0 600000
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
	testing.expect_value(t, keys[1].interp, format.Cutscene_Interp.Cubic)
	testing.expect_value(t, keys[1].in_tangent, 0.5)
	testing.expect_value(t, keys[1].out_tangent, -0.25)
	testing.expect_value(t, keys[2].interp, format.Cutscene_Interp.Constant)
	testing.expect_value(t, c.tracks[1].sections[0].weight, 0.5)
	testing.expect_value(t, c.tracks[1].finish, format.Cutscene_Finish.Restore)
	testing.expect_value(t, c.tracks[2].flags, format.Cutscene_Track_Flags{.Muted})
	testing.expect_value(t, c.tracks[2].binding, format.CUTSCENE_NONE)
	testing.expect_value(t, c.tracks[2].sections[0].start, 120000)
	testing.expect_value(t, c.tracks[4].name, "")

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
}

@(test)
each_mistake_in_a_cutscene_is_reported_at_its_line :: proc(t: ^testing.T) {
	S :: "@" + SCENE_GUID + "/0000000000000001"
	P :: "$" + PREFAB_GUID
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
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tspeed = 1\n",
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
			"an in and an out tangent",
		},
		{
			"cutscene 1\nlength = 10\ntrack 1 event \"A\"\n\tsection 1 0 10\n\t\tchannel x\n\t\t\tkey 0 0 linear 1 1\n",
			6,
			"a linear key has no tangents",
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

@(test)
each_kind_of_track_suits_its_binding :: proc(t: ^testing.T) {
	kinds := [?]struct {
		name:    string,
		use:     format.Cutscene_Binding_Use,
		section: string,
	} {
		{"transform", .Required, ""},
		{"property", .Required, ""},
		{"animation", .Required, "\t\tasset = $" + CLIP_GUID + "\n"},
		{"camera_cut", .None, ""},
		{"audio", .Optional, "\t\tasset = $" + SOUND_GUID + "\n"},
		{"event", .Optional, ""},
		{"sub_sequence", .None, "\t\tasset = $" + SHOT_GUID + "\n"},
		{"presentation", .None, ""},
	}
	for k in kinds {
		for bound in ([?]bool{false, true}) {
			text := fmt.tprintf(
				"cutscene 1\nlength = 10\nbinding 1 \"A\"\n\tpossess = @%s/1\ntrack 1 %s \"T\"\n%s\tsection 1 0 10\n%s",
				SCENE_GUID,
				k.name,
				"\tbinding = 1\n" if bound else "",
				k.section,
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
	}{"content/shot.cutscene", SHOT}, struct {
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
