package cook

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Perceptions are .perception text files: the tags that an agent's Perceiver notices, and the rows that fill its
// blackboard's keys from what it perceives (see docs/content/kinds/perceptions.md). The tags are names, which the
// runtime finds in the project's perception.tags, and the keys are names, which it finds in the agent's blackboard, so
// the cook reads neither.
PERCEPTION_COOK_VERSION :: "perceptions 1"

// Perception_Problem is an error in a perception's text, at a line from 1.
Perception_Problem :: struct {
	line:    int,
	message: string,
}

cook_perceptions :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	out_dir := config_dir(options)
	perceptions := carry_kind(pass, {.Perception})
	if len(perceptions) > 0 && !make_output_dir(pass, out_dir, {.Perception}) {
		return false
	}
	ok := true
	step_begin(pass, .Perception, "", len(perceptions))
	for i in perceptions {
		defer step_advance(pass)
		asset_source(pass, i)
		result := cook_perception(&assets[i], out_dir, pass)
		settle(pass, i, result)
		ok &&= !asset_failed(result)
	}
	return ok
}

@(private = "file")
cook_perception :: proc(a: ^Asset_Source, out_dir: string, pass: ^Pass) -> Asset_Result {
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	contents, parse_problems := perception_parse(string(source_of(a^)), context.temp_allocator)
	for p in parse_problems {
		report_error(problems, a.path, p.line, 0, "%s", p.message)
	}
	// A perception with errors keeps its old blob, so the running game keeps the last good version.
	if len(parse_problems) > 0 || !settings_ok {
		return .Failed
	}
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%x\x00", PERCEPTION_COOK_VERSION, a.name, format.perception_layout()))
	key = hash.fnv64a(source_of(a^), key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid))
	if cooked_key(output, .Perception, format.perception_layout()) == key && !pass.force[guid] {
		return .Current
	}
	contents.guid, contents.key, contents.source_path = guid, key, a.name
	if !write_blob(output, format.perception_write(contents, context.temp_allocator)) {
		return .Failed
	}
	return .Cooked
}

// perception_parse parses a perception's text into the contents of its blob, without its GUID, key or path: the first
// line `perception 1`, at most one `notices <Tag>, <Tag>...`, and rows `<key> = <source>`. It gives every problem that
// it finds, and the perception is good only without any.
perception_parse :: proc(text: string, allocator := context.allocator) -> (contents: format.Perception_Contents, problems: []Perception_Problem) {
	context.allocator = allocator
	found := make([dynamic]Perception_Problem)
	problem :: proc(found: ^[dynamic]Perception_Problem, line: int, f: string, args: ..any) {
		append(found, Perception_Problem{line, fmt.aprintf(f, ..args)})
	}
	SOURCES :: "a row is `<key> = <source>`, of the sources nearest [seen|heard] <Tag|any>, position <row>, visible <row>, since <row>, heard noise [<Tag>] and loudest noise [<Tag>]"
	notices := make([dynamic]string)
	rows := make([dynamic]format.Perception_Row_Contents)
	header, has_notices := false, false
	for raw, index in strings.split_lines(text) {
		line := index + 1
		trimmed := strings.trim_space(strip_line_comment(raw))
		if trimmed == "" {
			continue
		}
		if !header {
			if fields := strings.fields(trimmed); len(fields) == 2 && fields[0] == "perception" && fields[1] == "1" {
				header = true
				continue
			}
			problem(&found, line, "a perception starts with `perception 1`")
			return {}, found[:]
		}
		if word, _, rest := strings.partition(trimmed, " "); word == "notices" && !strings.contains(trimmed, "=") {
			if has_notices {
				problem(&found, line, "a perception has one notices line")
				continue
			}
			has_notices = true
			for part in strings.split(rest, ",") {
				tag := strings.trim_space(part)
				switch {
				case !is_identifier(tag):
					problem(&found, line, "notices takes tags' names between commas, such as Player, not %q", tag)
				case slice.contains(notices[:], tag):
					problem(&found, line, "notices gives %s twice", tag)
				case len(notices) == format.MAX_PERCEPTION_NOTICES:
					problem(&found, line, "a perception notices at most %d tags", format.MAX_PERCEPTION_NOTICES)
				case:
					append(&notices, tag)
				}
			}
			continue
		}
		key, has_source, source := strings.partition(trimmed, "=")
		key, source = strings.trim_space(key), strings.trim_space(source)
		if has_source == "" || !is_identifier(key) {
			problem(&found, line, SOURCES)
			continue
		}
		row, message := parse_perception_source(source, rows[:])
		if message != "" {
			problem(&found, line, "%s", message)
			continue
		}
		row.key = key
		clash := false
		for other in rows {
			if other.key == key {
				problem(&found, line, "another row fills %s", key)
				clash = true
			} else if format.animation_graph_hash(other.key) == format.animation_graph_hash(key) {
				problem(&found, line, "the keys %s and %s have the same hash: rename one", other.key, key)
				clash = true
			}
		}
		if clash {
			continue
		}
		if len(rows) == format.MAX_PERCEPTION_ROWS {
			problem(&found, line, "a perception has at most %d rows", format.MAX_PERCEPTION_ROWS)
			continue
		}
		append(&rows, row)
	}
	if !header {
		problem(&found, 1, "a perception starts with `perception 1`")
	}
	slice.stable_sort_by(found[:], proc(a, b: Perception_Problem) -> bool {return a.line < b.line})
	return {notices = notices[:], rows = rows[:]}, found[:]
}

// parse_perception_source reads a row's source: the words after its `=`. A row that reads another names a nearest row
// before it by its key.
@(private = "file")
parse_perception_source :: proc(text: string, rows: []format.Perception_Row_Contents) -> (row: format.Perception_Row_Contents, message: string) {
	words := strings.fields(text, context.temp_allocator)
	row.of = format.PERCEPTION_NONE
	if len(words) == 0 {
		return row, "a row needs a source after its ="
	}
	tag :: proc(word: string) -> (string, string) {
		if word == "any" {
			return "", ""
		}
		if !is_identifier(word) {
			return "", fmt.tprintf("%q is not a tag's name or any", word)
		}
		return word, ""
	}
	switch words[0] {
	case "nearest":
		row.source = .Nearest
		rest := words[1:]
		if len(rest) > 0 && rest[0] == "seen" {
			row.source, rest = .Nearest_Seen, rest[1:]
		} else if len(rest) > 0 && rest[0] == "heard" {
			row.source, rest = .Nearest_Heard, rest[1:]
		}
		if len(rest) != 1 {
			return row, "nearest is `nearest [seen|heard] <Tag|any>`"
		}
		row.tag, message = tag(rest[0])
	case "position", "visible", "since":
		switch words[0] {
		case "position":
			row.source = .Position
		case "visible":
			row.source = .Visible
		case "since":
			row.source = .Since
		}
		if len(words) != 2 {
			return row, fmt.tprintf("%s is `%s <row>`, where the row is a nearest row before it", words[0], words[0])
		}
		for r, i in rows {
			if r.key == words[1] {
				if !format.perception_source_chooses(r.source) {
					return row, fmt.tprintf("%s is not a nearest row, so it chooses no entity", words[1])
				}
				row.of = u32(i)
			}
		}
		if row.of == format.PERCEPTION_NONE {
			return row, fmt.tprintf("no nearest row before this one fills %s", words[1])
		}
	case "heard", "loudest":
		row.source = .Heard_Noise if words[0] == "heard" else .Loudest_Noise
		if len(words) < 2 || len(words) > 3 || words[1] != "noise" {
			return row, fmt.tprintf("%s is `%s noise [<Tag>]`", words[0], words[0])
		}
		if len(words) == 3 {
			row.tag, message = tag(words[2])
		}
	case:
		return row, fmt.tprintf("%q is not a source: nearest, position, visible, since, heard noise or loudest noise", words[0])
	}
	return
}
