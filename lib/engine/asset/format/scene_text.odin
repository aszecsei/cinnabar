package asset_format

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"

// The version on a scene file's first line, `scene 1`. A change that old loaders cannot read changes it.
SCENE_TEXT_VERSION :: 1

// Scene_Problem is an error or a warning in a scene file, at a line from 1.
Scene_Problem :: struct {
	line:    int,
	message: string,
	error:   bool,
}

// scene_parse reads a scene file (see docs/editor/document-and-scenes.md#scenes). The scene and the messages are in allocator, and the
// strings without escapes point into text. ok is false when any problem is an error. An entity key that the parser
// does not know is a warning, so a file from a newer editor still cooks.
scene_parse :: proc(text: string, allocator := context.allocator) -> (scene: Scene, problems: []Scene_Problem, ok: bool) {
	p := Parser {
		allocator = allocator,
		problems  = make([dynamic]Scene_Problem, allocator),
		entities  = make([dynamic]Scene_Entity, allocator),
	}
	rest := text
	header := false
	for raw in strings.split_lines_iterator(&rest) {
		p.line += 1
		line := strings.trim_right_space(raw)
		trimmed := strings.trim_left_space(line)
		if trimmed == "" || trimmed[0] == '#' {
			continue
		}
		if !header {
			header = true
			if trimmed != fmt.tprintf("scene %d", SCENE_TEXT_VERSION) {
				problem(&p, true, "a scene file starts with `scene %d`", SCENE_TEXT_VERSION)
				break
			}
			continue
		}
		indented := len(trimmed) < len(line)
		word, _, argument := strings.partition(trimmed, " ")
		switch {
		case !indented && word == "entity":
			parse_entity(&p, strings.trim_space(argument))
		case !indented && word == "component":
			parse_component(&p, strings.trim_space(argument))
		case !indented && word == "behaviour":
			parse_behaviour(&p, strings.trim_space(argument))
		case:
			parse_line(&p, trimmed, indented)
		}
	}
	if !header {
		problem(&p, true, "a scene file starts with `scene %d`", SCENE_TEXT_VERSION)
	}
	finish_entity(&p)
	for e, i in p.entities {
		for other in p.entities[:i] {
			if other.id == e.id {
				p.line = 0
				problem(&p, true, "two entities have the scene ID %016x", e.id)
			}
		}
	}
	ok = true
	for problem in p.problems {
		ok &&= !problem.error
	}
	return {entities = p.entities[:]}, p.problems[:], ok
}

@(private = "file")
Parser :: struct {
	allocator:  mem.Allocator,
	line:       int,
	problems:   [dynamic]Scene_Problem,
	entities:   [dynamic]Scene_Entity,
	// The entity that is open, and its blocks.
	open:       bool,
	entity:     Scene_Entity,
	components: [dynamic]Scene_Component,
	behaviours: [dynamic]Scene_Behaviour,
	// The fields of the block that indented lines belong to, while in_block.
	block:      [dynamic]Scene_Field,
	in_block:   bool,
	// Where the open block goes when it ends.
	block_kind: enum {
		Component,
		Behaviour,
	},
}

@(private = "file")
problem :: proc(p: ^Parser, error: bool, format: string, args: ..any) {
	append(&p.problems, Scene_Problem{line = p.line, message = fmt.aprintf(format, ..args, allocator = p.allocator), error = error})
}

@(private = "file")
parse_entity :: proc(p: ^Parser, argument: string) {
	finish_entity(p)
	id, ok := parse_hex(argument)
	if !ok || len(argument) != 16 || id == 0 {
		problem(p, true, "an entity needs a nonzero scene ID of 16 hex digits, not %q", argument)
	}
	p.open = true
	p.entity = {
		id     = id,
		active = true,
	}
	p.components = make([dynamic]Scene_Component, p.allocator)
	p.behaviours = make([dynamic]Scene_Behaviour, p.allocator)
}

@(private = "file")
parse_component :: proc(p: ^Parser, argument: string) {
	if !begin_block(p, "component") {
		return
	}
	id_text, _, name := strings.partition(argument, " ")
	id, ok := strconv.parse_u64_of_base(id_text, 10)
	if !ok || id == 0 {
		problem(p, true, "a component needs its stable ID in decimal and its name, not %q", argument)
	}
	for c in p.components {
		if c.id == id {
			problem(p, true, "the entity has component %d twice", id)
		}
	}
	append(&p.components, Scene_Component{id = id, name = strings.trim_space(name)})
	p.block_kind = .Component
}

@(private = "file")
parse_behaviour :: proc(p: ^Parser, argument: string) {
	if !begin_block(p, "behaviour") {
		return
	}
	script, ok := guid_parse(argument)
	if !ok {
		problem(p, true, "a behaviour needs its script's GUID of 32 hex digits, not %q", argument)
	}
	for b in p.behaviours {
		if b.script == script {
			problem(p, true, "the entity has the behaviour %s twice", argument)
		}
	}
	append(&p.behaviours, Scene_Behaviour{script = script})
	p.block_kind = .Behaviour
}

// begin_block ends the open block and starts the fields of a new one.
@(private = "file")
begin_block :: proc(p: ^Parser, what: string) -> bool {
	if !p.open {
		problem(p, true, "a %s needs an entity line before it", what)
		return false
	}
	finish_block(p)
	p.block = make([dynamic]Scene_Field, p.allocator)
	p.in_block = true
	return true
}

@(private = "file")
finish_block :: proc(p: ^Parser) {
	if !p.in_block {
		return
	}
	p.in_block = false
	switch p.block_kind {
	case .Component:
		p.components[len(p.components) - 1].fields = p.block[:]
	case .Behaviour:
		p.behaviours[len(p.behaviours) - 1].fields = p.block[:]
	}
}

@(private = "file")
finish_entity :: proc(p: ^Parser) {
	if !p.open {
		return
	}
	finish_block(p)
	slice.sort_by(p.components[:], proc(a, b: Scene_Component) -> bool {return a.id < b.id})
	p.entity.components = p.components[:]
	p.entity.behaviours = p.behaviours[:]
	append(&p.entities, p.entity)
	p.open = false
}

// parse_line reads `key = value`: a field of the open block when it is indented, and otherwise a key of the entity.
@(private = "file")
parse_line :: proc(p: ^Parser, line: string, indented: bool) {
	key, equals, value_text := strings.partition(line, "=")
	key = strings.trim_space(key)
	value_text = strings.trim_space(value_text)
	if equals == "" || !is_key(key) {
		problem(p, true, "expected `name = value`, not %q", line)
		return
	}
	if !p.open {
		problem(p, true, "%s needs an entity line before it", key)
		return
	}
	value, ok := parse_value(p, value_text)
	if !ok {
		return
	}
	if indented {
		if !p.in_block {
			problem(p, true, "the field %s is indented, but no component or behaviour is open", key)
			return
		}
		for f in p.block {
			if f.name == key {
				problem(p, true, "the field %s is set twice", key)
			}
		}
		append(&p.block, Scene_Field{name = key, hash = scene_field_hash(key), value = value})
		return
	}
	switch key {
	case "name":
		if value.kind != .String {
			problem(p, true, "name takes a quoted string")
		}
		p.entity.name = value.text
	case "parent":
		if value.kind != .Entity {
			problem(p, true, "parent takes a scene ID, such as @1b04c7e95a2f3d88")
		}
		p.entity.parent = value.entity
	case "active":
		if value.kind != .Bool {
			problem(p, true, "active takes true or false")
		}
		p.entity.active = value.ints[0] != 0
	case:
		problem(p, false, "the entity key %s is unknown, so it is ignored", key)
	}
}

@(private = "file")
is_key :: proc(key: string) -> bool {
	if key == "" {
		return false
	}
	for c in transmute([]byte)key {
		if !is_word_char(c) && c != '.' {
			return false
		}
	}
	return true
}

@(private = "file")
is_word_char :: proc(c: byte) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// parse_value reads a value: true or false, a number, an array of up to four numbers, a quoted string, a scene ID
// such as @1b04c7e95a2f3d88 (@0 for none), an asset's GUID such as $9db8150cc7215ffc2708d20d77cf60bf ($0 for none),
// or a bare word.
@(private = "file")
parse_value :: proc(p: ^Parser, text: string) -> (value: Scene_Value, ok: bool) {
	switch {
	case text == "":
		problem(p, true, "a value is missing")
		return
	case text == "true" || text == "false":
		return {kind = .Bool, ints = {0 = text == "true" ? 1 : 0}}, true
	case text[0] == '"':
		return parse_string(p, text)
	case text[0] == '@':
		id, id_ok := parse_hex(text[1:])
		if !id_ok {
			problem(p, true, "a scene ID is up to 16 hex digits after @, not %q", text)
			return
		}
		return {kind = .Entity, entity = id}, true
	case text[0] == '$':
		if text == "$0" {
			return {kind = .Asset}, true
		}
		guid, guid_ok := guid_parse(text[1:])
		if !guid_ok {
			problem(p, true, "an asset is 32 hex digits after $, or $0 for none, not %q", text)
			return
		}
		return {kind = .Asset, asset = guid}, true
	case text[0] == '[':
		if text[len(text) - 1] != ']' {
			problem(p, true, "an array ends with ], not %q", text)
			return
		}
		value.kind = .Number
		elements := strings.split(text[1:len(text) - 1], ",", context.temp_allocator)
		if len(elements) > 4 {
			problem(p, true, "an array has at most 4 numbers, not %d", len(elements))
			return
		}
		for element, i in elements {
			parse_number(p, &value, i, strings.trim_space(element)) or_return
		}
		value.count = u8(len(elements))
		return value, true
	case text[0] == '-' || text[0] == '+' || text[0] == '.' || (text[0] >= '0' && text[0] <= '9'):
		value.kind = .Number
		value.count = 1
		parse_number(p, &value, 0, text) or_return
		return value, true
	}
	for c in transmute([]byte)text {
		if !is_word_char(c) {
			problem(p, true, "a value is a number, an array, a quoted string, a scene ID, an asset or a word, not %q", text)
			return
		}
	}
	return {kind = .Name, text = text}, true
}

@(private = "file")
parse_number :: proc(p: ^Parser, value: ^Scene_Value, i: int, text: string) -> bool {
	digits := strings.trim_prefix(strings.trim_prefix(text, "-"), "+")
	integer := digits != ""
	for c in transmute([]byte)digits {
		integer &&= c >= '0' && c <= '9'
	}
	if integer {
		if n, signed_ok := strconv.parse_i64_of_base(text, 10); signed_ok {
			value.ints[i] = n
		} else if u, unsigned_ok := strconv.parse_u64_of_base(strings.trim_prefix(text, "+"), 10); unsigned_ok {
			// A u64 beyond i64's range keeps its bits.
			value.ints[i] = i64(u)
		} else {
			problem(p, true, "%s does not fit in 64 bits", text)
			return false
		}
		value.integer |= 1 << u8(i)
	}
	f, f_ok := strconv.parse_f64(text)
	if !f_ok {
		problem(p, true, "%q is not a number", text)
		return false
	}
	value.floats[i] = f
	return true
}

@(private = "file")
parse_string :: proc(p: ^Parser, text: string) -> (value: Scene_Value, ok: bool) {
	value.kind = .String
	if len(text) < 2 || text[len(text) - 1] != '"' {
		problem(p, true, "a string ends with a quote: %s", text)
		return
	}
	inner := text[1:len(text) - 1]
	if strings.index_byte(inner, '\\') < 0 {
		if strings.index_byte(inner, '"') >= 0 {
			problem(p, true, "a quote in a string needs a backslash before it: %s", text)
			return
		}
		value.text = inner
		return value, true
	}
	b := strings.builder_make(p.allocator)
	for i := 0; i < len(inner); i += 1 {
		c := inner[i]
		if c == '"' {
			problem(p, true, "a quote in a string needs a backslash before it: %s", text)
			return
		}
		if c != '\\' {
			strings.write_byte(&b, c)
			continue
		}
		i += 1
		if i == len(inner) {
			problem(p, true, "a string ends with a backslash: %s", text)
			return
		}
		switch inner[i] {
		case '"', '\\':
			strings.write_byte(&b, inner[i])
		case 'n':
			strings.write_byte(&b, '\n')
		case 't':
			strings.write_byte(&b, '\t')
		case:
			problem(p, true, "\\%c is not an escape. A string has \\\", \\\\, \\n and \\t.", inner[i])
			return
		}
	}
	value.text = strings.to_string(b)
	return value, true
}

// parse_hex reads 1 to 16 hex digits.
@(private = "file")
parse_hex :: proc(text: string) -> (value: u64, ok: bool) {
	if len(text) == 0 || len(text) > 16 {
		return
	}
	for c in transmute([]byte)text {
		digit := hex_digit(c) or_return
		value = value << 4 | u64(digit)
	}
	return value, true
}
