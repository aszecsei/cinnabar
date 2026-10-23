// The development host: loads a game DLL, runs the frame loop and hot-reloads the DLL.
package host

import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

import "cinnabar:core"

DEFAULT_GAME_PATH :: "build/mygame.dll"

Game_Module :: struct {
	source_path: string,
	version:     int,
	modified:    time.Time,
	api:         core.Game_API,
}

main :: proc() {
	context.logger = log.create_console_logger()

	source_path := len(os.args) > 1 ? os.args[1] : DEFAULT_GAME_PATH
	if !core.init("cinnabar host") {
		return
	}
	defer core.shutdown()

	game, ok := game_load(source_path, 0)
	if !ok {
		log.fatalf("host: could not load %s", source_path)
		return
	}
	platform := core.platform_api()
	state := core.alloc_game_state(game.api.state_size())
	game.api.init(state, platform)

	for {
		dt, keep_running := core.begin_frame()
		if !keep_running || !game.api.update(state, dt) {
			break
		}

		// End of frame: the job system is drained, so this is the reload point.
		if game_changed(game) {
			if next, loaded := game_load(source_path, game.version + 1); loaded {
				state = game_swap(&game, next, state)
			}
		}
	}
	game.api.shutdown(state)
}

// game_load copies the DLL to a versioned name and loads the copy, so the
// build can overwrite the original. Old copies are never unloaded.
game_load :: proc(source_path: string, version: int) -> (game: Game_Module, ok: bool) {
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
		return
	}

	log.infof("host: loaded %s", loaded_path)
	return {
			source_path = source_path,
			version = version,
			modified = modified,
			api = (proc() -> core.Game_API)(get_api)(),
		},
		true
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
		core.reset_permanent()
		state = core.alloc_game_state(next.api.state_size())
		next.api.init(state, platform)
	}
	game^ = next
	return state
}
