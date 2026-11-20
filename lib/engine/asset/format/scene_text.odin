package asset_format

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"

// The version on a scene file's first line, `scene 4`. A change that old loaders cannot read changes it. Version 2
// adds prefab instances and their overrides. Version 3 adds references to entities of other scenes, `@<guid>/<id>`.
// Version 4 adds the sublevel key. A reader takes versions 1 to 3 too.
SCENE_TEXT_VERSION :: 4

// The most IDs in a path: an instance at each of SCENE_EXPAND_DEPTH levels, and the entity.
SCENE_PATH_MAX :: SCENE_EXPAND_DEPTH + 1

// Scene_Parse_Options say what a scene file is for, which the text alone does not.
Scene_Parse_Options :: struct {
	// The file is a prefab's: a sublevel key is a warning and is ignored, because an instance can be in any sublevel.
	prefab:    bool,
	// The sublevels that the project declares, so a name that is not among them is a warning; nil checks no names.
	sublevels: Maybe([]Sublevel),
}

// Scene_Problem is an error or a warning in a scene file, at a line from 1.
Scene_Problem :: struct {
	line:    int,
	message: string,
	error:   bool,
}

// scene_parse reads a scene file (see docs/editor/document-and-scenes.md#scenes). The scene and the messages are in allocator, and the
// strings without escapes point into text. ok is false when any problem is an error. An entity key that the parser
// does not know is a warning, so a file from a newer editor still cooks. A path, in an entity line or an @ reference,
// reads as its scene ID, scene_path_id_of the path (see docs/editor/prefabs.md#instances-in-a-scene). Each entity's
// sublevel is its own key's, or else its parent's or its instance's (see docs/editor/document-and-scenes.md#sublevels).
scene_parse :: proc(
	text: string,
	allocator := context.allocator,
	options := Scene_Parse_Options{},
) -> (
	scene: Scene,
	problems: []Scene_Problem,
	ok: bool,
) {
	p := Parser {
		allocator = allocator,
		options   = options,
		problems  = make([dynamic]Scene_Problem, allocator),
		entities  = make([dynamic]Scene_Entity, allocator),
		sublevels = make([dynamic]Block_Sublevel, context.temp_allocator),
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
			if trimmed != "scene 1" &&
			   trimmed != "scene 2" &&
			   trimmed != "scene 3" &&
			   trimmed != fmt.tprintf("scene %d", SCENE_TEXT_VERSION) {
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
		case !indented && word == "remove":
			parse_remove(&p, strings.trim_space(argument))
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
	resolve_sublevels(&p)
	ok = true
	for problem in p.problems {
		ok &&= !problem.error
	}
	return {entities = p.entities[:]}, p.problems[:], ok
}

@(private = "file")
Parser :: struct {
	allocator:          mem.Allocator,
	options:            Scene_Parse_Options,
	line:               int,
	problems:           [dynamic]Scene_Problem,
	entities:           [dynamic]Scene_Entity,
	// What each entity's sublevel comes from, by its index in entities.
	sublevels:          [dynamic]Block_Sublevel,
	// The entity that is open, and its blocks.
	open:               bool,
	entity:             Scene_Entity,
	entity_sublevel:    Block_Sublevel,
	components:         [dynamic]Scene_Component,
	behaviours:         [dynamic]Scene_Behaviour,
	removed_components: [dynamic]u64,
	removed_behaviours: [dynamic]Guid,
	// The fields of the block that indented lines belong to, while in_block.
	block:              [dynamic]Scene_Field,
	in_block:           bool,
	// Where the open block goes when it ends.
	block_kind:         enum {
		Component,
		Behaviour,
	},
}

// Block_Sublevel is what an entity's sublevel comes from: its own key, at a line, and the instance of a parent that
// is a path, since its ID alone does not name it.
@(private = "file")
Block_Sublevel :: struct {
	explicit:        bool,
	line:            int,
	parent_instance: u64,
}

@(private = "file")
problem :: proc(p: ^Parser, error: bool, format: string, args: ..any) {
	append(
		&p.problems,
		Scene_Problem {
			line = p.line,
			message = fmt.aprintf(format, ..args, allocator = p.allocator),
			error = error,
		},
	)
}

@(private = "file")
parse_entity :: proc(p: ^Parser, argument: string) {
	finish_entity(p)
	path, ok := parse_path(argument, p.allocator)
	if !ok {
		problem(
			p,
			true,
			"an entity needs a nonzero scene ID of 16 hex digits, or a path of them joined by #, not %q",
			argument,
		)
	}
	p.open = true
	p.entity_sublevel = {}
	p.entity = {
		id     = scene_path_id_of(path),
		active = true,
		path   = len(path) > 1 ? path : nil,
	}
	p.components = make([dynamic]Scene_Component, p.allocator)
	p.behaviours = make([dynamic]Scene_Behaviour, p.allocator)
	p.removed_components = make([dynamic]u64, p.allocator)
	p.removed_behaviours = make([dynamic]Guid, p.allocator)
}

// parse_path reads a scene ID, or a path of up to SCENE_PATH_MAX of them joined by #, each 16 hex digits and nonzero.
@(private = "file")
parse_path :: proc(text: string, allocator: mem.Allocator) -> (path: []u64, ok: bool) {
	parts := strings.split(text, "#", context.temp_allocator)
	if len(parts) > SCENE_PATH_MAX {
		return
	}
	path = make([]u64, len(parts), allocator)
	for part, i in parts {
		id := parse_hex(part) or_return
		if len(part) != 16 || id == 0 {
			return
		}
		path[i] = id
	}
	return path, true
}

// parse_remove reads `remove component <id>` and `remove behaviour $<guid>`, which take away what the prefab's
// entity has.
@(private = "file")
parse_remove :: proc(p: ^Parser, argument: string) {
	if !p.open {
		problem(p, true, "a remove needs an entity line before it")
		return
	}
	finish_block(p)
	what, _, target := strings.partition(argument, " ")
	target = strings.trim_space(target)
	switch what {
	case "component":
		id, ok := strconv.parse_u64_of_base(target, 10)
		if !ok || id == 0 {
			problem(
				p,
				true,
				"remove component takes the component's stable ID in decimal, not %q",
				target,
			)
			return
		}
		append(&p.removed_components, id)
	case "behaviour":
		script, ok := guid_parse(strings.trim_prefix(target, "$"))
		if !ok || !strings.has_prefix(target, "$") {
			problem(
				p,
				true,
				"remove behaviour takes the script's GUID, such as $9d2e41c0b7a35f6e81c4d2a90b3e7f15, not %q",
				target,
			)
			return
		}
		append(&p.removed_behaviours, script)
	case:
		problem(p, true, "remove takes component <id> or behaviour $<guid>, not %q", argument)
	}
}

@(private = "file")
parse_component :: proc(p: ^Parser, argument: string) {
	if !begin_block(p, "component") {
		return
	}
	id_text, _, name := strings.partition(argument, " ")
	id, ok := strconv.parse_u64_of_base(id_text, 10)
	if !ok || id == 0 {
		problem(
			p,
			true,
			"a component needs its stable ID in decimal and its name, not %q",
			argument,
		)
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
	p.entity.removed_components = p.removed_components[:]
	p.entity.removed_behaviours = p.removed_behaviours[:]
	// Only the block of a prefab's entity can take away what the prefab gives it.
	plain := p.entity.prefab == {} && p.entity.path == nil
	if plain && (len(p.entity.removed_components) > 0 || len(p.entity.removed_behaviours) > 0) {
		problem(
			p,
			true,
			"entity %016x: only an instance or an override block removes a component or a behaviour",
			p.entity.id,
		)
	}
	if p.entity.node != 0 && (p.entity.prefab == {} || p.entity.path != nil) {
		problem(p, true, "entity %016x: only an instance block takes node", p.entity.id)
	}
	append(&p.entities, p.entity)
	append(&p.sublevels, p.entity_sublevel)
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
			problem(
				p,
				true,
				"the field %s is indented, but no component or behaviour is open",
				key,
			)
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
		p.entity.keys += {.Name}
	case "parent":
		if value.kind != .Entity {
			problem(p, true, "parent takes a scene ID, such as @1b04c7e95a2f3d88")
		} else if value.scene != {} {
			problem(p, true, "an entity cannot be a child of another scene's entity")
		}
		p.entity.parent = value.entity
		p.entity.keys += {.Parent}
		p.entity_sublevel.parent_instance = 0
		if hash := strings.index_byte(value_text, '#'); hash > 1 {
			p.entity_sublevel.parent_instance, _ = parse_hex(value_text[1:hash])
		}
	case "active":
		if value.kind != .Bool {
			problem(p, true, "active takes true or false")
		}
		p.entity.active = value.ints[0] != 0
		p.entity.keys += {.Active}
	case "prefab":
		if value.kind != .Asset || value.asset == {} {
			problem(
				p,
				true,
				"prefab takes the prefab's GUID, such as $9db8150cc7215ffc2708d20d77cf60bf",
			)
		} else if p.entity.path != nil {
			problem(p, true, "an override block cannot change which prefab an entity instantiates")
		}
		p.entity.prefab = value.asset
	case "node":
		if value.kind != .Entity || value.entity == 0 {
			problem(p, true, "node takes an entity of the prefab, such as @2000000000000002")
		} else if value.scene != {} {
			problem(p, true, "node takes an entity of the prefab, not of another scene")
		}
		p.entity.node = value.entity
	case "sublevel":
		switch {
		case value.kind != .String || !sublevel_name_valid(value.text):
			problem(
				p,
				true,
				"sublevel takes a quoted name of letters, digits and _ of at most %d characters, such as \"night\"",
				SUBLEVEL_MAX_NAME,
			)
		case p.options.prefab:
			problem(
				p,
				false,
				"an instance of a prefab is in the sublevel of its root, so the prefab's sublevel is ignored",
			)
		case:
			p.entity.sublevel = value.text
			p.entity_sublevel.explicit = true
			p.entity_sublevel.line = p.line
			if declared, checked := p.options.sublevels.?;
			   checked && !sublevel_known(declared, value.text) {
				problem(
					p,
					false,
					"the project does not declare the sublevel %s, so nothing activates it",
					value.text,
				)
			}
		}
	case "removed":
		if value.kind != .Bool {
			problem(p, true, "removed takes true or false")
		} else if p.entity.path == nil {
			problem(p, true, "only an override block, whose ID is a path, takes removed")
		}
		p.entity.removed = value.ints[0] != 0
	case:
		problem(p, false, "the entity key %s is unknown, so it is ignored", key)
	}
}

// resolve_sublevels gives every entity without its own sublevel key the sublevel of its owner, the instance of an
// override block or of a parent on a path, or else its parent. A key that differs from the owner's is an error, so a
// parent and its children always load together. An owner that the file does not have is not checked.
@(private = "file")
resolve_sublevels :: proc(p: ^Parser) {
	index := make(map[u64]int, len(p.entities), context.temp_allocator)
	for e, i in p.entities {
		index[e.id] = i
	}
	// 0 for not yet, 1 while its owners resolve, so a cycle of parents ends, and 2 for done.
	state := make([]u8, len(p.entities), context.temp_allocator)
	resolve :: proc(p: ^Parser, index: map[u64]int, state: []u8, i: int) -> string {
		e := &p.entities[i]
		if state[i] != 0 {
			return e.sublevel
		}
		state[i] = 1
		info := p.sublevels[i]
		owner := e.parent
		if e.path != nil {
			owner = e.path[0]
		} else if info.parent_instance != 0 {
			owner = info.parent_instance
		}
		if j, found := index[owner]; found && owner != 0 && j != i {
			inherited := resolve(p, index, state, j)
			if !info.explicit {
				e.sublevel = inherited
			} else if e.sublevel != inherited {
				p.line = info.line
				problem(p, true, "an entity cannot be in a sublevel other than its parent's")
			}
		}
		state[i] = 2
		return e.sublevel
	}
	for i in 0 ..< len(p.entities) {
		resolve(p, index, state, i)
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
// such as @1b04c7e95a2f3d88 (@0 for none) or a path such as @5f3a9c01e2b47d10#a90b3e7f15c4d2e8, either one after a
// scene's GUID and a slash for an entity of another scene, an asset's GUID such as $9db8150cc7215ffc2708d20d77cf60bf
// ($0 for none), or a bare word.
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
		return parse_reference(p, text)
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
			problem(
				p,
				true,
				"a value is a number, an array, a quoted string, a scene ID, an asset or a word, not %q",
				text,
			)
			return
		}
	}
	return {kind = .Name, text = text}, true
}

// parse_reference reads an entity reference: @<id>, @<path>, or either one after <guid>/ for an entity of another
// scene. The ID in another scene is nonzero.
@(private = "file")
parse_reference :: proc(p: ^Parser, text: string) -> (value: Scene_Value, ok: bool) {
	scene, entity, message := entity_reference_parse(text)
	if message != "" {
		problem(p, true, "%s", message)
		return {}, false
	}
	return {kind = .Entity, scene = scene, entity = entity}, true
}

// entity_reference_parse reads an entity reference as a scene file writes it: @<id>, @<path>, or either one after
// <guid>/ for an entity of another scene, whose ID is nonzero. A path reads as scene_path_id_of the path. scene is zero
// for a reference in the same scene. message, in the temporary allocator, is "" for a good reference.
entity_reference_parse :: proc(text: string) -> (scene: Guid, entity: u64, message: string) {
	if !strings.has_prefix(text, "@") {
		return {}, 0, fmt.tprintf("an entity reference starts with @, not %q", text)
	}
	rest := text[1:]
	if slash := strings.index_byte(rest, '/'); slash >= 0 {
		parsed, scene_ok := guid_parse(rest[:slash])
		if !scene_ok || parsed == {} {
			return {}, 0, fmt.tprintf("a reference to another scene starts with its nonzero GUID of 32 hex digits and a slash after @, not %q", text)
		}
		scene = parsed
		rest = rest[slash + 1:]
	}
	if strings.index_byte(rest, '#') >= 0 {
		path, path_ok := parse_path(rest, context.temp_allocator)
		if !path_ok {
			return {}, 0, fmt.tprintf("a path is scene IDs of 16 hex digits joined by # after @, not %q", text)
		}
		return scene, scene_path_id_of(path), ""
	}
	id, id_ok := parse_hex(rest)
	if !id_ok {
		return {}, 0, fmt.tprintf("a scene ID is up to 16 hex digits after @, not %q", text)
	}
	if scene != {} && id == 0 {
		return {}, 0, fmt.tprintf("a reference to another scene names an entity with a nonzero scene ID, not %q", text)
	}
	return scene, id, ""
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
		} else if u, unsigned_ok := strconv.parse_u64_of_base(strings.trim_prefix(text, "+"), 10);
		   unsigned_ok {
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
			problem(
				p,
				true,
				"\\%c is not an escape. A string has \\\", \\\\, \\n and \\t.",
				inner[i],
			)
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
