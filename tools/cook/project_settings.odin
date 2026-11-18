package cook

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import format "cinnabar:engine/asset/format"

// The project's settings, beside its content root, the root named game (see docs/overview/architecture.md#project-settings).
PROJECT_SETTINGS_FILE :: "project.settings"
PROJECT_USER_SETTINGS_FILE :: "project.user.settings"

// Project_Settings is the text of the project's settings file followed by its user file, so a later line wins, and the
// files that it came from, with the line of the text that each one starts after.
Project_Settings :: struct {
	text:   string,
	files:  []string,
	starts: []int,
}

// project_settings reads the project's settings files, once in a pass. The project is the folder above the root named
// game; a cook without one has no files, and the text is empty.
project_settings :: proc(options: Cook_Options, pass: ^Pass) -> Project_Settings {
	if settings, read := pass.settings.?; read {
		return settings
	}
	dir := ""
	for r in options.roots {
		if r.name == "game" {
			dir = filepath.dir(r.dir)
		}
	}
	text := strings.builder_make(context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	starts := make([dynamic]int, context.temp_allocator)
	lines := 0
	if dir != "" {
		for name in ([]string{PROJECT_SETTINGS_FILE, PROJECT_USER_SETTINGS_FILE}) {
			path := fmt.tprintf("%s/%s", dir, name)
			data, err := os.read_entire_file(path, context.temp_allocator)
			if err != nil {
				continue
			}
			append(&files, path)
			append(&starts, lines)
			strings.write_string(&text, string(data))
			strings.write_byte(&text, '\n')
			lines += strings.count(string(data), "\n") + 1
		}
	}
	pass.settings = Project_Settings{strings.to_string(text), files[:], starts[:]}
	return pass.settings.?
}

// report_settings_problems reports problems with lines of the settings' text as warnings at their files' lines.
report_settings_problems :: proc(
	pass: ^Pass,
	settings: Project_Settings,
	problems: []format.Settings_Problem,
) {
	for p in problems {
		file := 0
		for start, i in settings.starts {
			if p.line > start {
				file = i
			}
		}
		report_warning(
			&pass.problems,
			settings.files[file],
			p.line - settings.starts[file],
			0,
			"%s",
			p.text,
		)
	}
}

// project_sublevels reads the sublevels that the project declares, once in a pass, for the scenes' parse to check
// their names against. It is nil for a cook without project settings, which checks no names.
project_sublevels :: proc(options: Cook_Options, pass: ^Pass) -> Maybe([]format.Sublevel) {
	if sublevels, read := pass.sublevels.?; read {
		return sublevels.declared
	}
	settings := project_settings(options, pass)
	declared: Maybe([]format.Sublevel)
	if len(settings.files) > 0 {
		sublevels, problems := format.sublevels_parse(settings.text, context.temp_allocator)
		report_settings_problems(pass, settings, problems)
		declared = sublevels
	}
	pass.sublevels = Project_Sublevels{declared}
	return declared
}

// Project_Sublevels is the project's declared sublevels, which project_sublevels reads once in a pass.
Project_Sublevels :: struct {
	declared: Maybe([]format.Sublevel),
}
