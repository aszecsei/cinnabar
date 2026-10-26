package ecs

import "core:log"
import "core:mem"

DISABLED_ID :: Component_Id(5)
INACTIVE_ID :: Component_Id(6)

// Disabled marks an entity that was deactivated itself, like a GameObject with activeSelf false. Change it only with
// set_active.
Disabled :: struct {}

// Inactive marks an entity that has Disabled or an inactive ancestor. The world maintains it. A query skips Inactive
// entities unless one of its terms names Inactive. See docs/world/ecs.md#queries.
Inactive :: struct {}

MAX_LOG :: 1 << 16
MAX_WATCHED :: 8

Log_Kind :: enum u8 {
	// A watched component was removed, or its entity despawned. data holds its first 8 bytes.
	Removed,
	// The entity became active in the hierarchy, or inactive.
	Activated,
	Deactivated,
}

// Log_Entry is a change that the script runtime reacts to. It drains the log with take_log.
Log_Entry :: struct {
	entity: Entity,
	id:     Component_Id,
	data:   u64,
	kind:   Log_Kind,
}

// watch makes the world log the removals of these components, and if activity is set, every change of Inactive.
// Nothing is logged without it, so a game without scripts keeps no log.
watch :: proc(w: ^World, ids: []Component_Id, activity: bool) {
	assert(len(ids) <= MAX_WATCHED, "ecs: too many watched components")
	w.watched_count = copy(w.watched[:], ids)
	w.log_activity = activity
}

// take_log copies the log into allocator and empties it.
take_log :: proc(w: ^World, allocator := context.allocator) -> []Log_Entry {
	entries := make([]Log_Entry, w.log_count, allocator)
	copy(entries, ([^]Log_Entry)(w.log.base)[:w.log_count])
	w.log_count = 0
	return entries
}

@(private)
log_append :: proc(w: ^World, entry: Log_Entry) {
	if w.log_count == MAX_LOG {
		if !w.log_full {
			log.errorf("ecs: the log has more than %d entries, so later ones are lost. Drain it every frame.", MAX_LOG)
			w.log_full = true
		}
		return
	}
	if !region_commit(&w.log, w.platform, int(w.log_count + 1) * size_of(Log_Entry)) {
		panic("ecs: cannot commit the log")
	}
	([^]Log_Entry)(w.log.base)[w.log_count] = entry
	w.log_count += 1
	w.log_full = false
}

// log_removal logs the removal of a component at a row, if the component is watched.
@(private)
log_removal :: proc(w: ^World, e: Entity, index: u32, column: u32) {
	a := archetype(w, index)
	id := a.ids[column]
	for watched in w.watched[:w.watched_count] {
		if watched != id {
			continue
		}
		data: u64
		if a.sizes[column] > 0 {
			record := live_record(w, e)
			mem.copy(&data, component_at(w, index, column, record.row), min(int(a.sizes[column]), size_of(u64)))
		}
		log_append(w, {entity = e, id = id, data = data, kind = .Removed})
	}
}

// log_despawn logs the removal of every watched component of an entity that is despawned.
@(private)
log_despawn :: proc(w: ^World, e: Entity, record: ^Entity_Record) {
	if w.watched_count == 0 {
		return
	}
	a := archetype(w, record.archetype)
	for column in 0 ..< a.component_count {
		log_removal(w, e, record.archetype, column)
	}
}

// set_active activates or deactivates an entity and its descendants, like Unity's SetActive. It returns false if the
// entity is not alive.
set_active :: proc(w: ^World, e: Entity, active: bool) -> bool {
	if !is_alive(w, e) {
		return false
	}
	if active {
		remove_raw(w, e, DISABLED_ID)
	} else if !has_raw(w, e, DISABLED_ID) {
		add_raw(w, e, DISABLED_ID, nil)
	}
	update_activity(w)
	return true
}

// active_self is false for an entity that was deactivated itself.
active_self :: proc(w: ^World, e: Entity) -> bool {
	return is_alive(w, e) && !has_raw(w, e, DISABLED_ID)
}

// active_in_hierarchy is false for an entity that is Inactive.
active_in_hierarchy :: proc(w: ^World, e: Entity) -> bool {
	return is_alive(w, e) && !has_raw(w, e, INACTIVE_ID)
}

// update_activity gives Inactive to every entity that has Disabled or an inactive ancestor, and takes it from the
// others. apply and set_active call it. Code that adds or removes Parent or Disabled without them calls it before
// the next query. It does nothing if no Disabled or Parent changed since it last ran.
update_activity :: proc(w: ^World) {
	if !w.activity_dirty || registry_find(&w.registry, INACTIVE_ID) == nil {
		return
	}
	w.activity_dirty = false
	if w.hierarchy_dirty && registry_find(&w.registry, PARENT_ID) != nil {
		rebuild_hierarchy(w)
	}

	// Roots first: a root is inactive when it has Disabled. The handles are collected before any of them moves.
	roots := make([dynamic]Entity, w.platform.frame_allocator)
	for index in 0 ..< w.archetype_count {
		a := archetype(w, index)
		_, disabled := column_index(a, DISABLED_ID)
		_, inactive := column_index(a, INACTIVE_ID)
		_, child := column_index(a, PARENT_ID)
		if (disabled || inactive) && !child {
			for row in 0 ..< a.count {
				append(&roots, entity_at(w, index, row)^)
			}
		}
	}
	for e in roots {
		set_inactive(w, e, has_raw(w, e, DISABLED_ID))
	}

	// Then children, in depth order, so each parent is already up to date.
	children := ([^]Entity)(w.hierarchy.base)[:w.levels[MAX_HIERARCHY_DEPTH]]
	for e in children {
		parent := (^Parent)(get_raw(w, e, PARENT_ID))
		if parent == nil {
			continue
		}
		set_inactive(w, e, has_raw(w, e, DISABLED_ID) || has_raw(w, parent.entity, INACTIVE_ID))
	}
}

@(private = "file")
set_inactive :: proc(w: ^World, e: Entity, inactive: bool) {
	if has_raw(w, e, INACTIVE_ID) == inactive {
		return
	}
	if inactive {
		add_raw(w, e, INACTIVE_ID, nil)
	} else {
		remove_raw(w, e, INACTIVE_ID)
	}
	if w.log_activity {
		log_append(w, {entity = e, kind = inactive ? .Deactivated : .Activated})
	}
}
