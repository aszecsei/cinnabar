// The standard game as a project's game package: the engine's, with no hooks. standard.dll and runtime.exe are built
// from it, and a project without Odin runs them (see docs/world/game-package.md).
package standard

import "cinnabar:core"
import "cinnabar:engine/game"

@(export)
cinnabar_game_api :: proc() -> core.Game_API {
	return game.api(game.no_hooks)
}
