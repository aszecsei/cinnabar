package cook

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Animation graphs are .animation_graph text files: parameters, the clips that the graph plays with the events at
// their times, and nodes of a state machine, its states, blends and transitions (see
// docs/content/kinds/animation-graphs.md#animation-graphs). The cooker parses one and writes an Animation_Graph blob.
// It does not read the clips' blobs, so a marker past its clip's end and a root motion joint that the skin does not
// have are found when the game loads the graph.
ANIMATION_GRAPH_COOK_VERSION :: "animation graphs 1"

// ANIMATION_GRAPH_TEMPLATE is a new graph's text: a speed parameter, and one state that plays a clip whose GUID the
// author fills in.
ANIMATION_GRAPH_TEMPLATE :: `animation_graph 1
# Fill in the clip's GUID: one of a model's animation sub-assets, from its .meta file.
entry = idle

param speed float 0

clip idle = $00000000000000000000000000000000

node 1 state
	position = [0, 0]
	name = idle
	motion = idle
`

// Animation_Graph_Problem is an error in an animation graph's text, at a line from 1.
Animation_Graph_Problem :: struct {
	line:    int,
	message: string,
}

cook_animation_graphs :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	out_dir := config_dir(options)
	graphs := carry_kind(pass, {.Animation_Graph})
	if len(graphs) > 0 && !make_output_dir(pass, out_dir, {.Animation_Graph}) {
		return false
	}
	ok := true
	step_begin(pass, .Animation_Graph, "", len(graphs))
	for i in graphs {
		defer step_advance(pass)
		asset_source(pass, i)
		result := cook_animation_graph(&assets[i], out_dir, pass)
		settle(pass, i, result)
		ok &&= !asset_failed(result)
	}
	return ok
}

@(private = "file")
cook_animation_graph :: proc(a: ^Asset_Source, out_dir: string, pass: ^Pass) -> Asset_Result {
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	contents, parse_problems := animation_graph_parse(string(source_of(a^)), context.temp_allocator)
	for p in parse_problems {
		report_error(problems, a.path, p.line, 0, "%s", p.message)
	}
	// A graph with errors keeps its old blob, so the running game keeps the last good version.
	if len(parse_problems) > 0 || !settings_ok {
		return .Failed
	}
	// What it names is known whether it cooks or not, so the index has it either way.
	for c in contents.clips {
		if c.clip != {} {
			append(&a.dependencies, c.clip)
		}
	}
	layout := format.animation_graph_layout()
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%x\x00", ANIMATION_GRAPH_COOK_VERSION, a.name, layout))
	key = hash.fnv64a(source_of(a^), key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
	buffer: [32]u8
	output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(guid, &buffer))
	if cooked_key(output, .Animation_Graph, layout) == key && !pass.force[guid] {
		return .Current
	}
	contents.guid, contents.key, contents.source_path = guid, key, a.name
	if !write_blob(output, format.animation_graph_write(contents, context.temp_allocator)) {
		return .Failed
	}
	return .Cooked
}

@(private = "file")
Graph_Line :: struct {
	line:  int,
	key:   string,
	value: Graph_Value,
	// The text after the =, which a transition's when reads as conditions.
	text:  string,
}

@(private = "file")
Graph_Block_Kind :: enum {
	Clip,
	State,
	Blend,
	Transition,
}

// Graph_Block is a clip or a node, with the lines indented under it.
@(private = "file")
Graph_Block :: struct {
	kind:  Graph_Block_Kind,
	line:  int,
	id:    int,
	name:  string,
	guid:  format.Guid,
	lines: [dynamic]Graph_Line,
}

@(private = "file")
Graph_Parse :: struct {
	found:       ^[dynamic]Animation_Graph_Problem,
	parameters:  [dynamic]format.Animation_Graph_Parameter_Contents,
	clips:       [dynamic]format.Animation_Graph_Clip_Contents,
	events:      [dynamic]format.Animation_Graph_Event_Contents,
	states:      [dynamic]format.Animation_Graph_State_Contents,
	transitions: [dynamic]format.Animation_Graph_Transition_Contents,
	// Indices by name, and the line where each was named.
	parameter:   map[string]int,
	clip:        map[string]int,
	state:       map[string]int,
	blocks:      [dynamic]Graph_Block,
	// Each node's block, by its ID.
	nodes:       map[int]int,
	// Each blend_1d's parameter and points, by its block, once a state names it.
	blends:      map[int]Graph_Blend,
}

@(private = "file")
Graph_Blend :: struct {
	parameter: u32,
	points:    []format.Animation_Graph_Point,
}

@(private = "file")
problem :: proc(p: ^Graph_Parse, line: int, f: string, args: ..any) {
	append(p.found, Animation_Graph_Problem{line, fmt.aprintf(f, ..args)})
}

// animation_graph_parse parses an animation graph's text into the contents of its blob, without its GUID, key or
// path. It gives every problem that it finds, and the graph is good only without any.
animation_graph_parse :: proc(text: string, allocator := context.allocator) -> (contents: format.Animation_Graph_Contents, problems: []Animation_Graph_Problem) {
	context.allocator = allocator
	found := make([dynamic]Animation_Graph_Problem)
	p := Graph_Parse {
		found = &found,
	}
	header := false
	entry_name, entry_line := "", 0
	root_motion := ""
	current := -1
	for raw, index in strings.split_lines(text) {
		line := index + 1
		trimmed := strings.trim_space(strip_comment(raw))
		if trimmed == "" {
			continue
		}
		indented := raw[0] == '\t' || raw[0] == ' '
		fields := strings.fields(trimmed)
		if !header {
			if !indented && len(fields) == 2 && fields[0] == "animation_graph" && fields[1] == "1" {
				header = true
				continue
			}
			problem(&p, line, "an animation graph starts with `animation_graph 1`")
			return {}, found[:]
		}
		if indented {
			if current < 0 {
				problem(&p, line, "an indented line belongs to a `clip` or a `node`")
				continue
			}
			block_line(&p, &p.blocks[current], trimmed, line)
			continue
		}
		current = -1
		switch fields[0] {
		case "param":
			parameter_line(&p, fields[1:], line)
		case "clip":
			current = clip_line(&p, trimmed[len("clip"):], line)
		case "node":
			current = node_line(&p, fields[1:], line)
		case:
			key, _, value := strings.partition(trimmed, "=")
			key, value = strings.trim_space(key), strings.trim_space(value)
			v, message := parse_graph_value(value)
			switch {
			case message != "" && (key == "entry" || key == "root_motion"):
				problem(&p, line, "%s", message)
			case key == "entry" && v.kind == .Word:
				entry_name, entry_line = v.text, line
			case key == "root_motion" && v.kind == .Text:
				root_motion = v.text
			case key == "entry":
				problem(&p, line, "entry is the name of a state")
			case key == "root_motion":
				problem(&p, line, "root_motion is a joint's name in quotes")
			case:
				problem(&p, line, "expected `param`, `clip`, `node`, `entry = <state>` or `root_motion = \"<joint>\"`")
			}
		}
	}
	if !header {
		problem(&p, 1, "an animation graph starts with `animation_graph 1`")
		return {}, found[:]
	}
	resolve_graph(&p)
	entry := 0
	if entry_line == 0 {
		problem(&p, 1, "an animation graph has `entry = <state>`")
	} else if i, known := p.state[entry_name]; known {
		entry = i
	} else {
		problem(&p, entry_line, "there is no state named %s", entry_name)
	}
	if len(p.states) == 0 {
		problem(&p, 1, "an animation graph has a state at least")
	}
	contents = {
		entry       = u32(entry),
		root_motion = root_motion,
		parameters  = p.parameters[:],
		clips       = p.clips[:],
		events      = p.events[:],
		states      = p.states[:],
		transitions = p.transitions[:],
	}
	slice.stable_sort_by(found[:], proc(a, b: Animation_Graph_Problem) -> bool {return a.line < b.line})
	return contents, found[:]
}

// animation_graph_check gives the problems of an animation graph's text that the editor has not saved, as a cook of the
// file at this path would. A text without problems goes in the preview area of the cache, <config>/preview/<guid>.blob,
// which the editor's preview plays; the graph's own blob does not change. A text with problems leaves the last good one.
animation_graph_check :: proc(options: Cook_Options, guid: format.Guid, text, path, name: string) -> (problems: Problems) {
	contents, found := animation_graph_parse(text, context.temp_allocator)
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
	contents.guid, contents.source_path = guid, name
	// The key is of what the graph does, so moving a node or editing a comment, which the blob does not have, does not
	// start the preview again.
	contents.key = hash.fnv64a(format.animation_graph_write(contents, context.temp_allocator))
	buffer: [32]u8
	if !write_blob(fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer)), format.animation_graph_write(contents, context.temp_allocator)) {
		report_error(&problems, path, 0, 0, "cannot write its preview")
	}
	return
}

// strip_comment is a line without a # and what follows it, outside of quotes.
@(private = "file")
strip_comment :: proc(line: string) -> string {
	quoted := false
	for i := 0; i < len(line); i += 1 {
		switch {
		case quoted && line[i] == '\\':
			// The escaped character does not end the string.
			i += 1
		case line[i] == '"':
			quoted = !quoted
		case line[i] == '#' && !quoted:
			return line[:i]
		}
	}
	return line
}

// parameter_line reads `param <name> float [<value>]`, `param <name> bool [true|false]` or `param <name> trigger`.
@(private = "file")
parameter_line :: proc(p: ^Graph_Parse, fields: []string, line: int) {
	if len(fields) < 2 || len(fields) > 3 || !is_identifier(fields[0]) {
		problem(p, line, "a parameter is `param <name> float|bool|trigger [<default>]`")
		return
	}
	name := fields[0]
	parameter := format.Animation_Graph_Parameter_Contents {
		name = name,
	}
	switch fields[1] {
	case "float":
		parameter.kind = .Float
		if len(fields) == 3 {
			value, ok := strconv.parse_f32(fields[2])
			if !ok {
				problem(p, line, "a float parameter's default is a number")
				return
			}
			parameter.default = value
		}
	case "bool":
		parameter.kind = .Bool
		if len(fields) == 3 {
			switch fields[2] {
			case "true":
				parameter.default = 1
			case "false":
			case:
				problem(p, line, "a bool parameter's default is true or false")
				return
			}
		}
	case "trigger":
		parameter.kind = .Trigger
		if len(fields) == 3 {
			problem(p, line, "a trigger has no default: it is set for one tick")
			return
		}
	case:
		problem(p, line, "a parameter is a float, a bool or a trigger")
		return
	}
	if _, taken := p.parameter[name]; taken {
		problem(p, line, "another parameter is named %s", name)
		return
	}
	for other in p.parameters {
		if format.animation_graph_hash(other.name) == format.animation_graph_hash(name) {
			problem(p, line, "the parameters %s and %s have the same hash: rename one", other.name, name)
			return
		}
	}
	if len(p.parameters) == format.MAX_ANIMATION_GRAPH_PARAMETERS {
		problem(p, line, "an animation graph has at most %d parameters", format.MAX_ANIMATION_GRAPH_PARAMETERS)
		return
	}
	p.parameter[name] = len(p.parameters)
	append(&p.parameters, parameter)
}

// clip_line reads `clip <name> = $<guid>` and starts its block, whose lines are its events.
@(private = "file")
clip_line :: proc(p: ^Graph_Parse, rest: string, line: int) -> int {
	name, _, value := strings.partition(rest, "=")
	name, value = strings.trim_space(name), strings.trim_space(value)
	v, _ := parse_graph_value(value)
	if !is_identifier(name) || v.kind != .Asset {
		problem(p, line, "a clip is `clip <name> = $<guid>`, an animation's GUID")
		return -1
	}
	append(&p.blocks, Graph_Block{kind = .Clip, line = line, name = name, guid = v.guid})
	return len(p.blocks) - 1
}

// node_line reads `node <id> state|blend_1d|transition` and starts its block.
@(private = "file")
node_line :: proc(p: ^Graph_Parse, fields: []string, line: int) -> int {
	id, id_ok := strconv.parse_int(fields[0] if len(fields) > 0 else "")
	if len(fields) != 2 || !id_ok || id <= 0 {
		problem(p, line, "a node is `node <id> <kind>`, with an ID above 0")
		return -1
	}
	kind: Graph_Block_Kind
	switch fields[1] {
	case "state":
		kind = .State
	case "blend_1d":
		kind = .Blend
	case "transition":
		kind = .Transition
	case:
		problem(p, line, "a node is a state, a blend_1d or a transition")
		return -1
	}
	if _, taken := p.nodes[id]; taken {
		problem(p, line, "another node has the ID %d", id)
		return -1
	}
	p.nodes[id] = len(p.blocks)
	append(&p.blocks, Graph_Block{kind = kind, line = line, id = id})
	return len(p.blocks) - 1
}

// block_line reads a line indented under a clip, `event <time> <name> [<argument>]...`, or under a node,
// `<field> = <value>`, where an indexed field is `<field>.<index>`.
@(private = "file")
block_line :: proc(p: ^Graph_Parse, b: ^Graph_Block, text: string, line: int) {
	if b.kind == .Clip {
		event_line(p, b, text, line)
		return
	}
	key, _, value := strings.partition(text, "=")
	key, value = strings.trim_space(key), strings.trim_space(value)
	base, _, index := strings.partition(key, ".")
	if _, numbered := strconv.parse_uint(index); !is_identifier(base) || (index != "" && !numbered) {
		problem(p, line, "a node's line is `<field> = <value>`")
		return
	}
	for l in b.lines {
		if l.key == key {
			problem(p, line, "the node sets %s twice", key)
			return
		}
	}
	v: Graph_Value
	if key != "when" {
		message: string
		v, message = parse_graph_value(value)
		if message != "" {
			problem(p, line, "%s", message)
			return
		}
	}
	append(&b.lines, Graph_Line{line, key, v, value})
}

// event_line reads a clip's `event <time> <name> [<argument>]...`, whose arguments are numbers or quoted strings.
@(private = "file")
event_line :: proc(p: ^Graph_Parse, b: ^Graph_Block, text: string, line: int) {
	tokens, ok := split_tokens(text)
	if !ok || len(tokens) < 3 || tokens[0] != "event" {
		problem(p, line, "a clip's line is `event <time> <name> [<argument>]...`")
		return
	}
	// The event's line is its time, which resolve_graph puts in the clip.
	append(&b.lines, Graph_Line{line = line, key = "event", text = text})
}

// split_tokens splits a line at its spaces, keeping a quoted string, with spaces in it, as one token.
@(private = "file")
split_tokens :: proc(text: string) -> (tokens: []string, ok: bool) {
	result := make([dynamic]string)
	start := -1
	quoted := false
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		switch {
		case quoted && c == '\\':
			i += 1
		case c == '"':
			if start < 0 {
				start = i
			}
			quoted = !quoted
		case !quoted && (c == ' ' || c == '\t'):
			if start >= 0 {
				append(&result, text[start:i])
				start = -1
			}
		case start < 0:
			start = i
		}
	}
	if quoted {
		return
	}
	if start >= 0 {
		append(&result, text[start:])
	}
	return result[:], true
}

// resolve_graph turns the blocks into the graph's clips, states and transitions, now that every name is known.
@(private = "file")
resolve_graph :: proc(p: ^Graph_Parse) {
	for &b in p.blocks {
		if b.kind != .Clip {
			continue
		}
		if _, taken := p.clip[b.name]; taken {
			problem(p, b.line, "another clip is named %s", b.name)
			continue
		}
		p.clip[b.name] = len(p.clips)
		markers := make([dynamic]format.Animation_Graph_Marker)
		for l in b.lines {
			if marker, ok := resolve_event(p, l); ok {
				append(&markers, marker)
			}
		}
		slice.stable_sort_by(markers[:], proc(a, b: format.Animation_Graph_Marker) -> bool {return a.time < b.time})
		append(&p.clips, format.Animation_Graph_Clip_Contents{name = b.name, clip = b.guid, markers = markers[:]})
	}
	// States first, so that transitions find them by name.
	for &b in p.blocks {
		if b.kind == .State {
			resolve_state(p, &b)
		}
	}
	for &b in p.blocks {
		if b.kind == .Transition {
			resolve_transition(p, &b)
		}
	}
	for &b in p.blocks {
		if b.kind == .Blend {
			for l in b.lines {
				base, _, _ := strings.partition(l.key, ".")
				if base != "parameter" && base != "input" && base != "at" && base != "position" {
					problem(p, l.line, "a blend_1d has a parameter, and input.<n> and at.<n> for each clip")
				}
			}
		}
	}
}

@(private = "file")
resolve_event :: proc(p: ^Graph_Parse, l: Graph_Line) -> (marker: format.Animation_Graph_Marker, ok: bool) {
	tokens, _ := split_tokens(l.text)
	time, time_ok := strconv.parse_f32(tokens[1])
	if !time_ok || time < 0 {
		problem(p, l.line, "an event's time is a number of seconds from 0")
		return
	}
	if !is_identifier(tokens[2]) {
		problem(p, l.line, "an event's name is a word, such as footstep")
		return
	}
	args := tokens[3:]
	if len(args) > format.MAX_ANIMATION_GRAPH_ARGS {
		problem(p, l.line, "an event has at most %d arguments", format.MAX_ANIMATION_GRAPH_ARGS)
		return
	}
	event := format.Animation_Graph_Event_Contents {
		name = tokens[2],
	}
	for a, i in args {
		v, message := parse_graph_value(a)
		switch {
		case message == "" && v.kind == .Text:
			event.args[i] = {kind = .Text, text = v.text}
		case message == "" && v.kind == .Numbers && v.count == 1 && a[0] != '[':
			event.args[i] = {kind = .Number, number = f32(v.numbers[0])}
		case:
			problem(p, l.line, "an event's argument is a number or a quoted string")
			return
		}
	}
	append(&p.events, event)
	return {time = time, event = u32(len(p.events) - 1)}, true
}

@(private = "file")
add_event :: proc(p: ^Graph_Parse, name: string) -> u32 {
	append(&p.events, format.Animation_Graph_Event_Contents{name = name})
	return u32(len(p.events) - 1)
}

@(private = "file")
find_line :: proc(b: ^Graph_Block, key: string) -> (Graph_Line, bool) {
	for l in b.lines {
		if l.key == key {
			return l, true
		}
	}
	return {}, false
}

// number_field reads a node's number at least 0, or gives the default without it.
@(private = "file")
number_field :: proc(p: ^Graph_Parse, b: ^Graph_Block, key: string, default: f32) -> (value: f32, set: bool) {
	l, found := find_line(b, key)
	if !found {
		return default, false
	}
	if l.value.kind != .Numbers || l.value.count != 1 || l.value.numbers[0] < 0 {
		problem(p, l.line, "%s is a number from 0", key)
		return default, false
	}
	return f32(l.value.numbers[0]), true
}

// word_field reads a node's word, such as a name, or "" without it.
@(private = "file")
word_field :: proc(p: ^Graph_Parse, b: ^Graph_Block, key: string) -> (word: string, line: int) {
	l, found := find_line(b, key)
	if !found {
		return "", 0
	}
	if l.value.kind != .Word {
		problem(p, l.line, "%s is a name, such as walk", key)
		return "", 0
	}
	return l.value.text, l.line
}

@(private = "file")
resolve_state :: proc(p: ^Graph_Parse, b: ^Graph_Block) {
	for l in b.lines {
		switch l.key {
		case "name", "motion", "speed", "loop", "enter_event", "exit_event", "position":
		case:
			problem(p, l.line, "a state has a name, a motion, a speed, loop, an enter_event and an exit_event")
		}
	}
	name, name_line := word_field(p, b, "name")
	switch {
	case name_line == 0:
		problem(p, b.line, "a state has `name = <name>`")
		return
	case name == "any":
		problem(p, name_line, "any is every state, in a transition's from: name the state otherwise")
		return
	}
	if _, taken := p.state[name]; taken {
		problem(p, name_line, "another state is named %s", name)
		return
	}
	for other in p.states {
		if format.animation_graph_hash(other.name) == format.animation_graph_hash(name) {
			problem(p, name_line, "the states %s and %s have the same hash: rename one", other.name, name)
			return
		}
	}
	state := format.Animation_Graph_State_Contents {
		name        = name,
		parameter   = format.ANIMATION_GRAPH_NONE,
		enter_event = format.ANIMATION_GRAPH_NONE,
		exit_event  = format.ANIMATION_GRAPH_NONE,
		node        = u32(b.id),
		loop        = true,
	}
	state.speed, _ = number_field(p, b, "speed", 1)
	if l, found := find_line(b, "loop"); found {
		switch {
		case l.value.kind == .Word && l.value.text == "true":
		case l.value.kind == .Word && l.value.text == "false":
			state.loop = false
		case:
			problem(p, l.line, "loop is true or false")
		}
	}
	if event, line := word_field(p, b, "enter_event"); line != 0 {
		state.enter_event = add_event(p, event)
	}
	if event, line := word_field(p, b, "exit_event"); line != 0 {
		state.exit_event = add_event(p, event)
	}
	motion, found := find_line(b, "motion")
	switch {
	case !found:
		problem(p, b.line, "a state has `motion = <clip>` or `motion = @<blend_1d>.pose`")
	case motion.value.kind == .Word:
		clip, known := p.clip[motion.value.text]
		if !known {
			problem(p, motion.line, "there is no clip named %s", motion.value.text)
		}
		state.motion = .Clip
		state.points = slice.clone([]format.Animation_Graph_Point{{clip = u32(clip)}})
	case motion.value.kind == .Link && motion.value.text == "pose":
		blend_index, known := p.nodes[motion.value.node]
		if !known || p.blocks[blend_index].kind != .Blend {
			problem(p, motion.line, "node %d is not a blend_1d", motion.value.node)
		} else {
			blend, resolved := p.blends[blend_index]
			if !resolved {
				blend = resolve_blend(p, &p.blocks[blend_index])
				p.blends[blend_index] = blend
			}
			state.motion = .Blend_1D
			state.parameter, state.points = blend.parameter, blend.points
		}
	case:
		problem(p, motion.line, "a state's motion is a clip's name or @<blend_1d>.pose")
	}
	p.state[name] = len(p.states)
	append(&p.states, state)
}

// resolve_blend reads a blend_1d's parameter and its clips, ordered by their thresholds.
@(private = "file")
resolve_blend :: proc(p: ^Graph_Parse, b: ^Graph_Block) -> (blend: Graph_Blend) {
	blend.parameter = format.ANIMATION_GRAPH_NONE
	name, name_line := word_field(p, b, "parameter")
	if name_line == 0 {
		problem(p, b.line, "a blend_1d has `parameter = <float parameter>`")
	} else if i, known := p.parameter[name]; !known || p.parameters[i].kind != .Float {
		problem(p, name_line, "a blend_1d's parameter is a float parameter")
	} else {
		blend.parameter = u32(i)
	}
	points := make([dynamic]format.Animation_Graph_Point)
	inputs := 0
	for l in b.lines {
		if strings.has_prefix(l.key, "input.") {
			inputs += 1
		}
	}
	for n in 0 ..< inputs {
		clip, clip_line := word_field(p, b, fmt.tprintf("input.%d", n))
		if clip_line == 0 {
			problem(p, b.line, "a blend_1d's inputs are input.0, input.1 and on, each a clip's name")
			return
		}
		at, has_at := find_line(b, fmt.tprintf("at.%d", n))
		if !has_at || at.value.kind != .Numbers || at.value.count != 1 {
			problem(p, at.line if has_at else clip_line, "input.%d has at.%d, the parameter's value where it plays alone", n, n)
			continue
		}
		i, known := p.clip[clip]
		if !known {
			problem(p, clip_line, "there is no clip named %s", clip)
			continue
		}
		append(&points, format.Animation_Graph_Point{clip = u32(i), threshold = f32(at.value.numbers[0])})
	}
	for l in b.lines {
		if strings.has_prefix(l.key, "at.") {
			index := l.key[len("at."):]
			if n, _ := strconv.parse_int(index); n >= inputs {
				problem(p, l.line, "at.%s has no input.%s", index, index)
			}
		}
	}
	if inputs < 2 || inputs > format.MAX_ANIMATION_GRAPH_POINTS {
		problem(p, b.line, "a blend_1d has from 2 to %d inputs", format.MAX_ANIMATION_GRAPH_POINTS)
		return
	}
	slice.stable_sort_by(points[:], proc(a, b: format.Animation_Graph_Point) -> bool {return a.threshold < b.threshold})
	for i in 1 ..< len(points) {
		if points[i].threshold == points[i - 1].threshold {
			problem(p, b.line, "two of a blend_1d's inputs are at %v", points[i].threshold)
		}
	}
	blend.points = points[:]
	return
}

@(private = "file")
resolve_transition :: proc(p: ^Graph_Parse, b: ^Graph_Block) {
	for l in b.lines {
		switch l.key {
		case "from", "to", "when", "exit_time", "duration", "position":
		case:
			problem(p, l.line, "a transition has a from, a to, a when, an exit_time and a duration")
		}
	}
	t := format.Animation_Graph_Transition_Contents {
		node = u32(b.id),
	}
	from, from_line := word_field(p, b, "from")
	to, to_line := word_field(p, b, "to")
	if from_line == 0 || to_line == 0 {
		problem(p, b.line, "a transition has `from = <state or any>` and `to = <state>`")
		return
	}
	if from == "any" {
		t.from = format.ANIMATION_GRAPH_NONE
	} else if i, known := p.state[from]; known {
		t.from = u32(i)
	} else {
		problem(p, from_line, "there is no state named %s", from)
		return
	}
	if i, known := p.state[to]; known {
		t.to = u32(i)
	} else {
		problem(p, to_line, "there is no state named %s", to)
		return
	}
	if from == to {
		problem(p, b.line, "a transition goes to another state")
		return
	}
	exit_time, has_exit := number_field(p, b, "exit_time", -1)
	t.exit_time = exit_time
	t.duration, _ = number_field(p, b, "duration", 0)
	if has_exit && t.from == format.ANIMATION_GRAPH_NONE {
		problem(p, b.line, "a transition from any state has no exit_time")
	}
	when_line, has_when := find_line(b, "when")
	if has_when {
		conditions, ok := parse_conditions(p, when_line)
		if !ok {
			return
		}
		t.conditions = conditions
	}
	if !has_when && !has_exit {
		problem(p, b.line, "a transition has a when or an exit_time, or it would always be taken")
		return
	}
	append(&p.transitions, t)
}

// parse_conditions reads a transition's when: conditions joined by `and`, each a trigger's or a bool's name, a bool's
// name after !, or a float's name, >, <, == or !=, and a number.
@(private = "file")
parse_conditions :: proc(p: ^Graph_Parse, l: Graph_Line) -> (conditions: []format.Animation_Graph_Condition, ok: bool) {
	result := make([dynamic]format.Animation_Graph_Condition)
	terms := make([dynamic][dynamic]string)
	append(&terms, make([dynamic]string))
	for field in strings.fields(l.text) {
		if field == "and" {
			append(&terms, make([dynamic]string))
		} else {
			append(&terms[len(terms) - 1], field)
		}
	}
	for term in terms {
		if len(term) == 0 {
			problem(p, l.line, "when is conditions joined by `and`, such as speed > 0.1 and grounded")
			return
		}
		name := term[0]
		negated := strings.has_prefix(name, "!")
		if negated {
			name = name[1:]
		}
		index, known := p.parameter[name]
		if !known {
			problem(p, l.line, "there is no parameter named %s", name)
			return
		}
		kind := p.parameters[index].kind
		c := format.Animation_Graph_Condition {
			parameter = u32(index),
		}
		switch {
		case len(term) == 1 && kind == .Trigger && !negated:
			c.op = .Trigger
		case len(term) == 1 && kind == .Bool:
			c.op = .False if negated else .True
		case len(term) == 3 && kind == .Float && !negated:
			value, number := strconv.parse_f32(term[2])
			if !number {
				problem(p, l.line, "%s %s takes a number", name, term[1])
				return
			}
			c.value = value
			switch term[1] {
			case ">":
				c.op = .Greater
			case "<":
				c.op = .Less
			case "==":
				c.op = .Equal
			case "!=":
				c.op = .Not_Equal
			case:
				problem(p, l.line, "a float is compared with >, <, == or !=")
				return
			}
		case kind == .Float:
			problem(p, l.line, "the float %s is compared with a number, such as %s > 0.5", name, name)
			return
		case kind == .Bool:
			problem(p, l.line, "the bool %s is a condition alone, or after !", name)
			return
		case:
			problem(p, l.line, "the trigger %s is a condition alone", name)
			return
		}
		append(&result, c)
	}
	return result[:], true
}
