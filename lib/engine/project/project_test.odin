package project

import "base:runtime"
import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"

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
