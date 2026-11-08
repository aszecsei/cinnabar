package cook

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
FOX_GRAPH :: `animation_graph 1
# A fox that looks about, and walks and runs by its speed.
root_motion = "b_Root_00"
entry = idle

param speed float 0
param grounded bool true
param look trigger

clip survey = $00112233445566778899aabbccddeeff
clip walk = $ffeeddccbbaa99887766554433221100   # its feet
	event 0.55 footstep "right"
	event 0.2 footstep "left # front"
clip run = $0123456789abcdef0123456789abcdef
	event 0.1 footstep "left" 2

node 1 state
	position = [0, 0]
	name = idle
	motion = survey
node 2 state
	name = move
	motion = @10.pose
	enter_event = started
node 3 state
	name = look
	motion = survey
	loop = false
	speed = 1.5
	exit_event = looked

node 10 blend_1d
	parameter = speed
	input.0 = run
	at.0 = 3
	input.1 = walk
	at.1 = 0.4

node 20 transition
	from = idle
	to = move
	when = speed > 0.1 and grounded
	duration = 0.25
node 21 transition
	from = move
	to = idle
	when = speed < 0.05
	duration = 0.3
node 22 transition
	from = any
	to = look
	when = look
	duration = 0.2
node 23 transition
	from = look
	to = idle
	exit_time = 0.95
	duration = 0.3
`

@(test)
animation_graphs_parse_into_states_and_transitions :: proc(t: ^testing.T) {
	g, problems := animation_graph_parse(FOX_GRAPH, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	if len(problems) != 0 {
		return
	}
	testing.expect_value(t, g.root_motion, "b_Root_00")
	testing.expect_value(t, g.entry, 0)
	testing.expect_value(t, len(g.parameters), 3)
	testing.expect_value(t, g.parameters[1].kind, format.Animation_Graph_Parameter_Kind.Bool)
	testing.expect_value(t, g.parameters[1].default, 1)

	// A clip's markers are in the order of their times, and a # in quotes is not a comment.
	walk := g.clips[1]
	testing.expect_value(t, len(walk.markers), 2)
	testing.expect_value(t, walk.markers[0].time, 0.2)
	left := g.events[walk.markers[0].event]
	testing.expect_value(t, left.name, "footstep")
	testing.expect_value(t, left.args[0].text, "left # front")
	run := g.events[g.clips[2].markers[0].event]
	testing.expect_value(t, run.args[1].kind, format.Animation_Graph_Value_Kind.Number)
	testing.expect_value(t, run.args[1].number, 2)

	// The blend's inputs are in the order of their thresholds.
	move := g.states[1]
	testing.expect_value(t, move.motion, format.Animation_Graph_Motion.Blend_1D)
	testing.expect_value(t, move.parameter, 0)
	testing.expect_value(t, len(move.points), 2)
	testing.expect_value(t, move.points[0].clip, 1)
	testing.expect_value(t, move.points[1].threshold, 3)
	testing.expect_value(t, g.events[move.enter_event].name, "started")
	look := g.states[2]
	testing.expect(t, !look.loop)
	testing.expect_value(t, look.speed, 1.5)
	testing.expect_value(t, g.events[look.exit_event].name, "looked")
	testing.expect_value(t, g.states[0].speed, 1)
	testing.expect_value(t, g.states[0].node, 1)

	testing.expect_value(t, len(g.transitions), 4)
	start := g.transitions[0]
	testing.expect_value(t, len(start.conditions), 2)
	testing.expect_value(t, start.conditions[0].op, format.Animation_Graph_Condition_Op.Greater)
	testing.expect_value(t, start.conditions[0].value, 0.1)
	testing.expect_value(t, start.conditions[1].op, format.Animation_Graph_Condition_Op.True)
	testing.expect_value(t, start.exit_time, -1)
	testing.expect_value(t, g.transitions[2].from, format.ANIMATION_GRAPH_NONE)
	testing.expect_value(t, g.transitions[2].conditions[0].op, format.Animation_Graph_Condition_Op.Trigger)
	testing.expect_value(t, g.transitions[3].exit_time, 0.95)
	testing.expect_value(t, len(g.transitions[3].conditions), 0)

	// The contents make a blob that the runtime takes.
	written := format.animation_graph_write(g, context.temp_allocator)
	data, _ := mem.alloc_bytes(len(written), format.BLOB_ALIGN, context.temp_allocator)
	copy(data, written)
	_, ok := format.animation_graph_view(data)
	testing.expect(t, ok)
}

@(test)
an_unsaved_graphs_problems_name_its_file_and_its_lines :: proc(t: ^testing.T) {
	cache, err := os.make_directory_temp("", "animation_graph_check_*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(cache)
	defer os.remove_all(cache)
	options := Cook_Options {
		cache  = cache,
		config = .Dev,
	}
	guid, _ := format.guid_parse("00112233445566778899aabbccddeeff")
	blob := fmt.tprintf("%s/preview/00112233445566778899aabbccddeeff.blob", config_dir(options))

	problems := animation_graph_check(options, guid, FOX_GRAPH, "C:/game/fox.animation_graph", "game/fox.animation_graph")
	testing.expect_value(t, len(problems.list), 0)
	// A text without problems is what the preview plays.
	read_blob :: proc(path: string) -> (^format.Blob_Header, bool) {
		read, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			return nil, false
		}
		aligned, _ := mem.alloc_bytes(len(read), format.BLOB_ALIGN, context.temp_allocator)
		copy(aligned, read)
		return format.blob_header(aligned)
	}
	header, valid := read_blob(blob)
	testing.expect(t, valid && header.guid == guid && header.kind == .Animation_Graph)
	before := header.key

	problems = animation_graph_check(options, guid, "animation_graph 1\nentry = nowhere\nnode 1 state\n\tname = a\n", "C:/game/fox.animation_graph", "game/fox.animation_graph")
	defer delete(problems.list)
	// A text with problems leaves the last good one.
	header, valid = read_blob(blob)
	testing.expect(t, valid)
	testing.expect_value(t, header.key, before)
	testing.expect_value(t, len(problems.list), 2)
	testing.expect_value(t, problems.list[0].file, "C:/game/fox.animation_graph")
	testing.expect_value(t, problems.list[0].line, 2)
	testing.expect_value(t, problems.list[1].line, 3)
}

@(test)
the_animation_graph_template_parses :: proc(t: ^testing.T) {
	g, problems := animation_graph_parse(ANIMATION_GRAPH_TEMPLATE, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, len(g.states), 1)
}

@(test)
animation_graph_mistakes_are_problems_at_their_lines :: proc(t: ^testing.T) {
	HEAD :: "animation_graph 1\nentry = a\nparam f float\nparam b bool\nparam go trigger\nclip c = $00112233445566778899aabbccddeeff\nnode 1 state\n\tname = a\n\tmotion = c\n"
	cases := []struct {
		text: string,
		line: int,
	} {
		{"entry = a\n", 1},
		{"animation_graph 1\nparam f float\nclip c = $00112233445566778899aabbccddeeff\nnode 1 state\n\tname = a\n\tmotion = c\n", 1},
		{"animation_graph 1\nentry = nowhere\nclip c = $00112233445566778899aabbccddeeff\nnode 1 state\n\tname = a\n\tmotion = c\n", 2},
		{HEAD + "param f bool\n", 10},
		{HEAD + "param x vector\n", 10},
		{HEAD + "param x trigger 1\n", 10},
		{HEAD + "clip d = walk\n", 10},
		{HEAD + "clip d = $00112233445566778899aabbccddeeff\n\tevent -1 step\n", 11},
		{HEAD + "clip d = $00112233445566778899aabbccddeeff\n\tevent 0.5 step 1 2 3\n", 11},
		{HEAD + "clip d = $00112233445566778899aabbccddeeff\n\tevent 0.5 step [1, 2]\n", 11},
		{HEAD + "\tsize = 2\n", 10},
		{HEAD + "node 1 state\n", 10},
		{HEAD + "node 2 tree\n", 10},
		{HEAD + "node 2 state\n\tname = a\n\tmotion = c\n", 11},
		{HEAD + "node 2 state\n\tname = any\n\tmotion = c\n", 11},
		{HEAD + "node 2 state\n\tname = d\n\tmotion = nothing\n", 12},
		{HEAD + "node 2 state\n\tname = d\n\tmotion = @1.pose\n", 12},
		{HEAD + "node 2 state\n\tname = d\n\tmotion = c\n\tloop = maybe\n", 13},
		{HEAD + "node 2 state\n\tname = d\n\tmotion = c\n\tspeed = -1\n", 13},
		{HEAD + "node 2 state\n\tname = d\n\tmotion = @3.pose\nnode 3 blend_1d\n\tparameter = b\n\tinput.0 = c\n\tat.0 = 0\n\tinput.1 = c\n\tat.1 = 1\n", 14},
		{HEAD + "node 2 state\n\tname = d\n\tmotion = @3.pose\nnode 3 blend_1d\n\tparameter = f\n\tinput.0 = c\n\tat.0 = 0\n", 13},
		{HEAD + "node 2 state\n\tname = d\n\tmotion = @3.pose\nnode 3 blend_1d\n\tparameter = f\n\tinput.0 = c\n\tat.0 = 1\n\tinput.1 = c\n\tat.1 = 1\n", 13},
		{HEAD + "node 2 state\n\tname = d\n\tmotion = @3.pose\nnode 3 blend_1d\n\tparameter = f\n\tinput.0 = c\n\tat.0 = 0\n\tinput.1 = c\n", 17},
		{HEAD + "node 2 transition\n\tfrom = a\n\tto = a\n\twhen = go\n", 10},
		{HEAD + "node 2 transition\n\tfrom = a\n\tto = z\n\twhen = go\n", 12},
		{HEAD + "node 2 transition\n\tfrom = any\n\tto = a\n", 10},
		{HEAD + "node 2 transition\n\tfrom = any\n\tto = a\n\texit_time = 1\n", 10},
		{HEAD + "node 2 transition\n\tfrom = any\n\tto = a\n\twhen = f\n", 13},
		{HEAD + "node 2 transition\n\tfrom = any\n\tto = a\n\twhen = b > 1\n", 13},
		{HEAD + "node 2 transition\n\tfrom = any\n\tto = a\n\twhen = !go\n", 13},
		{HEAD + "node 2 transition\n\tfrom = any\n\tto = a\n\twhen = f >= 1\n", 13},
		{HEAD + "node 2 transition\n\tfrom = any\n\tto = a\n\twhen = go and\n", 13},
		{HEAD + "node 2 transition\n\tfrom = any\n\tto = a\n\twhen = missing\n", 13},
	}
	for c in cases {
		_, problems := animation_graph_parse(c.text, context.temp_allocator)
		testing.expectf(t, len(problems) > 0 && problems[0].line == c.line, "%q: %v", c.text, problems)
	}
}

@(test)
animation_graphs_cook_to_blobs_that_depend_on_their_clips :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/animations/fox.animation_graph", FOX_GRAPH}, {"content/animations/broken.animation_graph", "animation_graph 1\n"}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Animation_Graph}, log_problems = false)
	// The broken graph fails, and the fox cooks.
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Animation_Graph], 1)
	data := tree_blob(t, tree, tree_guid(t, tree, "animations/fox.animation_graph"))
	blob, ok := format.animation_graph_view(data)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, len(format.animation_graph_states(data, blob)), 3)
		testing.expect_value(t, format.blob_string(data, blob.source_path), "game/animations/fox.animation_graph")
	}
	for a in pass.assets {
		if a.kind == .Animation_Graph && a.result == .Cooked {
			testing.expect_value(t, len(a.dependencies), 3)
		}
	}
	// A second cook finds it up to date.
	pass = cook(options, {.Animation_Graph}, log_problems = false)
	testing.expect_value(t, pass.current[.Animation_Graph], 1)
}

// The files that the editor's reader and writer are tested with too (see AnimationGraphFileTests.cs), so the two agree:
// a `# problem` comment is on each line that the cooker reports, and `# nodes:` names the file's nodes.
@(private = "file")
CORPUS := #load_directory("testdata/animation_graphs")

@(test)
the_shared_files_have_their_problems_at_their_lines_and_their_nodes :: proc(t: ^testing.T) {
	testing.expect(t, len(CORPUS) > 0)
	for file in CORPUS {
		text := string(file.data)
		expected := make([dynamic]int, context.temp_allocator)
		nodes := make([dynamic]u32, context.temp_allocator)
		for line, i in strings.split_lines(text, context.temp_allocator) {
			if strings.contains(line, "# problem") {
				append(&expected, i + 1)
			}
			if listed, found := strings.substring_from(line, len("# nodes: ")); found && strings.has_prefix(line, "# nodes: ") {
				for field in strings.fields(strings.trim_space(listed), context.temp_allocator) {
					id, ok := strconv.parse_int(field)
					testing.expect(t, ok)
					append(&nodes, u32(id))
				}
			}
		}
		g, problems := animation_graph_parse(text, context.temp_allocator)
		found := make([dynamic]int, context.temp_allocator)
		for p in problems {
			if len(found) == 0 || found[len(found) - 1] != p.line {
				append(&found, p.line)
			}
		}
		testing.expectf(t, slice.equal(found[:], expected[:]), "%s: problems at %v, expected at %v: %v", file.name, found, expected, problems)
		// A graph without problems has the nodes that the file names; the blob keeps its states' and transitions'.
		if len(problems) == 0 {
			for s in g.states {
				testing.expectf(t, slice.contains(nodes[:], s.node), "%s: state's node %d", file.name, s.node)
			}
			for tr in g.transitions {
				testing.expectf(t, slice.contains(nodes[:], tr.node), "%s: transition's node %d", file.name, tr.node)
			}
		}
	}
}
