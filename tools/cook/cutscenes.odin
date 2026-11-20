package cook

import "core:fmt"
import "core:hash"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Cutscenes are .cutscene text files: the entities that a cinematic possesses or spawns, and its tracks on one time axis
// in ticks, each with sections of keyed channels, a clip, a sound or a sub-sequence (see
// docs/content/kinds/cutscenes.md). The cook checks the assets that a cutscene names and its sub-sequences' nesting, which
// it reads from the other cutscenes' sources, so the order of the passes does not matter.
CUTSCENE_COOK_VERSION :: "cutscenes 3"

// CUTSCENE_TEMPLATE is the text of a new cutscene: 10 seconds at 30 frames a second, with no bindings or tracks.
CUTSCENE_TEMPLATE :: `cutscene 1
# Bindings, tracks, sections and keys (see docs/content/kinds/cutscenes.md). Times are ticks, 60000 a second.
length = 600000
rate = 30
`

// Cutscene_Problem is an error in a cutscene's text, at a line from 1.
Cutscene_Problem :: struct {
	line:    int,
	message: string,
}

// Cutscene_Reference is an asset that a cutscene names, the kind that it must be, and the line that names it.
Cutscene_Reference :: struct {
	guid: format.Guid,
	want: format.Asset_Kind,
	line: int,
}

// Cutscene_Parsed is a cutscene's text as cutscene_parse reads it: the contents of its blob, without its GUID, key or
// path, and the assets that it names. The references are there even when the text has problems.
Cutscene_Parsed :: struct {
	contents:   format.Cutscene_Contents,
	references: []Cutscene_Reference,
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
	graph := Cutscene_Graph {
		by_guid = make(map[format.Guid]int, len(cutscenes), context.temp_allocator),
		nodes   = make([]Cutscene_Node, len(cutscenes), context.temp_allocator),
	}
	for i, n in cutscenes {
		graph.by_guid[assets[i].meta.guid] = n
	}
	for i, n in cutscenes {
		node := &graph.nodes[n]
		node.asset = i
		node.parsed, node.problems = cutscene_parse(
			string(asset_source(pass, i)),
			context.temp_allocator,
		)
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
	cutscene_cycles(&graph, assets)
	cutscene_depths(&graph, assets)
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

@(private = "file")
Cutscene_Child :: struct {
	node: int,
	line: int,
}

@(private = "file")
Cutscene_Node :: struct {
	asset:          int,
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
cutscene_cycles :: proc(graph: ^Cutscene_Graph, assets: []Asset_Source) {
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
			strings.write_string(&builder, assets[graph.nodes[at].asset].name)
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

// cutscene_depths gives each cutscene the depth of its sub-sequences, and a problem to each that nests deeper than
// CUTSCENE_MAX_DEPTH, at the line of the first sub-sequence on its deepest path. Cycles have their own problem, so a
// path into one counts it as no depth.
@(private = "file")
cutscene_depths :: proc(graph: ^Cutscene_Graph, assets: []Asset_Source) {
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
		strings.write_string(&builder, assets[node.asset].name)
		for at := n; graph.nodes[at].deepest >= 0; {
			at = graph.nodes[at].children[graph.nodes[at].deepest].node
			fmt.sbprintf(&builder, " -> %s", assets[graph.nodes[at].asset].name)
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
		case kind != r.want:
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
	for p in found {
		report_error(problems, a.path, p.line, 0, "%s", p.message)
	}
	// A cutscene with errors keeps its old blob, so the running game keeps the last good version.
	if len(found) > 0 || !settings_ok {
		return .Failed
	}
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf(
			"%s\x00%s\x00%x\x00",
			CUTSCENE_COOK_VERSION,
			a.name,
			format.cutscene_layout(),
		),
	)
	key = hash.fnv64a(source_of(a^), key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
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
	// The line of policy, which only a possessed binding takes, and of the first setting that only a spawned one takes.
	policy:      int,
	spawn_only:  int,
	spawn_name:  string,
	parent_line: int,
	// The line of suspend, or 0 when the binding takes the cutscene's.
	suspend:     int,
}

@(private = "file")
Pending_Channel :: struct {
	name: string,
	line: int,
	keys: [dynamic]format.Cutscene_Key,
}

@(private = "file")
Pending_Section :: struct {
	contents:   format.Cutscene_Section_Contents,
	line:       int,
	seen:       [dynamic]string,
	asset_line: int,
	channels:   [dynamic]Pending_Channel,
}

@(private = "file")
Pending_Track :: struct {
	contents:     format.Cutscene_Track_Contents,
	line:         int,
	seen:         [dynamic]string,
	binding_id:   u32,
	binding_line: int,
	sections:     [dynamic]Pending_Section,
}

// Cutscene_Block is the innermost block that a line is in.
@(private = "file")
Cutscene_Block :: enum {
	Header,
	Binding,
	Track,
	Section,
	Channel,
}

// cutscene_parse parses a cutscene's text: the first line `cutscene 1`, the header's settings, then `binding <id>
// "<name>"` and `track <id> <kind> "<name>"` blocks, a track's `section <id> <start> <end>` blocks, a section's `channel
// <name>` blocks and a channel's `key <time> <value> <interp> [<in> <out>]` lines. A `<name> = <value>` line sets a
// setting of the innermost block. It checks everything but the assets that the text names, and gives every problem that
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
	header_line, length_seen, range_line := 0, false, 0
	block := Cutscene_Block.Header
	section_ids := make(map[u32]bool, 16, context.temp_allocator)
	section_count, channel_count, key_count := 0, 0, 0
	for raw, index in strings.split_lines(text) {
		line := index + 1
		trimmed := strings.trim_space(strip_line_comment(raw))
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
			id, id_ok := cutscene_id(id_text)
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
		if is_block && word == "track" {
			block = .Track
			tr := Pending_Track {
				line = line,
				seen = make([dynamic]string),
				sections = make([dynamic]Pending_Section),
				contents = {binding = format.CUTSCENE_NONE},
			}
			id_text, _, after_id := strings.partition(rest, " ")
			kind_text, _, name_text := strings.partition(strings.trim_space(after_id), " ")
			id, id_ok := cutscene_id(id_text)
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
			if block != .Track && block != .Section && block != .Channel {
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
				id, id_ok = cutscene_id(fields[0])
				s.contents.start, start_ok = cutscene_ticks_text(fields[1])
				s.contents.end, end_ok = cutscene_ticks_text(fields[2])
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
		if is_block && word == "key" {
			if block != .Channel {
				problem(&found, line, "a key comes after a channel line")
				continue
			}
			tr := &tracks[len(tracks) - 1]
			s := &tr.sections[len(tr.sections) - 1]
			c := &s.channels[len(s.channels) - 1]
			key, message := cutscene_key(rest, s.contents.end - s.contents.start)
			if message != "" {
				problem(&found, line, "%s", message)
				continue
			}
			if len(c.keys) > 0 && key.time <= c.keys[len(c.keys) - 1].time {
				problem(&found, line, "keys are in order of time, each after the one before")
				continue
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
				"a line is binding, track, section, channel, key or `<name> = <value>`",
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
				ticks, ok := cutscene_ticks_text(value_text)
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
			case:
				problem(
					&found,
					line,
					"%q is not a setting of the cutscene: length, rate, clock, range, suspend, input_context or hide_ui",
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
				id, ok := cutscene_id(value_text)
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
			case:
				problem(
					&found,
					line,
					"%q is not a setting of a track: binding, muted or when_finished",
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
			case "ease_in", "ease_out", "pre_roll", "post_roll":
				ticks, ok := cutscene_ticks_text(value_text)
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
			case "binding", "muted", "when_finished":
				problem(&found, line, "%s comes before the track's sections", name)
			case:
				problem(
					&found,
					line,
					"%q is not a setting of a section: ease_in, ease_out, weight, pre_roll, post_roll or asset",
					name,
				)
			}
		case .Channel:
			switch name {
			case "ease_in", "ease_out", "weight", "pre_roll", "post_roll", "asset":
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
	// Bindings: what kind each is, and that its settings suit it.
	result_bindings := make([]format.Cutscene_Binding_Contents, len(bindings))
	for &b, i in bindings {
		switch {
		case b.possess == 0 && b.spawn == 0:
			problem(
				&found,
				b.line,
				"a binding possesses an entity with possess, or spawns a prefab with spawn",
			)
		case b.possess != 0 && b.spawn != 0:
			problem(&found, max(b.possess, b.spawn), "a binding possesses or spawns, not both")
		case b.possess != 0:
			b.contents.kind = .Possessed
			if b.spawn_only != 0 {
				problem(&found, b.spawn_only, "%s is for a spawned binding", b.spawn_name)
			}
		case:
			b.contents.kind = .Spawned
			if b.policy != 0 {
				problem(&found, b.policy, "policy is for a possessed binding")
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
		want := format.cutscene_track_asset(kind)
		sections := make([]format.Cutscene_Section_Contents, len(tr.sections))
		for s, j in tr.sections {
			c := s.contents
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
			channels := make([]format.Cutscene_Channel_Contents, len(s.channels))
			for ch, k in s.channels {
				if len(ch.keys) == 0 {
					problem(&found, ch.line, "the channel has no keys")
				}
				channels[k] = {
					name = ch.name,
					keys = ch.keys[:],
				}
			}
			c.channels = channels
			sections[j] = c
		}
		result.sections = sections
		result_tracks[i] = result
	}
	contents.bindings, contents.tracks = result_bindings, result_tracks
	contents.hide_ui = hide_ui[:]
	slice.stable_sort_by(found[:], proc(a, b: Cutscene_Problem) -> bool {return a.line < b.line})
	slice.stable_sort_by(references[:], proc(a, b: Cutscene_Reference) -> bool {
		return a.line < b.line
	})
	return {contents = contents, references = references[:]}, found[:]
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
		id, ok := cutscene_id(value_text)
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
			"%q is not a setting of a binding: possess, policy, spawn, parent, position, rotation, scale, suspend or keep_velocity",
			name,
		)
	}
}

// cutscene_key reads a key's line after `key`: a time in ticks from its section's start, at most its duration, a
// value, an interpolation, and for a cubic key its in and out tangents.
@(private = "file")
cutscene_key :: proc(text: string, duration: i32) -> (key: format.Cutscene_Key, message: string) {
	USAGE :: "a key is `key <time> <value> constant|linear|cubic [<in> <out>]`"
	fields := strings.fields(text, context.temp_allocator)
	if len(fields) != 3 && len(fields) != 5 {
		return {}, USAGE
	}
	time, time_ok := cutscene_ticks_text(fields[0])
	if !time_ok || (duration > 0 && time > duration) {
		return {}, fmt.tprintf("a key's time is a whole number of ticks from 0 to the section's duration (%d)", duration)
	}
	finite :: proc(text: string) -> (f32, bool) {
		v, ok := strconv.parse_f64(text)
		if !ok || !(abs(v) <= f64(max(f32))) {
			return 0, false
		}
		return f32(v), true
	}
	value, value_ok := finite(fields[1])
	if !value_ok {
		return {}, "a key's value is a finite number"
	}
	key = {
		time  = time,
		value = value,
	}
	switch fields[2] {
	case "constant":
		key.interp = .Constant
	case "linear":
		key.interp = .Linear
	case "cubic":
		key.interp = .Cubic
	case:
		return {}, fmt.tprintf("%q is not an interpolation: constant, linear or cubic", fields[2])
	}
	if key.interp == .Cubic {
		if len(fields) != 5 {
			return {}, "a cubic key has an in and an out tangent"
		}
		in_ok, out_ok: bool
		key.in_tangent, in_ok = finite(fields[3])
		key.out_tangent, out_ok = finite(fields[4])
		if !in_ok || !out_ok {
			return {}, "a key's tangents are finite numbers"
		}
	} else if len(fields) == 5 {
		return {}, fmt.tprintf("a %s key has no tangents", fields[2])
	}
	return key, ""
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

// cutscene_name reads a quoted name.
@(private = "file")
cutscene_name :: proc(text: string) -> (name: string, ok: bool) {
	value, message := parse_graph_value(text)
	if message != "" || value.kind != .Text {
		return
	}
	return value.text, true
}

// cutscene_id reads an ID: a whole number from 1 to 2147483647.
@(private = "file")
cutscene_id :: proc(text: string) -> (id: u32, ok: bool) {
	for c in transmute([]byte)text {
		if c < '0' || c > '9' {
			return
		}
	}
	n := strconv.parse_u64_of_base(text, 10) or_return
	if n == 0 || n > u64(max(i32)) {
		return
	}
	return u32(n), true
}

// cutscene_ticks_text reads a time in ticks: a whole number from 0 to 2147483647, in digits.
@(private = "file")
cutscene_ticks_text :: proc(text: string) -> (ticks: i32, ok: bool) {
	if text == "" {
		return
	}
	for c in transmute([]byte)text {
		if c < '0' || c > '9' {
			return
		}
	}
	n := strconv.parse_u64_of_base(text, 10) or_return
	if n > u64(max(i32)) {
		return
	}
	return i32(n), true
}

// cutscene_ticks_number is a number that parse_graph_value read as a time in ticks, if it is a whole one in range.
@(private = "file")
cutscene_ticks_number :: proc(n: f64) -> (ticks: i32, ok: bool) {
	if !(n >= 0 && n <= f64(max(i32))) || n != math.floor(n) {
		return
	}
	return i32(n), true
}
