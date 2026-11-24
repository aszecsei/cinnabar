package asset_format

import "core:strings"

// settings_value is a key's value in the text of a file of `key = value` lines with `#` comments, such as a project's
// settings (see docs/overview/architecture.md#project-settings): the last line that sets it, or "" when none does. The
// tools and a release's entry point read single keys with it; the game reads the whole file with lib/engine/project.
settings_value :: proc(text, key: string) -> string {
	result := ""
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		if k, v, ok := settings_line(raw); ok && k == key {
			result = v
		}
	}
	return result
}

// Settings_Problem is a problem with a line of a project's settings.
Settings_Problem :: struct {
	// The line of the settings' text, from 1.
	line: int,
	text: string,
}

// settings_line splits a `key = value` line, and ok is false for a blank line or a comment.
settings_line :: proc(raw: string) -> (key, value: string, ok: bool) {
	s := strings.trim_space(raw)
	if s == "" || s[0] == '#' {
		return
	}
	k, _, v := strings.partition(s, "=")
	return strings.trim_space(k), strings.trim_space(v), true
}
