package editorctl

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"
import "core:testing"

@(test)
arguments_are_read_and_checked :: proc(t: ^testing.T) {
	o, problem := parse_args(
		{"screenshot", "--view", "depth", "--view", "normals", "--out", "shots/a", "--json"},
	)
	defer delete(o.views)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, o.command, "screenshot")
	testing.expect_value(t, len(o.views), 2)
	testing.expect_value(t, o.views[1], "normals")
	testing.expect_value(t, o.out, "shots/a")
	testing.expect(t, o.json)

	status, ok := parse_args({"--automation", "x.json", "status"})
	testing.expect_value(t, ok, "")
	testing.expect_value(t, status.automation, "x.json")

	_, none := parse_args({})
	testing.expect(t, strings.contains(none, "no command"))
	_, unknown := parse_args({"dance"})
	testing.expect(t, strings.contains(unknown, "unknown command"))
	_, option := parse_args({"gif", "--nope"})
	testing.expect(t, strings.contains(option, "--nope"))
	bad_view, view_problem := parse_args({"gif", "--view", "depth"})
	defer delete(bad_view.views)
	testing.expect(t, strings.contains(view_problem, "--view"))
	_, out_problem := parse_args({"status", "--out", "x"})
	testing.expect(t, strings.contains(out_problem, "--out"))

	// viewport changes settings by name, and camera places the camera.
	viewport, viewport_problem := parse_args({"viewport", "--set", "shadingStats=true", "--set", "renderScale=0.5", "--set", "debugView=QuadOverdraw"})
	defer delete(viewport.settings)
	testing.expect_value(t, viewport_problem, "")
	on, _ := viewport.settings["shadingStats"].(json.Boolean)
	scale, _ := viewport.settings["renderScale"].(json.Float)
	view, _ := viewport.settings["debugView"].(json.String)
	testing.expect(t, bool(on))
	testing.expect_value(t, f64(scale), 0.5)
	testing.expect_value(t, string(view), "QuadOverdraw")
	_, empty := parse_args({"viewport"})
	testing.expect(t, strings.contains(empty, "--set"))
	camera, camera_problem := parse_args({"camera", "--position", "1, 2.5,-3", "--yaw", "0.5"})
	testing.expect_value(t, camera_problem, "")
	testing.expect_value(t, len(camera.position), 3)
	testing.expect_value(t, camera.position[2], -3)
	testing.expect_value(t, camera.yaw.? or_else 0, 0.5)
	// Each takes the viewport that it changes or captures, the first scene view without one.
	testing.expect(t, camera.viewport == nil)
	second, second_problem := parse_args({"camera", "--viewport", "1", "--position", "0,0,0"})
	testing.expect_value(t, second_problem, "")
	testing.expect_value(t, second.viewport.? or_else -1, 1)
	_, not_a_viewport := parse_args({"camera", "--viewport", "top", "--position", "0,0,0"})
	testing.expect(t, strings.contains(not_a_viewport, "--viewport"))
	_, stray_viewport := parse_args({"status", "--viewport", "1"})
	testing.expect(t, strings.contains(stray_viewport, "--viewport"))
	for command in ([]string{"screenshot", "gif"}) {
		captured, captured_problem := parse_args({command, "--viewport", "2", "--out", "a.png"})
		testing.expect_value(t, captured_problem, "")
		testing.expect_value(t, captured.viewport.? or_else -1, 2)
	}
	_, no_position := parse_args({"camera", "--yaw", "1"})
	testing.expect(t, strings.contains(no_position, "--position"))
	_, two := parse_args({"camera", "--position", "1,2"})
	testing.expect(t, strings.contains(two, "three numbers"))
	_, stray := parse_args({"status", "--yaw", "1"})
	testing.expect(t, strings.contains(stray, "camera"))
}

@(test)
ui_parses_its_options :: proc(t: ^testing.T) {
	o, problem := parse_args({"ui", "--window", "contentBrowser", "--out", "a.png"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, o.command, "ui")
	testing.expect_value(t, o.window, "contentBrowser")
	testing.expect_value(t, o.out, "a.png")
	_, stray := parse_args({"gif", "--window", "console"})
	testing.expect(t, strings.contains(stray, "--window"))
}

@(test)
content_takes_settings_or_none :: proc(t: ^testing.T) {
	asked, problem := parse_args({"content"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, asked.command, "content")
	changed, changed_problem := parse_args({"content", "--set", "search=door"})
	defer delete(changed.settings)
	testing.expect_value(t, changed_problem, "")
	search, _ := changed.settings["search"].(json.String)
	testing.expect_value(t, string(search), "door")
}

@(test)
the_request_is_one_json_line :: proc(t: ^testing.T) {
	o := Options {
		command = "screenshot",
	}
	append(&o.views, "depth")
	defer delete(o.views)
	line := request_line(o, 7, context.allocator)
	defer delete(line)
	text := string(line)
	testing.expect(t, strings.has_suffix(text, "}\n"))
	testing.expect(t, strings.contains(text, `"id":7`))
	testing.expect(t, strings.contains(text, `"command":"screenshot"`))
	testing.expect(t, strings.contains(text, `"views":["depth"]`))
	testing.expect(t, strings.contains(text, `"path":""`))
}

@(test)
responses_decode_with_their_status_and_files :: proc(t: ^testing.T) {
	// The decoded strings are the test's temporary memory.
	r, ok := decode_response(
		transmute([]byte)string(`{"id":1,"ok":true,"files":["E:/a.png","E:/a.json"]}`),
		context.temp_allocator,
	)
	testing.expect(t, ok)
	testing.expect(t, r.ok)
	testing.expect_value(t, len(r.files), 2)
	testing.expect_value(t, r.files[1], "E:/a.json")
	_, no_status := r.status.?
	testing.expect(t, !no_status)

	s, ok2 := decode_response(
		transmute([]byte)string(
			`{"id":2,"ok":true,"status":{"linked":true,"hostState":"Running","mode":"Edit","scene":"E:/door.scene","game":"mygame","hostPid":42}}`,
		),
		context.temp_allocator,
	)
	testing.expect(t, ok2)
	status, has := s.status.?
	testing.expect(t, has)
	testing.expect_value(t, status.host_state, "Running")
	testing.expect_value(t, status.host_pid, 42)

	e, ok3 := decode_response(
		transmute([]byte)string(`{"id":3,"ok":false,"error":"unknown command dance"}`),
		context.temp_allocator,
	)
	testing.expect(t, ok3)
	testing.expect(t, !e.ok)
	testing.expect_value(t, e.error, "unknown command dance")

	_, bad := decode_response(transmute([]byte)string("{not json"), context.temp_allocator)
	testing.expect(t, !bad)
}

@(test)
the_automation_file_is_found_below_the_repository_root :: proc(t: ^testing.T) {
	root :=
		filepath.join(
			{os.temp_directory(context.temp_allocator) or_else ".", "cinnabar-editorctl-test"},
			context.temp_allocator,
		) or_else ""
	deep := filepath.join({root, "src", "editor"}, context.temp_allocator) or_else ""
	info_dir := filepath.join({root, "build", "obj", "editor"}, context.temp_allocator) or_else ""
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory_all(deep) == nil)
	testing.expect(t, os.make_directory_all(info_dir) == nil)

	// Without the marker nothing is found; with it, the file is named even before it exists.
	_, found := find_automation_file(deep, context.temp_allocator)
	testing.expect(t, !found)
	marker := filepath.join({root, ROOT_MARKER}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(marker, []byte{}) == nil)
	path, exists := find_automation_file(deep, context.temp_allocator)
	testing.expect(t, !exists)
	expected := filepath.join({root, AUTOMATION_FILE}, context.temp_allocator) or_else ""
	testing.expect_value(
		t,
		filepath.clean(path, context.temp_allocator) or_else "",
		filepath.clean(expected, context.temp_allocator) or_else "",
	)

	testing.expect(
		t,
		os.write_entire_file(
			path,
			transmute([]byte)string(`{"port":51234,"pid":777,"started":"2026-10-27T08:00:00Z"}`),
		) ==
		nil,
	)
	_, exists = find_automation_file(deep, context.temp_allocator)
	testing.expect(t, exists)
	info, ok := read_info(path, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, info.port, 51234)
	testing.expect_value(t, info.pid, u32(777))

	// A pid that no process has is not alive; this one is.
	testing.expect(t, !process_alive(0xfffffff0))
	testing.expect(t, process_alive(u32(win.GetCurrentProcessId())))
}
