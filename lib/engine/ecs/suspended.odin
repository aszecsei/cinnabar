package ecs

SUSPENDED_ID :: Component_Id(11)

// Suspend is a system that stops acting on an entity while something holds the entity, such as a cutscene that
// possesses it (see docs/cinematics/possession.md).
Suspend :: enum u8 {
	// The behaviours get no update, fixed_update or events, as if their enabled were false.
	Behaviours,
	// The Agent does not think or act.
	AI,
	// The Nav_Agent leaves its crowd, and its move stops.
	Navigation,
	// A dynamic body is kinematic, and a character leaves the simulation.
	Physics,
	// The Ui_Document is hidden.
	Ui,
}
Suspend_Set :: bit_set[Suspend;u8]

// Suspended counts, for each system, the holders that suspend it on the entity. Two holders both resume a system
// before it acts on the entity again. suspend and resume are its only writers, and the entity loses it when every count
// is 0. Nothing saves it, and a scene's text cannot name it.
Suspended :: struct {
	counts: [Suspend]u16 `editor:"-" script:"-"`,
}

// suspend counts one more holder of each system in a set on an entity, and gives the systems that it suspended: those
// that no holder suspended before. The script runtime learns of suspended behaviours from the log, and its next drain
// runs their on_disable.
suspend :: proc(w: ^World, e: Entity, systems: Suspend_Set) -> (started: Suspend_Set) {
	if systems == {} || !is_alive(w, e) {
		return
	}
	if get_raw(w, e, SUSPENDED_ID) == nil {
		add(w, e, Suspended{})
	}
	s := get_write(w, e, Suspended)
	if s == nil {
		return
	}
	for system in systems {
		if s.counts[system] == 0 {
			started += {system}
		}
		s.counts[system] += 1
	}
	if .Behaviours in started && w.log_activity {
		log_append(w, {entity = e, kind = .Suspended})
	}
	return
}

// resume counts one less holder of each system in a set on an entity, and gives the systems that it resumed: those
// that no holder suspends now. A system that no holder suspends stays as it is. The entity loses Suspended when no
// holder suspends anything.
resume :: proc(w: ^World, e: Entity, systems: Suspend_Set) -> (ended: Suspend_Set) {
	if systems == {} || !is_alive(w, e) || get_raw(w, e, SUSPENDED_ID) == nil {
		return
	}
	s := get_write(w, e, Suspended)
	for system in systems {
		if s.counts[system] == 0 {
			continue
		}
		s.counts[system] -= 1
		if s.counts[system] == 0 {
			ended += {system}
		}
	}
	if s.counts == {} {
		remove(w, e, Suspended)
	}
	if .Behaviours in ended && w.log_activity {
		log_append(w, {entity = e, kind = .Resumed})
	}
	return
}

// suspended is whether a holder suspends a system on an entity.
suspended :: proc(w: ^World, e: Entity, system: Suspend) -> bool {
	s := (^Suspended)(get_raw(w, e, SUSPENDED_ID))
	return s != nil && s.counts[system] > 0
}
