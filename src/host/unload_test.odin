package host

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:testing"

import "cinnabar:core/layout"
import "cinnabar:core/testlog"

// The mixer that just audio-plugin builds stands in for the game's builds: the test loads copies of it.
@(private = "file")
FIXTURE_DLL :: "build/obj/audio/audio_cinnabar.dll"

@(private = "file")
Unload_State :: struct {
	frame:    u64,
	// A procedure stored in the state, which keeps its image loaded.
	callback: proc "c" (),
}

@(private = "file")
audit_unload_state :: proc(
	state: rawptr,
	image: layout.Range,
	allocator: runtime.Allocator,
) -> []layout.Finding {
	return layout.audit(state, Unload_State, image, "Unload_State", allocator)
}

// load_build copies the fixture to a build's name in dir and loads the copy.
@(private = "file")
load_build :: proc(t: ^testing.T, dir: string, version: int) -> (Game_Module, bool) {
	game := Game_Module {
		source_path = "build/obj/audio/unload.dll",
		load_dir = dir,
		version = version,
		api = {pointer_audit = audit_unload_state},
	}
	path := copy_path(game.source_path, dir, os.get_pid(), version)
	if err := os.copy_file(path, FIXTURE_DLL); err != nil {
		testing.expectf(t, false, "copy %s: %v", FIXTURE_DLL, err)
		return game, false
	}
	lib, ok := dynlib.load_library(path)
	testing.expectf(t, ok, "load %s: %s", path, dynlib.last_error())
	game.lib = lib
	return game, ok
}

@(private = "file")
is_loaded :: proc(game: Game_Module) -> bool {
	path, _ := strings.replace_all(
		copy_path(game.source_path, game.load_dir, os.get_pid(), game.version),
		"/",
		"\\",
		context.temp_allocator,
	)
	return win.GetModuleHandleW(win.utf8_to_wstring(path)) != nil
}

@(private = "file")
fresh_dir :: proc(name: string) -> string {
	// Absolute, so that GetModuleHandleW finds the copies by their paths.
	dir, _ := os.get_absolute_path(
		fmt.tprintf("build/obj/host_test/%s_%d", name, os.get_pid()),
		context.temp_allocator,
	)
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

@(test)
a_reload_unloads_each_old_image :: proc(t: ^testing.T) {
	dir := fresh_dir("unloads")
	defer os.remove_all(dir)
	state: Unload_State
	game, ok := load_build(t, dir, 0)
	if !ok {
		return
	}
	for version in 1 ..= 3 {
		next, next_ok := load_build(t, dir, version)
		if !next_ok {
			break
		}
		testing.expect(t, unload_old_image(game, next, &state))
		testing.expect(t, !is_loaded(game))
		// Windows refuses to remove an image that is mapped.
		old_path := copy_path(game.source_path, dir, os.get_pid(), game.version)
		testing.expect_value(t, os.remove(old_path), nil)
		game = next
	}
	dynlib.unload_library(game.lib)
}

@(test)
a_reload_that_finds_a_pointer_keeps_the_old_image :: proc(t: ^testing.T) {
	// The audit logs its finding as an error.
	context.logger = testlog.expected_errors()
	dir := fresh_dir("keeps")
	defer os.remove_all(dir)
	old, ok := load_build(t, dir, 0)
	if !ok {
		return
	}
	next, next_ok := load_build(t, dir, 1)
	if !next_ok {
		dynlib.unload_library(old.lib)
		return
	}
	defer dynlib.unload_library(next.lib)
	entry, found := dynlib.symbol_address(old.lib, "cinnabar_audio_api")
	testing.expect(t, found)
	state := Unload_State {
		frame    = 12,
		callback = (proc "c" ())(entry),
	}
	testing.expect(t, !unload_old_image(old, next, &state))
	testing.expect(t, is_loaded(old))

	// Once the state lets go, the next try unloads it.
	state.callback = nil
	testing.expect(t, unload_old_image(old, next, &state))
	testing.expect(t, !is_loaded(old))
}

@(test)
a_game_without_an_audit_keeps_the_old_image :: proc(t: ^testing.T) {
	dir := fresh_dir("no_audit")
	defer os.remove_all(dir)
	old, ok := load_build(t, dir, 0)
	if !ok {
		return
	}
	defer dynlib.unload_library(old.lib)
	next := old
	next.version = 1
	next.api.pointer_audit = nil
	state: Unload_State
	testing.expect(t, !unload_old_image(old, next, &state))
	testing.expect(t, is_loaded(old))
}
