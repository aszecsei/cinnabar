package game

import "core:log"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// Sublevel_State is where a sublevel is (see docs/world/sublevels.md#the-active-set). An inactive sublevel's parts are
// not loaded. A sublevel that is loading is active, and some of its parts are not ready yet. An active one has all of
// its parts of the loaded scenes ready. A failed one is active, and one of its parts did not load. Change it only with
// change_sublevel.
Sublevel_State :: enum u8 {
	Inactive,
	Loading,
	Active,
	Failed,
}

// Sublevel_Event_Kind is what happened to a sublevel.
Sublevel_Event_Kind :: enum u8 {
	// Its parts began to load: it was activated, or a scene that loaded brought parts of it.
	Loading,
	// Its parts of every loaded scene are ready.
	Ready,
	// It was deactivated, and its parts unloaded.
	Unloaded,
	// One of its parts did not load.
	Failed,
}

// Sublevel_Event is something that happened to a sublevel in this frame.
Sublevel_Event :: struct {
	kind:     Sublevel_Event_Kind,
	sublevel: format.Sublevel_Name,
}

// Sublevels is the level's active set: each sublevel that the project declares, and its state. Each level starts with
// the project's settings (see follow_level). The events use the heap.
Sublevels :: struct {
	// The level generation that the states were set in.
	level:  u64,
	count:  int,
	names:  [format.MAX_SUBLEVELS]format.Sublevel_Name,
	states: [format.MAX_SUBLEVELS]Sublevel_State,
	events: [dynamic]Sublevel_Event,
}

// Sublevel_Change is a sublevel to activate or deactivate, which set_sublevel asked for.
Sublevel_Change :: struct {
	sublevel: format.Sublevel_Name,
	active:   bool,
}

// set_sublevel asks for a sublevel to be active or not. The change applies at the start of the next frame, or of this one
// from begin_frame, with load_scene's requests (see docs/world/sublevels.md#activation). Activating loads the
// sublevel's part of every loaded scene in stages. Deactivating unloads them, with what they own. It gives false, and
// asks nothing, for a sublevel that the project does not declare.
set_sublevel :: proc(g: ^Game, name: string, active: bool) -> bool {
	if _, known := sublevel_index(g, name); !known {
		log.errorf("game: the project declares no sublevel %q", name)
		return false
	}
	append(&g.scene_requests, Sublevel_Change{format.sublevel_name(name), active})
	return true
}

// sublevel_state is the state of a sublevel, and false for one that the project does not declare.
sublevel_state :: proc(g: ^Game, name: string) -> (state: Sublevel_State, ok: bool) {
	index := sublevel_index(g, name) or_return
	return g.sublevels.states[index], true
}

// sublevel_requested is whether a sublevel was last asked to be active: by the last change that set_sublevel queued
// for it, or else by its state. It is true at once after set_sublevel activates it. It gives false for a sublevel that
// the project does not declare.
sublevel_requested :: proc(g: ^Game, name: string) -> (active: bool, ok: bool) {
	state := sublevel_state(g, name) or_return
	active = state != .Inactive
	for request in g.scene_requests {
		if change, is_change := request.(Sublevel_Change); is_change {
			sublevel := change.sublevel
			if format.sublevel_name_text(&sublevel) == name {
				active = change.active
			}
		}
	}
	return active, true
}

// sublevel_events is what happened to the sublevels in this frame, in order. They are valid until the next frame.
sublevel_events :: proc(g: ^Game) -> []Sublevel_Event {
	follow_sublevel_level(g)
	return g.sublevels.events[:]
}

// active_sublevels is the names of the sublevels that are active, loading or not, in the frame allocator.
active_sublevels :: proc(g: ^Game) -> []string {
	follow_sublevel_level(g)
	s := &g.sublevels
	names := make([dynamic]string, g.platform.frame_allocator)
	for i in 0 ..< s.count {
		if s.states[i] != .Inactive {
			append(&names, format.sublevel_name_text(&s.names[i]))
		}
	}
	return names[:]
}

@(private)
sublevel_index :: proc(g: ^Game, name: string) -> (index: int, ok: bool) {
	follow_sublevel_level(g)
	s := &g.sublevels
	for i in 0 ..< s.count {
		if format.sublevel_name_text(&s.names[i]) == name {
			return i, true
		}
	}
	return
}

// follow_sublevel_level starts the active set again from the project's settings when a new level began, since the active
// set belongs to the level. A sublevel that the settings declare since then joins the set, inactive.
@(private)
follow_sublevel_level :: proc(g: ^Game) {
	s := &g.sublevels
	if generation := g.platform.level_generation(); s.level != generation {
		reset_sublevels(s, g.project.settings.sublevels)
		s.level = generation
	}
	defaults := &g.project.settings.sublevels
	declared: for i in 0 ..< defaults.count {
		for j in 0 ..< s.count {
			if s.names[j] == defaults.names[i] {
				continue declared
			}
		}
		if s.count < format.MAX_SUBLEVELS {
			s.names[s.count] = defaults.names[i]
			s.count += 1
		}
	}
}

// reset_sublevels sets the active set to the project's settings. The sublevels that were active go inactive, and those
// that start active are Loading until their parts are ready, each with its event.
@(private)
reset_sublevels :: proc(s: ^Sublevels, defaults: format.Sublevel_Defaults) {
	for i in 0 ..< s.count {
		if s.states[i] != .Inactive {
			change_sublevel(s, i, .Inactive)
		}
	}
	// Every state is Inactive now, so only the names change.
	s.count = defaults.count
	s.names = defaults.names
	for i in 0 ..< defaults.count {
		if i in defaults.active {
			change_sublevel(s, i, .Loading)
		}
	}
}

// change_sublevel is the one writer of a sublevel's state, and emits the event of the change. A sublevel goes from
// Inactive to Loading, from Loading to Active and back, and from either to Inactive. It gives false, and changes
// nothing, for any other change.
@(private)
change_sublevel :: proc(s: ^Sublevels, index: int, to: Sublevel_State) -> bool {
	from := s.states[index]
	allowed := false
	switch from {
	case .Inactive:
		allowed = to == .Loading
	case .Loading, .Active, .Failed:
		allowed = to != from
	}
	if !allowed {
		log.errorf(
			"game: the sublevel %s cannot go from %v to %v",
			format.sublevel_name_text(&s.names[index]),
			from,
			to,
		)
		return false
	}
	s.states[index] = to
	kind: Sublevel_Event_Kind
	switch to {
	case .Inactive:
		kind = .Unloaded
	case .Loading:
		kind = .Loading
	case .Active:
		kind = .Ready
	case .Failed:
		kind = .Failed
	}
	append(&s.events, Sublevel_Event{kind, s.names[index]})
	return true
}

// apply_sublevel_change makes a sublevel active or not, as set_sublevel asked. It gives whether the parts in the table
// must change.
@(private)
apply_sublevel_change :: proc(g: ^Game, change: Sublevel_Change) -> bool {
	name := change.sublevel
	index, known := sublevel_index(g, format.sublevel_name_text(&name))
	if !known {
		return false
	}
	active := g.sublevels.states[index] != .Inactive
	if active == change.active {
		return false
	}
	if !change.active {
		// A part that did not load is tried again when the sublevel is activated again, in this frame too.
		scene.retry_sublevel(&g.scenes, format.sublevel_name_text(&name))
	}
	return change_sublevel(&g.sublevels, index, .Loading if change.active else .Inactive)
}

// update_sublevels moves each active sublevel between Loading, Active and Failed: it failed while a part of it did not
// load, and is loading while any of its parts in the table is not ready. Call it after the scenes advanced in the
// frame.
@(private)
update_sublevels :: proc(g: ^Game) {
	follow_sublevel_level(g)
	s := &g.sublevels
	loading: bit_set[0 ..< format.MAX_SUBLEVELS]
	for row in scene.loaded_scenes(&g.scenes) {
		name, is_part := scene.sublevel_of(&g.scenes, row.number)
		if !is_part {
			continue
		}
		if kind, _ := scene.stage_of(&g.scenes, row.number); kind == .Ready {
			continue
		}
		if index, known := sublevel_index(g, format.sublevel_name_text(&name)); known {
			loading += {index}
		}
	}
	for i in 0 ..< s.count {
		if s.states[i] == .Inactive {
			continue
		}
		to := Sublevel_State.Active
		if scene.sublevel_failed(&g.scenes, format.sublevel_name_text(&s.names[i])) {
			to = .Failed
		} else if i in loading {
			to = .Loading
		}
		if s.states[i] != to {
			change_sublevel(s, i, to)
		}
	}
}

// send_sublevel_events sends the frame's sublevel events to every behaviour that has their handlers:
// on_sublevel_loading, on_sublevel_ready, on_sublevel_unloaded and on_sublevel_failed, with the sublevel's name (see
// docs/world/sublevels.md#events). Call it after update_sublevels, before the script phase.
@(private)
send_sublevel_events :: proc(g: ^Game) {
	for &event in sublevel_events(g) {
		name: string
		switch event.kind {
		case .Loading:
			name = "sublevel_loading"
		case .Ready:
			name = "sublevel_ready"
		case .Unloaded:
			name = "sublevel_unloaded"
		case .Failed:
			name = "sublevel_failed"
		}
		script.broadcast(&g.scripts, name, format.sublevel_name_text(&event.sublevel))
	}
}
