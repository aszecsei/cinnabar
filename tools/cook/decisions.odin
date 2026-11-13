package cook

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Decisions are .decision text files: how an agent picks its actions, by one technique over a blackboard (see
// docs/content/kinds/decisions.md). The cook reads the header and the nodes, and each node's shared parts, its `when`,
// `action` and `set` lines, against the blackboard's keys, which it reads from the blackboard's source. The rest of each
// node, and the header's other lines, go to the technique's reader, which writes the technique's own part of the blob
// and sizes the agents' module state.
DECISION_COOK_VERSION :: "decisions 1"

// Decision_Field is a `<field> = <value>` line that the shared parts do not read, which the technique's reader does.
Decision_Field :: struct {
	line:  int,
	key:   string,
	value: string,
}

// Decision_Text_Node is a node, `node <id> <kind>`, with the fields that its technique reads. Its shared parts are its
// record in the parser's nodes, at index; set_line is the line of its first `set`, or 0 without one, and its writes are
// a range of the parser's writes.
Decision_Text_Node :: struct {
	id:          int,
	kind:        string,
	line:        int,
	index:       int,
	set_line:    int,
	first_write: u32,
	write_count: u32,
	fields:      [dynamic]Decision_Field,
}

// Decision_Text is what a technique's reader gets: the header's lines other than the technique and the blackboard,
// and the nodes in the text's order.
Decision_Text :: struct {
	settings: [dynamic]Decision_Field,
	nodes:    [dynamic]Decision_Text_Node,
}

// Technique_Reader reads a technique's part of a decision. read reports problems with decision_problem and gives the
// bytes of module state that each agent needs and the technique's data for the blob. version is in the decisions'
// cache key, so a new reader cooks every decision of its technique again.
Technique_Reader :: struct {
	version: string,
	read:    proc(p: ^Decision_Parser, text: ^Decision_Text) -> (state_size: u32, data: []byte),
}

// Technique_Readers are the readers of each technique. A technique without one is a problem in each decision that
// names it. Each technique adds its own (see docs/content/kinds/decisions.md#techniques).
Technique_Readers :: [format.Decision_Technique]Technique_Reader

// TECHNIQUE_READERS are the cooker's readers.
TECHNIQUE_READERS :: #partial Technique_Readers {
	.Behavior_Tree = BEHAVIOR_TREE_READER,
	.Utility       = UTILITY_READER,
	.Goap          = GOAP_READER,
	.Htn           = HTN_READER,
}

// Decision_Header is what decision_header finds of a decision before its blackboard is read.
Decision_Header :: struct {
	blackboard:      format.Guid,
	blackboard_line: int,
}

// decision_header finds the blackboard that a decision names, so that the cook can read its keys before it parses the
// rest. A decision that names none, or names it twice, is a problem that decision_parse reports.
decision_header :: proc(text: string) -> (header: Decision_Header) {
	for raw, index in strings.split_lines(text, context.temp_allocator) {
		if len(raw) == 0 || raw[0] == '\t' || raw[0] == ' ' {
			continue
		}
		key, has_value, value := strings.partition(strings.trim_space(strip_line_comment(raw)), "=")
		if has_value != "" && strings.trim_space(key) == "blackboard" {
			v, _ := parse_graph_value(strings.trim_space(value))
			if v.kind == .Asset && header.blackboard_line == 0 {
				header = {v.guid, index + 1}
			}
		}
	}
	return
}

// decision_parse parses a decision's text against its blackboard's keys into the contents of its blob, without its
// GUID, key, path or blackboard's key. It gives every problem that it finds, and the decision is good only without
// any.
decision_parse :: proc(
	text: string,
	keys: []format.Blackboard_Key_Contents,
	readers: Technique_Readers,
	allocator := context.allocator,
) -> (
	contents: format.Decision_Contents,
	problems: []Blackboard_Problem,
) {
	context.allocator = allocator
	found := make([dynamic]Blackboard_Problem)
	p := Decision_Parser {
		found = &found,
		keys  = keys,
	}
	nodes := make([dynamic]format.Decision_Node_Contents)
	d := Decision_Text{}
	ids := make(map[int]int)
	header := false
	technique: Maybe(format.Decision_Technique)
	technique_line, blackboard_line := 0, 0
	current := -1
	for raw, index in strings.split_lines(text) {
		line := index + 1
		trimmed := strings.trim_space(strip_line_comment(raw))
		if trimmed == "" {
			continue
		}
		if !header {
			if fields := strings.fields(trimmed); len(fields) == 2 && fields[0] == "decision" && fields[1] == "1" && raw[0] != '\t' && raw[0] != ' ' {
				header = true
				continue
			}
			decision_problem(&p, line, "a decision starts with `decision 1`")
			return {}, found[:]
		}
		if raw[0] == '\t' || raw[0] == ' ' {
			if current < 0 {
				decision_problem(&p, line, "an indented line belongs to a `node`")
				continue
			}
			node_field(&p, &d.nodes[current], &nodes[current], trimmed, line)
			continue
		}
		current = -1
		if fields := strings.fields(trimmed, context.temp_allocator); fields[0] == "node" {
			id, id_ok := strconv.parse_int(fields[1] if len(fields) > 1 else "")
			if len(fields) != 3 || !id_ok || id <= 0 || !is_identifier(fields[2]) {
				decision_problem(&p, line, "a node is `node <id> <kind>`, with an ID above 0")
				continue
			}
			if _, taken := ids[id]; taken {
				decision_problem(&p, line, "another node has the ID %d", id)
				continue
			}
			ids[id] = len(nodes)
			current = len(nodes)
			append(&d.nodes, Decision_Text_Node{id = id, kind = fields[2], line = line, index = len(nodes)})
			append(&nodes, format.Decision_Node_Contents{id = u32(id), kind = fields[2], condition = format.DECISION_NONE, action = format.DECISION_NONE})
			continue
		}
		key, has_value, value := strings.partition(trimmed, "=")
		key, value = strings.trim_space(key), strings.trim_space(value)
		if has_value == "" || !is_identifier(key) || value == "" {
			decision_problem(&p, line, "expected `technique = <technique>`, `blackboard = $<guid>`, `<setting> = <value>` or `node <id> <kind>`")
			continue
		}
		switch key {
		case "technique":
			if technique_line != 0 {
				decision_problem(&p, line, "the decision names its technique twice")
				continue
			}
			technique_line = line
			for name, t in format.DECISION_TECHNIQUE_NAMES {
				if name == value {
					technique = t
				}
			}
			if technique == nil {
				names := make([dynamic]string, context.temp_allocator)
				for name in format.DECISION_TECHNIQUE_NAMES {
					append(&names, name)
				}
				decision_problem(&p, line, "%s is not a technique: a decision is %s", value, strings.join(names[:], ", ", context.temp_allocator))
			}
		case "blackboard":
			v, _ := parse_graph_value(value)
			if blackboard_line != 0 {
				decision_problem(&p, line, "the decision names its blackboard twice")
			} else if v.kind != .Asset {
				decision_problem(&p, line, "blackboard is a blackboard's GUID, $<32 hex digits>")
			}
			blackboard_line = line
		case:
			for s in d.settings {
				if s.key == key {
					decision_problem(&p, line, "the decision sets %s twice", key)
				}
			}
			append(&d.settings, Decision_Field{line, key, value})
		}
	}
	if !header {
		decision_problem(&p, 1, "a decision starts with `decision 1`")
		return {}, found[:]
	}
	if technique_line == 0 {
		decision_problem(&p, 1, "a decision names its technique: `technique = <technique>`")
	}
	if blackboard_line == 0 {
		decision_problem(&p, 1, "a decision names its blackboard: `blackboard = $<guid>`")
	}
	state_size: u32
	data: []byte
	if t, known := technique.?; known {
		technique_names := format.DECISION_TECHNIQUE_NAMES
		contents.technique = t
		if readers[t].read == nil {
			decision_problem(&p, technique_line, "the technique %s has no reader in this cooker yet", technique_names[t])
		} else {
			state_size, data = readers[t].read(&p, &d)
			if state_size > format.MAX_DECISION_STATE {
				decision_problem(&p, technique_line, "the decision's state is %d bytes, more than %d", state_size, format.MAX_DECISION_STATE)
			}
		}
	}
	contents.state_size = state_size
	contents.technique_data = data
	contents.nodes = nodes[:]
	contents.conditions = p.conditions[:]
	contents.ops = p.ops[:]
	contents.constants = p.constants[:]
	contents.actions = p.actions[:]
	contents.args = p.args[:]
	contents.writes = p.writes[:]
	slice.stable_sort_by(found[:], proc(a, b: Blackboard_Problem) -> bool {return a.line < b.line})
	return contents, found[:]
}

// node_field reads a line indented under a node: `when = <condition>`, `action = <action>`, `set <key> = <value>`,
// `position = [x, y]`, which the cook keeps for the editor and does not read, or a field of the technique's.
@(private = "file")
node_field :: proc(p: ^Decision_Parser, node: ^Decision_Text_Node, record: ^format.Decision_Node_Contents, text: string, line: int) {
	if strings.has_prefix(text, "set ") || strings.has_prefix(text, "set\t") {
		if node.set_line == 0 {
			node.set_line = line
		}
		write :=decision_write(p, strings.trim_space(text[len("set"):]), line)
		if write == format.DECISION_NONE {
			return
		}
		// A node's lines follow each other, so its writes are one range.
		if record.write_count == 0 {
			record.first_write = write
		}
		assert(record.first_write + record.write_count == write)
		record.write_count += 1
		node.first_write, node.write_count = record.first_write, record.write_count
		return
	}
	key, has_value, value := strings.partition(text, "=")
	key, value = strings.trim_space(key), strings.trim_space(value)
	if has_value == "" || !is_identifier(key) || value == "" {
		decision_problem(p, line, "a node's line is `<field> = <value>` or `set <key> = <value>`")
		return
	}
	for f in node.fields {
		if f.key == key {
			decision_problem(p, line, "the node sets %s twice", key)
			return
		}
	}
	// The field is the node's, whether it parses or not, so a second one is a problem either way.
	append(&node.fields, Decision_Field{line, key, value})
	switch key {
	case "when":
		record.condition = decision_condition(p, value, line)
	case "action":
		record.action = decision_action(p, value, line)
	}
}

cook_decisions :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	out_dir := config_dir(options)
	decisions := carry_kind(pass, {.Decision})
	if len(decisions) > 0 && !make_output_dir(pass, out_dir, {.Decision}) {
		return false
	}
	by_guid := make(map[format.Guid]int, len(assets), context.temp_allocator)
	for a, i in assets {
		by_guid[a.meta.guid] = i
	}
	readers := TECHNIQUE_READERS
	for r, t in options.technique_readers {
		if r.read != nil {
			readers[t] = r
		}
	}
	ok := true
	step_begin(pass, .Decision, "", len(decisions))
	for i in decisions {
		defer step_advance(pass)
		asset_source(pass, i)
		result := cook_decision(i, assets, by_guid, out_dir, pass, readers)
		settle(pass, i, result)
		ok &&= !asset_failed(result)
	}
	return ok
}

@(private = "file")
cook_decision :: proc(
	index: int,
	assets: []Asset_Source,
	by_guid: map[format.Guid]int,
	out_dir: string,
	pass: ^Pass,
	readers: Technique_Readers,
) -> Asset_Result {
	a := &assets[index]
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	text := string(source_of(a^))
	header := decision_header(text)
	// What it names is known whether it cooks or not, so the index has it either way, and fixing the blackboard cooks the
	// decision again.
	if header.blackboard != {} {
		append(&a.dependencies, header.blackboard)
	}
	board := -1
	keys: []format.Blackboard_Key_Contents
	board_ok := true
	if header.blackboard_line != 0 {
		child, found := by_guid[header.blackboard]
		switch {
		case !found:
			report_error(problems, a.path, header.blackboard_line, 0, "no asset has the GUID $%s", guid_text(header.blackboard))
			board_ok = false
		case assets[child].kind != .Blackboard:
			report_error(problems, a.path, header.blackboard_line, 0, "%s is not a blackboard", assets[child].name)
			board_ok = false
		case:
			asset_source(pass, child)
			board = child
			contents, board_problems := blackboard_parse(string(source_of(assets[child])), context.temp_allocator)
			if len(board_problems) > 0 {
				report_error(problems, a.path, header.blackboard_line, 0, "the blackboard %s has problems", assets[child].name)
				board_ok = false
			}
			keys = contents.keys
		}
	}
	contents, parse_problems := decision_parse(text, keys, readers, context.temp_allocator)
	// Without the blackboard's keys every key is unknown, so only the blackboard's problem is reported.
	if board_ok {
		for p in parse_problems {
			report_error(problems, a.path, p.line, 0, "%s", p.message)
		}
	}
	// A decision with errors keeps its old blob, so the running game keeps the last good version.
	if len(parse_problems) > 0 || !board_ok || !settings_ok {
		return .Failed
	}
	layout := format.decision_layout()
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%x\x00%s\x00", DECISION_COOK_VERSION, a.name, layout, readers[contents.technique].version))
	key = hash.fnv64a(source_of(a^), key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
	board_key := blackboard_key(assets[board])
	key = hash.fnv64a(transmute([]byte)fmt.tprintf("%x", board_key), key)
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid))
	if cooked_key(output, .Decision, layout) == key && !pass.force[guid] {
		return .Current
	}
	contents.guid, contents.key, contents.source_path = guid, key, a.name
	contents.blackboard, contents.blackboard_key = header.blackboard, board_key
	if !write_blob(output, format.decision_write(contents, context.temp_allocator)) {
		return .Failed
	}
	return .Cooked
}
