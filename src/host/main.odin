// The development host: loads a game DLL, runs the frame loop and hot-reloads the DLL.
package host

import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/profile"
import "cinnabar:engine/editor/link"

// The game DLL, beside the host, when no argument names one: the standard game, which a project without Odin runs (see
// docs/world/game-package.md).
DEFAULT_GAME_NAME :: "standard.dll"

Game_Module :: struct {
	source_path: string,
	version:     int,
	modified:    time.Time,
	api:         core.Game_API,
}

main :: proc() {
	context.logger = log.create_console_logger()

	// host [game.dll] [--content <dir>] [--project <file>] [--physics <name>] [--shared <name>] [--adapter <luid>]
	// [--link <port>] [--emit-script-types <file>] [--emit-link-schema <file>]. The DLL is standard.dll beside the host by
	// default. --physics names the physics backend, physics_<name>.dll beside the host or none, in place of the
	// project's physics.backend (see docs/physics/backends.md#choosing).
	// --content is the game's loose cache and --project its settings file, which are content and project.settings
	// beside the host by default (see docs/overview/building-and-running.md#build-layout). --shared renders into shared
	// textures for the editor or tools/viewer. --adapter names the GPU by its LUID in hex, so that the editor can open
	// the shared textures on its own device. --link serves the editor link on that port of 127.0.0.1.
	// --emit-script-types writes the scripts' definition file, and --emit-link-schema the editor link's schema, and
	// each exits.
	exe_dir, exe_err := os.get_executable_directory(context.temp_allocator)
	if exe_err != nil {
		log.fatalf("host: cannot find the executable's directory: %v", exe_err)
		return
	}
	source_path, _ := filepath.join({exe_dir, DEFAULT_GAME_NAME}, context.temp_allocator)
	content_dir, project_path, physics_backend, audio_backend := "", "", "", ""
	shared_target := ""
	adapter: u64
	link_port := -1
	script_types := ""
	for i := 1; i < len(os.args); i += 1 {
		switch {
		case os.args[i] == "--content" && i + 1 < len(os.args):
			content_dir = os.args[i + 1]
			i += 1
		case os.args[i] == "--project" && i + 1 < len(os.args):
			project_path = os.args[i + 1]
			i += 1
		case os.args[i] == "--physics" && i + 1 < len(os.args):
			physics_backend = os.args[i + 1]
			i += 1
		case os.args[i] == "--audio" && i + 1 < len(os.args):
			audio_backend = os.args[i + 1]
			i += 1
		case os.args[i] == "--shared" && i + 1 < len(os.args):
			shared_target = os.args[i + 1]
			i += 1
		case os.args[i] == "--adapter" && i + 1 < len(os.args):
			luid, ok := strconv.parse_u64_of_base(os.args[i + 1], 16)
			if !ok || luid == 0 {
				log.fatalf("host: --adapter takes a LUID in hex, not %q", os.args[i + 1])
				return
			}
			adapter = luid
			i += 1
		case os.args[i] == "--link" && i + 1 < len(os.args):
			port, ok := strconv.parse_int(os.args[i + 1])
			if !ok || port < 1 || port > 65535 {
				log.fatalf("host: --link takes a port, not %q", os.args[i + 1])
				return
			}
			link_port = port
			i += 1
		case os.args[i] == "--emit-link-schema" && i + 1 < len(os.args):
			write_file(os.args[i + 1], link.schema(context.temp_allocator))
			log.infof("host: wrote the editor link's schema to %s", os.args[i + 1])
			return
		case os.args[i] == "--emit-script-types" && i + 1 < len(os.args):
			script_types = os.args[i + 1]
			// The window stays hidden.
			shared_target = "cinnabar_script_types"
			i += 1
		case:
			source_path = os.args[i]
		}
	}
	editor: Link
	if link_port >= 0 && !link_start(&editor, link_port, filepath.stem(source_path)) {
		return
	}
	defer link_stop(&editor)
	// Before core.init, so the job system's threads take the link's logger with the rest of the context. Not inside
	// an if: a change to the context lasts only to the end of its scope.
	context.logger = link_logger(&editor) if link_port >= 0 else context.logger
	if !core.init(
		"cinnabar host",
		shared_target = shared_target,
		adapter = adapter,
		content_dir = content_dir,
		project_path = project_path,
		physics_backend_name = physics_backend,
		audio_backend_name = audio_backend,
	) {
		return
	}
	defer core.shutdown()
	// Stopped before core.shutdown: its worker holds the backend's capture memory.
	capture: Capture
	capture_start(&capture, &editor)
	defer capture_stop(&capture)

	game, result := game_load(source_path, 0)
	if result != .Loaded {
		log.fatalf("host: could not load %s", source_path)
		return
	}
	platform := core.platform_api()
	if script_types != "" {
		emit_script_types(game, platform, script_types)
		return
	}
	state := core.alloc_game_state(game.api.state_size())
	game.api.init(state, platform)
	editor.layout_hash = game.api.layout_hash()

	for {
		dt, keep_running := core.begin_frame()
		work := time.tick_now()
		if !keep_running || !update_game(game, state, dt) {
			break
		}
		core.end_frame()
		link_frame(&editor, dt, time.tick_since(work))

		// End of frame: the job system is drained, so this is the reload point.
		if game_changed(game) {
			profile.zone_text("Hot reload", .Editor)
			reload_start := time.tick_now()
			audio_before := platform.audio_status()
			switch next, reload := game_load(source_path, game.version + 1); reload {
			case .Loaded:
				kind := link.Reload_Kind.Code if next.api.layout_hash() == game.api.layout_hash() else .Soft_Restart
				state = game_swap(&game, next, state)
				audio_after := platform.audio_status()
				log.debugf(
					"host: the reload took %v, and left %d of %d audio frames queued, with %d starved",
					time.tick_since(reload_start),
					audio_after.queued,
					audio_before.queued,
					audio_after.starved - audio_before.starved,
				)
				editor.layout_hash = game.api.layout_hash()
				link_send(&editor, link.Game_Reloaded{kind = kind})
			case .Refused:
				// The refused copy stays loaded and locked, so the next build needs the next version's file name.
				game.version = next.version
				game.modified = next.modified
				link_send(&editor, link.Game_Reloaded{kind = .Refused})
			case .Not_Ready:
			}
		}
		link_poll(&editor, game.api, state)
		// After the poll, so a request handled in it gets the very next frame.
		capture_tick(&capture)
	}
	game.api.shutdown(state)
}

update_game :: proc(game: Game_Module, state: rawptr, dt: time.Duration) -> bool {
	profile.zone_text("Game update", .Frame)
	return game.api.update(state, dt)
}

emit_script_types :: proc(game: Game_Module, platform: ^core.Platform_API, path: string) {
	write_file(path, game.api.script_types(platform))
	log.infof("host: wrote the script types to %s", path)
}

// write_file writes a generated file, with its directory, or exits.
write_file :: proc(path, text: string) {
	if dir := filepath.dir(path); dir != "" {
		os.make_directory_all(dir)
	}
	if err := os.write_entire_file(path, transmute([]byte)text); err != nil {
		log.errorf("host: %s: %v", path, err)
		os.exit(1)
	}
}

Load_Result :: enum {
	Loaded,
	// The build is incomplete or missing. The next frame retries.
	Not_Ready,
	// The DLL loaded but cannot run in this host. Only a new build is tried.
	Refused,
}

// game_load copies the DLL to a versioned name and loads the copy, so the build can overwrite the original. Old copies
// are never unloaded. The copy's name has the process's ID, so two hosts can run one DLL, as the editor's and its Run
// Game do: neither can replace a copy that the other has loaded.
game_load :: proc(source_path: string, version: int) -> (game: Game_Module, result: Load_Result) {
	result = .Not_Ready
	modified, stat_err := os.modification_time_by_path(source_path)
	if stat_err != nil {
		log.errorf("host: %s: %v", source_path, stat_err)
		return
	}
	if version == 0 {
		remove_old_copies(source_path)
	}

	loaded_path := copy_path(source_path, os.get_pid(), version)
	if err := os.copy_file(loaded_path, source_path); err != nil {
		// The linker may still be writing the DLL; the next frame retries.
		log.debugf("host: copy %s: %v", source_path, err)
		return
	}
	lib, did_load := dynlib.load_library(loaded_path)
	if !did_load {
		log.debugf("host: load %s: %s", loaded_path, dynlib.last_error())
		return
	}
	get_api, found := dynlib.symbol_address(lib, core.GAME_API_SYMBOL)
	if !found {
		log.errorf("host: %s does not export %s", loaded_path, core.GAME_API_SYMBOL)
		return {version = version, modified = modified}, .Refused
	}

	game = {
		source_path = source_path,
		version     = version,
		modified    = modified,
		api         = (proc() -> core.Game_API)(get_api)(),
	}
	if game.api.abi_hash() != core.abi_hash() {
		log.errorf("host: %s was built with a different GPU command format or Platform_API. Restart the host to load it.", loaded_path)
		return game, .Refused
	}
	log.infof("host: loaded %s", loaded_path)
	return game, .Loaded
}

// copy_path is the name of a DLL's copy that a host loads: <name>_<process>_<version>.dll beside it.
copy_path :: proc(source_path: string, pid, version: int, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s_%d_%d.dll", strings.trim_suffix(source_path, ".dll"), pid, version, allocator = allocator)
}

// is_copy_of is whether a file's name is a copy of a DLL's, as copy_path names it, or as hosts before it named them,
// <name>_<version>.dll.
is_copy_of :: proc(name, source_name: string) -> bool {
	prefix := strings.concatenate({strings.trim_suffix(source_name, ".dll"), "_"}, context.temp_allocator)
	if !strings.has_prefix(name, prefix) || !strings.has_suffix(name, ".dll") || len(name) <= len(prefix) + len(".dll") {
		return false
	}
	for part in strings.split(name[len(prefix):len(name) - len(".dll")], "_", context.temp_allocator) {
		if _, ok := strconv.parse_uint(part, 10); !ok {
			return false
		}
	}
	return true
}

// remove_old_copies removes the copies of a DLL that earlier hosts loaded. Those that a running host has loaded stay,
// because Windows refuses to remove them.
remove_old_copies :: proc(source_path: string) {
	dir, name := filepath.split(source_path)
	if dir == "" {
		dir = "."
	}
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for entry in entries {
		if is_copy_of(entry.name, name) {
			_ = os.remove(entry.fullpath)
		}
	}
}

game_changed :: proc(game: Game_Module) -> bool {
	modified, err := os.modification_time_by_path(game.source_path)
	return err == nil && modified != game.modified
}

// game_swap switches to the new DLL. It keeps the state if the layout of
// Game_State is unchanged, and otherwise soft-restarts the game with fresh state.
game_swap :: proc(game: ^Game_Module, next: Game_Module, state: rawptr) -> rawptr {
	platform := core.platform_api()
	state := state
	if next.api.layout_hash() == game.api.layout_hash() {
		next.api.on_reload(state, platform)
	} else {
		log.info("host: Game_State layout changed, restarting game")
		game.api.shutdown(state)
		core.soft_restart()
		state = core.alloc_game_state(next.api.state_size())
		next.api.init(state, platform)
	}
	game^ = next
	return state
}
