package project

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import script_host "cinnabar:core/script"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

@(test)
display_settings_round_trip_and_keep_other_lines :: proc(t: ^testing.T) {
	choice := Display_Choice {
		mode        = .Fullscreen,
		width       = 2560,
		height      = 1440,
		output      = .Sdr,
		paper_white = 275.5,
	}
	before := "# Mine.\nquality.preset = High\noutput = Hdr10\n\nui.scale = 1.5\ndisplay.mode = Windowed\n"
	text := with_display(before, choice, context.temp_allocator)

	settings: Settings
	problems := make([dynamic]string, context.temp_allocator)
	parse(text, &settings, &problems)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, settings.output, gpu.Output_Request.Sdr)
	testing.expect_value(
		t,
		settings.display.given,
		Display_Keys{.Mode, .Width, .Height, .Paper_White},
	)
	testing.expect_value(t, settings.display.mode, core.Window_Mode.Fullscreen)
	testing.expect_value(t, settings.display.width, i32(2560))
	testing.expect_value(t, settings.display.height, i32(1440))
	testing.expect_value(t, settings.display.paper_white, f32(275.5))
	// The other lines stay, in their places, and the keys that the file had are replaced, not repeated.
	testing.expect(
		t,
		strings.has_prefix(
			text,
			"# Mine.\nquality.preset = High\noutput = Sdr\n\nui.scale = 1.5\n",
		),
	)
	testing.expect_value(t, strings.count(text, "display.mode"), 1)
	testing.expect_value(t, strings.count(text, "output ="), 1)
	testing.expect_value(t, settings.ui_scale, f32(1.5))

	// Without a paper white choice, a paper white that the file has stays.
	kept := with_display(
		"display.paper_white = 150\n",
		{mode = .Windowed, width = 1280, height = 720},
		context.temp_allocator,
	)
	again: Settings
	parse(kept, &again)
	testing.expect_value(t, again.display.paper_white, f32(150))
	testing.expect_value(t, again.display.mode, core.Window_Mode.Windowed)
}

@(test)
display_keys_that_do_not_fit_are_problems :: proc(t: ^testing.T) {
	settings: Settings
	problems := make([dynamic]string, context.temp_allocator)
	parse(
		"display.mode = Maximized\ndisplay.width = 0\ndisplay.height = wide\ndisplay.paper_white = 900\ndisplay.paper_white = 79\n",
		&settings,
		&problems,
	)
	testing.expect_value(t, len(problems), 5)
	testing.expect_value(
		t,
		problems[0],
		`1: display.mode takes Windowed, Borderless, Fullscreen, not "Maximized"`,
	)
	testing.expect_value(t, settings.display, Display_Settings{})
}

// The fake platform's window, the display and the files that Display.save wrote. The platform's procedures reach it by
// name, since they have no data pointer.
@(private = "file")
Fake_Display :: struct {
	state:        core.Display_State,
	sizes:        [][2]i32,
	// What set_window_mode gives back, and how often it was called.
	accepts:      bool,
	calls:        int,
	output:       gpu.Output_Request,
	display:      gpu.Display,
	files:        map[string]string,
	// What the bindings of the test's script reach.
	test_quality: ^Script_Quality,
}

// Thread local, as the tests run on threads of their own.
@(private = "file", thread_local)
fake: Fake_Display

@(private = "file")
fake_sizes := [2][2]i32{{1920, 1080}, {1280, 720}}

@(private = "file")
fake_platform :: proc(arena: ^virtual.Arena) -> core.Platform_API {
	return {
		frame_allocator = virtual.arena_allocator(arena),
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
		display_resolutions = proc(allocator: runtime.Allocator) -> [][2]i32 {
			return fake.sizes
		},
		display_state = proc() -> core.Display_State {
			state := fake.state
			state.output = fake.output
			return state
		},
		set_window_mode = proc(mode: core.Window_Mode, size: [2]i32) -> bool {
			fake.calls += 1
			if fake.accepts {
				fake.state.mode = mode
				fake.state.size = size if mode != .Borderless else fake.state.monitor
				if mode != .Fullscreen {
					fake.state.requested = size
				}
			}
			return fake.accepts
		},
		gpu_request_output = proc(request: gpu.Output_Request) {
			fake.output = request
		},
		gpu_output = proc() -> gpu.Output {
			return {display = fake.display}
		},
		file_read = proc(
			path: string,
			align: int,
			allocator: runtime.Allocator,
		) -> (
			[]byte,
			bool,
		) {
			text, ok := fake.files[path]
			return transmute([]byte)text, ok
		},
		file_write = proc(path: string, data: []byte) -> bool {
			// The path is in the frame's memory, which the test frees before it reads the files.
			if old, ok := fake.files[path]; ok {
				delete(old)
				fake.files[path] = strings.clone(string(data))
			} else {
				fake.files[strings.clone(path)] = strings.clone(string(data))
			}
			return true
		},
	}
}

// reset_fake is a 1280x720 window on a 1920x1080 monitor, in Windowed, with an HDR display.
@(private = "file")
reset_fake :: proc() {
	fake = {
		state = {
			mode = .Windowed,
			size = {1280, 720},
			requested = {1280, 720},
			monitor = {1920, 1080},
			hdr_available = true,
		},
		sizes = fake_sizes[:],
		accepts = true,
		files = make(map[string]string),
	}
}

@(private = "file")
free_fake :: proc() {
	for path, text in fake.files {
		delete(path)
		delete(text)
	}
	delete(fake.files)
}

// run_display_script runs a script with the Render and Display bindings on the fake platform and a renderer, which it
// gives back and the test frees. The script fails the test with an error if an assertion does not hold.
@(private = "file")
run_display_script :: proc(t: ^testing.T, source: string) -> ^render.Renderer {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	platform := fake_platform(&arena)
	renderer := new(render.Renderer)
	q := script_quality(renderer, "game/project.settings")
	fake.test_quality = &q
	r := new(script.Runtime)
	defer free(r)
	testing.expect(t, script.init(r, &platform, nil, nil, proc(r: ^script.Runtime) {
			define_quality_bindings(r, fake.test_quality)
			define_display_bindings(r)
		}))
	defer script.destroy(r)
	_, ok := script.spawn_source(r, "=display", source)
	testing.expect(t, ok)
	return renderer
}

@(test)
display_set_raises_on_an_unknown_mode :: proc(t: ^testing.T) {
	reset_fake()
	defer free_fake()
	renderer := run_display_script(
		t,
		`
local ok, err = pcall(Display.set, { mode = "Maximized" })
assert(not ok and string.find(err, "mode takes Windowed, Borderless, Fullscreen", 1, true), err)
ok, err = pcall(Display.set, { mode = 3 })
assert(not ok and string.find(err, "mode takes a string", 1, true), err)
ok, err = pcall(Display.set, { fov = 3 })
assert(not ok and string.find(err, "there is no display field", 1, true), err)
ok, err = pcall(Display.set, { hdr_available = true })
assert(not ok and string.find(err, "cannot be set", 1, true), err)
assert(Display.get().mode == "Windowed")
`,
	)
	defer free(renderer)
	testing.expect_value(t, fake.calls, 0)
}

@(test)
display_set_raises_on_a_size_that_is_not_a_display_mode_in_fullscreen :: proc(t: ^testing.T) {
	reset_fake()
	defer free_fake()
	renderer := run_display_script(
		t,
		`
local ok, err = pcall(Display.set, { mode = "Fullscreen", width = 1000, height = 700 })
assert(not ok and string.find(err, "1000x700 is not a display mode", 1, true), err)
-- A size has to be a whole number of pixels.
ok, err = pcall(Display.set, { width = 12.5 })
assert(not ok and string.find(err, "width takes a whole number", 1, true), err)
ok, err = pcall(Display.set, { height = 0 })
assert(not ok and string.find(err, "height takes a whole number", 1, true), err)
-- Windowed takes any size.
Display.set({ width = 1000, height = 700 })
assert(Display.get().width == 1000)
-- Fullscreen without a size is the monitor's own, which is a display mode.
Display.set({ mode = "Fullscreen" })
local state = Display.get()
assert(state.mode == "Fullscreen" and state.width == 1920 and state.height == 1080)
Display.set({ width = 1280, height = 720 })
assert(Display.get().width == 1280)
ok, err = pcall(Display.set, { width = 1281 })
assert(not ok and string.find(err, "1281x720", 1, true), err)
`,
	)
	defer free(renderer)
	// The three changes that were allowed reached the window, and none of those that raised.
	testing.expect_value(t, fake.calls, 3)
}

@(test)
display_set_raises_on_a_paper_white_out_of_range :: proc(t: ^testing.T) {
	reset_fake()
	defer free_fake()
	renderer := run_display_script(
		t,
		`
for _, nits in { 79, 501, 0, -5 } do
	local ok, err = pcall(Display.set, { paper_white = nits })
	assert(not ok and string.find(err, "paper_white takes nits from 80 to 500", 1, true), err)
end
local ok, err = pcall(Display.set, { paper_white = "bright" })
assert(not ok and string.find(err, "paper_white takes a number", 1, true), err)
Display.set({ paper_white = 350 })
assert(Display.get().paper_white == 350)
`,
	)
	defer free(renderer)
	testing.expect_value(t, renderer.paper_white, f32(350))
}

@(test)
display_get_set_and_save_the_display :: proc(t: ^testing.T) {
	reset_fake()
	defer free_fake()
	fake.display = {
		hdr       = true,
		sdr_white = 240,
	}
	renderer := run_display_script(
		t,
		`
assert(#Display.modes() == 3 and Display.modes()[1] == "Windowed" and Display.modes()[3] == "Fullscreen")
local sizes = Display.resolutions()
assert(#sizes == 2 and sizes[1].width == 1920 and sizes[1].height == 1080 and sizes[2].width == 1280)
local state = Display.get()
assert(state.mode == "Windowed" and state.width == 1280 and state.height == 720, "the window")
assert(state.hdr == true and state.hdr_available == true and state.paper_white == 240, "the display's SDR white")

Display.set({ hdr = false, mode = "Borderless", paper_white = 300 })
state = Display.get()
assert(state.mode == "Borderless" and state.hdr == false and state.paper_white == 300)
-- A change that gives nothing, or only a part, leaves the rest.
Display.set({})
Display.set({ hdr = true })
assert(Display.get().mode == "Borderless" and Display.get().hdr == true)
-- Windowed returns to the size that it had.
Display.set({ mode = "Windowed" })
assert(Display.get().width == 1280 and Display.get().height == 720)
assert(Display.save())
`,
	)
	defer free(renderer)
	testing.expect_value(t, renderer.paper_white, f32(300))
	testing.expect_value(t, fake.output, gpu.Output_Request.Auto)

	saved: Settings
	parse(fake.files["game/project.user.settings"], &saved)
	testing.expect_value(t, saved.output, gpu.Output_Request.Auto)
	testing.expect_value(t, saved.display.mode, core.Window_Mode.Windowed)
	testing.expect_value(t, [2]i32{saved.display.width, saved.display.height}, [2]i32{1280, 720})
	testing.expect_value(t, saved.display.paper_white, f32(300))
}

@(test)
the_definitions_have_the_display_library_and_its_types :: proc(t: ^testing.T) {
	reset_fake()
	defer free_fake()
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	platform := fake_platform(&arena)
	renderer := new(render.Renderer)
	defer free(renderer)
	q := script_quality(renderer, "game/project.settings")
	fake.test_quality = &q
	r := new(script.Runtime)
	defer free(r)
	testing.expect(t, script.init(r, &platform, nil, nil, proc(r: ^script.Runtime) {
			define_quality_bindings(r, fake.test_quality)
			define_display_bindings(r)
		}))
	defer script.destroy(r)
	// The checkout's line endings are its own.
	text, _ := strings.replace_all(
		script.definitions(r, context.temp_allocator),
		"\r\n",
		"\n",
		context.temp_allocator,
	)
	for fragment in ([]string{"type DisplaySize = {\n\twidth: number,\n\theight: number,\n}", "type DisplayState = {\n\tmode: string,\n\twidth: number,\n\theight: number,\n\thdr: boolean,\n\thdr_available: boolean,\n\tpaper_white: number,\n}", "type DisplayChange = {\n\tmode: string?,\n\twidth: number?,\n\theight: number?,\n\thdr: boolean?,\n\tpaper_white: number?,\n}", "modes: () -> { string }", "resolutions: () -> { DisplaySize }", "get: () -> DisplayState", "set: (change: DisplayChange) -> ()", "save: () -> boolean"}) {
		testing.expectf(
			t,
			strings.contains(text, fragment),
			"the definitions have no %q",
			fragment,
		)
	}
}

@(test)
a_refused_window_change_is_not_committed :: proc(t: ^testing.T) {
	reset_fake()
	defer free_fake()
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	platform := fake_platform(&arena)
	renderer := new(render.Renderer)
	defer free(renderer)
	settings: Settings
	parse("display.mode = Borderless\ndisplay.paper_white = 200\noutput = Sdr\n", &settings)
	applied: Maybe(Display_File)

	// The window refuses: nothing is committed, the output and the paper white apply, and the next refresh tries again.
	fake.accepts = false
	apply_display_settings(&applied, &platform, renderer, settings)
	testing.expect_value(t, applied == nil, true)
	testing.expect_value(t, fake.calls, 1)
	testing.expect_value(t, fake.output, gpu.Output_Request.Sdr)
	testing.expect_value(t, renderer.paper_white, f32(200))
	testing.expect_value(t, fake.state.mode, core.Window_Mode.Windowed)

	fake.accepts = true
	apply_display_settings(&applied, &platform, renderer, settings)
	testing.expect_value(t, fake.calls, 2)
	testing.expect_value(t, fake.state.mode, core.Window_Mode.Borderless)
	testing.expect_value(t, applied != nil, true)

	// What the player set since stays while the display keys are as they were.
	fake.state.mode = .Windowed
	apply_display_settings(&applied, &platform, renderer, settings)
	testing.expect_value(t, fake.calls, 2)
	testing.expect_value(t, fake.state.mode, core.Window_Mode.Windowed)
	// A change of the keys applies, and a window that is already as they say is not touched.
	parse("display.mode = Windowed\n", &settings)
	apply_display_settings(&applied, &platform, renderer, settings)
	testing.expect_value(t, fake.calls, 2)
	parse("display.mode = Fullscreen\n", &settings)
	apply_display_settings(&applied, &platform, renderer, settings)
	testing.expect_value(t, fake.calls, 3)
	testing.expect_value(t, fake.state.mode, core.Window_Mode.Fullscreen)
}

@(test)
the_paper_white_of_the_player_wins_over_the_volume_and_the_display :: proc(t: ^testing.T) {
	display := gpu.Display {
		sdr_white = 240,
	}
	testing.expect_value(t, render.paper_white_nits(0, 0, {}), f32(render.DEFAULT_PAPER_WHITE))
	testing.expect_value(t, render.paper_white_nits(0, 0, display), f32(240))
	testing.expect_value(t, render.paper_white_nits(0, 180, display), f32(180))
	testing.expect_value(t, render.paper_white_nits(350, 180, display), f32(350))
	r := new(render.Renderer)
	defer free(r)
	render.set_paper_white(r, 1000)
	testing.expect_value(t, r.paper_white, f32(render.MAX_PAPER_WHITE))
	render.set_paper_white(r, 10)
	testing.expect_value(t, r.paper_white, f32(render.MIN_PAPER_WHITE))
	render.set_paper_white(r, 0)
	testing.expect_value(t, r.paper_white, f32(0))
}
