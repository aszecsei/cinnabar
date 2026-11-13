package cook

import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// The utility technique of the decision kind (see docs/content/kinds/decisions.md#utility). Each `option` node names an
// action and the `consideration` nodes that score it, and each consideration reads an input, normalizes it over a range
// and maps it through a curve. The reader checks the options and considerations, and lays out the agents' module state:
// the running option, each option's state, and the last input and score of each of its considerations.

UTILITY_READER :: Technique_Reader {
	version = "utility 1",
	read    = read_utility,
}

// The defaults of the header's settings.
UTILITY_DEFAULT_WITHIN :: 0.1
UTILITY_DEFAULT_MOMENTUM :: 0.25

@(private = "file")
OPTION_FIELDS :: []string{"action", "when", "weight", "considerations", "target", "target_tag", "cooldown", "position"}
@(private = "file")
CONSIDERATION_FIELDS :: []string{"input", "range", "curve", "slope", "exponent", "x_shift", "y_shift", "points", "position"}

@(private = "file")
Utility_Kind :: enum {
	Unknown,
	Option,
	Consideration,
}

@(private = "file")
Utility_Text_Node :: struct {
	kind:           Utility_Kind,
	option:         format.Utility_Option,
	consideration:  format.Utility_Consideration,
	points:         [dynamic]format.Utility_Point,
	// An option's considerations, by their index in the text's nodes.
	children:       [dynamic]int,
	children_line:  int,
	// Whether an option lists the consideration, and its index among the considerations.
	listed:         bool,
	index:          int,
	// A consideration's input is a bool, which takes no range.
	is_bool:        bool,
	range_line:     int,
	target_tag_line: int,
}

read_utility :: proc(p: ^Decision_Parser, text: ^Decision_Text) -> (state_size: u32, data: []byte) {
	problems := len(p.found)
	contents := format.Utility_Contents {
		within   = UTILITY_DEFAULT_WITHIN,
		momentum = UTILITY_DEFAULT_MOMENTUM,
	}
	within_line := 0
	for s in text.settings {
		switch s.key {
		case "pick":
			pick, ok := name_of(format.UTILITY_PICK_NAMES, s.value)
			if !ok {
				decision_problem(p, s.line, "pick is best or weighted")
			}
			contents.pick = pick
		case "within":
			within_line = s.line
			value, ok := strconv.parse_f32(s.value)
			if !ok || !(value >= 0 && value <= 1) {
				decision_problem(p, s.line, "within is a fraction from 0 to 1")
			}
			contents.within = value
		case "momentum":
			value, ok := strconv.parse_f32(s.value)
			if !ok || !(value >= 0) || value - value != 0 {
				decision_problem(p, s.line, "momentum is a fraction of 0 or more")
			}
			contents.momentum = value
		case:
			decision_problem(p, s.line, "a utility decision has no setting %s: its settings are pick, within and momentum", s.key)
		}
	}
	if within_line != 0 && contents.pick != .Weighted {
		decision_problem(p, within_line, "within is for pick = weighted")
	}
	nodes := make([]Utility_Text_Node, len(text.nodes), context.temp_allocator)
	by_id := make(map[int]int, len(text.nodes), context.temp_allocator)
	for n, i in text.nodes {
		by_id[n.id] = i
	}
	options := 0
	for &n, i in text.nodes {
		read_utility_node(p, &n, &nodes[i])
		options += int(nodes[i].kind == .Option)
	}
	if options == 0 {
		decision_problem(p, 1, "a utility decision has options: `node <id> option`")
	}
	// Each option's considerations.
	for &n in nodes {
		if n.kind != .Option {
			continue
		}
		ids := slice.clone(n.children[:], context.temp_allocator)
		for id, at in ids {
			child, found := by_id[id]
			switch {
			case !found:
				decision_problem(p, n.children_line, "no node has the ID %d", id)
				child = -1
			case nodes[child].kind != .Consideration:
				decision_problem(p, n.children_line, "node %d is not a consideration", id)
				child = -1
			case:
				for other in ids[:at] {
					if other == id {
						decision_problem(p, n.children_line, "node %d is a consideration of this option twice", id)
					}
				}
				nodes[child].listed = true
			}
			n.children[at] = child
		}
	}
	for n, i in nodes {
		if n.kind == .Consideration && !n.listed {
			decision_problem(p, text.nodes[i].line, "no option lists the consideration %d", text.nodes[i].id)
		}
	}
	if len(p.found) > problems {
		return
	}
	// The considerations and their points, in the text's order.
	considerations := make([dynamic]format.Utility_Consideration, context.temp_allocator)
	points := make([dynamic]format.Utility_Point, context.temp_allocator)
	for &n in nodes {
		if n.kind != .Consideration {
			continue
		}
		n.index = len(considerations)
		c := n.consideration
		if c.curve == .Table {
			c.first_point = u32(len(points))
			c.point_count = u32(len(n.points))
			append(&points, ..n.points[:])
		}
		append(&considerations, c)
	}
	// The module state: the running option, then each option's state, then each option's links' states.
	at := u32(size_of(format.Utility_Running))
	records := make([dynamic]format.Utility_Option, context.temp_allocator)
	links := make([dynamic]u32, context.temp_allocator)
	for &n in nodes {
		if n.kind != .Option {
			continue
		}
		o := n.option
		o.first_link = u32(len(links))
		o.link_count = u32(len(n.children))
		for child in n.children {
			append(&links, u32(nodes[child].index))
		}
		o.state = at
		at += size_of(format.Utility_Option_State)
		append(&records, o)
	}
	for &o in records {
		o.links_state = at
		at += o.link_count * size_of(format.Utility_Link_State)
	}
	// The option states are 8-aligned, so the next decision's are too.
	at = (at + 7) &~ 7
	contents.options = records[:]
	contents.considerations = considerations[:]
	contents.links = links[:]
	contents.points = points[:]
	return at, format.utility_write(contents)
}

// read_utility_node reads a node's kind and fields.
@(private = "file")
read_utility_node :: proc(p: ^Decision_Parser, text: ^Decision_Text_Node, n: ^Utility_Text_Node) {
	n.children = make([dynamic]int, context.temp_allocator)
	n.points = make([dynamic]format.Utility_Point, context.temp_allocator)
	switch text.kind {
	case "option":
		n.kind = .Option
	case "consideration":
		n.kind = .Consideration
	case:
		decision_problem(p, text.line, "%s is not a node of a utility decision: a node is option or consideration", text.kind)
		return
	}
	takes := OPTION_FIELDS if n.kind == .Option else CONSIDERATION_FIELDS
	has := proc(text: ^Decision_Text_Node, key: string) -> bool {
		for f in text.fields {
			if f.key == key {
				return true
			}
		}
		return false
	}
	kind_name := text.kind
	if n.kind == .Option {
		n.option = {
			node       = u32(text.index),
			weight     = 1,
			target     = format.DECISION_NONE,
		}
	} else {
		n.consideration = {
			node     = u32(text.index),
			max      = 1,
			slope    = 1,
			exponent = 1,
		}
		if text.set_line != 0 {
			decision_problem(p, text.set_line, "only an option writes keys, and this is a consideration")
		}
	}
	for f in text.fields {
		own := false
		for k in takes {
			own ||= k == f.key
		}
		if !own {
			other := CONSIDERATION_FIELDS if n.kind == .Option else OPTION_FIELDS
			known := false
			for k in other {
				known ||= k == f.key
			}
			if known {
				decision_problem(p, f.line, "%s %s has no %s", "an" if n.kind == .Option else "a", kind_name, f.key)
			} else {
				decision_problem(p, f.line, "a utility decision's node has no field %s", f.key)
			}
			continue
		}
		if n.kind == .Option {
			read_option_field(p, n, f)
		} else {
			read_consideration_field(p, n, f)
		}
	}
	if n.kind == .Option {
		if !has(text, "action") {
			decision_problem(p, text.line, "an option has an action")
		}
		if n.target_tag_line != 0 && n.option.target == format.DECISION_NONE {
			decision_problem(p, n.target_tag_line, "target_tag is for an option with a target")
		}
		return
	}
	c := &n.consideration
	if !has(text, "input") {
		decision_problem(p, text.line, "a consideration has an input")
	}
	if !has(text, "curve") {
		decision_problem(p, text.line, "a consideration has a curve")
	}
	if n.is_bool && n.range_line != 0 {
		decision_problem(p, n.range_line, "a bool's input is 0 or 1, so it takes no range")
	}
	curve_names := format.UTILITY_CURVE_NAMES
	for f in text.fields {
		switch f.key {
		case "exponent":
			if c.curve == .Linear || c.curve == .Step {
				decision_problem(p, f.line, "a %s curve has no exponent", curve_names[c.curve])
			}
		case "points":
			if c.curve != .Table {
				decision_problem(p, f.line, "points are for a table curve")
			}
		}
	}
	if c.curve == .Table && !has(text, "points") && has(text, "curve") {
		decision_problem(p, text.line, "a table curve has points: `points = [x, y], [x, y], ...`")
	}
}

@(private = "file")
read_option_field :: proc(p: ^Decision_Parser, n: ^Utility_Text_Node, f: Decision_Field) {
	switch f.key {
	case "weight":
		weight, ok := strconv.parse_f32(f.value)
		if !ok || !(weight >= 0) || weight - weight != 0 {
			decision_problem(p, f.line, "weight is a number of 0 or more")
			return
		}
		n.option.weight = weight
	case "considerations":
		n.children_line = f.line
		for part in strings.split(f.value, ",", context.temp_allocator) {
			id, ok := strconv.parse_int(strings.trim_space(part))
			if !ok {
				decision_problem(p, f.line, "considerations are node IDs: `considerations = <id>, <id>, ...`")
				clear(&n.children)
				return
			}
			append(&n.children, id)
		}
	case "target":
		slot, type, found := utility_key(p, f.value)
		switch {
		case !found:
			decision_problem(p, f.line, "the blackboard has no key named %s", f.value)
		case type != .Entity:
			decision_problem(p, f.line, "%s is a %s, and target is an entity key", f.value, type_name(type))
		case:
			n.option.target = u32(slot)
		}
	case "target_tag":
		n.target_tag_line = f.line
		if !is_identifier(f.value) {
			decision_problem(p, f.line, "target_tag is a tag's name, from perception.tags")
			return
		}
		n.option.target_tag = format.animation_graph_hash(f.value)
		n.option.flags += {.Tag}
	case "cooldown":
		n.option.cooldown = tree_time(p, f)
		n.option.flags += {.Cooldown}
	case "action", "when", "position":
	// The shared parts read action and when, and nothing reads position.
	}
}

@(private = "file")
read_consideration_field :: proc(p: ^Decision_Parser, n: ^Utility_Text_Node, f: Decision_Field) {
	c := &n.consideration
	number :: proc(p: ^Decision_Parser, f: Decision_Field) -> f32 {
		value, ok := strconv.parse_f32(f.value)
		if !ok || value - value != 0 {
			decision_problem(p, f.line, "%s is a number", f.key)
			return 0
		}
		return value
	}
	switch f.key {
	case "input":
		read_input(p, n, f)
	case "range":
		n.range_line = f.line
		values, count, ok := parse_numbers(f.value)
		if !ok || count != 2 || !strings.has_prefix(f.value, "[") {
			decision_problem(p, f.line, "range is [min, max]")
			return
		}
		if values[0] == values[1] {
			decision_problem(p, f.line, "a range's min and max differ")
			return
		}
		c.min, c.max = f32(values[0]), f32(values[1])
	case "curve":
		curve, ok := name_of(format.UTILITY_CURVE_NAMES, f.value)
		if !ok {
			decision_problem(p, f.line, "curve is linear, polynomial, logistic, logit, step or table")
		}
		c.curve = curve
	case "slope":
		c.slope = number(p, f)
	case "exponent":
		c.exponent = number(p, f)
		if !(c.exponent > 0) {
			decision_problem(p, f.line, "exponent is above 0")
			c.exponent = 1
		}
	case "x_shift":
		c.x_shift = number(p, f)
	case "y_shift":
		c.y_shift = number(p, f)
	case "points":
		read_points(p, n, f)
	case "position":
	}
}

// read_input reads `<key>`, `distance(<place>, <place>)` or `since(<key>)`.
@(private = "file")
read_input :: proc(p: ^Decision_Parser, n: ^Utility_Text_Node, f: Decision_Field) {
	c := &n.consideration
	value := f.value
	call :: proc(value, name: string) -> (inner: string, ok: bool) {
		rest := strings.trim_left_space(strings.trim_prefix(value, name))
		if !strings.has_prefix(value, name) || !strings.has_prefix(rest, "(") || !strings.has_suffix(rest, ")") {
			return
		}
		return strings.trim_space(rest[1:len(rest) - 1]), true
	}
	if inner, ok := call(value, "distance"); ok {
		c.input = .Distance
		parts := strings.split(inner, ",", context.temp_allocator)
		if len(parts) != 2 {
			decision_problem(p, f.line, "distance takes two places: `distance(<place>, <place>)`")
			return
		}
		places: [2]u32
		for part, i in parts {
			name := strings.trim_space(part)
			if name == "self" {
				places[i] = format.UTILITY_SELF
				continue
			}
			slot, type, found := utility_key(p, name)
			switch {
			case !found:
				decision_problem(p, f.line, "the blackboard has no key named %s", name)
			case type != .Entity && type != .Position:
				decision_problem(p, f.line, "%s is a %s, and a place is self, an entity key or a position key", name, type_name(type))
			case:
				places[i] = u32(slot)
			}
		}
		c.a, c.b = places[0], places[1]
		return
	}
	if inner, ok := call(value, "since"); ok {
		c.input = .Since
		slot, _, found := utility_key(p, inner)
		if !found {
			decision_problem(p, f.line, "the blackboard has no key named %s", inner)
			return
		}
		c.a = u32(slot)
		return
	}
	if !is_identifier(value) {
		decision_problem(p, f.line, "input is a number or bool key, distance(<place>, <place>) or since(<key>)")
		return
	}
	slot, type, found := utility_key(p, value)
	switch {
	case !found:
		decision_problem(p, f.line, "the blackboard has no key named %s", value)
	case type != .Float && type != .Int && type != .Bool:
		decision_problem(p, f.line, "%s is a %s, and an input key is a float, an int or a bool", value, type_name(type))
	case:
		c.input = .Number
		c.a = u32(slot)
		n.is_bool = type == .Bool
	}
}

// read_points reads a table's points: `[x, y], [x, y], ...`, at least 2 and in the order of their x.
@(private = "file")
read_points :: proc(p: ^Decision_Parser, n: ^Utility_Text_Node, f: Decision_Field) {
	rest := strings.trim_space(f.value)
	for rest != "" {
		end := strings.index_byte(rest, ']')
		if !strings.has_prefix(rest, "[") || end < 0 {
			decision_problem(p, f.line, "points are `[x, y], [x, y], ...`")
			clear(&n.points)
			return
		}
		values, count, ok := parse_numbers(rest[:end + 1])
		if !ok || count != 2 {
			decision_problem(p, f.line, "a point is [x, y]")
			clear(&n.points)
			return
		}
		append(&n.points, format.Utility_Point{f32(values[0]), f32(values[1])})
		rest = strings.trim_space(rest[end + 1:])
		if rest != "" {
			if rest[0] != ',' {
				decision_problem(p, f.line, "points are `[x, y], [x, y], ...`")
				clear(&n.points)
				return
			}
			rest = strings.trim_space(rest[1:])
		}
	}
	switch {
	case len(n.points) < 2:
		decision_problem(p, f.line, "a table has at least 2 points")
	case len(n.points) > format.MAX_UTILITY_POINTS:
		decision_problem(p, f.line, "a table has at most %d points", format.MAX_UTILITY_POINTS)
	case:
		for i in 1 ..< len(n.points) {
			if n.points[i].x < n.points[i - 1].x {
				decision_problem(p, f.line, "a table's points are in the order of their x")
				return
			}
		}
	}
}

// utility_key is the slot and type of the blackboard's key of a name.
@(private = "file")
utility_key :: proc(p: ^Decision_Parser, name: string) -> (slot: int, type: format.Blackboard_Type, found: bool) {
	for k, i in p.keys {
		if k.name == name {
			return i, k.type, true
		}
	}
	return -1, {}, false
}
