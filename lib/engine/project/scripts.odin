package project

import "core:c"
import "core:fmt"
import "core:reflect"
import "core:strings"

import "cinnabar:core/luau"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

// The render quality's script API (see docs/scripting/api.md#render), for a settings menu in Luau: Render.quality,
// Render.set_quality, Render.caps, Render.presets and Render.save_quality. A quality is a table of the settings
// files' quality keys (see docs/rendering/quality.md#saved-quality), named as SCRIPT_QUALITY_FIELDS names them, with
// the enums' values as strings.

// The longest project settings path that Script_Quality holds.
MAX_SCRIPT_PATH :: 260

// Script_Quality is what the Render bindings reach: the renderer, and the project settings file, beside which
// Render.save_quality writes the user file. It lives in Game_State, so its address stays across code reloads.
Script_Quality :: struct {
	renderer: ^render.Renderer,
	path:     [MAX_SCRIPT_PATH]u8,
	path_len: int,
}

// The registry field that holds the Script_Quality's address, which define_quality_bindings sets.
@(private = "file")
REGISTRY_KEY :: "cinnabar.render_quality"

// The fields of a script's quality table, by the settings files' keys.
@(rodata)
SCRIPT_QUALITY_FIELDS := [Quality_Key]cstring {
	.Preset             = "preset",
	.Shadows            = "shadows",
	.Ray_Traced_Shadows = "ray_traced_shadows",
	.Ao                 = "ao",
	.Ao_Level           = "ao_level",
	.Gi                 = "gi",
	.Gi_Level           = "gi_level",
	.Fog                = "fog",
	.Aa                 = "aa",
	.Render_Scale       = "render_scale",
}

// script_quality is the Script_Quality of a renderer and a project settings file.
script_quality :: proc(renderer: ^render.Renderer, path: string) -> (q: Script_Quality) {
	assert(len(path) <= MAX_SCRIPT_PATH, "project: the settings path is too long for the script API")
	q.renderer = renderer
	q.path_len = copy(q.path[:], path)
	return
}

// define_quality_bindings defines the Render bindings, which reach q. A game's Register_Proc calls it, so init and
// every reload define them again. The bindings read q only when a script calls them.
define_quality_bindings :: proc(r: ^script.Runtime, q: ^Script_Quality) {
	luau.pushlightuserdata(r.L, q)
	luau.setfield(r.L, luau.REGISTRYINDEX, REGISTRY_KEY)
	script.define(r, "Render.quality", quality_binding, "() -> RenderQuality")
	script.define(r, "Render.set_quality", set_quality_binding, "(quality: RenderQualityChange) -> ()")
	script.define(r, "Render.caps", caps_binding, "() -> RenderCaps")
	script.define(r, "Render.presets", presets_binding, "() -> { string }")
	script.define(r, "Render.save_quality", save_quality_binding, "() -> boolean")
}

@(private = "file")
script_quality_of :: proc(L: ^luau.State) -> ^Script_Quality {
	luau.getfield(L, luau.REGISTRYINDEX, REGISTRY_KEY)
	q := (^Script_Quality)(luau.tolightuserdata(L, -1))
	luau.pop(L, 1)
	return q
}

// Render.quality() is the renderer's quality, with every field.
@(private = "file")
quality_binding :: proc(L: ^luau.State) -> c.int {
	r := script_quality_of(L).renderer
	q := r.quality
	luau.createtable(L, 0, len(Quality_Key))
	for value, k in quality_values(q, r.caps) {
		#partial switch k {
		case .Ray_Traced_Shadows:
			luau.pushboolean(L, b32(q.shadows.ray_traced))
		case .Render_Scale:
			luau.pushnumber(L, f64(q.render_scale))
		case:
			luau.pushodinstring(L, value)
		}
		luau.setfield(L, -2, SCRIPT_QUALITY_FIELDS[k])
	}
	return 1
}

// Render.set_quality(t) makes the renderer's quality its own with the fields that t gives in place of its own, as a
// settings file's keys replace the defaults: a preset sets every feature first. The device limits it, as
// render.set_quality does. A field that does not exist or a value that does not fit raises an error, and changes
// nothing.
@(private = "file")
set_quality_binding :: proc(L: ^luau.State) -> c.int {
	luau.L_checktype(L, 1, .TABLE)
	sq := script_quality_of(L)
	allocator := script.runtime_of(L).platform.frame_allocator
	text := strings.builder_make(allocator)
	luau.pushnil(L)
	for luau.next(L, 1) {
		name := luau.type(L, -2) == .STRING ? luau.toodinstring(L, -2) : ""
		key, found := Quality_Key(0), false
		for field, k in SCRIPT_QUALITY_FIELDS {
			if string(field) == name {
				key, found = k, true
			}
		}
		if !found {
			script.raise(L, fmt.aprintf("Render.set_quality: there is no quality field %q", name, allocator = allocator))
		}
		value: string
		#partial switch luau.type(L, -1) {
		case .BOOLEAN:
			value = luau.toboolean(L, -1) ? "true" : "false"
		case .NUMBER:
			value = fmt.aprintf("%v", luau.tonumber(L, -1), allocator = allocator)
		case .STRING:
			value = strings.clone(luau.toodinstring(L, -1), allocator)
		case:
			script.raise(L, fmt.aprintf("Render.set_quality: %s takes a string, a number or a boolean", name, allocator = allocator))
		}
		fmt.sbprintf(&text, "%s = %s\n", QUALITY_KEY_NAMES[key], value)
		luau.pop(L, 1)
	}
	settings: Settings
	problems := make([dynamic]string, allocator)
	parse(strings.to_string(text), &settings, &problems)
	if len(problems) > 0 {
		// The problems name the line, which the script does not have.
		_, _, problem := strings.partition(problems[0], ": ")
		script.raise(L, fmt.aprintf("Render.set_quality: %s", problem, allocator = allocator))
	}
	r := sq.renderer
	render.set_quality(r, with_keys(r.quality, settings, r.caps))
	return 0
}

// Render.caps() is what the device can do that the quality depends on: ray_query for traced shadows, the adapter's
// vendor and video memory in bytes, and aa, the anti-aliasing techniques that it runs.
@(private = "file")
caps_binding :: proc(L: ^luau.State) -> c.int {
	caps := script_quality_of(L).renderer.caps
	luau.createtable(L, 0, 4)
	luau.pushboolean(L, b32(caps.ray_query))
	luau.setfield(L, -2, "ray_query")
	vendor, _ := reflect.enum_name_from_value(caps.vendor)
	luau.pushodinstring(L, vendor)
	luau.setfield(L, -2, "vendor")
	luau.pushnumber(L, f64(caps.video_memory))
	luau.setfield(L, -2, "video_memory")
	luau.createtable(L, len(render.Aa_Technique), 0)
	n: c.int = 0
	for technique in render.Aa_Technique {
		if render.clamp_quality({aa = technique}, caps).aa != technique {
			continue
		}
		name, _ := reflect.enum_name_from_value(technique)
		n += 1
		luau.pushodinstring(L, name)
		luau.rawseti(L, -2, n)
	}
	luau.setfield(L, -2, "aa")
	return 1
}

// Render.presets() is the presets' names, from the cheapest: Custom is not one, but a quality's preset may be it.
@(private = "file")
presets_binding :: proc(L: ^luau.State) -> c.int {
	luau.createtable(L, len(render.Quality_Preset) - 1, 0)
	for preset in render.Quality_Preset.Low ..= render.Quality_Preset.Ultra {
		name, _ := reflect.enum_name_from_value(preset)
		luau.pushodinstring(L, name)
		luau.rawseti(L, -2, c.int(preset) + 1)
	}
	return 1
}

// Render.save_quality() writes the renderer's quality to the user settings file, as the player's choice on this
// machine. It returns false if it could not write the file.
@(private = "file")
save_quality_binding :: proc(L: ^luau.State) -> c.int {
	sq := script_quality_of(L)
	r := sq.renderer
	ok := save_quality(script.runtime_of(L).platform, string(sq.path[:sq.path_len]), r.quality, r.caps)
	luau.pushboolean(L, b32(ok))
	return 1
}
