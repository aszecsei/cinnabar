package editor

import "core:time"

import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"

// Modes (see docs/editor/document-and-scenes.md#modes). While an editor is linked, it decides whether the game's world runs: in Edit
// nothing runs, so the editor's document is the world; in Play the full frame runs; and while Paused, only a frame
// for each step runs. Without an editor, the world always runs. The mode also decides what the viewport shows over the
// game: the editor's overlays and the debug layer draw only in Edit.

// mode is the editor's mode, or Play without an editor.
mode :: proc(e: ^Editor) -> link.Editor_Mode {
	return e.mode if active(e) else .Play
}

// editing is true while a linked editor is in Edit: the editor's outline, gizmo, icons and helpers draw only then.
editing :: proc(e: ^Editor) -> bool {
	return active(e) && e.mode == .Edit
}

// debug_shown is whether the frame draws its debug layer: always without an editor, and only while editing with one,
// so the viewport in Play and Paused shows what the game shows.
debug_shown :: proc(e: ^Editor) -> bool {
	return !active(e) || e.mode == .Edit
}

// playing is the Particle_Systems that play while the world stands still, for render.Frame_Desc.playing: the editor's
// selection, so a selected effect plays in Edit and while paused (see docs/rendering/particles.md#time). Without an
// editor, none.
playing :: proc(e: ^Editor) -> []ecs.Entity {
	if !active(e) {
		return nil
	}
	return e.viewport.selection[:]
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
