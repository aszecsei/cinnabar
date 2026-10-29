// Release entry point: links core, engine and the game statically and calls Game_API directly. The game's content
// and project.settings are beside the executable (see docs/overview/building-and-running.md#build-layout).
package main

import "core:log"

import "cinnabar:core"
import game ".."

main :: proc() {
	context.logger = log.create_console_logger()

	if !core.init("intel") {
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
