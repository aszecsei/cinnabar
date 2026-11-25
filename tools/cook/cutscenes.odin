package cook

import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Cutscenes are .cutscene text files: the entities that a cinematic possesses or spawns, and its tracks on one time axis
// in ticks, each with sections of keyed channels, a clip, a sound or a sub-sequence (see
// docs/content/kinds/cutscenes.md). The cook checks the assets that a cutscene names and its sub-sequences' nesting, which
// it reads from the other cutscenes' sources, so the order of the passes does not matter.
CUTSCENE_COOK_VERSION :: "cutscenes 15"

// CUTSCENE_TEMPLATE is the text of a new cutscene: 10 seconds at 30 frames a second, with no bindings and an empty
// camera cut track. testdata/cutscenes/template.cutscene is the same text, which the editor's tests read.
CUTSCENE_TEMPLATE :: `cutscene 1
# Bindings, tracks, sections and keys (see docs/content/kinds/cutscenes.md). Times are ticks, 60000 a second.
length = 600000
rate = 30

track 1 camera_cut "Cameras"
`

// Cutscene_Problem is an error in a cutscene's text, at a line from 1.
Cutscene_Problem :: struct {
	line:    int,
	message: string,
}

// Cutscene_Reference is an asset that a cutscene names, the kind that it must be, or .None for any kind, and the line
// that names it.
Cutscene_Reference :: struct {
	guid: format.Guid,
	want: format.Asset_Kind,
	line: int,
}

// Cutscene_Parsed is a cutscene's text as cutscene_parse reads it: the contents of its blob, without its GUID, key or
// path, the assets that it names, and the lines of its sub-sequence sections' maps of their children's bindings, which
// the cook checks against the children. The references are there even when the text has problems.
Cutscene_Parsed :: struct {
	contents:   format.Cutscene_Contents,
	references: []Cutscene_Reference,
	maps:       []Cutscene_Map_Line,
}

// Cutscene_Map_Line is a sub-sequence section's map of a child's binding, by its ID in the child, to a binding of the
// cutscene, by its index, at a line, or a sub-sequence section's trim at its line with child 0 and parent
// CUTSCENE_NONE. track and section are indexes into the contents.
Cutscene_Map_Line :: struct {
	track:   int,
	section: int,
	child:   u32,
	parent:  u32,
	line:    int,
}

cook_cutscenes :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	// A sub-sequence's cycle or depth is a property of every cutscene that it reaches, so a pass that looks at one
	// looks at all.
	cutscenes := carry_kind(pass, {.Cutscene}, all_or_nothing = true)
	if len(cutscenes) == 0 {
		return true
	}
	out_dir := config_dir(options)
	if !make_output_dir(pass, out_dir, {.Cutscene}) {
		return false
	}
	// Every asset that a cutscene can name, with the sub-assets in the .meta files, such as a glTF's clips.
	kinds := make(map[format.Guid]format.Asset_Kind, len(assets), context.temp_allocator)
	names := make(map[format.Guid]string, len(assets), context.temp_allocator)
	for a in assets {
		kinds[a.meta.guid] = a.kind
		names[a.meta.guid] = a.name
		for s in a.meta.subassets {
			kinds[s.guid] = format.subasset_kind_of(s.kind)
			names[s.guid] = fmt.tprintf("%s %s %s", a.name, s.kind, s.name)
		}
	}
	sources := make([]Cutscene_Source, len(cutscenes), context.temp_allocator)
	for i, n in cutscenes {
		sources[n] = {assets[i].meta.guid, assets[i].name, string(asset_source(pass, i))}
	}
	graph := cutscene_graph(sources)
	ok := true
	step_begin(pass, .Cutscene, "", len(cutscenes))
	for i, n in cutscenes {
		defer step_advance(pass)
		result := cook_cutscene(&assets[i], &graph.nodes[n], kinds, names, out_dir, pass)
		settle(pass, i, result)
		ok &&= !asset_failed(result)
	}
	return ok
}

// cutscene_check gives the problems of a cutscene's text that the editor has not saved, as a cook of the file at this
// path would: its own, those of the assets that it names, which the index has, and those of its sub-sequences, read
// with the other cutscenes' sources on disk. A text without problems goes in the preview area of the cache,
// <config>/preview/<guid>.blob, which the editor's preview plays; the cutscene's own blob does not change. A text with
// problems leaves the last good one.
cutscene_check :: proc(
	options: Cook_Options,
	index: ^Index,
	guid: format.Guid,
	text, path, name: string,
) -> (
	problems: Problems,
) {
	kinds := index_kinds(index)
	names := make(map[format.Guid]string, len(index.assets), context.temp_allocator)
	sources := make([dynamic]Cutscene_Source, context.temp_allocator)
	append(&sources, Cutscene_Source{guid, name, text})
	for key, a in index.assets {
		g, valid := format.guid_parse(key)
		if !valid {
			continue
		}
		kind := kinds[g]
		file := fmt.tprintf("%s/%s", a.root, a.path)
		names[g] =
			a.parent == "" ? file : fmt.tprintf("%s %s %s", file, format.subasset_kind_name(kind), a.subasset)
		if kind != .Cutscene || a.parent != "" || g == guid {
			continue
		}
		// A cutscene that cannot be read is left out, as a cook fails it on its own.
		for r in options.roots {
			if r.name != a.root {
				continue
			}
			if data, err := os.read_entire_file(
				fmt.tprintf("%s/%s", r.dir, a.path),
				context.temp_allocator,
			); err == nil {
				append(&sources, Cutscene_Source{g, file, string(data)})
			}
		}
	}
	graph := cutscene_graph(sources[:])
	node := &graph.nodes[0]
	found := cutscene_problems(node, kinds, names)
	for p in found {
		report_error(&problems, path, p.line, 0, "%s", p.message)
	}
	if len(found) > 0 {
		return
	}
	dir := fmt.tprintf("%s/preview", config_dir(options))
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		report_error(&problems, dir, 0, 0, "%v", err)
		return
	}
	contents := node.parsed.contents
	contents.guid, contents.source_path = guid, name
	contents.key = cutscene_blob_key(name, transmute([]byte)text, guid)
	if !write_blob(
		fmt.tprintf("%s/%s.blob", dir, guid_text(guid)),
		format.cutscene_write(contents, context.temp_allocator),
	) {
		report_error(&problems, path, 0, 0, "cannot write its preview")
	}
	return
}

// Cutscene_Source is a cutscene's GUID, its name, such as "game/cutscenes/intro.cutscene", and its text.
@(private = "file")
Cutscene_Source :: struct {
	guid: format.Guid,
	name: string,
	text: string,
}

// cutscene_graph parses each cutscene, links the cutscenes that its sub-sequences name, and finds the problems that they
// have together: cycles, depths, and sub-sequences' trims and binds. Its nodes are in the order of the sources.
@(private = "file")
cutscene_graph :: proc(sources: []Cutscene_Source) -> Cutscene_Graph {
	graph := Cutscene_Graph {
		by_guid = make(map[format.Guid]int, len(sources), context.temp_allocator),
		nodes   = make([]Cutscene_Node, len(sources), context.temp_allocator),
	}
	for s, n in sources {
		graph.by_guid[s.guid] = n
	}
	for s, n in sources {
		node := &graph.nodes[n]
		node.name = s.name
		node.parsed, node.problems = cutscene_parse(s.text, context.temp_allocator)
		node.children = make([dynamic]Cutscene_Child, context.temp_allocator)
		for r in node.parsed.references {
			if r.want != .Cutscene {
				continue
			}
			if child, found := graph.by_guid[r.guid]; found {
				append(&node.children, Cutscene_Child{child, r.line})
			}
		}
		node.graph_problems = make([dynamic]Cutscene_Problem, context.temp_allocator)
	}
	cutscene_cycles(&graph)
	cutscene_depths(&graph)
	cutscene_sub_sequences(&graph)
	return graph
}

@(private = "file")
Cutscene_Child :: struct {
	node: int,
	line: int,
}

@(private = "file")
Cutscene_Node :: struct {
	// The cutscene's name, such as "game/cutscenes/intro.cutscene".
	name:           string,
	parsed:         Cutscene_Parsed,
	problems:       []Cutscene_Problem,
	// The cutscenes that its sub-sequence sections name, with the lines that name them.
	children:       [dynamic]Cutscene_Child,
	graph_problems: [dynamic]Cutscene_Problem,
	in_cycle:       bool,
	// The depth of its sub-sequences, 0 without any, once depth_known.
	depth:          int,
	depth_known:    bool,
	// The child on its deepest path, or -1.
	deepest:        int,
}

@(private = "file")
Cutscene_Graph :: struct {
	by_guid: map[format.Guid]int,
	nodes:   []Cutscene_Node,
}

// cutscene_cycles gives each cutscene that reaches itself through its sub-sequences a problem at the line that names the
// next cutscene on its shortest cycle, with the cycle's path. Every cutscene of a cycle reaches itself, so each one fails,
// whatever order the scan found them in.
@(private = "file")
cutscene_cycles :: proc(graph: ^Cutscene_Graph) {
	// A breadth-first search from each cutscene's children, which notes how it reached each cutscene, so the path back
	// to the start is the shortest.
	from := make([]int, len(graph.nodes), context.temp_allocator)
	queue := make([dynamic]int, context.temp_allocator)
	for n in 0 ..< len(graph.nodes) {
		slice.fill(from, -2)
		clear(&queue)
		for c in graph.nodes[n].children {
			if from[c.node] == -2 {
				from[c.node] = -1
				append(&queue, c.node)
			}
		}
		for head := 0; head < len(queue) && from[n] == -2; head += 1 {
			at := queue[head]
			for c in graph.nodes[at].children {
				if from[c.node] == -2 {
					from[c.node] = at
					append(&queue, c.node)
				}
			}
		}
		if from[n] == -2 {
			continue
		}
		// The path from n back to n, walked backwards from n.
		path := make([dynamic]int, context.temp_allocator)
		for at := n; true; {
			append(&path, at)
			at = from[at]
			if at == -1 {
				break
			}
		}
		append(&path, n)
		slice.reverse(path[:])
		builder := strings.builder_make(context.temp_allocator)
		for at, i in path {
			if i > 0 {
				strings.write_string(&builder, " -> ")
			}
			strings.write_string(&builder, graph.nodes[at].name)
		}
		node := &graph.nodes[n]
		line := 0
		for c in node.children {
			if c.node == path[1] {
				line = c.line
				break
			}
		}
		node.in_cycle = true
		append(
			&node.graph_problems,
			Cutscene_Problem {
				line,
				fmt.tprintf("sub-sequence cycle: %s", strings.to_string(builder)),
			},
		)
	}
}

// cutscene_sub_sequences checks each sub-sequence section against the cutscene that it plays, from that cutscene's text:
// its trim within the child's range, and each bind to a binding that the child has, of a kind that fits. The cook sees
// a binding's kind in its own cutscene: a camera when its camera cut track shows it, and an entity with an Animator when
// an animation track drives it. A bind of a camera to an animated entity that is not a camera, either way, is a problem.
@(private = "file")
cutscene_sub_sequences :: proc(graph: ^Cutscene_Graph) {
	Kinds :: struct {
		cameras:  map[u32]bool,
		animated: map[u32]bool,
	}
	kinds_of :: proc(contents: format.Cutscene_Contents) -> (k: Kinds) {
		k.cameras = make(map[u32]bool, context.temp_allocator)
		k.animated = make(map[u32]bool, context.temp_allocator)
		for tr in contents.tracks {
			#partial switch tr.kind {
			case .Camera_Cut:
				for s in tr.sections {
					k.cameras[s.camera] = true
				}
			case .Animation:
				k.animated[tr.binding] = true
			}
		}
		return
	}
	misfit :: proc(a: Kinds, ia: u32, b: Kinds, ib: u32) -> bool {
		return a.cameras[ia] && b.animated[ib] && !b.cameras[ib]
	}
	for &node in graph.nodes {
		contents := node.parsed.contents
		own := kinds_of(contents)
		for m in node.parsed.maps {
			if m.track >= len(contents.tracks) ||
			   m.section >= len(contents.tracks[m.track].sections) {
				continue
			}
			section := contents.tracks[m.track].sections[m.section]
			n, found := graph.by_guid[section.asset]
			if !found {
				continue
			}
			child := graph.nodes[n].parsed.contents
			name := graph.nodes[n].name
			if m.parent == format.CUTSCENE_NONE {
				if child.range_end > child.range_start &&
				   (section.offset < child.range_start ||
						   section.offset >= child.range_end ||
						   section.trim_end > child.range_end) {
					append(
						&node.graph_problems,
						Cutscene_Problem {
							m.line,
							fmt.tprintf(
								"the trim is within %s's range, [%d, %d]",
								name,
								child.range_start,
								child.range_end,
							),
						},
					)
				}
				continue
			}
			index := -1
			for b, k in child.bindings {
				if b.id == m.child {
					index = k
				}
			}
			if index < 0 {
				append(
					&node.graph_problems,
					Cutscene_Problem {
						m.line,
						fmt.tprintf("%s has no binding with the ID %d", name, m.child),
					},
				)
				continue
			}
			theirs := kinds_of(child)
			if misfit(theirs, u32(index), own, m.parent) ||
			   misfit(own, m.parent, theirs, u32(index)) {
				append(
					&node.graph_problems,
					Cutscene_Problem {
						m.line,
						fmt.tprintf(
							"the binding %d of %s and the binding %d here are not of one kind: one is a camera, and the other an animated entity",
							m.child,
							name,
							contents.bindings[m.parent].id,
						),
					},
				)
			}
		}
	}
}

// cutscene_depths gives each cutscene the depth of its sub-sequences, and a problem to each that nests deeper than

// CUTSCENE_MAX_DEPTH, at the line of the first sub-sequence on its deepest path. Cycles have their own problem, so a
// path into one counts it as no depth.
@(private = "file")
cutscene_depths :: proc(graph: ^Cutscene_Graph) {
	depth :: proc(graph: ^Cutscene_Graph, n: int) -> int {
		node := &graph.nodes[n]
		if node.depth_known {
			return node.depth
		}
		node.depth_known, node.deepest = true, -1
		if node.in_cycle {
			return 0
		}
		for c, i in node.children {
			if graph.nodes[c.node].in_cycle {
				continue
			}
			if d := depth(graph, c.node) + 1; d > node.depth {
				node.depth, node.deepest = d, i
			}
		}
		return node.depth
	}
	for n in 0 ..< len(graph.nodes) {
		if depth(graph, n) <= format.CUTSCENE_MAX_DEPTH {
			continue
		}
		node := &graph.nodes[n]
		builder := strings.builder_make(context.temp_allocator)
		strings.write_string(&builder, node.name)
		for at := n; graph.nodes[at].deepest >= 0; {
			at = graph.nodes[at].children[graph.nodes[at].deepest].node
			fmt.sbprintf(&builder, " -> %s", graph.nodes[at].name)
		}
		append(
			&node.graph_problems,
			Cutscene_Problem {
				node.children[node.deepest].line,
				fmt.tprintf(
					"the sub-sequences nest %d deep, past %d: %s",
					node.depth,
					format.CUTSCENE_MAX_DEPTH,
					strings.to_string(builder),
				),
			},
		)
	}
}

@(private = "file")
cook_cutscene :: proc(
	a: ^Asset_Source,
	node: ^Cutscene_Node,
	kinds: map[format.Guid]format.Asset_Kind,
	names: map[format.Guid]string,
	out_dir: string,
	pass: ^Pass,
) -> Asset_Result {
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	// What it names is known whether it cooks or not, so the index has it either way, and fixing an asset that it names
	// cooks it again.
	for r in node.parsed.references {
		if !slice.contains(a.dependencies[:], r.guid) {
			append(&a.dependencies, r.guid)
		}
	}
	found := cutscene_problems(node, kinds, names)
	for p in found {
		report_error(problems, a.path, p.line, 0, "%s", p.message)
	}
	// A cutscene with errors keeps its old blob, so the running game keeps the last good version.
	if len(found) > 0 || !settings_ok {
		return .Failed
	}
	guid := a.meta.guid
	key := cutscene_blob_key(a.name, source_of(a^), guid)
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid))
	if cooked_key(output, .Cutscene, format.cutscene_layout()) == key && !pass.force[guid] {
		return .Current
	}
	contents := node.parsed.contents
	contents.guid, contents.key, contents.source_path = guid, key, a.name
	if !write_blob(output, format.cutscene_write(contents, context.temp_allocator)) {
		return .Failed
	}
	return .Cooked
}

// cutscene_problems is a cutscene's problems, sorted by line: its text's, its sub-sequences', and those of the assets
// that it names, which must exist and be of the kind that their place asks for.
@(private = "file")
cutscene_problems :: proc(
	node: ^Cutscene_Node,
	kinds: map[format.Guid]format.Asset_Kind,
	names: map[format.Guid]string,
) -> []Cutscene_Problem {
	found := make([dynamic]Cutscene_Problem, context.temp_allocator)
	append(&found, ..node.problems)
	append(&found, ..node.graph_problems[:])
	for r in node.parsed.references {
		kind, known := kinds[r.guid]
		switch {
		case !known:
			append(
				&found,
				Cutscene_Problem {
					r.line,
					fmt.tprintf("no asset has the GUID %s", guid_text(r.guid)),
				},
			)
		case r.want != .None && kind != r.want:
			append(
				&found,
				Cutscene_Problem {
					r.line,
					fmt.tprintf(
						"%s is not %s, but %s",
						names[r.guid],
						cutscene_kind_noun(r.want),
						kind_noun(kind),
					),
				},
			)
		}
	}
	slice.stable_sort_by(found[:], proc(a, b: Cutscene_Problem) -> bool {return a.line < b.line})
	return found[:]
}

// cutscene_blob_key is the key of a cutscene's blob: of the cook's version, the cutscene's name, the blob's layout, its
// text and its GUID.
@(private = "file")
cutscene_blob_key :: proc(name: string, source: []byte, guid: format.Guid) -> u64 {
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf(
			"%s\x00%s\x00%x\x00",
			CUTSCENE_COOK_VERSION,
			name,
			format.cutscene_layout(),
		),
	)
	key = hash.fnv64a(source, key)
	guid := guid
	return hash.fnv64a(guid[:], key)
}

// cutscene_kind_noun is what a reference must be, in a message.
@(private = "file")
cutscene_kind_noun :: proc(kind: format.Asset_Kind) -> string {
	#partial switch kind {
	case .Scene:
		return "a scene"
	case .Prefab:
		return "a prefab"
	case .Animation:
		return "an animation"
	case .Audio:
		return "a sound"
	case .Cutscene:
		return "a cutscene"
	case .Ui:
		return "a UI document"
	}
	return kind_noun(kind)
}

@(private = "file")
CUTSCENE_TRACK_KINDS := [format.Cutscene_Track_Kind]string {
	.Transform    = "transform",
	.Property     = "property",
	.Animation    = "animation",
	.Camera_Cut   = "camera_cut",
	.Audio        = "audio",
	.Event        = "event",
	.Sub_Sequence = "sub_sequence",
	.Presentation = "presentation",
}

// What a section of a kind of track names with asset, in a message.
@(private = "file")
CUTSCENE_ASSET_NOUNS := [format.Cutscene_Track_Kind]string {
	.Transform    = "",
	.Property     = "",
	.Animation    = "clip",
	.Camera_Cut   = "",
	.Audio        = "sound",
	.Event        = "",
	.Sub_Sequence = "cutscene",
	.Presentation = "",
}

@(private = "file")
Pending_Binding :: struct {
	contents:    format.Cutscene_Binding_Contents,
	line:        int,
	seen:        [dynamic]string,
	possess:     int,
	spawn:       int,
	provided:    int,
	// The line of policy, which only a possessed or provided binding takes, and of the first setting that only a spawned one takes.
	policy:      int,
	spawn_only:  int,
	spawn_name:  string,
	parent_line: int,
	// The line of suspend, or 0 when the binding takes the cutscene's.
	suspend:     int,
	// The constraints on the binding as a camera.
	constraints: Pending_Constraints,
}

// Pending_Constraints is the camera constraints that a section or a binding sets: of each kind, the ID of the binding
// that it targets and the lines of its settings, 0 for a setting that it does not have.
@(private = "file")
Pending_Constraints :: struct {
	targets:       [format.Cutscene_Constraint_Kind]u32,
	lines:         [format.Cutscene_Constraint_Kind]int,
	offsets:       [format.Cutscene_Constraint_Kind][3]f32,
	offset_lines:  [format.Cutscene_Constraint_Kind]int,
	dampings:      [format.Cutscene_Constraint_Kind]i32,
	damping_lines: [format.Cutscene_Constraint_Kind]int,
	// The line of the first constraint setting, to report one on a section or binding that takes none.
	first:         int,
}

// The constraint settings' names, by kind. A Focus constraint has no offset or damping.
@(private = "file")
CUTSCENE_CONSTRAINT_NAMES := [format.Cutscene_Constraint_Kind]string {
	.Look_At = "look_at",
	.Follow  = "follow",
	.Focus   = "focus",
}

@(private = "file")
Pending_Channel :: struct {
	name:           string,
	line:           int,
	keys:           [dynamic]format.Cutscene_Key,
	// How many of its keys name an asset.
	guids:          int,
	// The line of its first key that teleports, or 0.
	teleport:       int,
	// Its pre_infinity and post_infinity, and the lines that set them, or 0.
	infinity:       [2]format.Cutscene_Infinity,
	infinity_lines: [2]int,
}

// The infinity modes' names, as a channel's pre_infinity and post_infinity take them.
@(private = "file")
CUTSCENE_INFINITY_NAMES := [format.Cutscene_Infinity]string {
	.Constant     = "constant",
	.Linear       = "linear",
	.Cycle        = "cycle",
	.Cycle_Offset = "cycle_offset",
	.Oscillate    = "oscillate",
}

@(private = "file")
Pending_Section :: struct {
	contents:           format.Cutscene_Section_Contents,
	line:               int,
	seen:               [dynamic]string,
	asset_line:         int,
	blend_line:         int,
	// The lines of the settings that only a section that plays its clip takes: offset, speed, loop and root_motion.
	play_lines:         [4]int,
	// The line of the first of ease_in, ease_out, weight, pre_roll and post_roll, which a camera cut section does
	// not take, and its name.
	shape_line:         int,
	shape_name:         string,
	// The settings that only a camera cut section takes: the ID of its camera's binding, and the lines of camera,
	// blend_in, blend_out and blend_on_skip.
	camera_id:          u32,
	cut_lines:          [4]int,
	// The lines of the settings that only an audio section takes: bus, min_distance, max_distance and
	// plays_through_skip. And the line of the first of pre_roll and post_roll, which an audio section does not take.
	audio_lines:        [4]int,
	roll_line:          int,
	// The settings that only a sub-sequence section takes: the lines of trim and scale, and its binds.
	sub_lines:          [2]int,
	// The line of a sub-sequence section's name, which the editor's shot list shows. It is not in the blob.
	name_line:          int,
	binds:              [dynamic]Pending_Bind,
	// The lines of the settings that only a presentation section takes: kind, color, speaker, text, key and audio,
	// and the ID of the audio section that audio names.
	presentation_lines: [6]int,
	audio_id:           u32,
	constraints:        Pending_Constraints,
	channels:           [dynamic]Pending_Channel,
}

// Pending_Bind is a sub-sequence section's `bind <child binding id> = <binding id>` line.
@(private = "file")
Pending_Bind :: struct {
	child:  u32,
	parent: u32,
	line:   int,
}

@(private = "file")
Pending_Track :: struct {
	contents:       format.Cutscene_Track_Contents,
	line:           int,
	seen:           [dynamic]string,
	binding_id:     u32,
	binding_line:   int,
	// The lines of component and field, which only a property track takes.
	component_line: int,
	field_line:     int,
	// The lines of space and origin, which only a transform track takes, and the ID of the binding that space names.
	space_line:     int,
	origin_line:    int,
	relative_id:    u32,
	// The lines of gain and time_scale, which only an audio track takes.
	audio_lines:    [2]int,
	// The line of letterbox_aspect, which only a presentation track takes.
	aspect_line:    int,
	// The line of when_finished, which an event track does not take.
	finish_line:    int,
	sections:       [dynamic]Pending_Section,
	events:         [dynamic]Pending_Event,
}

// Pending_Event is a trigger or a range of an event track, with its values. An Entity value's index is still its
// binding's ID.
@(private = "file")
Pending_Event :: struct {
	contents: format.Cutscene_Event_Contents,
	line:     int,
	seen:     [dynamic]string,
	values:   [dynamic]Pending_Value,
}

@(private = "file")
Pending_Value :: struct {
	contents: format.Cutscene_Event_Value_Contents,
	line:     int,
}

// Pending_Marker is a marker, with the line that sets its color.
@(private = "file")
Pending_Marker :: struct {
	contents:   format.Cutscene_Marker_Contents,
	line:       int,
	color_line: int,
}

// CUTSCENE_MARKER_COLOR is the color of a marker without one: amber.
CUTSCENE_MARKER_COLOR :: [3]u8{0xf5, 0xa6, 0x23}

// Cutscene_Block is the innermost block that a line is in.
@(private = "file")
Cutscene_Block :: enum {
	Header,
	Binding,
	Track,
	Section,
	Channel,
	Event,
	Marker,
}

// cutscene_parse parses a cutscene's text: the first line `cutscene 1`, the header's settings, then `binding <id>
// "<name>"` and `track <id> <kind> "<name>"` blocks, a track's `section <id> <start> <end>` blocks, a section's `channel
// <name>` blocks and a channel's `key <time> <value> <interp> [<in> <out>]` lines, and an event track's `trigger <id>
// <time> <name>` and `range <id> <start> <end> <name>` blocks, and the cutscene's `marker <id> <time> "<name>"` blocks. A
// `<name> = <value>` line sets a setting of the innermost block. It checks everything but the assets that the text names, and gives every problem that
// it finds; the cutscene is good only without any.
cutscene_parse :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	parsed: Cutscene_Parsed,
	problems: []Cutscene_Problem,
) {
	context.allocator = allocator
	found := make([dynamic]Cutscene_Problem)
	problem :: proc(found: ^[dynamic]Cutscene_Problem, line: int, f: string, args: ..any) {
		append(found, Cutscene_Problem{line, fmt.aprintf(f, ..args)})
	}
	references := make([dynamic]Cutscene_Reference)
	bindings := make([dynamic]Pending_Binding)
	tracks := make([dynamic]Pending_Track)
	header_seen := make([dynamic]string)
	contents := format.Cutscene_Contents {
		rate          = 30,
		input_context = format.CUTSCENE_INPUT_CONTEXT,
	}
	// What a binding without its own suspend suspends.
	default_suspend := format.CUTSCENE_SUSPEND_ALL
	hide_ui := make([dynamic]format.Guid)
	header_line, length_seen, range_line, skip_line := 0, false, 0, 0
	skip_ranges := make([dynamic]format.Cutscene_Skip_Range)
	block := Cutscene_Block.Header
	section_ids := make(map[u32]bool, 16, context.temp_allocator)
	event_ids := make(map[u32]bool, 16, context.temp_allocator)
	event_count := 0
	markers := make([dynamic]Pending_Marker)
	// The assets that keys name, in the blob's order, and each one's index.
	guids := make([dynamic]format.Guid)
	guid_index := make(map[format.Guid]int, 16, context.temp_allocator)
	// The sub-sequence sections' binds, as maps with their lines.
	maps := make([dynamic]Cutscene_Map_Line)
	section_count, channel_count, key_count := 0, 0, 0
	for raw, index in strings.split_lines(text) {
		line := index + 1
		trimmed := strings.trim_space(format.strip_comment(raw, hash_in_word = true))
		if trimmed == "" {
			continue
		}
		if header_line == 0 {
			if fields := strings.fields(trimmed, context.temp_allocator);
			   len(fields) == 2 && fields[0] == "cutscene" && fields[1] == "1" {
				header_line = line
				continue
			}
			problem(&found, line, "a cutscene starts with `cutscene 1`")
			return {}, found[:]
		}
		word, _, rest := strings.partition(trimmed, " ")
		rest = strings.trim_space(rest)
		is_block := !strings.has_prefix(rest, "=")
		if is_block && word == "binding" {
			block = .Binding
			b := Pending_Binding {
				line = line,
				seen = make([dynamic]string),
				contents = {
					parent = format.CUTSCENE_NONE,
					rotation = {0, 0, 0, 1},
					scale = {1, 1, 1},
				},
			}
			id_text, _, name_text := strings.partition(rest, " ")
			id, id_ok := format.whole_id(id_text)
			name, name_ok := cutscene_name(strings.trim_space(name_text))
			if !id_ok || !name_ok || name == "" {
				problem(
					&found,
					line,
					"a binding is `binding <id> \"<name>\"`, with an ID from 1 to 2147483647 and a name",
				)
			}
			for other in bindings {
				if id_ok && other.contents.id == id {
					problem(&found, line, "the cutscene has a binding with the ID %d already", id)
				}
				if name_ok && name != "" {
					if other.contents.name == name {
						problem(&found, line, "the cutscene has a binding named %q already", name)
					} else if format.animation_graph_hash(other.contents.name) ==
					   format.animation_graph_hash(name) {
						problem(
							&found,
							line,
							"the bindings %q and %q have the same hash: rename one",
							other.contents.name,
							name,
						)
					}
				}
			}
			if len(bindings) == format.MAX_CUTSCENE_BINDINGS {
				problem(
					&found,
					line,
					"a cutscene has at most %d bindings",
					format.MAX_CUTSCENE_BINDINGS,
				)
			}
			b.contents.id, b.contents.name = id, strings.clone(name)
			append(&bindings, b)
			continue
		}
		if is_block && word == "marker" {
			block = .Marker
			m := Pending_Marker {
				line = line,
				contents = {color = CUTSCENE_MARKER_COLOR},
			}
			id_text, _, after_id := strings.partition(rest, " ")
			time_text, _, name_text := strings.partition(strings.trim_space(after_id), " ")
			id, id_ok := format.whole_id(id_text)
			time, time_ok := format.whole_ticks(time_text)
			name, name_ok := cutscene_name(strings.trim_space(name_text))
			if !id_ok || !time_ok || !name_ok || name == "" {
				problem(
					&found,
					line,
					"a marker is `marker <id> <time> \"<name>\"`, with an ID from 1 to 2147483647, a time in whole ticks and a name",
				)
			}
			for other in markers {
				if id_ok && other.contents.id == id {
					problem(&found, line, "the cutscene has a marker with the ID %d already", id)
				}
			}
			if len(markers) == format.MAX_CUTSCENE_MARKERS {
				problem(
					&found,
					line,
					"a cutscene has at most %d markers",
					format.MAX_CUTSCENE_MARKERS,
				)
			}
			m.contents.id, m.contents.time, m.contents.name = id, time, strings.clone(name)
			append(&markers, m)
			continue
		}
		if is_block && word == "track" {
			block = .Track
			tr := Pending_Track {
				line = line,
				seen = make([dynamic]string),
				sections = make([dynamic]Pending_Section),
				events = make([dynamic]Pending_Event),
				contents = {binding = format.CUTSCENE_NONE},
			}
			id_text, _, after_id := strings.partition(rest, " ")
			kind_text, _, name_text := strings.partition(strings.trim_space(after_id), " ")
			id, id_ok := format.whole_id(id_text)
			name, name_ok := cutscene_name(strings.trim_space(name_text))
			kind_ok := false
			for k, kind in CUTSCENE_TRACK_KINDS {
				if k == kind_text {
					tr.contents.kind, kind_ok = kind, true
				}
			}
			switch {
			case !id_ok || !name_ok || kind_text == "":
				problem(
					&found,
					line,
					"a track is `track <id> <kind> \"<name>\"`, with an ID from 1 to 2147483647",
				)
			case !kind_ok:
				problem(
					&found,
					line,
					"%q is not a track's kind: transform, property, animation, camera_cut, audio, event, sub_sequence or presentation",
					kind_text,
				)
			}
			for other in tracks {
				if id_ok && other.contents.id == id {
					problem(&found, line, "the cutscene has a track with the ID %d already", id)
				}
			}
			if len(tracks) == format.MAX_CUTSCENE_TRACKS {
				problem(
					&found,
					line,
					"a cutscene has at most %d tracks",
					format.MAX_CUTSCENE_TRACKS,
				)
			}
			tr.contents.id, tr.contents.name = id, strings.clone(name)
			append(&tracks, tr)
			continue
		}
		if is_block && word == "section" {
			if block != .Track && block != .Section && block != .Channel && block != .Event {
				problem(&found, line, "a section comes after a track line")
				continue
			}
			block = .Section
			tr := &tracks[len(tracks) - 1]
			s := Pending_Section {
				line = line,
				seen = make([dynamic]string),
				channels = make([dynamic]Pending_Channel),
				contents = {weight = 1},
			}
			fields := strings.fields(rest, context.temp_allocator)
			ok := len(fields) == 3
			id: u32
			if ok {
				id_ok, start_ok, end_ok: bool
				id, id_ok = format.whole_id(fields[0])
				s.contents.start, start_ok = format.whole_ticks(fields[1])
				s.contents.end, end_ok = format.whole_ticks(fields[2])
				ok = id_ok && start_ok && end_ok
			}
			if !ok {
				problem(
					&found,
					line,
					"a section is `section <id> <start> <end>`, with an ID from 1 to 2147483647 and times in whole ticks",
				)
			} else if section_ids[id] {
				problem(&found, line, "the cutscene has a section with the ID %d already", id)
			} else if s.contents.start >= s.contents.end {
				problem(&found, line, "a section starts before it ends")
			}
			section_ids[id] = true
			s.contents.id = id
			section_count += 1
			if section_count == format.MAX_CUTSCENE_SECTIONS + 1 {
				problem(
					&found,
					line,
					"a cutscene has at most %d sections",
					format.MAX_CUTSCENE_SECTIONS,
				)
			}
			append(&tr.sections, s)
			continue
		}
		if is_block && (word == "trigger" || word == "range") {
			if block == .Header || block == .Binding || block == .Marker {
				problem(&found, line, "a %s comes after a track line", word)
				continue
			}
			block = .Event
			tr := &tracks[len(tracks) - 1]
			ev := Pending_Event {
				line   = line,
				seen   = make([dynamic]string),
				values = make([dynamic]Pending_Value),
			}
			is_range := word == "range"
			fields := strings.fields(rest, context.temp_allocator)
			ok := len(fields) == (4 if is_range else 3)
			id: u32
			if ok {
				id_ok, start_ok, end_ok: bool
				id, id_ok = format.whole_id(fields[0])
				ev.contents.start, start_ok = format.whole_ticks(fields[1])
				ev.contents.end, end_ok = ev.contents.start, true
				if is_range {
					ev.contents.end, end_ok = format.whole_ticks(fields[2])
				}
				ev.contents.name = fields[len(fields) - 1]
				ok = id_ok && start_ok && end_ok && is_identifier(ev.contents.name)
			}
			switch {
			case !ok && is_range:
				problem(
					&found,
					line,
					"a range is `range <id> <start> <end> <name>`, with an ID from 1 to 2147483647, times in whole ticks and a name of letters, digits and _",
				)
			case !ok:
				problem(
					&found,
					line,
					"a trigger is `trigger <id> <time> <name>`, with an ID from 1 to 2147483647, a time in whole ticks and a name of letters, digits and _",
				)
			case event_ids[id]:
				problem(
					&found,
					line,
					"the cutscene has a trigger or a range with the ID %d already",
					id,
				)
			case is_range && ev.contents.start >= ev.contents.end:
				problem(&found, line, "a range starts before it ends")
			}
			event_ids[id] = true
			ev.contents.id = id
			ev.contents.name = strings.clone(ev.contents.name) if ok else ""
			if is_range {
				ev.contents.flags += {.Range}
			}
			event_count += 1
			if event_count == format.MAX_CUTSCENE_EVENTS + 1 {
				problem(
					&found,
					line,
					"a cutscene has at most %d triggers and ranges",
					format.MAX_CUTSCENE_EVENTS,
				)
			}
			append(&tr.events, ev)
			continue
		}
		if is_block && word == "channel" {
			if block != .Section && block != .Channel {
				problem(&found, line, "a channel comes after a section line")
				continue
			}
			block = .Channel
			tr := &tracks[len(tracks) - 1]
			s := &tr.sections[len(tr.sections) - 1]
			if !is_identifier(rest) {
				problem(
					&found,
					line,
					"a channel is `channel <name>`, a name of letters, digits and _",
				)
			}
			for c in s.channels {
				if c.name == rest {
					problem(&found, line, "the section has a channel named %s already", rest)
				}
			}
			channel_count += 1
			if channel_count == format.MAX_CUTSCENE_CHANNELS + 1 {
				problem(
					&found,
					line,
					"a cutscene has at most %d channels",
					format.MAX_CUTSCENE_CHANNELS,
				)
			}
			append(
				&s.channels,
				Pending_Channel {
					name = strings.clone(rest),
					line = line,
					keys = make([dynamic]format.Cutscene_Key),
				},
			)
			continue
		}
		if is_block && word == "bind" {
			if block != .Section {
				problem(
					&found,
					line,
					"a bind comes after a section line, before the section's channels",
				)
				continue
			}
			tr := &tracks[len(tracks) - 1]
			s := &tr.sections[len(tr.sections) - 1]
			child_text, has_parent, parent_text := strings.partition(rest, "=")
			child, child_ok := format.whole_id(strings.trim_space(child_text))
			parent, parent_ok := format.whole_id(strings.trim_space(parent_text))
			if has_parent == "" || !child_ok || !parent_ok {
				problem(
					&found,
					line,
					"a bind is `bind <id of the sub-sequence's binding> = <id of a binding of this cutscene>`",
				)
				continue
			}
			for other in s.binds {
				if other.child == child {
					problem(&found, line, "the section binds the binding %d already", child)
				}
			}
			append(&s.binds, Pending_Bind{child, parent, line})
			continue
		}
		if is_block && word == "key" {
			if block != .Channel {
				problem(&found, line, "a key comes after a channel line")
				continue
			}
			tr := &tracks[len(tracks) - 1]
			s := &tr.sections[len(tr.sections) - 1]
			c := &s.channels[len(s.channels) - 1]
			key, guid, message := cutscene_key(rest, s.contents.end - s.contents.start)
			if message != "" {
				problem(&found, line, "%s", message)
				continue
			}
			if len(c.keys) > 0 && key.time <= c.keys[len(c.keys) - 1].time {
				problem(&found, line, "keys are in order of time, each after the one before")
				continue
			}
			if .Teleport in key.flags && c.teleport == 0 {
				c.teleport = line
			}
			if guid != {} {
				slot, known := guid_index[guid]
				if !known {
					slot = len(guids)
					guid_index[guid] = slot
					append(&guids, guid)
					append(&references, Cutscene_Reference{guid, .None, line})
				}
				key.value = f32(slot)
				c.guids += 1
			}
			key_count += 1
			if key_count == format.MAX_CUTSCENE_KEYS + 1 {
				problem(&found, line, "a cutscene has at most %d keys", format.MAX_CUTSCENE_KEYS)
			}
			append(&c.keys, key)
			continue
		}
		name, has_value, value_text := strings.partition(trimmed, "=")
		name, value_text = strings.trim_space(name), strings.trim_space(value_text)
		if has_value == "" || !is_identifier(name) {
			problem(
				&found,
				line,
				"a line is binding, track, marker, section, channel, key, trigger, range or `<name> = <value>`",
			)
			continue
		}
		switch block {
		case .Header:
			if slice.contains(header_seen[:], name) {
				problem(&found, line, "%s is set twice", name)
				continue
			}
			append(&header_seen, name)
			switch name {
			case "length":
				ticks, ok := format.whole_ticks(value_text)
				if !ok || ticks == 0 {
					problem(&found, line, "length is a whole number of ticks from 1 to 2147483647")
					continue
				}
				contents.length, length_seen = ticks, true
			case "rate":
				value, message := parse_graph_value(value_text)
				rate := u32(value.numbers[0])
				if message != "" ||
				   value.kind != .Numbers ||
				   value.count != 1 ||
				   f64(rate) != value.numbers[0] ||
				   !format.cutscene_rate_valid(rate) {
					problem(&found, line, "rate is 24, 25, 30, 48, 50 or 60")
					continue
				}
				contents.rate = rate
			case "clock":
				switch value_text {
				case "game":
					contents.clock = .Game
				case "real":
					contents.clock = .Real
				case:
					problem(&found, line, "clock is game or real")
				}
			case "range":
				value, message := parse_graph_value(value_text)
				start, start_ok := cutscene_ticks_number(value.numbers[0])
				end, end_ok := cutscene_ticks_number(value.numbers[1])
				if message != "" ||
				   value.kind != .Numbers ||
				   value.count != 2 ||
				   !start_ok ||
				   !end_ok {
					problem(&found, line, "range is two whole numbers of ticks, [<start>, <end>]")
					continue
				}
				contents.range_start, contents.range_end, range_line = start, end, line
			case "suspend":
				set, ok := cutscene_suspend(value_text)
				if !ok {
					problem(&found, line, "%s", CUTSCENE_SUSPEND_MESSAGE)
					continue
				}
				default_suspend = set
			case "input_context":
				context_name, ok := cutscene_name(value_text)
				if !ok || len(context_name) > format.CUTSCENE_INPUT_CONTEXT_CAPACITY {
					problem(
						&found,
						line,
						"input_context is the quoted name of an input context, at most %d bytes, or \"\" for none",
						format.CUTSCENE_INPUT_CONTEXT_CAPACITY,
					)
					continue
				}
				contents.input_context = strings.clone(context_name)
			case "hide_ui":
				items, ok := cutscene_list(value_text)
				for item in items {
					value, message := parse_graph_value(item)
					if message != "" || value.kind != .Asset || value.guid == {} {
						ok = false
						break
					}
					append(&hide_ui, value.guid)
					append(&references, Cutscene_Reference{value.guid, .Ui, line})
				}
				if !ok {
					problem(&found, line, "hide_ui is a list of UI documents, [$<guid>, ...]")
				}
			case "skip":
				switch value_text {
				case "anywhere":
					contents.skip = .Anywhere
				case "none":
					contents.skip = .None
				case:
					ranges, ok := cutscene_skip_ranges(value_text)
					if !ok {
						problem(
							&found,
							line,
							"skip is anywhere, none, or a list of ranges in ticks, [[<start>, <end>], ...]",
						)
						continue
					}
					contents.skip = .Ranges
					append(&skip_ranges, ..ranges)
					skip_line = line
				}
			case "skip_fade":
				ticks, ok := format.whole_ticks(value_text)
				if !ok {
					problem(
						&found,
						line,
						"skip_fade is a whole number of ticks from 0 to 2147483647",
					)
					continue
				}
				contents.skip_fade = ticks
			case "skip_color":
				color, ok := cutscene_color(value_text)
				if !ok {
					problem(&found, line, "skip_color is %s", CUTSCENE_COLOR_FORM)
					continue
				}
				contents.skip_color = color
			case:
				problem(
					&found,
					line,
					"%q is not a setting of the cutscene: length, rate, clock, range, suspend, input_context, hide_ui, skip, skip_fade or skip_color",
					name,
				)
			}
		case .Binding:
			b := &bindings[len(bindings) - 1]
			if slice.contains(b.seen[:], name) {
				problem(&found, line, "%s is set twice", name)
				continue
			}
			append(&b.seen, name)
			cutscene_binding_setting(&found, &references, bindings[:], b, name, value_text, line)
		case .Track:
			tr := &tracks[len(tracks) - 1]
			if slice.contains(tr.seen[:], name) {
				problem(&found, line, "%s is set twice", name)
				continue
			}
			append(&tr.seen, name)
			switch name {
			case "binding":
				id, ok := format.whole_id(value_text)
				if !ok {
					problem(&found, line, "binding is the ID of a binding of the cutscene")
					continue
				}
				tr.binding_id, tr.binding_line = id, line
			case "muted":
				switch value_text {
				case "true":
					tr.contents.flags += {.Muted}
				case "false":
				case:
					problem(&found, line, "muted is true or false")
				}
			case "when_finished":
				switch value_text {
				case "restore":
					tr.contents.finish = .Restore
				case "keep":
					tr.contents.finish = .Keep
				case:
					problem(&found, line, "when_finished is restore or keep")
				}
				tr.finish_line = line
			case "component":
				id, ok := strconv.parse_u64_of_base(value_text, 10)
				if !ok || id == 0 {
					problem(
						&found,
						line,
						"component is a component's stable ID in decimal, as a scene names it",
					)
					continue
				}
				tr.contents.component, tr.component_line = id, line
			case "field":
				field, ok := cutscene_name(value_text)
				if !ok || !cutscene_field_name(field) {
					problem(
						&found,
						line,
						"field is the quoted name of a field, with dots between the names of nested fields, such as \"light.intensity\"",
					)
					continue
				}
				tr.contents.field, tr.field_line = strings.clone(field), line
			case "space":
				words := strings.fields(value_text, context.temp_allocator)
				id: u32
				space: format.Cutscene_Space
				ok := true
				switch {
				case len(words) == 1 && words[0] == "absolute":
					space = .Absolute
				case len(words) == 1 && words[0] == "relative":
					space = .Relative
				case len(words) == 2 && words[0] == "relative":
					space = .Relative_To
					id, ok = format.whole_id(words[1])
				case:
					ok = false
				}
				if !ok {
					problem(
						&found,
						line,
						"space is absolute, relative, or relative <binding id> for another binding",
					)
					continue
				}
				tr.contents.space, tr.relative_id, tr.space_line = space, id, line
			case "gain":
				value, message := parse_graph_value(value_text)
				if message != "" ||
				   value.kind != .Numbers ||
				   value.count != 1 ||
				   !(value.numbers[0] >= 0) ||
				   f32(value.numbers[0]) > max(f32) {
					problem(&found, line, "gain is a number from 0")
					continue
				}
				tr.contents.gain, tr.audio_lines[0] = f32(value.numbers[0]), line
			case "time_scale":
				switch value_text {
				case "follow":
					tr.contents.time_scale = .Follow
				case "free":
					tr.contents.time_scale = .Free
				case:
					problem(&found, line, "time_scale is follow or free")
					continue
				}
				tr.audio_lines[1] = line
			case "letterbox_aspect":
				switch value_text {
				case "camera":
					tr.contents.flags += {.Follow_Camera}
				case "sections":
				case:
					problem(&found, line, "letterbox_aspect is camera or sections")
					continue
				}
				tr.aspect_line = line
			case "origin":
				value, message := parse_graph_value(value_text)
				ok := message == "" && value.kind == .Numbers && value.count == 3
				origin: [3]i64
				for axis in 0 ..< 3 {
					raw, in_range := format.world_raw_from_meters(value.numbers[axis])
					ok &&= in_range
					origin[axis] = raw
				}
				if !ok {
					problem(
						&found,
						line,
						"origin is three numbers in meters, [x, y, z], inside the bounds of a World_Position",
					)
					continue
				}
				tr.contents.origin, tr.origin_line = origin, line
			case "fire_on_seek", "fire_when_skipped", "value":
				problem(&found, line, "%s is a setting of a trigger or a range", name)
			case:
				problem(
					&found,
					line,
					"%q is not a setting of a track: binding, muted, when_finished, component, field, space, origin, gain, time_scale or letterbox_aspect",
					name,
				)
			}
		case .Event:
			tr := &tracks[len(tracks) - 1]
			ev := &tr.events[len(tr.events) - 1]
			if name != "value" {
				if slice.contains(ev.seen[:], name) {
					problem(&found, line, "%s is set twice", name)
					continue
				}
				append(&ev.seen, name)
			}
			switch name {
			case "fire_on_seek", "fire_when_skipped":
				flag: format.Cutscene_Event_Flag =
					.Fire_On_Seek if name == "fire_on_seek" else .Fire_When_Skipped
				switch value_text {
				case "true":
					ev.contents.flags += {flag}
				case "false":
					ev.contents.flags -= {flag}
				case:
					problem(&found, line, "%s is true or false", name)
				}
			case "value":
				if len(ev.values) == format.MAX_CUTSCENE_EVENT_VALUES {
					problem(
						&found,
						line,
						"a trigger or a range has at most %d values",
						format.MAX_CUTSCENE_EVENT_VALUES,
					)
					continue
				}
				v, message := cutscene_event_value(value_text)
				if message != "" {
					problem(&found, line, "%s", message)
					continue
				}
				if v.kind == .Asset {
					slot, known := guid_index[v.guid]
					if !known {
						slot = len(guids)
						guid_index[v.guid] = slot
						append(&guids, v.guid)
						append(&references, Cutscene_Reference{v.guid, .None, line})
					}
					v.contents.index = u32(slot)
				}
				append(&ev.values, Pending_Value{contents = v.contents, line = line})
			case "binding",
			     "muted",
			     "when_finished",
			     "component",
			     "field",
			     "space",
			     "origin",
			     "gain",
			     "time_scale",
			     "letterbox_aspect":
				problem(&found, line, "%s comes before the track's triggers and ranges", name)
			case:
				problem(
					&found,
					line,
					"%q is not a setting of a trigger or a range: value, fire_on_seek or fire_when_skipped",
					name,
				)
			}
		case .Section:
			tr := &tracks[len(tracks) - 1]
			s := &tr.sections[len(tr.sections) - 1]
			if slice.contains(s.seen[:], name) {
				problem(&found, line, "%s is set twice", name)
				continue
			}
			append(&s.seen, name)
			switch name {
			case "ease_in", "ease_out", "pre_roll", "post_roll", "weight":
				if s.shape_line == 0 {
					s.shape_line, s.shape_name = line, name
				}
			}
			if cutscene_constraint_setting(&found, &s.constraints, name, value_text, line) {
				continue
			}
			switch name {
			case "ease_in", "ease_out", "pre_roll", "post_roll":
				ticks, ok := format.whole_ticks(value_text)
				if !ok {
					problem(&found, line, "%s is a whole number of ticks", name)
					continue
				}
				switch name {
				case "ease_in":
					s.contents.ease_in = ticks
				case "ease_out":
					s.contents.ease_out = ticks
				case "pre_roll":
					s.contents.pre_roll = ticks
				case "post_roll":
					s.contents.post_roll = ticks
				}
				if (name == "pre_roll" || name == "post_roll") && s.roll_line == 0 {
					s.roll_line = line
				}
			case "weight":
				value, message := parse_graph_value(value_text)
				if message != "" ||
				   value.kind != .Numbers ||
				   value.count != 1 ||
				   !(value.numbers[0] >= 0 && value.numbers[0] <= 1) {
					problem(&found, line, "weight is a number from 0 to 1")
					continue
				}
				s.contents.weight = f32(value.numbers[0])
			case "asset":
				value, message := parse_graph_value(value_text)
				if message != "" || value.kind != .Asset || value.guid == {} {
					problem(&found, line, "asset is $<guid>, with 32 hex digits")
					continue
				}
				s.contents.asset, s.asset_line = value.guid, line
			case "blend":
				switch value_text {
				case "absolute":
					s.contents.flags -= {.Additive}
				case "additive":
					s.contents.flags += {.Additive}
				case:
					problem(&found, line, "blend is absolute or additive")
					continue
				}
				s.blend_line = line
			case "trim":
				start_text, _, end_text := strings.partition(value_text, " ")
				start, start_ok := format.whole_ticks(start_text)
				end, end_ok := i32(0), true
				if end_text = strings.trim_space(end_text); end_text != "" {
					end, end_ok = format.whole_ticks(end_text)
				}
				if !start_ok || !end_ok || (end != 0 && end <= start) {
					problem(
						&found,
						line,
						"trim is the sub-sequence's start and, if not its end, its end, in ticks on its time: <start> [<end>]",
					)
					continue
				}
				s.contents.offset, s.contents.trim_end, s.sub_lines[0] = start, end, line
			case "name":
				if _, ok := cutscene_name(value_text); !ok {
					problem(&found, line, "name is quoted text")
					continue
				}
				s.name_line = line
			case "scale":
				value, message := parse_graph_value(value_text)
				if message != "" ||
				   value.kind != .Numbers ||
				   value.count != 1 ||
				   !(value.numbers[0] > 0) ||
				   f32(value.numbers[0]) > max(f32) {
					problem(
						&found,
						line,
						"scale is a number above 0: the sub-sequence's time per the cutscene's",
					)
					continue
				}
				s.contents.speed, s.sub_lines[1] = f32(value.numbers[0]), line
			case "offset":
				ticks, ok := format.whole_ticks(value_text)
				if !ok {
					problem(&found, line, "offset is a whole number of ticks into the clip")
					continue
				}
				s.contents.offset, s.play_lines[0] = ticks, line
			case "speed":
				value, message := parse_graph_value(value_text)
				if message != "" ||
				   value.kind != .Numbers ||
				   value.count != 1 ||
				   !(value.numbers[0] > 0) ||
				   f32(value.numbers[0]) > max(f32) {
					problem(
						&found,
						line,
						"speed is a number above 0: the clip's time per the cutscene's",
					)
					continue
				}
				s.contents.speed, s.play_lines[1] = f32(value.numbers[0]), line
			case "loop":
				switch value_text {
				case "true":
					s.contents.flags += {.Loop}
				case "false":
					s.contents.flags -= {.Loop}
				case:
					problem(&found, line, "loop is true or false")
					continue
				}
				s.play_lines[2] = line
			case "root_motion":
				switch value_text {
				case "bake":
					s.contents.root_motion = .Bake
				case "apply":
					s.contents.root_motion = .Apply
				case "in_place":
					s.contents.root_motion = .In_Place
				case:
					problem(&found, line, "root_motion is bake, apply or in_place")
					continue
				}
				s.play_lines[3] = line
			case "camera":
				id, ok := format.whole_id(value_text)
				if !ok {
					problem(&found, line, "camera is the ID of a binding of the cutscene")
					continue
				}
				s.camera_id, s.cut_lines[0] = id, line
			case "blend_in", "blend_out":
				ticks_text, _, curve_text := strings.partition(value_text, " ")
				ticks, ticks_ok := format.whole_ticks(ticks_text)
				curve, curve_ok := cutscene_blend_curve(strings.trim_space(curve_text))
				if !ticks_ok || !curve_ok {
					problem(
						&found,
						line,
						"%s is a whole number of ticks and a curve: linear (the default), smooth, ease_in or ease_out",
						name,
					)
					continue
				}
				if name == "blend_in" {
					s.contents.blend_in, s.contents.blend_curves[0], s.cut_lines[1] =
						ticks, curve, line
				} else {
					s.contents.blend_out, s.contents.blend_curves[1], s.cut_lines[2] =
						ticks, curve, line
				}
			case "blend_on_skip":
				switch value_text {
				case "true":
					s.contents.flags += {.Blend_On_Skip}
				case "false":
					s.contents.flags -= {.Blend_On_Skip}
				case:
					problem(&found, line, "blend_on_skip is true or false")
					continue
				}
				s.cut_lines[3] = line
			case "bus":
				value, message := parse_graph_value(value_text)
				if message != "" ||
				   value.kind != .Numbers ||
				   value.count != 1 ||
				   !(value.numbers[0] >= 0 && value.numbers[0] <= format.MAX_CUTSCENE_BUS) ||
				   value.numbers[0] != math.floor(value.numbers[0]) {
					problem(
						&found,
						line,
						"bus is a whole number from 0, Master, to %d: n is the nth of the project's audio.buses",
						format.MAX_CUTSCENE_BUS,
					)
					continue
				}
				s.contents.bus, s.audio_lines[0] = u32(value.numbers[0]), line
			case "min_distance", "max_distance":
				value, message := parse_graph_value(value_text)
				if message != "" ||
				   value.kind != .Numbers ||
				   value.count != 1 ||
				   !(value.numbers[0] >= 0) ||
				   f32(value.numbers[0]) > max(f32) {
					problem(&found, line, "%s is a number of meters from 0", name)
					continue
				}
				if name == "min_distance" {
					s.contents.min_distance, s.audio_lines[1] = f32(value.numbers[0]), line
				} else {
					s.contents.max_distance, s.audio_lines[2] = f32(value.numbers[0]), line
				}
			case "plays_through_skip":
				switch value_text {
				case "true":
					s.contents.flags += {.Plays_Through_Skip}
				case "false":
					s.contents.flags -= {.Plays_Through_Skip}
				case:
					problem(&found, line, "plays_through_skip is true or false")
					continue
				}
				s.audio_lines[3] = line
			case "kind":
				kind: format.Cutscene_Presentation_Kind
				switch value_text {
				case "fade":
					kind = .Fade
				case "letterbox":
					kind = .Letterbox
				case "subtitle":
					kind = .Subtitle
				case:
					problem(&found, line, "kind is fade, letterbox or subtitle")
					continue
				}
				s.contents.presentation.kind, s.presentation_lines[0] = kind, line
			case "color":
				color, ok := cutscene_color(value_text)
				if !ok {
					problem(&found, line, "color is %s", CUTSCENE_COLOR_FORM)
					continue
				}
				s.contents.presentation.color, s.presentation_lines[1] = color, line
			case "speaker", "text", "key":
				quoted, ok := cutscene_name(value_text)
				if !ok {
					problem(&found, line, "%s is quoted text", name)
					continue
				}
				switch name {
				case "speaker":
					s.contents.presentation.speaker, s.presentation_lines[2] =
						strings.clone(quoted), line
				case "text":
					s.contents.presentation.text, s.presentation_lines[3] =
						strings.clone(quoted), line
				case "key":
					s.contents.presentation.key, s.presentation_lines[4] =
						strings.clone(quoted), line
				}
			case "audio":
				id, ok := format.whole_id(value_text)
				if !ok {
					problem(&found, line, "audio is the ID of a section of an audio track")
					continue
				}
				s.audio_id, s.presentation_lines[5] = id, line
			case "binding",
			     "muted",
			     "when_finished",
			     "component",
			     "field",
			     "space",
			     "origin",
			     "gain",
			     "time_scale",
			     "letterbox_aspect":
				problem(&found, line, "%s comes before the track's sections", name)
			case:
				problem(
					&found,
					line,
					"%q is not a setting of a section: ease_in, ease_out, weight, pre_roll, post_roll, asset, blend, offset, speed, loop, trim, scale, root_motion, camera, blend_in, blend_out, blend_on_skip, look_at, look_at_offset, look_at_damping, follow, follow_offset, follow_damping, focus, bus, min_distance, max_distance, plays_through_skip, kind, color, speaker, text, key or audio",
					name,
				)
			}
		case .Marker:
			m := &markers[len(markers) - 1]
			if name != "color" {
				problem(&found, line, "%q is not a setting of a marker: color", name)
				continue
			}
			if m.color_line != 0 {
				problem(&found, line, "color is set twice")
				continue
			}
			color, ok := cutscene_color(value_text)
			if !ok {
				problem(&found, line, "color is %s", CUTSCENE_COLOR_FORM)
				continue
			}
			m.contents.color, m.color_line = color, line
		case .Channel:
			switch name {
			case "pre_infinity", "post_infinity":
				tr := &tracks[len(tracks) - 1]
				s := &tr.sections[len(tr.sections) - 1]
				ch := &s.channels[len(s.channels) - 1]
				side := 0 if name == "pre_infinity" else 1
				if len(ch.keys) > 0 {
					problem(&found, line, "%s comes before the channel's keys", name)
					continue
				}
				if ch.infinity_lines[side] != 0 {
					problem(&found, line, "%s is set twice", name)
					continue
				}
				ch.infinity_lines[side] = line
				mode, known := format.Cutscene_Infinity.Constant, false
				for n, m in CUTSCENE_INFINITY_NAMES {
					if n == value_text {
						mode, known = m, true
					}
				}
				if !known {
					problem(
						&found,
						line,
						"%s is constant, linear, cycle, cycle_offset or oscillate",
						name,
					)
					continue
				}
				ch.infinity[side] = mode
			case "ease_in",
			     "ease_out",
			     "weight",
			     "pre_roll",
			     "post_roll",
			     "asset",
			     "blend",
			     "offset",
			     "speed",
			     "loop",
			     "trim",
			     "scale",
			     "name",
			     "root_motion",
			     "camera",
			     "blend_in",
			     "blend_out",
			     "blend_on_skip",
			     "look_at",
			     "look_at_offset",
			     "look_at_damping",
			     "follow",
			     "follow_offset",
			     "follow_damping",
			     "focus",
			     "bus",
			     "min_distance",
			     "max_distance",
			     "plays_through_skip",
			     "kind",
			     "color",
			     "speaker",
			     "text",
			     "key",
			     "audio":
				problem(&found, line, "%s comes before the section's channels", name)
			case:
				problem(&found, line, "a channel has keys, not settings")
			}
		}
	}
	if header_line == 0 {
		problem(&found, 1, "a cutscene starts with `cutscene 1`")
		return {}, found[:]
	}
	if !length_seen {
		problem(&found, header_line, "the cutscene has a length")
	}
	if range_line == 0 {
		contents.range_end = contents.length
	} else if length_seen &&
	   (contents.range_start >= contents.range_end || contents.range_end > contents.length) {
		problem(
			&found,
			range_line,
			"range starts before it ends, inside the length (%d)",
			contents.length,
		)
	}
	if skip_line != 0 && length_seen {
		for r, i in skip_ranges {
			if r.start >= r.end || r.end > contents.length {
				problem(
					&found,
					skip_line,
					"a skip range starts before it ends, inside the length (%d)",
					contents.length,
				)
				break
			}
			if i > 0 && r.start < skip_ranges[i - 1].end {
				problem(&found, skip_line, "the skip ranges are in time order and do not overlap")
				break
			}
		}
	}
	if len(skip_ranges) > format.MAX_CUTSCENE_SKIP_RANGES {
		problem(
			&found,
			skip_line,
			"a cutscene has at most %d skip ranges",
			format.MAX_CUTSCENE_SKIP_RANGES,
		)
	}
	contents.skip_ranges = skip_ranges[:]
	marker_contents := make([]format.Cutscene_Marker_Contents, len(markers))
	for m, i in markers {
		if length_seen && (m.contents.time < 0 || m.contents.time > contents.length) {
			problem(&found, m.line, "a marker is inside the length (%d)", contents.length)
		}
		marker_contents[i] = m.contents
	}
	contents.markers = marker_contents
	// Bindings: what kind each is, and that its settings suit it.
	result_bindings := make([]format.Cutscene_Binding_Contents, len(bindings))
	for &b, i in bindings {
		switch {
		case b.possess == 0 && b.spawn == 0 && b.provided == 0:
			problem(
				&found,
				b.line,
				"a binding possesses an entity with possess, spawns a prefab with spawn, or is provided by a script with provided = true",
			)
		case (b.possess != 0 ? 1 : 0) + (b.spawn != 0 ? 1 : 0) + (b.provided != 0 ? 1 : 0) > 1:
			problem(
				&found,
				max(b.possess, b.spawn, b.provided),
				"a binding possesses, spawns or is provided, only one of them",
			)
		case b.provided != 0:
			b.contents.kind = .Provided
			if b.spawn_only != 0 {
				problem(&found, b.spawn_only, "%s is for a spawned binding", b.spawn_name)
			}
		case b.possess != 0:
			b.contents.kind = .Possessed
			if b.spawn_only != 0 {
				problem(&found, b.spawn_only, "%s is for a spawned binding", b.spawn_name)
			}
		case:
			b.contents.kind = .Spawned
			if b.policy != 0 {
				problem(&found, b.policy, "policy is for a possessed or provided binding")
			}
		}
		if b.suspend == 0 {
			b.contents.suspend = default_suspend
		}
		result_bindings[i] = b.contents
	}
	for b in bindings {
		if b.parent_line != 0 &&
		   b.contents.parent != format.CUTSCENE_NONE &&
		   bindings[b.contents.parent].spawn == 0 {
			problem(&found, b.parent_line, "parent is a spawned binding")
		}
	}
	// Tracks: their bindings, and their sections in the length.
	result_tracks := make([]format.Cutscene_Track_Contents, len(tracks))
	// The line of each binding's animation track, by the binding's index: a binding has one.
	animated := make(map[u32]int, context.temp_allocator)
	// The line of the camera cut track, of which a cutscene has one, and the cameras that its sections show.
	cut_line := 0
	cameras := make(map[u32]bool, context.temp_allocator)
	// Each audio section's index among all the sections, by its ID, which a subtitle names it by.
	audio_sections := make(map[u32]u32, context.temp_allocator)
	{
		n := u32(0)
		for tr in tracks {
			for s in tr.sections {
				if tr.contents.kind == .Audio {
					audio_sections[s.contents.id] = n
				}
				n += 1
			}
		}
	}
	for tr, i in tracks {
		kind := tr.contents.kind
		// The kind with its article, such as "an audio".
		kind_name := CUTSCENE_TRACK_KINDS[kind]
		kind_name = fmt.aprintf(
			"%s %s",
			"an" if strings.index_byte("aeiou", kind_name[0]) >= 0 else "a",
			kind_name,
		)
		result := tr.contents
		if tr.binding_line != 0 {
			for b, j in bindings {
				if b.contents.id == tr.binding_id {
					result.binding = u32(j)
				}
			}
		}
		use := format.cutscene_track_binding(kind)
		switch {
		case tr.binding_line != 0 && use == .None:
			problem(&found, tr.binding_line, "%s track has no binding", kind_name)
		case tr.binding_line != 0 && result.binding == format.CUTSCENE_NONE:
			problem(&found, tr.binding_line, "binding is the ID of a binding of the cutscene")
		case tr.binding_line == 0 && use == .Required:
			problem(&found, tr.line, "%s track needs a binding", kind_name)
		}
		if kind == .Property {
			if tr.component_line == 0 || tr.field_line == 0 {
				problem(
					&found,
					tr.line,
					"a property track names its field with component = <stable ID> and field = \"<name>\"",
				)
			}
		} else {
			for setting_line in ([2]int{tr.component_line, tr.field_line}) {
				if setting_line != 0 {
					problem(&found, setting_line, "only a property track names a field")
				}
			}
		}
		if kind == .Transform {
			if tr.origin_line != 0 && result.space != .Absolute {
				problem(&found, tr.origin_line, "origin is for space = absolute")
			}
			if result.space == .Relative_To {
				result.relative = format.CUTSCENE_NONE
				for b, j in bindings {
					if b.contents.id == tr.relative_id {
						result.relative = u32(j)
					}
				}
				switch {
				case result.relative == format.CUTSCENE_NONE:
					problem(
						&found,
						tr.space_line,
						"space = relative <id> names a binding of the cutscene by its ID",
					)
				case result.relative == result.binding:
					problem(
						&found,
						tr.space_line,
						"a track relative to its own binding has space = relative",
					)
				}
			}
		} else {
			for setting_line in ([2]int{tr.space_line, tr.origin_line}) {
				if setting_line != 0 {
					problem(
						&found,
						setting_line,
						"only a transform track has a space and an origin",
					)
				}
			}
		}
		if kind == .Animation && result.binding != format.CUTSCENE_NONE {
			if other, taken := animated[result.binding]; taken {
				problem(
					&found,
					tr.line,
					"the binding has an animation track at line %d already: put its clips in that track's sections",
					other,
				)
			} else {
				animated[result.binding] = tr.line
			}
		}
		if kind == .Camera_Cut {
			if cut_line != 0 {
				problem(
					&found,
					tr.line,
					"the cutscene has a camera_cut track at line %d already: a cutscene has one",
					cut_line,
				)
			} else {
				cut_line = tr.line
			}
		}
		if kind == .Event {
			result.events = cutscene_event_track(
				&found,
				tr,
				bindings[:],
				result_bindings,
				result.binding,
				contents.length if length_seen else max(i32),
			)
		} else {
			for ev in tr.events {
				problem(&found, ev.line, "only an event track has triggers and ranges")
			}
		}
		if kind == .Audio {
			if tr.audio_lines[0] == 0 {
				result.gain = 1
			}
		} else {
			for setting_line in tr.audio_lines {
				if setting_line != 0 {
					problem(
						&found,
						setting_line,
						"only an audio track has a gain and a time_scale",
					)
				}
			}
			result.gain, result.time_scale = 0, .Follow
		}
		if kind != .Presentation && tr.aspect_line != 0 {
			problem(&found, tr.aspect_line, "only a presentation track has a letterbox_aspect")
			result.flags -= {.Follow_Camera}
		}
		want := format.cutscene_track_asset(kind)
		plays := format.cutscene_track_plays(kind)
		sections := make([]format.Cutscene_Section_Contents, len(tr.sections))
		for s, j in tr.sections {
			c := s.contents
			if kind == .Camera_Cut {
				c.constraints = cutscene_cut_section(
					&found,
					tr.sections[:],
					j,
					bindings[:],
					&c,
					&cameras,
				)
			} else {
				cut_settings := [4]string{"a camera", "a blend in", "a blend out", "blend_on_skip"}
				for setting_line, k in s.cut_lines {
					if setting_line != 0 {
						problem(
							&found,
							setting_line,
							"only a camera_cut section has %s",
							cut_settings[k],
						)
					}
				}
				if s.constraints.first != 0 {
					problem(
						&found,
						s.constraints.first,
						"only a camera_cut section, or a camera binding, has constraints",
					)
				}
				c.blend_in, c.blend_out, c.blend_curves = 0, 0, {}
				c.flags -= {.Blend_On_Skip}
			}
			if !plays {
				for setting_line in s.play_lines {
					if setting_line != 0 {
						problem(
							&found,
							setting_line,
							"only an animation or an audio section has an offset, only those and a sub_sequence section a loop, and only an animation section a speed and a root motion",
						)
					}
				}
				c.offset, c.speed, c.root_motion = 0, 0, .Bake
				c.flags -= {.Loop}
			} else if kind == .Sub_Sequence {
				for setting_line in ([3]int{s.play_lines[0], s.play_lines[1], s.play_lines[3]}) {
					if setting_line != 0 {
						problem(
							&found,
							setting_line,
							"a sub_sequence section has a trim and a scale, not an offset, a speed or a root motion",
						)
					}
				}
				if s.sub_lines[1] == 0 {
					c.speed = 1
				}
				c.root_motion = .Bake
			} else if kind == .Audio {
				for setting_line in ([2]int{s.play_lines[1], s.play_lines[3]}) {
					if setting_line != 0 {
						problem(
							&found,
							setting_line,
							"an audio section has no speed or root motion: its pitch channel sets its rate",
						)
					}
				}
				c.speed, c.root_motion = 1, .Bake
			} else if s.play_lines[1] == 0 {
				c.speed = 1
			}
			if kind == .Sub_Sequence {
				c.bindings = cutscene_sub_sequence_section(
					&found,
					tr.sections[:],
					j,
					bindings[:],
					&maps,
					i,
				)
			} else {
				for setting_line in s.sub_lines {
					if setting_line != 0 {
						problem(
							&found,
							setting_line,
							"only a sub_sequence section has a trim and a scale",
						)
					}
				}
				if len(s.binds) > 0 {
					problem(&found, s.binds[0].line, "only a sub_sequence section binds bindings")
				}
				if s.name_line != 0 {
					problem(&found, s.name_line, "only a sub_sequence section has a name")
				}
				c.trim_end = 0
				if !plays {
					c.offset = 0
				}
			}
			if kind == .Audio {
				cutscene_audio_section(&found, s, &c)
			} else {
				for setting_line in s.audio_lines {
					if setting_line != 0 {
						problem(
							&found,
							setting_line,
							"only an audio section has a bus, distances and plays_through_skip",
						)
					}
				}
				c.bus, c.min_distance, c.max_distance = 0, 0, 0
				c.flags -= {.Plays_Through_Skip}
			}
			if kind == .Presentation {
				cutscene_presentation_section(&found, s, &c, audio_sections)
			} else {
				for setting_line in s.presentation_lines {
					if setting_line != 0 {
						problem(
							&found,
							setting_line,
							"only a presentation section has a kind, a color, a speaker, text, a key and audio",
						)
					}
				}
				c.presentation = {}
			}
			if length_seen && c.end > contents.length {
				problem(
					&found,
					s.line,
					"a section ends at most at the length (%d)",
					contents.length,
				)
			}
			if c.end > c.start && i64(c.ease_in) + i64(c.ease_out) > i64(c.end) - i64(c.start) {
				problem(
					&found,
					s.line,
					"ease_in and ease_out together are at most the section's duration (%d)",
					c.end - c.start,
				)
			}
			switch {
			case want == .None && s.asset_line != 0:
				problem(&found, s.asset_line, "%s section has no asset", kind_name)
			case want != .None && s.asset_line == 0:
				problem(
					&found,
					s.line,
					"%s section names its %s with asset = $<guid>",
					kind_name,
					CUTSCENE_ASSET_NOUNS[kind],
				)
			case want != .None:
				append(&references, Cutscene_Reference{c.asset, want, s.asset_line})
			}
			if .Additive in c.flags && !format.cutscene_track_additive(kind) {
				problem(&found, s.blend_line, "%s section cannot be additive", kind_name)
			}
			if kind == .Property {
				cutscene_property_channels(&found, s)
			}
			if kind == .Transform {
				cutscene_transform_channels(&found, s)
			}
			channels := make([]format.Cutscene_Channel_Contents, len(s.channels))
			for ch, k in s.channels {
				if len(ch.keys) == 0 {
					problem(&found, ch.line, "the channel has no keys")
				}
				if ch.guids > 0 && ch.guids < len(ch.keys) {
					problem(&found, ch.line, "a channel's keys are all assets or all numbers")
				} else if ch.guids > 0 && kind != .Property {
					problem(&found, ch.line, "only a property track keys assets")
				}
				if ch.teleport != 0 && kind != .Transform {
					problem(&found, ch.teleport, "only a transform track's keys teleport")
				}
				flags := format.Cutscene_Channel_Flags{.Guids} if ch.guids > 0 else {}
				for side in 0 ..< 2 {
					mode := ch.infinity[side]
					if !format.cutscene_infinity_valid(mode, flags) {
						problem(
							&found,
							ch.infinity_lines[side],
							"assets have no slope or change of value, so they are constant, cycle or oscillate",
						)
					}
					if kind == .Audio &&
					   ch.name == format.CUTSCENE_AUDIO_PITCH &&
					   mode != .Constant {
						problem(
							&found,
							ch.infinity_lines[side],
							"a pitch is constant before and after its keys, since the sound's place is its integral",
						)
					}
				}
				channels[k] = {
					name          = ch.name,
					flags         = flags,
					pre_infinity  = ch.infinity[0],
					post_infinity = ch.infinity[1],
					keys          = ch.keys[:],
				}
			}
			c.channels = channels
			sections[j] = c
		}
		result.sections = sections
		result_tracks[i] = result
	}
	// A binding's constraints are on it as a camera: one that a camera cut section shows.
	for b, i in bindings {
		if b.constraints.first == 0 {
			continue
		}
		if !cameras[u32(i)] {
			problem(
				&found,
				b.constraints.first,
				"constraints are on a camera binding: one that a camera_cut section shows with camera = <binding id>",
			)
			continue
		}
		result_bindings[i].constraints = cutscene_constraints(
			&found,
			b.constraints,
			bindings[:],
			u32(i),
		)
	}
	contents.bindings, contents.tracks = result_bindings, result_tracks
	cutscene_relative_cycles(&found, tracks[:], result_tracks, result_bindings)
	contents.hide_ui = hide_ui[:]
	contents.guids = guids[:]
	if len(guids) > format.MAX_CUTSCENE_GUIDS {
		problem(
			&found,
			header_line,
			"a cutscene keys at most %d assets",
			format.MAX_CUTSCENE_GUIDS,
		)
	}
	slice.stable_sort_by(found[:], proc(a, b: Cutscene_Problem) -> bool {return a.line < b.line})
	slice.stable_sort_by(references[:], proc(a, b: Cutscene_Reference) -> bool {
		return a.line < b.line
	})
	return {contents = contents, references = references[:], maps = maps[:]}, found[:]
}

// cutscene_sub_sequence_section checks what a sub-sequence section has (see
// docs/cinematics/tracks.md#sub-sequence-tracks): no channels, a start at or after the end of the section before it,
// and binds to bindings of the cutscene, each child's binding once. It gives the binds as maps to the bindings' indexes,
// and records their lines in maps, which the cook checks against the child.
@(private = "file")
cutscene_sub_sequence_section :: proc(
	found: ^[dynamic]Cutscene_Problem,
	sections: []Pending_Section,
	index: int,
	bindings: []Pending_Binding,
	maps: ^[dynamic]Cutscene_Map_Line,
	track: int,
) -> []format.Cutscene_Binding_Map_Contents {
	problem :: proc(found: ^[dynamic]Cutscene_Problem, line: int, f: string, args: ..any) {
		append(found, Cutscene_Problem{line, fmt.aprintf(f, ..args)})
	}
	s := sections[index]
	if len(s.channels) > 0 {
		problem(
			found,
			s.channels[0].line,
			"a sub_sequence section has no channels: its sub-sequence's tracks do",
		)
	}
	if index > 0 && s.contents.start < sections[index - 1].contents.end {
		problem(
			found,
			s.line,
			"a sub_sequence track's sections are in time order and do not overlap: this one starts before %d",
			sections[index - 1].contents.end,
		)
	}
	trim_line := s.sub_lines[0] if s.sub_lines[0] != 0 else s.line
	append(maps, Cutscene_Map_Line{track, index, 0, format.CUTSCENE_NONE, trim_line})
	result := make([dynamic]format.Cutscene_Binding_Map_Contents, 0, len(s.binds))
	for bind in s.binds {
		parent := -1
		for b, k in bindings {
			if b.contents.id == bind.parent {
				parent = k
			}
		}
		if parent < 0 {
			problem(found, bind.line, "the cutscene has no binding with the ID %d", bind.parent)
			continue
		}
		append(&result, format.Cutscene_Binding_Map_Contents{bind.child, u32(parent)})
		append(maps, Cutscene_Map_Line{track, index, bind.child, u32(parent), bind.line})
	}
	return result[:]
}


// cutscene_event_track checks what an event track has (see docs/cinematics/tracks.md#event-tracks): no sections, no
// when_finished, and a binding, if it has one, that does not suspend its behaviours, which would get none of its events.
// It gives the track's events in start order, each within the length, with its Entity values' bindings by index.
@(private = "file")
cutscene_event_track :: proc(
	found: ^[dynamic]Cutscene_Problem,
	tr: Pending_Track,
	bindings: []Pending_Binding,
	result_bindings: []format.Cutscene_Binding_Contents,
	binding: u32,
	length: i32,
) -> []format.Cutscene_Event_Contents {
	for s in tr.sections {
		append(
			found,
			Cutscene_Problem {
				s.line,
				"an event track has no sections: it has trigger and range lines",
			},
		)
	}
	if tr.finish_line != 0 {
		append(
			found,
			Cutscene_Problem {
				tr.finish_line,
				"an event track has no when_finished: its events change state through scripts, which own it",
			},
		)
	}
	if binding != format.CUTSCENE_NONE && .Behaviours in result_bindings[binding].suspend {
		append(
			found,
			Cutscene_Problem {
				tr.binding_line,
				"the binding suspends its behaviours, so they would get none of the track's events: give it a suspend without behaviours, or leave the track's binding out to send its events to every behaviour",
			},
		)
	}
	events := make([]format.Cutscene_Event_Contents, len(tr.events))
	for ev, i in tr.events {
		c := ev.contents
		if c.end > length {
			append(
				found,
				Cutscene_Problem {
					ev.line,
					fmt.aprintf("a trigger or a range is inside the length (%d)", length),
				},
			)
		}
		values := make([]format.Cutscene_Event_Value_Contents, len(ev.values))
		for v, j in ev.values {
			values[j] = v.contents
			if v.contents.kind != .Entity {
				continue
			}
			values[j].index = format.CUTSCENE_NONE
			for b, k in bindings {
				if b.contents.id == v.contents.index {
					values[j].index = u32(k)
				}
			}
			if values[j].index == format.CUTSCENE_NONE {
				append(
					found,
					Cutscene_Problem {
						v.line,
						"an entity value is the ID of a binding of the cutscene",
					},
				)
				values[j].index = 0
			}
		}
		c.values = values
		events[i] = c
	}
	slice.stable_sort_by(events, proc(a, b: format.Cutscene_Event_Contents) -> bool {
		return a.start < b.start
	})
	return events
}

// Cutscene_Value_Text is an event's value as cutscene_event_value reads it: an Entity's index is its binding's ID, and
// an Asset's GUID is beside it, for the caller to give an index.
@(private = "file")
Cutscene_Value_Text :: struct {
	using contents: format.Cutscene_Event_Value_Contents,
	guid:           format.Guid,
}

// cutscene_event_value reads an event's value, `<kind> <value>`: number <n>, bool true|false, string "<text>", vector
// [x, y, z], entity <binding id>, position [x, y, z] in meters, or asset $<guid>.
@(private = "file")
cutscene_event_value :: proc(text: string) -> (v: Cutscene_Value_Text, message: string) {
	kind_text, _, value_text := strings.partition(text, " ")
	value_text = strings.trim_space(value_text)
	value, value_message := parse_graph_value(value_text)
	switch kind_text {
	case "number":
		v.kind = .Number
		if value_message != "" ||
		   value.kind != .Numbers ||
		   value.count != 1 ||
		   strings.has_prefix(value_text, "[") ||
		   !(abs(value.numbers[0]) <= max(f64)) {
			return v, "a number value is `number <n>`, a finite number"
		}
		v.number = value.numbers[0]
	case "bool":
		v.kind = .Bool
		switch value_text {
		case "true":
			v.index = 1
		case "false":
		case:
			return v, "a bool value is `bool true` or `bool false`"
		}
	case "string":
		v.kind = .String
		if value_message != "" || value.kind != .Text {
			return v, "a string value is `string \"<text>\"`"
		}
		v.text = strings.clone(value.text)
	case "vector":
		v.kind = .Vector
		ok := value_message == "" && value.kind == .Numbers && value.count == 3
		for axis in 0 ..< 3 {
			ok &&= abs(value.numbers[axis]) <= f64(max(f32))
			v.vector[axis] = f32(value.numbers[axis])
		}
		if !ok {
			return v, "a vector value is `vector [x, y, z]`, three finite numbers"
		}
	case "entity":
		v.kind = .Entity
		id, ok := format.whole_id(value_text)
		if !ok {
			return v,
				"an entity value is `entity <binding id>`, the ID of a binding of the cutscene"
		}
		v.index = id
	case "position":
		v.kind = .Position
		ok := value_message == "" && value.kind == .Numbers && value.count == 3
		for axis in 0 ..< 3 {
			raw, in_range := format.world_raw_from_meters(value.numbers[axis])
			ok &&= in_range
			v.position[axis] = raw
		}
		if !ok {
			return v,
				"a position value is `position [x, y, z]`, in meters, inside the bounds of a World_Position"
		}
	case "asset":
		v.kind = .Asset
		if value_message != "" || value.kind != .Asset || value.guid == {} {
			return v, "an asset value is `asset $<guid>`, with 32 hex digits"
		}
		v.guid = value.guid
	case:
		return v,
			"a value is `<kind> <value>`, of the kinds number, bool, string, vector, entity, position and asset"
	}
	return v, ""
}

// cutscene_binding_setting reads a setting of a binding.
@(private = "file")
cutscene_binding_setting :: proc(
	found: ^[dynamic]Cutscene_Problem,
	references: ^[dynamic]Cutscene_Reference,
	bindings: []Pending_Binding,
	b: ^Pending_Binding,
	name, value_text: string,
	line: int,
) {
	problem :: proc(found: ^[dynamic]Cutscene_Problem, line: int, f: string, args: ..any) {
		append(found, Cutscene_Problem{line, fmt.aprintf(f, ..args)})
	}
	spawn_only :: proc(b: ^Pending_Binding, name: string, line: int) {
		if b.spawn_only == 0 {
			b.spawn_only, b.spawn_name = line, name
		}
	}
	if cutscene_constraint_setting(found, &b.constraints, name, value_text, line) {
		return
	}
	switch name {
	case "possess":
		scene, entity, message := format.entity_reference_parse(value_text)
		switch {
		case message != "":
			problem(found, line, "possess: %s", message)
		case scene == {}:
			problem(found, line, "possess is @<scene guid>/<id or path>, an entity of a scene")
		case:
			b.contents.asset, b.contents.entity = scene, entity
			append(references, Cutscene_Reference{scene, .Scene, line})
		}
		b.possess = line
	case "policy":
		switch value_text {
		case "required":
			b.contents.policy = .Required
		case "optional":
			b.contents.policy = .Optional
		case:
			problem(found, line, "policy is required or optional")
		}
		b.policy = line
	case "spawn":
		value, message := parse_graph_value(value_text)
		if message != "" || value.kind != .Asset || value.guid == {} {
			problem(found, line, "spawn is $<prefab guid>, with 32 hex digits")
		} else {
			b.contents.asset = value.guid
			append(references, Cutscene_Reference{value.guid, .Prefab, line})
		}
		b.spawn = line
	case "provided":
		if value_text != "true" {
			problem(found, line, "provided is true")
		}
		b.provided = line
	case "suspend":
		b.suspend = line
		set, ok := cutscene_suspend(value_text)
		if !ok {
			problem(found, line, "%s", CUTSCENE_SUSPEND_MESSAGE)
			return
		}
		b.contents.suspend = set
	case "keep_velocity":
		switch value_text {
		case "true":
			b.contents.flags += {.Keep_Velocity}
		case "false":
		case:
			problem(found, line, "keep_velocity is true or false")
		}
	case "parent":
		spawn_only(b, name, line)
		b.parent_line = line
		id, ok := format.whole_id(value_text)
		if ok {
			for other, i in bindings[:len(bindings) - 1] {
				if other.contents.id == id {
					b.contents.parent = u32(i)
				}
			}
		}
		if b.contents.parent == format.CUTSCENE_NONE {
			problem(found, line, "parent is the ID of a binding before this one")
			b.parent_line = 0
		}
	case "position":
		spawn_only(b, name, line)
		value, message := parse_graph_value(value_text)
		ok := message == "" && value.kind == .Numbers && value.count == 3
		for axis in 0 ..< 3 {
			raw, in_range := format.world_raw_from_meters(value.numbers[axis])
			ok &&= in_range
			b.contents.position[axis] = raw
		}
		if !ok {
			problem(
				found,
				line,
				"position is three numbers in meters, [x, y, z], inside the bounds of a World_Position",
			)
		}
	case "rotation":
		spawn_only(b, name, line)
		value, message := parse_graph_value(value_text)
		q := [4]f64{value.numbers[0], value.numbers[1], value.numbers[2], value.numbers[3]}
		length := math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
		if message != "" ||
		   value.kind != .Numbers ||
		   value.count != 4 ||
		   !(abs(length - 1) <= 1e-3) {
			problem(found, line, "rotation is a quaternion of length 1, [x, y, z, w]")
			return
		}
		for i in 0 ..< 4 {
			b.contents.rotation[i] = f32(q[i] / length)
		}
	case "scale":
		spawn_only(b, name, line)
		value, message := parse_graph_value(value_text)
		ok := message == "" && value.kind == .Numbers && value.count == 3
		for axis in 0 ..< 3 {
			s := value.numbers[axis]
			ok &&= s != 0 && abs(s) <= f64(max(f32))
			b.contents.scale[axis] = f32(s)
		}
		if !ok {
			problem(found, line, "scale is three numbers, [x, y, z], none of them 0")
		}
	case:
		problem(
			found,
			line,
			"%q is not a setting of a binding: possess, policy, spawn, provided, parent, position, rotation, scale, suspend, keep_velocity, look_at, look_at_offset, look_at_damping, follow, follow_offset, follow_damping or focus",
			name,
		)
	}
}

// cutscene_constraint_setting reads a camera constraint's setting of a section or a binding: `look_at`, `follow` or
// `focus` = <binding id>, and `<kind>_offset` = [x, y, z] in meters and `<kind>_damping` = <ticks> for look_at and
// follow. It reports false for a name that is not one.
@(private = "file")
cutscene_constraint_setting :: proc(
	found: ^[dynamic]Cutscene_Problem,
	pc: ^Pending_Constraints,
	name, value_text: string,
	line: int,
) -> bool {
	problem :: proc(found: ^[dynamic]Cutscene_Problem, line: int, f: string, args: ..any) {
		append(found, Cutscene_Problem{line, fmt.aprintf(f, ..args)})
	}
	for kind_name, kind in CUTSCENE_CONSTRAINT_NAMES {
		switch {
		case name == kind_name:
			id, ok := format.whole_id(value_text)
			if !ok {
				problem(found, line, "%s is the ID of a binding of the cutscene", name)
			} else {
				pc.targets[kind] = id
			}
			pc.lines[kind] = line
		case kind != .Focus && name == fmt.tprintf("%s_offset", kind_name):
			value, message := parse_graph_value(value_text)
			ok := message == "" && value.kind == .Numbers && value.count == 3
			for axis in 0 ..< 3 {
				ok &&= abs(value.numbers[axis]) <= f64(max(f32))
				pc.offsets[kind][axis] = f32(value.numbers[axis])
			}
			if !ok {
				problem(found, line, "%s is three numbers in meters, [x, y, z]", name)
			}
			pc.offset_lines[kind] = line
		case kind != .Focus && name == fmt.tprintf("%s_damping", kind_name):
			ticks, ok := format.whole_ticks(value_text)
			if !ok {
				problem(found, line, "%s is a whole number of ticks", name)
			}
			pc.dampings[kind], pc.damping_lines[kind] = ticks, line
		case:
			continue
		}
		if pc.first == 0 {
			pc.first = line
		}
		return true
	}
	return false
}

// cutscene_cut_section checks a camera cut section and gives its constraints: it shows a camera binding, it has none of
// the settings that blend a section, it follows the section before it without overlap, and it blends in from gameplay
// and out to it only at an edge with gameplay. The section's camera goes into c, and into cameras.
@(private = "file")
cutscene_cut_section :: proc(
	found: ^[dynamic]Cutscene_Problem,
	sections: []Pending_Section,
	index: int,
	bindings: []Pending_Binding,
	c: ^format.Cutscene_Section_Contents,
	cameras: ^map[u32]bool,
) -> []format.Cutscene_Constraint_Contents {
	problem :: proc(found: ^[dynamic]Cutscene_Problem, line: int, f: string, args: ..any) {
		append(found, Cutscene_Problem{line, fmt.aprintf(f, ..args)})
	}
	s := sections[index]
	c.camera = format.CUTSCENE_NONE
	if s.cut_lines[0] == 0 {
		problem(
			found,
			s.line,
			"a camera_cut section shows a camera binding with camera = <binding id>",
		)
	} else {
		for b, i in bindings {
			if b.contents.id == s.camera_id {
				c.camera = u32(i)
			}
		}
		if c.camera == format.CUTSCENE_NONE {
			problem(found, s.cut_lines[0], "camera is the ID of a binding of the cutscene")
		} else {
			cameras[c.camera] = true
		}
	}
	if s.shape_line != 0 {
		problem(
			found,
			s.shape_line,
			"a camera_cut section cuts: it has no %s, and blends with gameplay with blend_in and blend_out",
			s.shape_name,
		)
	}
	if len(s.channels) > 0 {
		problem(found, s.channels[0].line, "a camera_cut section has no channels")
	}
	if index > 0 && s.contents.start < sections[index - 1].contents.end {
		problem(
			found,
			s.line,
			"camera_cut sections are in time order and do not overlap: the one before ends at %d",
			sections[index - 1].contents.end,
		)
	}
	after_gap := index == 0 || sections[index - 1].contents.end < s.contents.start
	before_gap := index == len(sections) - 1 || sections[index + 1].contents.start > s.contents.end
	if s.cut_lines[1] != 0 && c.blend_in > 0 {
		switch {
		case !after_gap:
			problem(
				found,
				s.cut_lines[1],
				"a camera_cut section blends in only from gameplay: as the first section, or after a gap",
			)
		case c.end > c.start && c.blend_in > c.end - c.start:
			problem(
				found,
				s.cut_lines[1],
				"blend_in is at most the section's duration (%d)",
				c.end - c.start,
			)
		}
	}
	if s.cut_lines[2] != 0 && c.blend_out > 0 && !before_gap {
		problem(
			found,
			s.cut_lines[2],
			"a camera_cut section blends out only to gameplay: as the last section, or before a gap",
		)
	}
	if .Blend_On_Skip in c.flags && c.blend_out == 0 {
		problem(found, s.cut_lines[3], "blend_on_skip is for a section with a blend_out")
	}
	return cutscene_constraints(found, s.constraints, bindings, c.camera)
}

// cutscene_blend_curve reads a camera cut's blend curve, linear when it is empty.
@(private = "file")
cutscene_blend_curve :: proc(text: string) -> (curve: format.Cutscene_Blend_Curve, ok: bool) {
	switch text {
	case "", "linear":
		return .Linear, true
	case "smooth":
		return .Smooth, true
	case "ease_in":
		return .Ease_In, true
	case "ease_out":
		return .Ease_Out, true
	}
	return
}

// cutscene_constraints resolves the constraints that a section or a binding sets on a camera, by the bindings' IDs,
// and reports their problems: a target that is not a binding or is the camera itself, and an offset or a damping
// without its constraint. camera is the camera's binding index, or CUTSCENE_NONE when it is not known.
@(private = "file")
cutscene_constraints :: proc(
	found: ^[dynamic]Cutscene_Problem,
	pc: Pending_Constraints,
	bindings: []Pending_Binding,
	camera: u32,
) -> []format.Cutscene_Constraint_Contents {
	problem :: proc(found: ^[dynamic]Cutscene_Problem, line: int, f: string, args: ..any) {
		append(found, Cutscene_Problem{line, fmt.aprintf(f, ..args)})
	}
	result := make([dynamic]format.Cutscene_Constraint_Contents)
	for kind_name, kind in CUTSCENE_CONSTRAINT_NAMES {
		if pc.lines[kind] == 0 {
			if pc.offset_lines[kind] != 0 {
				problem(
					found,
					pc.offset_lines[kind],
					"%s_offset is for %s = <binding id>",
					kind_name,
					kind_name,
				)
			}
			if pc.damping_lines[kind] != 0 {
				problem(
					found,
					pc.damping_lines[kind],
					"%s_damping is for %s = <binding id>",
					kind_name,
					kind_name,
				)
			}
			continue
		}
		if pc.targets[kind] == 0 {
			continue
		}
		target := format.CUTSCENE_NONE
		for b, i in bindings {
			if b.contents.id == pc.targets[kind] {
				target = u32(i)
			}
		}
		switch {
		case target == format.CUTSCENE_NONE:
			problem(found, pc.lines[kind], "%s is the ID of a binding of the cutscene", kind_name)
		case target == camera:
			problem(found, pc.lines[kind], "%s names the camera itself", kind_name)
		case:
			append(
				&result,
				format.Cutscene_Constraint_Contents {
					kind = kind,
					target = target,
					offset = pc.offsets[kind],
					damping = pc.dampings[kind],
				},
			)
		}
	}
	return result[:]
}

// cutscene_key reads a key's line after `key`: a time in ticks from its section's start, at most its duration, a value,
// an interpolation, and for a Bezier key its tangents: one slope, or an in and an out slope apart, in value per second,
// and then `weights <in> <out>` for weighted tangents. The value is a number, or `$<guid>` for a constant key of an
// asset field, which guid gives. A whole number of more than 2^24 that an f32 cannot hold exactly is a problem.
@(private = "file")
cutscene_key :: proc(
	text: string,
	duration: i32,
) -> (
	key: format.Cutscene_Key,
	guid: format.Guid,
	message: string,
) {
	USAGE :: "a key is `key <time> <value> constant|linear|auto [teleport]` or `key <time> <value> bezier <slope>|<in> <out> [weights <in> <out>] [teleport]`"
	fields := strings.fields(text, context.temp_allocator)
	if len(fields) > 3 && fields[len(fields) - 1] == "teleport" {
		key.flags += {.Teleport}
		fields = fields[:len(fields) - 1]
	}
	if len(fields) < 3 {
		return {}, {}, USAGE
	}
	time, time_ok := format.whole_ticks(fields[0])
	if !time_ok || (duration > 0 && time > duration) {
		return {}, {}, fmt.tprintf("a key's time is a whole number of ticks from 0 to the section's duration (%d)", duration)
	}
	finite :: proc(text: string) -> (f32, bool) {
		v, ok := strconv.parse_f64(text)
		if !ok || !(abs(v) <= f64(max(f32))) {
			return 0, false
		}
		return f32(v), true
	}
	key.time = time
	if strings.has_prefix(fields[1], "$") {
		value, value_message := parse_graph_value(fields[1])
		if value_message != "" || value.kind != .Asset || value.guid == {} {
			return {}, {}, "a key's asset is $<guid>, with 32 hex digits"
		}
		guid = value.guid
	} else {
		value, value_ok := finite(fields[1])
		if !value_ok {
			return {}, {}, "a key's value is a finite number, or an asset, $<guid>"
		}
		if whole, is_whole := strconv.parse_i64_of_base(fields[1], 10);
		   is_whole && i64(value) != whole {
			return {}, {}, fmt.tprintf("%s is not exact as a key's value: whole numbers are exact up to 16777216", fields[1])
		}
		key.value = value
	}
	switch fields[2] {
	case "constant":
		key.interp = .Constant
	case "linear":
		key.interp = .Linear
	case "bezier":
		key.interp = .Bezier
	case "auto":
		key.interp = .Auto
	case:
		return {}, {}, fmt.tprintf("%q is not an interpolation: constant, linear, bezier or auto", fields[2])
	}
	if guid != {} && key.interp != .Constant {
		return {}, {}, "a key of an asset is constant"
	}
	rest := fields[3:]
	if key.interp != .Bezier {
		if len(rest) > 0 {
			return {}, {}, fmt.tprintf("%s %s key has no tangents", "an" if key.interp == .Auto else "a", fields[2])
		}
		return key, guid, ""
	}
	slopes := rest
	weights: []string
	for word, i in rest {
		if word == "weights" {
			slopes, weights = rest[:i], rest[i + 1:]
			if len(weights) != 2 {
				return {}, {}, "weights is followed by an in and an out weight, each from 0 to 1"
			}
			break
		}
	}
	in_ok, out_ok := true, true
	switch len(slopes) {
	case 1:
		key.in_slope, in_ok = finite(slopes[0])
		key.out_slope = key.in_slope
	case 2:
		key.in_slope, in_ok = finite(slopes[0])
		key.out_slope, out_ok = finite(slopes[1])
		key.flags += {.Broken}
	case:
		return {}, {}, "a bezier key has one slope, or an in and an out slope, in value per second"
	}
	if !in_ok || !out_ok {
		return {}, {}, "a key's slopes are finite numbers"
	}
	if weights != nil {
		w_in, w_in_ok := finite(weights[0])
		w_out, w_out_ok := finite(weights[1])
		if !w_in_ok || !w_out_ok || !(w_in >= 0 && w_in <= 1) || !(w_out >= 0 && w_out <= 1) {
			return {}, {}, "a key's weights are numbers from 0 to 1"
		}
		key.flags += {.Weighted}
		key.in_weight, key.out_weight = w_in, w_out
	}
	return key, guid, ""
}

// cutscene_field_name is whether a field's name is names of letters, digits and _, with dots between them.
@(private = "file")
cutscene_field_name :: proc(name: string) -> bool {
	if name == "" {
		return false
	}
	rest := name
	for part in strings.split_iterator(&rest, ".") {
		if !is_identifier(part) {
			return false
		}
	}
	return true
}

// cutscene_property_channels checks a property section's channels against what any field takes: value alone, for a
// number or a field that steps, or a vector's numbers, as x, y and z, or r, g and b, not both. The cooker cannot see the
// field's kind, because native components exist only in the game's code, so the game checks the rest when it loads the
// cutscene (see docs/cinematics/tracks.md#property-tracks).
@(private = "file")
cutscene_property_channels :: proc(found: ^[dynamic]Cutscene_Problem, s: Pending_Section) {
	MESSAGE :: "a property track's channel is value, or x, y and z, or r, g and b"
	value, xyz, rgb := false, false, false
	for c in s.channels {
		switch c.name {
		case "value":
			value = true
		case "x", "y", "z":
			xyz = true
		case "r", "g", "b":
			rgb = true
		case:
			append(found, Cutscene_Problem{c.line, MESSAGE})
			continue
		}
		if int(value) + int(xyz) + int(rgb) > 1 {
			append(
				found,
				Cutscene_Problem {
					c.line,
					"a property section keys value alone, or a vector's x, y and z, or its r, g and b",
				},
			)
			return
		}
	}
}

// The distances that an audio section is heard at when it sets none, as Audio_Source's.
CUTSCENE_AUDIO_MIN_DISTANCE :: 1
CUTSCENE_AUDIO_MAX_DISTANCE :: 50

// cutscene_presentation_section checks what a presentation section has (see
// docs/cinematics/tracks.md#presentation-tracks): a kind; a color only on a fade; a speaker, text, a key and an audio
// section only on a subtitle, which has text; an audio section of an audio track; and the channels of its kind, in
// their ranges. It sets the audio section's index.
@(private = "file")
cutscene_presentation_section :: proc(
	found: ^[dynamic]Cutscene_Problem,
	s: Pending_Section,
	c: ^format.Cutscene_Section_Contents,
	audio_sections: map[u32]u32,
) {
	add :: proc(found: ^[dynamic]Cutscene_Problem, line: int, f: string, args: ..any) {
		append(found, Cutscene_Problem{line, fmt.aprintf(f, ..args)})
	}
	lines := s.presentation_lines
	if lines[0] == 0 {
		add(found, s.line, "a presentation section has a kind: fade, letterbox or subtitle")
		return
	}
	kind := c.presentation.kind
	if kind != .Fade && lines[1] != 0 {
		add(found, lines[1], "only a fade has a color")
	}
	if kind != .Subtitle {
		for line in lines[2:] {
			if line != 0 {
				add(found, line, "only a subtitle has a speaker, text, a key and audio")
			}
		}
		c.presentation = {
			kind  = kind,
			color = c.presentation.color if kind == .Fade else {},
		}
	} else if lines[3] == 0 {
		add(found, s.line, "a subtitle section has its text, as text = \"...\"")
	}
	if kind == .Subtitle && lines[5] != 0 {
		if index, found_audio := audio_sections[s.audio_id]; found_audio {
			c.presentation.audio = index
		} else {
			add(found, lines[5], "audio is the ID of a section of an audio track of the cutscene")
		}
	}
	for ch in s.channels {
		switch kind {
		case .Fade:
			if ch.name != format.CUTSCENE_FADE_OPACITY {
				add(found, ch.line, "a fade's channel is opacity")
				continue
			}
		case .Letterbox:
			if ch.name != format.CUTSCENE_LETTERBOX_ASPECT &&
			   ch.name != format.CUTSCENE_LETTERBOX_AMOUNT {
				add(found, ch.line, "a letterbox's channels are aspect and amount")
				continue
			}
		case .Subtitle:
			add(found, ch.line, "a subtitle has no channels")
			continue
		}
		low, high: f32 = 0, 1
		if ch.name == format.CUTSCENE_LETTERBOX_ASPECT {
			low, high = format.CUTSCENE_MIN_ASPECT, format.CUTSCENE_MAX_ASPECT
		}
		for k in ch.keys {
			if !(k.value >= low && k.value <= high) {
				add(found, ch.line, "%s keys are numbers from %v to %v", ch.name, low, high)
				break
			}
		}
	}
}

// cutscene_audio_section checks what an audio section has (see docs/cinematics/tracks.md#audio-tracks): no pre_roll or
// post_roll, distances whose max is above their min, and channels of gain from 0 and pitch from CUTSCENE_MIN_PITCH to
// CUTSCENE_MAX_PITCH. It sets the distances that the section does not.
@(private = "file")
cutscene_audio_section :: proc(
	found: ^[dynamic]Cutscene_Problem,
	s: Pending_Section,
	c: ^format.Cutscene_Section_Contents,
) {
	if s.roll_line != 0 {
		append(
			found,
			Cutscene_Problem {
				s.roll_line,
				"an audio section has no pre_roll or post_roll: its sound plays only over the section",
			},
		)
	}
	if s.audio_lines[1] == 0 {
		c.min_distance = CUTSCENE_AUDIO_MIN_DISTANCE
	}
	if s.audio_lines[2] == 0 {
		c.max_distance = CUTSCENE_AUDIO_MAX_DISTANCE
	}
	if c.max_distance <= c.min_distance {
		append(
			found,
			Cutscene_Problem {
				max(s.audio_lines[1], s.audio_lines[2]),
				"max_distance is farther than min_distance",
			},
		)
	}
	for ch in s.channels {
		switch ch.name {
		case format.CUTSCENE_AUDIO_GAIN:
			for k in ch.keys {
				if k.value < 0 {
					append(found, Cutscene_Problem{ch.line, "a gain key is a number from 0"})
					break
				}
			}
		case format.CUTSCENE_AUDIO_PITCH:
			for k in ch.keys {
				if !(k.value >= format.CUTSCENE_MIN_PITCH &&
					   k.value <= format.CUTSCENE_MAX_PITCH) {
					append(
						found,
						Cutscene_Problem {
							ch.line,
							fmt.aprintf(
								"a pitch key is a number from %v to %v",
								format.CUTSCENE_MIN_PITCH,
								format.CUTSCENE_MAX_PITCH,
							),
						},
					)
					break
				}
			}
		case:
			append(found, Cutscene_Problem{ch.line, "an audio track's channel is gain or pitch"})
		}
	}
}

// CUTSCENE_TRANSFORM_CHANNELS are the channels of a transform track: position in meters, rotation as Euler angles in
// degrees, and scale.
CUTSCENE_TRANSFORM_CHANNELS :: [9]string {
	"position_x",
	"position_y",
	"position_z",
	"rotation_x",
	"rotation_y",
	"rotation_z",
	"scale_x",
	"scale_y",
	"scale_z",
}

// cutscene_transform_channels checks that a transform section's channels are among the nine of a pose.
@(private = "file")
cutscene_transform_channels :: proc(found: ^[dynamic]Cutscene_Problem, s: Pending_Section) {
	names := CUTSCENE_TRANSFORM_CHANNELS
	for c in s.channels {
		if !slice.contains(names[:], c.name) {
			append(
				found,
				Cutscene_Problem {
					c.line,
					"a transform track's channel is position_x, position_y, position_z, rotation_x, rotation_y, rotation_z, scale_x, scale_y or scale_z",
				},
			)
		}
	}
}

// cutscene_relative_cycles reports each transform track whose binding is, through the tracks relative to other
// bindings, relative to itself, at its space line, with the path, such as `relative bindings form a cycle: Fox -> Ship
// -> Fox`. A track relative to its own binding is reported where its space is read.
@(private = "file")
cutscene_relative_cycles :: proc(
	found: ^[dynamic]Cutscene_Problem,
	pending: []Pending_Track,
	tracks: []format.Cutscene_Track_Contents,
	bindings: []format.Cutscene_Binding_Contents,
) {
	n := len(bindings)
	relative :: proc(tr: format.Cutscene_Track_Contents, n: int) -> bool {
		return(
			tr.kind == .Transform &&
			tr.space == .Relative_To &&
			int(tr.binding) < n &&
			int(tr.relative) < n &&
			tr.binding != tr.relative \
		)
	}
	// from[b] is the binding that the search reached b from, or -1.
	from := make([]int, n, context.temp_allocator)
	queue := make([dynamic]int, context.temp_allocator)
	for tr, i in tracks {
		if !relative(tr, n) {
			continue
		}
		slice.fill(from, -1)
		clear(&queue)
		start, target := int(tr.relative), int(tr.binding)
		from[start] = target
		append(&queue, start)
		reached := false
		for head := 0; head < len(queue) && !reached; head += 1 {
			b := queue[head]
			for other in tracks {
				if !relative(other, n) || int(other.binding) != b || from[other.relative] >= 0 {
					continue
				}
				from[other.relative] = b
				if int(other.relative) == target {
					reached = true
					break
				}
				append(&queue, int(other.relative))
			}
		}
		if !reached {
			continue
		}
		path := make([dynamic]string, context.temp_allocator)
		append(&path, bindings[target].name)
		for b := from[target]; b != target; b = from[b] {
			append(&path, bindings[b].name)
		}
		append(&path, bindings[target].name)
		slice.reverse(path[:])
		append(
			found,
			Cutscene_Problem {
				pending[i].space_line,
				fmt.aprintf(
					"relative bindings form a cycle: %s",
					strings.join(path[:], " -> ", context.temp_allocator),
				),
			},
		)
	}
}

CUTSCENE_SUSPEND_MESSAGE :: "suspend is a list of behaviours, ai, navigation and physics, such as [behaviours, ai], or []"

// cutscene_suspend reads a list of the systems that a binding suspends, such as [behaviours, ai], each at most once.
@(private = "file")
cutscene_suspend :: proc(text: string) -> (set: format.Cutscene_Suspend_Set, ok: bool) {
	items := cutscene_list(text) or_return
	next: for item in items {
		for name, system in format.CUTSCENE_SUSPEND_NAMES {
			if item == name && system not_in set {
				set += {system}
				continue next
			}
		}
		return {}, false
	}
	return set, true
}

// cutscene_list reads `[a, b, c]` into its items, trimmed, in the temporary allocator. `[]` has none.
@(private = "file")
cutscene_list :: proc(text: string) -> (items: []string, ok: bool) {
	if !strings.has_prefix(text, "[") || !strings.has_suffix(text, "]") {
		return
	}
	inner := strings.trim_space(text[1:len(text) - 1])
	if inner == "" {
		return {}, true
	}
	parts := strings.split(inner, ",", context.temp_allocator)
	for &part in parts {
		part = strings.trim_space(part)
		if part == "" {
			return
		}
	}
	return parts, true
}

// cutscene_skip_ranges reads `[[a, b], [c, d]]` into ranges of ticks, in the temporary allocator. A list without
// ranges is not one: a cutscene that cannot be skipped says none.
@(private = "file")
cutscene_skip_ranges :: proc(text: string) -> (ranges: []format.Cutscene_Skip_Range, ok: bool) {
	if !strings.has_prefix(text, "[") || !strings.has_suffix(text, "]") {
		return
	}
	rest := strings.trim_space(text[1:len(text) - 1])
	found := make([dynamic]format.Cutscene_Skip_Range, context.temp_allocator)
	for rest != "" {
		if len(found) > 0 {
			if !strings.has_prefix(rest, ",") {
				return
			}
			rest = strings.trim_space(rest[1:])
		}
		close := strings.index_byte(rest, ']')
		if !strings.has_prefix(rest, "[") || close < 0 {
			return
		}
		value, message := parse_graph_value(rest[:close + 1])
		if message != "" || value.kind != .Numbers || value.count != 2 {
			return
		}
		start := cutscene_ticks_number(value.numbers[0]) or_return
		end := cutscene_ticks_number(value.numbers[1]) or_return
		append(&found, format.Cutscene_Skip_Range{start, end})
		rest = strings.trim_space(rest[close + 1:])
	}
	if len(found) == 0 {
		return
	}
	return found[:], true
}

// CUTSCENE_COLOR_FORM is how the text gives a color, for the problems that name it.
@(private = "file")
CUTSCENE_COLOR_FORM :: "a quoted color, as \"#rrggbb\" or \"#rgb\", without alpha"

// cutscene_color reads a quoted opaque color, as a UI document gives one: quoted, since a # outside quotes starts a
// comment.
@(private = "file")
cutscene_color :: proc(text: string) -> (color: [3]u8, ok: bool) {
	quoted := cutscene_name(text) or_return
	if len(quoted) != 4 && len(quoted) != 7 {
		return
	}
	parsed := format.ui_parse_color(quoted) or_return
	return parsed.rgb, true
}

// cutscene_name reads a quoted name.
@(private = "file")
cutscene_name :: proc(text: string) -> (name: string, ok: bool) {
	value, message := parse_graph_value(text)
	if message != "" || value.kind != .Text {
		return
	}
	return value.text, true
}

// cutscene_ticks_number is a number that parse_graph_value read as a time in ticks, if it is a whole one in range.
@(private = "file")
cutscene_ticks_number :: proc(n: f64) -> (ticks: i32, ok: bool) {
	if !(n >= 0 && n <= f64(max(i32))) || n != math.floor(n) {
		return
	}
	return i32(n), true
}
