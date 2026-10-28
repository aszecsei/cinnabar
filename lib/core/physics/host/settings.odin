package physics_host

import "core:os"
import "core:strings"

// BACKEND_KEY names the project's physics backend in its settings files (see docs/physics/backends.md#choosing).
BACKEND_KEY :: "physics.backend"

// backend_setting reads the physics backend that a project's settings name: the user's file beside the project's, if it
// names one, else the project's, else "". The host reads it before the game starts, so it cannot use the game's
// parser; it reads this key and ignores the rest.
backend_setting :: proc(project_path: string, allocator := context.allocator) -> string {
	if project_path == "" {
		return ""
	}
	if name := read_key(user_path(project_path), BACKEND_KEY); name != "" {
		return strings.clone(name, allocator)
	}
	return strings.clone(read_key(project_path, BACKEND_KEY), allocator)
}

// user_path is the user's file beside a project's: project.settings has project.user.settings.
@(private)
user_path :: proc(path: string) -> string {
	dot := strings.last_index_byte(path, '.')
	slash := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	if dot <= slash {
		return strings.concatenate({path, ".user"}, context.temp_allocator)
	}
	return strings.concatenate({path[:dot], ".user", path[dot:]}, context.temp_allocator)
}

// read_key is a key's value in a settings file of `key = value` lines, the last one that sets it, or "".
@(private)
read_key :: proc(path, key: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	value := ""
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		s := strings.trim_space(line)
		if s == "" || s[0] == '#' {
			continue
		}
		k, _, v := strings.partition(s, "=")
		if strings.trim_space(k) == key {
			value = strings.trim_space(v)
		}
	}
	return value
}
