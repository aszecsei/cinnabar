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
import "cinnabar:core/gpu"
import "cinnabar:engine/editor/link"

DEFAULT_GAME_PATH :: "build/mygame.dll"

Game_Module :: struct {
	source_path: string,
	version:     int,
	modified:    time.Time,
	api:         core.Game_API,
}

main :: proc() {
	context.logger = log.create_console_logger()

	// host [game.dll] [--shared <name>] [--adapter <luid>] [--link <port>] [--emit-script-types <file>]
	// [--emit-link-schema <file>]. --shared renders into shared textures for the editor or tools/viewer. --adapter
	// names the GPU by its LUID in hex, so that the editor can open the shared textures on its own device. --link
	// serves the editor link on that port of 127.0.0.1. --emit-script-types writes the scripts' definition file, and
	// --emit-link-schema the editor link's schema, and each exits.
	source_path := DEFAULT_GAME_PATH
	shared_target := ""
	adapter: u64
	link_port := -1
	script_types := ""
	for i := 1; i < len(os.args); i += 1 {
		switch {
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
	if !core.init("cinnabar host", shared_target = shared_target, adapter = adapter) {
		return
	}
	defer core.shutdown()

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
		if !keep_running || !game.api.update(state, dt) {
			break
		}
		core.end_frame()

		// End of frame: the job system is drained, so this is the reload point.
		if game_changed(game) {
			switch next, reload := game_load(source_path, game.version + 1); reload {
			case .Loaded:
				kind := link.Reload_Kind.Code if next.api.layout_hash() == game.api.layout_hash() else .Soft_Restart
				state = game_swap(&game, next, state)
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
	}
	game.api.shutdown(state)
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

// game_load copies the DLL to a versioned name and loads the copy, so the
// build can overwrite the original. Old copies are never unloaded.
game_load :: proc(source_path: string, version: int) -> (game: Game_Module, result: Load_Result) {
	result = .Not_Ready
	modified, stat_err := os.modification_time_by_path(source_path)
	if stat_err != nil {
		log.errorf("host: %s: %v", source_path, stat_err)
		return
	}

	loaded_path := fmt.tprintf("%s_%d.dll", strings.trim_suffix(source_path, ".dll"), version)
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
	if game.api.gpu_format_hash() != gpu.format_hash() {
		log.errorf("host: %s was built with a different GPU command format. Restart the host to load it.", loaded_path)
		return game, .Refused
	}
	log.infof("host: loaded %s", loaded_path)
	return game, .Loaded
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
