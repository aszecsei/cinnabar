package editor

import "core:time"

import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/script"

// Modes (see docs/editor/document-and-scenes.md#modes). While an editor is linked, it decides whether the game's world runs: in Edit
// only the behaviours that run in edit mode run, and their writes go to the editor's document, which is the world; in
// Play the full frame runs; and while Paused, only a frame for each step runs. Without an editor, the world always runs. The mode also decides what the viewport shows over the
// game: the editor's overlays and the debug layer draw only in Edit.

// mode is the editor's mode, or Play without an editor.
mode :: proc(e: ^Editor) -> link.Editor_Mode {
	return e.session.mode if active(e) else .Play
}

// world_loads counts the times that the editor replaced the game's world with its scene, at Play, at Stop and when it
// opens a scene. What the game keeps for one world, such as its views, starts again when it changes: the old world's
// behaviours end without their callbacks then, so they cannot undo what they set.
world_loads :: proc(e: ^Editor) -> u64 {
	return e.loads
}

// editing is true while a linked editor is in Edit: the editor's outline, gizmo, icons and helpers draw only then.
editing :: proc(e: ^Editor) -> bool {
	return active(e) && e.session.mode == .Edit
}

// debug_shown is whether the game's frame draws its debug layer when no viewport draws it: always without an editor,
// and only while editing with one, so it shows what the game shows in Play and Paused. A scene view always has the debug
// layer, and the Game view never has one (see plan_view).
debug_shown :: proc(e: ^Editor) -> bool {
	return !active(e) || e.session.mode == .Edit
}

// playing is the Particle_Systems and the Sprite_Renderers that play while the world stands still, for render.Frame_Desc.playing: the editor's
// selection, so a selected effect plays in Edit and while paused (see docs/rendering/particles.md#time). Without an
// editor, none.
playing :: proc(e: ^Editor) -> []ecs.Entity {
	if !active(e) {
		return nil
	}
	return e.session.view.selection[:]
}

// Simulation is what a frame runs (see docs/editor/document-and-scenes.md#modes):
// - Run: the world, its systems and scripts, as in Play and in a paused step, and always without an editor;
// - Edit: the edit phase, for the behaviours that run in edit mode, while the world is the editor's document;
// - Wait: no script code, and the world's changes wait for the scripts too, while the editor has not answered the
//   behaviours' last edits, or for a second after it refused them;
// - Hold: no script code, as while paused, or in Edit before the editor's scene is the world.
Simulation :: enum u8 {
	Run,
	Edit,
	Wait,
	Hold,
}

// simulation reports what this frame runs, and with what time step: the frame's in Play, and one fixed tick for a step
// while paused. A frame that does not run the world still propagates transforms and renders. Call it once per frame.
simulation :: proc(
	e: ^Editor,
	w: ^ecs.World,
	dt: time.Duration,
) -> (
	what: Simulation,
	step: time.Duration,
) {
	switch mode(e) {
	case .Play:
		return .Run, dt
	case .Paused:
		if e.session.steps > 0 {
			e.session.steps -= 1
			return .Run, ecs.tick_length(w)
		}
	case .Edit:
		m, mirrors := &e.session.mirror.?
		if !mirrors {
			break
		}
		switch b in m.batch {
		case Batch_Sent:
			return .Wait, 0
		case Batch_Refused:
			if e.platform.time_seconds() < b.until {
				return .Wait, 0
			}
			m.batch = nil
		}
		return .Edit, 0
	}
	return .Hold, 0
}

// script_callbacks is which behaviours get callbacks in a frame that runs what: every one when the world runs, the
// edit-mode classes' while the world is the editor's document in Edit, and none otherwise.
script_callbacks :: proc(e: ^Editor, what: Simulation) -> script.Callbacks {
	if what == .Run {
		return .All
	}
	return callbacks_between_frames(e)
}

// callbacks_between_frames is which behaviours get callbacks outside the frame's phases, as for the editor's edits.
@(private)
callbacks_between_frames :: proc(e: ^Editor) -> script.Callbacks {
	switch {
	case mode(e) == .Play:
		return .All
	case mode(e) == .Edit && e.session.mirror != nil:
		return .Edit_Mode
	}
	return .None
}
