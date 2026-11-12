package cook

import "core:fmt"
import "core:hash"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Blackboards are .blackboard text files: the typed keys that an agent's decision reads and its actions and scripts
// write (see docs/content/kinds/blackboards.md). The cooker gives each key a slot, its line's order, and an offset in
// the agent's values, and writes a Blackboard blob. A decision reads its blackboard's source with blackboard_parse, so
// its slots are the blob's.
BLACKBOARD_COOK_VERSION :: "blackboards 1"

// Blackboard_Problem is an error in a blackboard's or a decision's text, at a line from 1.
Blackboard_Problem :: struct {
	line:    int,
	message: string,
}

// BLACKBOARD_TYPE_NAMES are the types as a blackboard's text names them. String is only an action's argument.
BLACKBOARD_TYPE_NAMES :: [format.Blackboard_Type]string {
	.Float    = "float",
	.Int      = "int",
	.Bool     = "bool",
	.Enum     = "enum",
	.Entity   = "entity",
	.Position = "position",
	.Vector   = "vector",
	.String   = "string",
}

// type_name is a type's name in the text.
type_name :: proc(t: format.Blackboard_Type) -> string {
	names := BLACKBOARD_TYPE_NAMES
	return names[t]
}

cook_blackboards :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	out_dir := config_dir(options)
	boards := carry_kind(pass, {.Blackboard})
	if len(boards) > 0 && !make_output_dir(pass, out_dir, {.Blackboard}) {
		return false
	}
	ok := true
	step_begin(pass, .Blackboard, "", len(boards))
	for i in boards {
		defer step_advance(pass)
		asset_source(pass, i)
		result := cook_blackboard(&assets[i], out_dir, pass)
		settle(pass, i, result)
		ok &&= !asset_failed(result)
	}
	return ok
}

// blackboard_key is a blackboard's cache key, which its blob's header holds. A decision computes it from the
// blackboard's source too, and keeps it, so the runtime uses a decision only with the blackboard it was cooked
// against.
blackboard_key :: proc(a: Asset_Source) -> u64 {
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%x\x00", BLACKBOARD_COOK_VERSION, a.name, format.blackboard_layout()))
	key = hash.fnv64a(source_of(a), key)
	guid := a.meta.guid
	return hash.fnv64a(guid[:], key)
}

@(private = "file")
cook_blackboard :: proc(a: ^Asset_Source, out_dir: string, pass: ^Pass) -> Asset_Result {
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	contents, parse_problems := blackboard_parse(string(source_of(a^)), context.temp_allocator)
	for p in parse_problems {
		report_error(problems, a.path, p.line, 0, "%s", p.message)
	}
	// A blackboard with errors keeps its old blob, so the running game keeps the last good version.
	if len(parse_problems) > 0 || !settings_ok {
		return .Failed
	}
	key := blackboard_key(a^)
	guid := a.meta.guid
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid))
	if cooked_key(output, .Blackboard, format.blackboard_layout()) == key && !pass.force[guid] {
		return .Current
	}
	contents.guid, contents.key, contents.source_path = guid, key, a.name
	if !write_blob(output, format.blackboard_write(contents, context.temp_allocator)) {
		return .Failed
	}
	return .Cooked
}

// strip_line_comment is a line without a # and what follows it, outside of quotes.
strip_line_comment :: proc(line: string) -> string {
	quoted := false
	for i := 0; i < len(line); i += 1 {
		switch {
		case quoted && line[i] == '\\':
			i += 1
		case line[i] == '"':
			quoted = !quoted
		case line[i] == '#' && !quoted:
			return line[:i]
		}
	}
	return line
}

// blackboard_parse parses a blackboard's text into the contents of its blob, without its GUID, key or path. It gives
// every problem that it finds, and the blackboard is good only without any.
blackboard_parse :: proc(text: string, allocator := context.allocator) -> (contents: format.Blackboard_Contents, problems: []Blackboard_Problem) {
	context.allocator = allocator
	found := make([dynamic]Blackboard_Problem)
	problem :: proc(found: ^[dynamic]Blackboard_Problem, line: int, f: string, args: ..any) {
		append(found, Blackboard_Problem{line, fmt.aprintf(f, ..args)})
	}
	keys := make([dynamic]format.Blackboard_Key_Contents)
	header := false
	for raw, index in strings.split_lines(text) {
		line := index + 1
		trimmed := strings.trim_space(strip_line_comment(raw))
		if trimmed == "" {
			continue
		}
		if !header {
			if fields := strings.fields(trimmed); len(fields) == 2 && fields[0] == "blackboard" && fields[1] == "1" {
				header = true
				continue
			}
			problem(&found, line, "a blackboard starts with `blackboard 1`")
			return {}, found[:]
		}
		declaration, has_default, default := strings.partition(trimmed, "=")
		declaration, default = strings.trim_space(declaration), strings.trim_space(default)
		type_name, _, rest := strings.partition(declaration, " ")
		rest = strings.trim_space(rest)
		type: format.Blackboard_Type
		known := false
		for name, t in BLACKBOARD_TYPE_NAMES {
			if name == type_name && t != .String {
				type, known = t, true
			}
		}
		if !known {
			problem(&found, line, "a key is `<type> <name> [= <default>]`, of the types float, int, bool, enum, entity, position and vector")
			continue
		}
		key := format.Blackboard_Key_Contents {
			type = type,
		}
		name := rest
		if type == .Enum {
			open := strings.index_byte(rest, '(')
			if open < 0 || !strings.has_suffix(rest, ")") {
				problem(&found, line, "an enum is `enum <name> (<value>, <value>...) [= <default>]`")
				continue
			}
			name = strings.trim_space(rest[:open])
			names := make([dynamic]string)
			bad := false
			for part in strings.split(rest[open + 1:len(rest) - 1], ",") {
				value := strings.trim_space(part)
				if !is_identifier(value) {
					problem(&found, line, "an enum's values are names, such as calm")
					bad = true
					break
				}
				if slice.contains(names[:], value) {
					problem(&found, line, "the enum %s has the value %s twice", name, value)
					bad = true
					break
				}
				append(&names, value)
			}
			if bad {
				continue
			}
			key.enum_names = names[:]
		}
		if !is_identifier(name) {
			problem(&found, line, "a key's name is a word, such as health")
			continue
		}
		key.name = name
		if has_default != "" {
			value, message := parse_board_value(type, default, key.enum_names)
			if message != "" {
				problem(&found, line, "%s", message)
				continue
			}
			key.default = value
		}
		clash := false
		for other in keys {
			if other.name == name {
				problem(&found, line, "another key is named %s", name)
				clash = true
			} else if format.animation_graph_hash(other.name) == format.animation_graph_hash(name) {
				problem(&found, line, "the keys %s and %s have the same hash: rename one", other.name, name)
				clash = true
			}
		}
		if clash {
			continue
		}
		if len(keys) == format.MAX_BLACKBOARD_KEYS {
			problem(&found, line, "a blackboard has at most %d keys", format.MAX_BLACKBOARD_KEYS)
			continue
		}
		append(&keys, key)
		if _, size := format.blackboard_offsets(keys[:], context.temp_allocator); size > format.MAX_BLACKBOARD_SIZE {
			problem(&found, line, "a blackboard's values are at most %d bytes", format.MAX_BLACKBOARD_SIZE)
			pop(&keys)
		}
	}
	if !header {
		problem(&found, 1, "a blackboard starts with `blackboard 1`")
	}
	slice.stable_sort_by(found[:], proc(a, b: Blackboard_Problem) -> bool {return a.line < b.line})
	return {keys = keys[:]}, found[:]
}

// parse_board_value reads a value of a type, as a key's default or a decision's constant holds it, into the bytes that
// an agent's values hold: a number for a float or an int, true or false, one of an enum's names, none for an entity,
// [x, y, z] in meters for a position, [x, y, z] for a vector, or a quoted string. It gives a message if it is not one.
parse_board_value :: proc(type: format.Blackboard_Type, text: string, enum_names: []string) -> (bytes: [format.BLACKBOARD_VALUE_SIZE]byte, message: string) {
	put :: proc(bytes: ^[format.BLACKBOARD_VALUE_SIZE]byte, v: $T) {
		(^T)(bytes)^ = v
	}
	switch type {
	case .Float:
		v, ok := strconv.parse_f32(text)
		if !ok || math.is_nan(v) || math.is_inf(v) {
			return {}, fmt.tprintf("%q is not a number", text)
		}
		put(&bytes, v)
	case .Int:
		v, ok := strconv.parse_i64(text)
		if !ok || v < i64(min(i32)) || v > i64(max(i32)) {
			return {}, fmt.tprintf("%q is not a whole number of 32 bits", text)
		}
		put(&bytes, i32(v))
	case .Bool:
		switch text {
		case "true":
			put(&bytes, u8(1))
		case "false":
		case:
			return {}, fmt.tprintf("%q is not true or false", text)
		}
	case .Enum:
		index, found := slice.linear_search(enum_names, text)
		if !found {
			return {}, fmt.tprintf("%q is not one of %s", text, strings.join(enum_names, ", ", context.temp_allocator))
		}
		put(&bytes, u32(index))
	case .Entity:
		if text != "none" {
			return {}, "an entity's value is none: a script or an action sets it"
		}
	case .Position, .Vector:
		numbers, count, ok := parse_numbers(text)
		if !ok || count != 3 || !strings.has_prefix(text, "[") {
			return {}, fmt.tprintf("%q is not [x, y, z]", text)
		}
		if type == .Vector {
			put(&bytes, [3]f32{f32(numbers[0]), f32(numbers[1]), f32(numbers[2])})
		} else {
			raw: [3]i64
			for i in 0 ..< 3 {
				step := math.round(numbers[i] * (1 << 24))
				if !(abs(step) < 1 << 62) {
					return {}, fmt.tprintf("%q is out of the world", text)
				}
				raw[i] = i64(step)
			}
			put(&bytes, raw)
		}
	case .String:
		v, problem := parse_graph_value(text)
		if problem != "" || v.kind != .Text {
			return {}, fmt.tprintf("%s is not a quoted string", text)
		}
	}
	return bytes, ""
}
