package editor

import "core:time"

import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"

// Modes (see docs/editor.md#modes). While an editor is linked, it decides whether the game's world runs: in Edit
// nothing runs, so the editor's document is the world; in Play the full frame runs; and while Paused, only a frame
// for each step runs. Without an editor, the world always runs.

// mode is the editor's mode, or Play without an editor.
mode :: proc(e: ^Editor) -> link.Editor_Mode {
	return e.mode if active(e) else .Play
}

// simulation reports whether this frame runs the world, its systems and scripts, and with what time step: the frame's
// in Play, and one fixed tick for a step while paused. A frame that does not run the world still propagates transforms
// and renders. Call it once per frame.
simulation :: proc(e: ^Editor, w: ^ecs.World, dt: time.Duration) -> (run: bool, step: time.Duration) {
	switch mode(e) {
	case .Play:
		return true, dt
	case .Paused:
		if e.steps > 0 {
			e.steps -= 1
			return true, ecs.tick_length(w)
		}
	case .Edit:
	}
	return false, 0
}
