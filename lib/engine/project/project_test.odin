package project

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/render"

@(test)
settings_files_are_keys_and_values :: proc(t: ^testing.T) {
	s: Settings
	problems := make([dynamic]string, context.temp_allocator)
	parse("# The window.\n\noutput = Sdr\nspeed = 2\noutput = Bright\n", &s, &problems)
	testing.expect_value(t, s.output, gpu.Output_Request.Sdr)
	testing.expect_value(t, len(problems), 2)
	testing.expect_value(t, problems[0], `4: there is no setting "speed"`)

	written: Settings
	parse(write({output = .Hdr10}, context.temp_allocator), &written)
	testing.expect_value(t, written.output, gpu.Output_Request.Hdr10)

	testing.expect_value(t, user_path("samples/game/project.settings"), "samples/game/project.user.settings")
	testing.expect_value(t, user_path("a.b/settings"), "a.b/settings.user")
}

// The files of the fake platform, by path, and their modification times.
@(private = "file")
files: map[string]struct {
	text: string,
	time: i64,
}

@(test)
the_user_file_replaces_the_projects_and_a_change_reads_them_again :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	files = make(map[string]struct {
			text: string,
			time: i64,
		})
	defer delete(files)
	platform := core.Platform_API {
		frame_allocator = virtual.arena_allocator(&arena),
		file_read = proc(path: string, align: int, allocator: runtime.Allocator) -> ([]byte, bool) {
			f, ok := files[path]
			return transmute([]byte)f.text, ok
		},
		file_modified = proc(path: string) -> i64 {
			return files[path].time
		},
	}
	w: Watch
	// Without files, the defaults.
	testing.expect(t, refresh(&w, &platform, "project.settings"))
	testing.expect_value(t, w.settings.output, gpu.Output_Request.Auto)
	testing.expect(t, !refresh(&w, &platform, "project.settings"))

	files["project.settings"] = {"output = Hdr10\n", 1}
	testing.expect(t, refresh(&w, &platform, "project.settings"))
	testing.expect_value(t, w.settings.output, gpu.Output_Request.Hdr10)

	files["project.user.settings"] = {"output = Sdr\n", 2}
	testing.expect(t, refresh(&w, &platform, "project.settings"))
	testing.expect_value(t, w.settings.output, gpu.Output_Request.Sdr)

	// Removing the user file brings the project's back.
	delete_key(&files, "project.user.settings")
	testing.expect(t, refresh(&w, &platform, "project.settings"))
	testing.expect_value(t, w.settings.output, gpu.Output_Request.Hdr10)
}

@(test)
quality_keys_replace_the_presets_features :: proc(t: ^testing.T) {
	caps := render.Caps{ray_query = true}
	// Without keys, the device's default.
	testing.expect_value(t, quality({}, caps), render.default_quality(caps))

	s: Settings
	problems := make([dynamic]string, context.temp_allocator)
	parse(
		"quality.preset = Low\nquality.ao = Off\nquality.shadows.ray_traced = true\nquality.fog = Loud\nquality.render_scale = 0.75\nquality.render_scale = half\nquality.lod_error = 3\n",
		&s,
		&problems,
	)
	testing.expect_value(t, len(problems), 2)
	testing.expect_value(t, problems[0], `4: quality.fog takes Low, Medium, High, Ultra, not "Loud"`)
	testing.expect_value(t, problems[1], `6: quality.render_scale takes a number from 0.5 to 1, not "half"`)
	q := quality(s, caps)
	testing.expect_value(t, q.render_scale, 0.75)
	testing.expect_value(t, q.lod_error, 3)
	testing.expect_value(t, q.shadows.level, render.Quality_Level.Low)
	testing.expect(t, q.shadows.ray_traced)
	testing.expect_value(t, q.ao.technique, render.Ao_Technique.Off)
	testing.expect_value(t, q.gi, render.preset_quality(.Low, caps).gi)
	// A device without Ray_Query has no traced shadows, whatever the file says.
	testing.expect(t, !quality(s, {}).shadows.ray_traced)

	// Every key that quality_values writes reads back as the same quality.
	written: Settings
	text := ""
	for value, k in quality_values(q, caps) {
		text = set_value(text, QUALITY_KEY_NAMES[k], value)
	}
	parse(text, &written)
	testing.expect_value(t, written.quality_given, ~Quality_Keys{})
	testing.expect_value(t, quality(written, caps), q)
}

@(test)
setting_a_value_keeps_the_files_other_lines :: proc(t: ^testing.T) {
	text := "# The player's.\noutput = Sdr\nquality.fog = Low\n\nquality.fog = High\n"
	testing.expect_value(t, set_value(text, "quality.fog", "Ultra"), "# The player's.\noutput = Sdr\n\nquality.fog = Ultra\n")
	testing.expect_value(t, set_value(text, "quality.aa", "Taa"), "# The player's.\noutput = Sdr\nquality.fog = Low\n\nquality.fog = High\nquality.aa = Taa\n")
	testing.expect_value(t, set_value("", "output", "Hdr10"), "output = Hdr10\n")
}

// The fake platform's files for a_saved_quality_is_the_user_files, apart from the other test's, which runs beside it.
@(private = "file")
saved_files: map[string]struct {
	text: string,
	time: i64,
}

@(test)
a_saved_quality_is_the_user_files :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	saved_files = make(map[string]struct {
			text: string,
			time: i64,
		})
	defer {
		for _, f in saved_files {
			delete(f.text)
		}
		delete(saved_files)
	}
	saved_files["project.settings"] = {strings.clone("quality.preset = Ultra\n"), 1}
	saved_files["project.user.settings"] = {strings.clone("output = Sdr\n"), 1}
	platform := core.Platform_API {
		frame_allocator = virtual.arena_allocator(&arena),
		file_read = proc(path: string, align: int, allocator: runtime.Allocator) -> ([]byte, bool) {
			f, ok := saved_files[path]
			return transmute([]byte)f.text, ok
		},
		file_modified = proc(path: string) -> i64 {
			return saved_files[path].time
		},
		file_write = proc(path: string, data: []byte) -> bool {
			old := saved_files[path]
			delete(old.text)
			saved_files[path] = {strings.clone(string(data)), old.time + 1}
			return true
		},
	}
	caps := render.Caps{}
	w: Watch
	testing.expect(t, refresh(&w, &platform, "project.settings"))
	testing.expect_value(t, render.quality_preset(quality(w.settings, caps), caps), render.Quality_Preset.Ultra)

	q := render.preset_quality(.Low, caps)
	q.aa = .Off
	testing.expect(t, save_quality(&platform, "project.settings", q, caps))
	testing.expect(t, refresh(&w, &platform, "project.settings"))
	testing.expect_value(t, quality(w.settings, caps), q)
	// The user file keeps its own lines, and the project's is as it was.
	testing.expect(t, strings.has_prefix(saved_files["project.user.settings"].text, "output = Sdr\n"))
	testing.expect_value(t, w.settings.output, gpu.Output_Request.Sdr)
	testing.expect_value(t, saved_files["project.settings"].text, "quality.preset = Ultra\n")
}
