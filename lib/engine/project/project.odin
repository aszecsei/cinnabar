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
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/physics"
import "cinnabar:engine/render"

// The user file is the project file's name with .user before its extension: project.settings has
// project.user.settings. Version control ignores it.
USER_SUFFIX :: ".user"

// The editor's default mesh material and texel density, as the settings file names them.
MESH_DEFAULT_MATERIAL_KEY :: "mesh.default_material"
MESH_TEXEL_DENSITY_KEY :: "mesh.texel_density"
// The physics layers' names, and the pairs of them that do not collide (see docs/physics/design.md#layers).
PHYSICS_LAYERS_KEY :: "physics.layers"
PHYSICS_IGNORE_KEY :: "physics.ignore"
// The physics backend, which the host reads before the game starts (see docs/physics/backends.md#choosing); the game
// only knows the key.
PHYSICS_BACKEND_KEY :: "physics.backend"

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
	// The material of new faces in the editor's mesh mode, by GUID, or zero for the engine's dev_gray (see
	// docs/editor/mesh-editing.md#dev-materials). The editor reads it; the game only knows the key.
	mesh_default_material: format.Guid,
	// The texel density of the editor's texture tools, in texels per meter, or 0 for the editor's default (see
	// docs/editor/mesh-editing.md#texture-tools). The editor reads it; the game only knows the key.
	mesh_texel_density:    f32,
	// The physics layers, or none for physics.default_layers.
	physics_layers:        physics.Layers,
}

// physics_layers gives the layers that settings name, or the default ones.
physics_layers :: proc(settings: Settings) -> physics.Layers {
	return settings.physics_layers if settings.physics_layers.count > 0 else physics.default_layers()
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
	Lod_Error,
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
	.Lod_Error          = "quality.lod_error",
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
	// physics.ignore names layers, which physics.layers may give after it, so its pairs are read at the end.
	Ignore :: struct {
		line:  int,
		value: string,
	}
	ignores := make([dynamic]Ignore, context.temp_allocator)
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
		if key == MESH_DEFAULT_MATERIAL_KEY {
			if guid, ok := format.guid_parse(value); ok {
				settings.mesh_default_material = guid
			} else {
				problem(problems, line, "%s takes a material's GUID of 32 hex digits, not %q", key, value)
			}
			continue
		}
		if key == PHYSICS_LAYERS_KEY {
			layers: physics.Layers
			ok := true
			for part in strings.split(value, ",", context.temp_allocator) {
				name := strings.trim_space(part)
				if !physics.add_layer(&layers, name) {
					problem(problems, line, "%s: %q is empty, longer than %d, given twice, or past %d layers", key, name, physics.MAX_LAYER_NAME, physics.MAX_LAYERS)
					ok = false
				}
			}
			if ok {
				settings.physics_layers = layers
			}
			continue
		}
		if key == PHYSICS_IGNORE_KEY {
			append(&ignores, Ignore{line, value})
			continue
		}
		if key == PHYSICS_BACKEND_KEY {
			if value == "" {
				problem(problems, line, "%s takes a backend's name, such as jolt or none", key)
			}
			continue
		}
		if key == MESH_TEXEL_DENSITY_KEY {
			if density, ok := strconv.parse_f32(value); ok && density > 0 {
				settings.mesh_texel_density = density
			} else {
				problem(problems, line, "%s takes a number of texels per meter above 0, not %q", key, value)
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
				// World_Probes was the split cascades' technique's name, and older files keep it.
				if value == "World_Probes" {
					q.gi.technique, ok = .Split_Cascades, true
				} else {
					ok = enum_value(problems, line, key, value, &q.gi.technique)
				}
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
			case .Lod_Error:
				error: f32
				error, ok = strconv.parse_f32(value)
				if ok {
					q.lod_error = error
				} else {
					problem(problems, line, "%s takes a number of pixels from %v to %v, not %q", key, render.MIN_LOD_ERROR, render.MAX_LOD_ERROR, value)
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
	for ig in ignores {
		layers := physics_layers(settings^)
		ok := true
		for pair in strings.split(ig.value, ",", context.temp_allocator) {
			a, _, b := strings.partition(pair, ":")
			ia, found_a := physics.layer_index(layers, strings.trim_space(a))
			ib, found_b := physics.layer_index(layers, strings.trim_space(b))
			if !found_a || !found_b {
				problem(problems, ig.line, "%s takes pairs of layers that physics.layers names, as A:B, not %q", PHYSICS_IGNORE_KEY, strings.trim_space(pair))
				ok = false
				continue
			}
			physics.ignore(&layers, ia, ib)
		}
		if ok {
			settings.physics_layers = layers
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
	if .Lod_Error in given {q.lod_error = s.lod_error}
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
		.Lod_Error          = fmt.tprintf("%v", q.lod_error),
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
