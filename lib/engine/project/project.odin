// A project's settings (see docs/architecture.md#project-settings): a text file of `key = value` lines, beside the
// game, that the editor edits, and a user file beside it whose values replace the project's on one machine. The game
// reads both when it starts, and again when either changes, so a running game takes an edit at once.
package project

import "core:fmt"
import "core:log"
import "core:reflect"
import "core:strings"

import "cinnabar:core"
import "cinnabar:core/gpu"

// The user file is the project file's name with .user before its extension: project.settings has
// project.user.settings. Version control ignores it.
USER_SUFFIX :: ".user"

// Settings are a project's settings. A key that no file gives keeps its default.
Settings :: struct {
	// The window's output mode (see docs/rendering.md#hdr-output). Auto is HDR10 on a display in HDR, and SDR
	// otherwise. CINNABAR_OUTPUT replaces it.
	output: gpu.Output_Request,
}

// Watch is a project's settings and when their files last changed. It is plain data, so a code reload keeps it.
Watch :: struct {
	settings: Settings,
	// The files' modification times when they were read, 0 for a file that does not exist.
	project:  i64,
	user:     i64,
	read:     bool,
}

// user_path is the user file beside a project file.
user_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	dot := strings.last_index_byte(path, '.')
	slash := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	if dot <= slash {
		return strings.concatenate({path, USER_SUFFIX}, allocator)
	}
	return strings.concatenate({path[:dot], USER_SUFFIX, path[dot:]}, allocator)
}

// parse applies a settings file's lines to settings: `key = value`, with blank lines and `#` comments. An unknown key
// or a value that does not fit is a problem, and the setting keeps what it had.
parse :: proc(text: string, settings: ^Settings, problems: ^[dynamic]string = nil) {
	problem :: proc(problems: ^[dynamic]string, line: int, format: string, args: ..any) {
		if problems != nil {
			append(problems, fmt.tprintf("%d: %s", line, fmt.tprintf(format, ..args)))
		}
	}
	rest := text
	line := 0
	for raw in strings.split_lines_iterator(&rest) {
		line += 1
		s := strings.trim_space(raw)
		if s == "" || s[0] == '#' {
			continue
		}
		key, _, value := strings.partition(s, "=")
		key, value = strings.trim_space(key), strings.trim_space(value)
		switch key {
		case "output":
			if output, ok := reflect.enum_from_name(gpu.Output_Request, value); ok {
				settings.output = output
			} else {
				problem(problems, line, "output takes Auto, Sdr, Hdr10 or Scrgb, not %q", value)
			}
		case:
			problem(problems, line, "there is no setting %q", key)
		}
	}
}

// write is a settings file that holds settings, for the editor's tests and tools.
write :: proc(settings: Settings, allocator := context.allocator) -> string {
	name, _ := reflect.enum_name_from_value(settings.output)
	return strings.concatenate({"# Project settings (see docs/architecture.md#project-settings).\noutput = ", name, "\n"}, allocator)
}

// refresh reads the project file and its user file the first time, and again when either changed. It returns true
// when it read them.
refresh :: proc(w: ^Watch, platform: ^core.Platform_API, path: string) -> (changed: bool) {
	user := user_path(path, platform.frame_allocator)
	project_time, user_time := platform.file_modified(path), platform.file_modified(user)
	if w.read && project_time == w.project && user_time == w.user {
		return false
	}
	w.read, w.project, w.user = true, project_time, user_time
	settings: Settings
	for file in ([]string{path, user}) {
		data, ok := platform.file_read(file, 1, platform.frame_allocator)
		if !ok {
			continue
		}
		problems := make([dynamic]string, platform.frame_allocator)
		parse(string(data), &settings, &problems)
		for p in problems {
			log.warnf("project: %s:%s", file, p)
		}
	}
	w.settings = settings
	return true
}

