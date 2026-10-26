// A project's settings (see docs/overview/architecture.md#project-settings): a text file of `key = value` lines, beside the
// game, that the editor edits, and a user file beside it whose values replace the project's on one machine. The game
// reads both when it starts, and again when either changes, so a running game takes an edit at once.
package project

import "core:fmt"
import "core:log"
import "core:reflect"
import "core:strconv"
import "core:strings"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/render"

// The user file is the project file's name with .user before its extension: project.settings has
// project.user.settings. Version control ignores it.
USER_SUFFIX :: ".user"

// Settings are a project's settings. A key that no file gives keeps its default.
Settings :: struct {
	// The window's output mode (see docs/rendering/layers-and-output.md#hdr-output). Auto is HDR10 on a display in HDR, and SDR
	// otherwise. CINNABAR_OUTPUT replaces it.
	output:        gpu.Output_Request,
	// The render quality (see docs/rendering/quality.md#saved-quality): a preset, and the keys that replace its
	// features. The keys that no file gives come from the device's default_quality (see quality).
	quality_given: Quality_Keys,
	preset:        render.Quality_Preset,
	quality:       render.Quality,
}

// Quality_Key is a render quality key of the settings files, by its name in QUALITY_KEY_NAMES.
Quality_Key :: enum u8 {
	Preset,
	Shadows,
	Ray_Traced_Shadows,
	Ao,
	Ao_Level,
	Gi,
	Gi_Level,
	Fog,
	Aa,
	Render_Scale,
}

Quality_Keys :: bit_set[Quality_Key]

@(rodata)
QUALITY_KEY_NAMES := [Quality_Key]string {
	.Preset             = "quality.preset",
	.Shadows            = "quality.shadows",
	.Ray_Traced_Shadows = "quality.shadows.ray_traced",
	.Ao                 = "quality.ao",
	.Ao_Level           = "quality.ao.level",
	.Gi                 = "quality.gi",
	.Gi_Level           = "quality.gi.level",
	.Fog                = "quality.fog",
	.Aa                 = "quality.aa",
	.Render_Scale       = "quality.render_scale",
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
	// enum_value parses an enum's value by its name into value, or says which names it takes.
	enum_value :: proc(problems: ^[dynamic]string, line: int, key, text: string, value: ^$T) -> bool {
		if v, ok := reflect.enum_from_name(T, text); ok {
			value^ = v
			return true
		}
		problem(problems, line, "%s takes %s, not %q", key, strings.join(reflect.enum_field_names(T), ", ", context.temp_allocator), text)
		return false
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
		if key == "output" {
			if output, ok := reflect.enum_from_name(gpu.Output_Request, value); ok {
				settings.output = output
			} else {
				problem(problems, line, "output takes Auto, Sdr, Hdr10 or Scrgb, not %q", value)
			}
			continue
		}
		found := false
		for name, k in QUALITY_KEY_NAMES {
			if name != key {
				continue
			}
			found = true
			q := &settings.quality
			ok: bool
			switch k {
			case .Preset:
				ok = enum_value(problems, line, key, value, &settings.preset)
			case .Shadows:
				ok = enum_value(problems, line, key, value, &q.shadows.level)
			case .Ray_Traced_Shadows:
				switch value {
				case "true":
					q.shadows.ray_traced, ok = true, true
				case "false":
					q.shadows.ray_traced, ok = false, true
				case:
					problem(problems, line, "%s takes true or false, not %q", key, value)
				}
			case .Ao:
				ok = enum_value(problems, line, key, value, &q.ao.technique)
			case .Ao_Level:
				ok = enum_value(problems, line, key, value, &q.ao.level)
			case .Gi:
				ok = enum_value(problems, line, key, value, &q.gi.technique)
			case .Gi_Level:
				ok = enum_value(problems, line, key, value, &q.gi.level)
			case .Fog:
				ok = enum_value(problems, line, key, value, &q.fog)
			case .Aa:
				ok = enum_value(problems, line, key, value, &q.aa)
			case .Render_Scale:
				scale: f32
				scale, ok = strconv.parse_f32(value)
				if ok {
					q.render_scale = scale
				} else {
					problem(problems, line, "%s takes a number from %v to 1, not %q", key, render.MIN_RENDER_SCALE, value)
				}
			}
			if ok {
				settings.quality_given += {k}
			}
		}
		if !found {
			problem(problems, line, "there is no setting %q", key)
		}
	}
}

// quality is the render quality that settings give on a device: the preset's, or the device's default without one,
// with each key that a file gave in place of the preset's.
quality :: proc(settings: Settings, caps: render.Caps) -> render.Quality {
	return with_keys(render.default_quality(caps), settings, caps)
}

// with_keys is a quality with the keys that settings give in place of its own: the preset's features, unless it is
// Custom, and then each other key.
with_keys :: proc(q: render.Quality, settings: Settings, caps: render.Caps) -> render.Quality {
	q := q
	if .Preset in settings.quality_given && settings.preset != .Custom {
		q = render.preset_quality(settings.preset, caps)
	}
	given, s := settings.quality_given, settings.quality
	if .Shadows in given {q.shadows.level = s.shadows.level}
	if .Ray_Traced_Shadows in given {q.shadows.ray_traced = s.shadows.ray_traced}
	if .Ao in given {q.ao.technique = s.ao.technique}
	if .Ao_Level in given {q.ao.level = s.ao.level}
	if .Gi in given {q.gi.technique = s.gi.technique}
	if .Gi_Level in given {q.gi.level = s.gi.level}
	if .Fog in given {q.fog = s.fog}
	if .Aa in given {q.aa = s.aa}
	if .Render_Scale in given {q.render_scale = s.render_scale}
	return render.clamp_quality(q, caps)
}

// quality_values are a quality's keys and values, every key, as a settings file holds them.
quality_values :: proc(q: render.Quality, caps: render.Caps) -> (values: [Quality_Key]string) {
	name :: proc(value: $T) -> string {
		n, _ := reflect.enum_name_from_value(value)
		return n
	}
	values = {
		.Preset             = name(render.quality_preset(q, caps)),
		.Shadows            = name(q.shadows.level),
		.Ray_Traced_Shadows = q.shadows.ray_traced ? "true" : "false",
		.Ao                 = name(q.ao.technique),
		.Ao_Level           = name(q.ao.level),
		.Gi                 = name(q.gi.technique),
		.Gi_Level           = name(q.gi.level),
		.Fog                = name(q.fog),
		.Aa                 = name(q.aa),
		.Render_Scale       = fmt.tprintf("%v", q.render_scale),
	}
	return
}

// set_value is a settings file's text with a key set to a value: its last line with the key replaced, and its other
// lines with the key removed, or a line added at the end. The other lines stay as they were, comments too, as the
// editor's ProjectSettings.Set keeps them.
set_value :: proc(text, key, value: string, allocator := context.temp_allocator) -> string {
	line_key :: proc(line: string) -> string {
		s := strings.trim_space(line)
		if s == "" || s[0] == '#' {
			return ""
		}
		k, _, _ := strings.partition(s, "=")
		return strings.trim_space(k)
	}
	lines := make([dynamic]string, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		append(&lines, line)
	}
	last := -1
	for line, i in lines {
		if line_key(line) == key {
			last = i
		}
	}
	b := strings.builder_make(allocator)
	for line, i in lines {
		switch {
		case i == last:
			fmt.sbprintf(&b, "%s = %s\n", key, value)
		case line_key(line) != key:
			fmt.sbprintf(&b, "%s\n", line)
		}
	}
	if last < 0 {
		fmt.sbprintf(&b, "%s = %s\n", key, value)
	}
	return strings.to_string(b)
}

// save_quality writes a quality to the user file beside a project file, every key of it, so the user file alone gives
// it. The file's other lines stay. The next refresh reads it back. It returns false if it could not write the file.
save_quality :: proc(platform: ^core.Platform_API, path: string, q: render.Quality, caps: render.Caps) -> bool {
	user := user_path(path, platform.frame_allocator)
	text := ""
	if data, ok := platform.file_read(user, 1, platform.frame_allocator); ok {
		text = string(data)
	}
	for value, k in quality_values(q, caps) {
		text = set_value(text, QUALITY_KEY_NAMES[k], value, platform.frame_allocator)
	}
	if !platform.file_write(user, transmute([]byte)text) {
		log.errorf("project: could not write %s", user)
		return false
	}
	return true
}

// write is a settings file that holds settings, for the editor's tests and tools.
write :: proc(settings: Settings, allocator := context.allocator) -> string {
	name, _ := reflect.enum_name_from_value(settings.output)
	return strings.concatenate({"# Project settings (see docs/overview/architecture.md#project-settings).\noutput = ", name, "\n"}, allocator)
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
