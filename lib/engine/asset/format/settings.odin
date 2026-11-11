package asset_format

import "core:strings"

// settings_value is a key's value in the text of a file of `key = value` lines with `#` comments, such as a project's
// settings (see docs/overview/architecture.md#project-settings): the last line that sets it, or "" when none does. The
// tools and a release's entry point read single keys with it; the game reads the whole file with lib/engine/project.
settings_value :: proc(text, key: string) -> string {
	result := ""
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		s := strings.trim_space(raw)
		if s == "" || s[0] == '#' {
			continue
		}
		k, _, v := strings.partition(s, "=")
		if strings.trim_space(k) == key {
			result = strings.trim_space(v)
		}
	}
	return result
}
