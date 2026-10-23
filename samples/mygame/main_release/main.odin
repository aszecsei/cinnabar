// Release entry point: links core, engine and the game statically and calls Game_API directly.
package main

import "core:log"

import "cinnabar:core"
import game ".."

main :: proc() {
	context.logger = log.create_console_logger()

	if !core.init("mygame") {
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
	}
	api.shutdown(state)
}
