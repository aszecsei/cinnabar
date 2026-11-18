package asset_format

import "core:fmt"
import "core:strings"

// A project's settings declare its sublevels (see docs/overview/architecture.md#project-settings), one line each:
// `sublevel.<name> = active` for one that starts active, or `= inactive`. An entity of a scene is in one with its
// `sublevel` key (see docs/editor/document-and-scenes.md#sublevels). The cooker reads them with sublevels_parse, and
// lib/engine/project checks each line with sublevel_check_setting.
SUBLEVEL_PREFIX :: "sublevel."
// The cooker splits each sublevel of a scene into a blob of its own: a sub-asset of this kind, `sublevel.<name>`, in the
// scene's .meta file, whose blob is a scene (see docs/content/kinds/scenes.md#sublevels).
SUBLEVEL_KIND :: "sublevel"
SUBLEVEL_MAX_NAME :: 31

// Sublevel is a declared sublevel, and whether it is active when the game starts.
Sublevel :: struct {
	name:   string,
	active: bool,
}

// sublevel_is_setting says whether a settings key declares a sublevel.
sublevel_is_setting :: proc(key: string) -> bool {
	return strings.has_prefix(key, SUBLEVEL_PREFIX)
}

// sublevel_name_valid says whether a name can be a sublevel's: letters, digits and _, at most SUBLEVEL_MAX_NAME.
sublevel_name_valid :: proc(name: string) -> bool {
	if name == "" || len(name) > SUBLEVEL_MAX_NAME {
		return false
	}
	for c in transmute([]byte)name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

// sublevel_check_setting checks a line `sublevel.<name> = active|inactive`. problem is "" for a line that fits, and
// otherwise in the temp allocator.
sublevel_check_setting :: proc(key, value: string) -> (problem: string) {
	_, _, problem = sublevel_parse_line(key, value)
	return
}

// sublevels_parse reads the declared sublevels from a project's settings text, which is the project's file followed by
// its user file, so a later line for a name wins. They are in the order that their names first appear. The names point
// into text, and the problems' text is in allocator.
sublevels_parse :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	sublevels: []Sublevel,
	problems: []Settings_Problem,
) {
	list := make([dynamic]Sublevel, allocator)
	found := make([dynamic]Settings_Problem, allocator)
	rest := text
	line := 0
	lines: for raw in strings.split_lines_iterator(&rest) {
		line += 1
		key, value, ok := settings_line(raw)
		if !ok || !sublevel_is_setting(key) {
			continue
		}
		name, active, problem := sublevel_parse_line(key, value)
		if problem != "" {
			append(&found, Settings_Problem{line, strings.clone(problem, allocator)})
			continue
		}
		for &s in list {
			if s.name == name {
				s.active = active
				continue lines
			}
		}
		append(&list, Sublevel{name, active})
	}
	return list[:], found[:]
}

// sublevel_known says whether a name is among the declared sublevels.
sublevel_known :: proc(sublevels: []Sublevel, name: string) -> bool {
	for s in sublevels {
		if s.name == name {
			return true
		}
	}
	return false
}

@(private = "file")
sublevel_parse_line :: proc(key, value: string) -> (name: string, active: bool, problem: string) {
	name = key[len(SUBLEVEL_PREFIX):]
	if !sublevel_name_valid(name) {
		problem = fmt.tprintf(
			"%s: a sublevel's name is letters, digits and _ of at most %d characters, not %q",
			key,
			SUBLEVEL_MAX_NAME,
			name,
		)
		return
	}
	switch value {
	case "active":
		active = true
	case "inactive":
	case:
		problem = fmt.tprintf("%s takes active or inactive, not %q", key, value)
	}
	return
}

// The most sublevels that a project declares, which the game keeps in fixed tables (see
// docs/world/sublevels.md#the-active-set).
MAX_SUBLEVELS :: 32

// Sublevel_Name is a sublevel's name in a fixed array, so state that a code reload keeps can hold it.
Sublevel_Name :: struct {
	len:   u8,
	bytes: [SUBLEVEL_MAX_NAME]u8,
}

// sublevel_name makes a Sublevel_Name. A name longer than SUBLEVEL_MAX_NAME is cut; sublevel_name_valid refuses it
// first.
sublevel_name :: proc(name: string) -> Sublevel_Name {
	n: Sublevel_Name
	n.len = u8(copy(n.bytes[:], name))
	return n
}

// sublevel_name_text is the text of a Sublevel_Name, which points into it.
sublevel_name_text :: proc(n: ^Sublevel_Name) -> string {
	return string(n.bytes[:n.len])
}

// Sublevel_Defaults are the sublevels that a project's settings declare, in the order that their names first appear,
// and which of them start active.
Sublevel_Defaults :: struct {
	count:  int,
	names:  [MAX_SUBLEVELS]Sublevel_Name,
	active: bit_set[0 ..< MAX_SUBLEVELS],
}

// sublevel_default sets whether a declared sublevel starts active. A later call for a name replaces an earlier one. It
// returns false past MAX_SUBLEVELS.
sublevel_default :: proc(d: ^Sublevel_Defaults, name: string, active: bool) -> bool {
	i := 0
	for ; i < d.count; i += 1 {
		if sublevel_name_text(&d.names[i]) == name {
			break
		}
	}
	if i == d.count {
		if d.count >= MAX_SUBLEVELS {
			return false
		}
		d.names[i] = sublevel_name(name)
		d.count += 1
	}
	if active {
		d.active += {i}
	} else {
		d.active -= {i}
	}
	return true
}

// sublevel_parse_setting reads a line `sublevel.<name> = active|inactive`. name points into key, and problem is "" for
// a line that fits, and otherwise in the temp allocator.
sublevel_parse_setting :: proc(
	key, value: string,
) -> (
	name: string,
	active: bool,
	problem: string,
) {
	return sublevel_parse_line(key, value)
}
