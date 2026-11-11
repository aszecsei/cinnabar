// The release's entry point: it links core, the engine and a project's game package statically and calls its Game_API
// directly. The build names the project's game package with the project collection: the standard game's for
// runtime.exe, or a project's own game/ (see docs/world/game-package.md#releases). The content and project.settings are
// beside the executable (see docs/overview/building-and-running.md#build-layout).
package main

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "cinnabar:core"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/project"
import game "project:game"

// The window's title when the settings give no game.name.
DEFAULT_TITLE :: "cinnabar"

main :: proc() {
	title := game_name()
	logger, log_file := open_log(title)
	context.logger = logger
	defer if log_file != nil {
		os.close(log_file)
	}

	if !core.init(title) {
		return
	}
	defer core.shutdown()

	api := game.cinnabar_game_api()
	platform := core.platform_api()
	state := core.alloc_game_state(api.state_size())
	api.init(state, platform)

	for {
		dt, ok := core.begin_frame()
		if !ok || !api.update(state, dt) {
			break
		}
		core.end_frame()
	}
	api.shutdown(state)
}

// game_name is the game.name of the project.settings beside the executable, or DEFAULT_TITLE.
game_name :: proc() -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {
		return DEFAULT_TITLE
	}
	path, _ := filepath.join({dir, "project.settings"}, context.temp_allocator)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return DEFAULT_TITLE
	}
	name := format.settings_value(string(data), project.NAME_KEY)
	return strings.clone(name) if name != "" else DEFAULT_TITLE
}

// open_log logs to %LOCALAPPDATA%\<name>\log.txt, because a release has no console: it is a Windows application.
// Without the folder it logs to the console, which a build for the console subsystem shows.
open_log :: proc(name: string) -> (log.Logger, ^os.File) {
	base := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if base != "" {
		dir, _ := filepath.join({base, name}, context.temp_allocator)
		path, _ := filepath.join({dir, "log.txt"}, context.temp_allocator)
		if os.make_directory_all(dir) == nil || os.exists(dir) {
			if f, err := os.create(path); err == nil {
				return log.create_file_logger(f), f
			}
		}
	}
	return log.create_console_logger(), nil
}
