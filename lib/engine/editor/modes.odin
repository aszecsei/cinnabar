package editor

import "core:time"

import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/script"

// Modes (see docs/editor/document-and-scenes.md#modes). While an editor is linked, it decides whether the game's world runs: in Edit
// only the behaviours that run in edit mode run, and their writes go to the editor's document, which is the world; in
// Play the full frame runs; and while Paused, only a frame for each step runs. Without an editor, the world always runs. The mode also decides what the viewport shows over the
// game: the editor's overlays and the debug layer draw only in Edit.

// Session_Mode is the mode that the editor set, with what each mode holds: the steps that wait for a paused frame.
// change_mode is its one writer (see docs/overview/conventions.md#state-with-a-lifecycle). Its zero value is Edit, in
// which a session starts.
Session_Mode :: union #no_nil {
	Mode_Edit,
	Mode_Play,
	Mode_Paused,
	Mode_Render,
}

Mode_Edit :: struct {}

Mode_Play :: struct {}

// Mode_Paused counts the Step_Frame messages that wait for a paused frame.
Mode_Paused :: struct {
	steps: int,
}

// Mode_Render is a render out, in which the world runs as in Play, a frame of the run at a time (see render_out.odin).
Mode_Render :: struct {
	run: Render_Run,
}

// mode_of is the link's name of a session's mode. A render out runs the world as Play does, and the editor knows it as
// Play too.
mode_of :: proc(m: Session_Mode) -> link.Editor_Mode {
	switch _ in m {
	case Mode_Edit:
		return .Edit
	case Mode_Play:
		return .Play
	case Mode_Paused:
		return .Paused
	case Mode_Render:
		return .Play
	}
	return .Edit
}

// mode is the editor's mode, or Play without an editor.
mode :: proc(e: ^Editor) -> link.Editor_Mode {
	return mode_of(e.session.mode) if active(e) else .Play
}

// change_mode is the one writer of the session's mode, for the editor's Set_Mode. Play and Pause start from the
// document's world, and Edit waits for the editor's scene, which ends the overrides too. It gives whether the end of the
// overrides despawned entities.
change_mode :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	to: link.Editor_Mode,
) -> (
	despawned: bool,
) {
	from := mode_of(e.session.mode)
	if m, rendering := &e.session.mode.(Mode_Render); rendering {
		// A render out ends with any mode that the editor sets, as Stop does.
		end_render_run(e, w, &m.run)
		from = .Edit
	}
	if end_overrides(e, w, link.Override_End_Reason.Mode) {
		despawned = true
		forget_dead(w, &e.session.view.selection)
		forget_dead(w, &e.session.view.hidden)
	}
	switch to {
	case .Edit:
		e.session.mode = Mode_Edit{}
	case .Play:
		e.session.mode = Mode_Play{}
	case .Paused:
		// A pause of a pause keeps the steps that wait.
		if _, paused := e.session.mode.(Mode_Paused); !paused {
			e.session.mode = Mode_Paused{}
		}
	}
	// The world runs, or stops as it is, and the editor sends its scene again before Edit edits it. The edits that
	// follow in this poll run no script code outside Play, but the edit-mode behaviours' in Edit.
	e.session.mirror = nil
	if scripts != nil {
		script.set_callbacks(scripts, callbacks_between_frames(e))
		// Each Play from Edit draws the same numbers (see docs/scripting/api.md#random).
		if from == .Edit && to == .Play {
			script.restart_random(scripts)
		}
	}
	return
}

// enter_render leaves Edit for a render out, as Play leaves it: the overrides and the cutscene preview end, the editor
// sends its scene again after the run, and the scripts get every callback, with the numbers that a Play draws.
@(private)
enter_render :: proc(e: ^Editor, w: ^ecs.World, scripts: ^script.Runtime, run: Render_Run) -> (despawned: bool) {
	if end_overrides(e, w, link.Override_End_Reason.Mode) {
		despawned = true
		forget_dead(w, &e.session.view.selection)
		forget_dead(w, &e.session.view.hidden)
	}
	e.session.mode = Mode_Render{run}
	e.session.mirror = nil
	if scripts != nil {
		script.set_callbacks(scripts, callbacks_between_frames(e))
		script.restart_random(scripts)
	}
	return
}

// world_loads counts the times that the editor replaced the game's world with its scene, at Play, at Stop and when it
// opens a scene. What the game keeps for one world, such as its views, starts again when it changes: the old world's
// behaviours end without their callbacks then, so they cannot undo what they set.
world_loads :: proc(e: ^Editor) -> u64 {
	return e.loads
}

// editing is true while a linked editor is in Edit: the editor's outline, gizmo, icons and helpers draw only then.
editing :: proc(e: ^Editor) -> bool {
	return active(e) && mode_of(e.session.mode) == .Edit
}

// debug_shown is whether the game's frame draws its debug layer when no viewport draws it: always without an editor,
// and only while editing with one, so it shows what the game shows in Play and Paused. A scene view always has the debug
// layer, and the Game view never has one (see plan_view).
debug_shown :: proc(e: ^Editor) -> bool {
	return !active(e) || mode_of(e.session.mode) == .Edit
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
	if m, rendering := &e.session.mode.(Mode_Render); rendering && active(e) {
		return render_simulation(&m.run, dt)
	}
	switch mode(e) {
	case .Play:
		return .Run, dt
	case .Paused:
		if paused := &e.session.mode.(Mode_Paused); paused.steps > 0 {
			paused.steps -= 1
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
