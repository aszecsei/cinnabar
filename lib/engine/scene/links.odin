package scene

import "core:log"
import "core:strings"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// A link is a field that names an entity of another scene, by the scene's GUID and the entity's scene ID. The field
// reads none while that scene is not loaded, and holds the entity once the scene is ready (see
// docs/world/scenes.md#references-across-scenes). A link is in the row of the scene that holds the field, in that
// scene's memory, so it goes with its holder. This file is the only writer of a link's state.
//
// A link writes its field only while the field holds what the link wrote before. A field that a script or an edit
// has set since keeps its value, and the link ends.

// Component_Slot is a field of a component. It is found again by the hash of its name at each write, so a reloaded
// build's layout is followed.
Component_Slot :: struct {
	entity:    ecs.Entity,
	component: ecs.Component_Id,
	field:     u64,
}

// Behaviour_Slot is a declared field of a behaviour. field is in the holder's scene memory.
Behaviour_Slot :: struct {
	entity: ecs.Entity,
	script: format.Guid,
	field:  string,
}

Link_Slot :: union {
	Component_Slot,
	Behaviour_Slot,
}

// Link_Waiting is a link whose scene is not loaded: its field reads none.
Link_Waiting :: struct {}

// Link_Bound is a link that has written the entity of the scene with the number into its field.
Link_Bound :: struct {
	scene:  u32,
	entity: ecs.Entity,
}

Link_State :: union {
	Link_Waiting,
	Link_Bound,
}

Scene_Link :: struct {
	slot:   Link_Slot,
	// The GUID of the target's scene, and the target's scene ID in it.
	target: format.Guid,
	id:     u64,
	state:  Link_State,
}

// pending is the GUID of the scene that a component's field waits for, or false if it waits for none: the field
// names no other scene, or that scene is loaded.
pending :: proc(
	s: ^Scenes,
	w: ^ecs.World,
	entity: ecs.Entity,
	component: ecs.Component_Id,
	field: string,
) -> (
	target: format.Guid,
	waiting: bool,
) {
	hash := format.scene_field_hash(field)
	for link in holder_links(s, w, entity) {
		slot, is_component := link.slot.(Component_Slot)
		if is_component &&
		   slot.entity == entity &&
		   slot.component == component &&
		   slot.field == hash {
			return waiting_target(link)
		}
	}
	return
}

// pending_behaviour is the GUID of the scene that a behaviour's field waits for, as pending gives it for a component's.
pending_behaviour :: proc(
	s: ^Scenes,
	w: ^ecs.World,
	entity: ecs.Entity,
	script: format.Guid,
	field: string,
) -> (
	target: format.Guid,
	waiting: bool,
) {
	for link in holder_links(s, w, entity) {
		slot, is_behaviour := link.slot.(Behaviour_Slot)
		if is_behaviour && slot.entity == entity && slot.script == script && slot.field == field {
			return waiting_target(link)
		}
	}
	return
}

@(private = "file")
waiting_target :: proc(link: Scene_Link) -> (target: format.Guid, waiting: bool) {
	_, is_waiting := link.state.(Link_Waiting)
	return link.target, is_waiting
}

@(private = "file")
holder_links :: proc(s: ^Scenes, w: ^ecs.World, entity: ecs.Entity) -> []Scene_Link {
	if number, owned := scene_of(w, entity); owned {
		if index, found := find_loaded(s, number); found {
			return s.loaded[index].links[:]
		}
	}
	return nil
}

// release_slots ends the links of an entity's component fields, because what holds them is gone or replaced: of one
// field, with its component and the hash of its name, of a component, with only that, and of the entity, with
// neither. The fields keep what they hold. Behaviour fields end with the entity's all too; release_behaviour_slots
// ends a behaviour's.
release_slots :: proc(
	s: ^Scenes,
	w: ^ecs.World,
	entity: ecs.Entity,
	component: ecs.Component_Id = 0,
	field: u64 = 0,
) {
	release_where(s, w, entity, proc(slot: Link_Slot, a: Release) -> bool {
		switch v in slot {
		case Component_Slot:
			return(
				v.entity == a.entity &&
				(a.component == 0 || v.component == a.component) &&
				(a.field == 0 || v.field == a.field) \
			)
		case Behaviour_Slot:
			return v.entity == a.entity && a.component == 0 && a.field == 0
		}
		return false
	}, Release{entity = entity, component = component, field = field})
}

// release_behaviour_slots ends the links of a behaviour's fields: of one field, or with "", of all of them.
release_behaviour_slots :: proc(
	s: ^Scenes,
	w: ^ecs.World,
	entity: ecs.Entity,
	script: format.Guid,
	field := "",
) {
	release_where(s, w, entity, proc(slot: Link_Slot, a: Release) -> bool {
		v, is_behaviour := slot.(Behaviour_Slot)
		return(
			is_behaviour &&
			v.entity == a.entity &&
			v.script == a.script &&
			(a.name == "" || v.field == a.name) \
		)
	}, Release{entity = entity, script = script, name = field})
}

@(private = "file")
Release :: struct {
	entity:    ecs.Entity,
	component: ecs.Component_Id,
	field:     u64,
	script:    format.Guid,
	name:      string,
}

@(private = "file")
release_where :: proc(
	s: ^Scenes,
	w: ^ecs.World,
	entity: ecs.Entity,
	matches: proc(slot: Link_Slot, a: Release) -> bool,
	a: Release,
) {
	number, owned := scene_of(w, entity)
	if !owned {
		return
	}
	release_in(s, number, matches, a)
}

@(private = "file")
release_in :: proc(
	s: ^Scenes,
	number: u32,
	matches: proc(slot: Link_Slot, a: Release) -> bool,
	a: Release,
) {
	index, found := find_loaded(s, number)
	if !found {
		return
	}
	links := &s.loaded[index].links
	for i := len(links) - 1; i >= 0; i -= 1 {
		if matches(links[i].slot, a) {
			unordered_remove(links, i)
		}
	}
}

// release_slot ends the link of one slot of the scene with the number, if it has one.
@(private = "file")
release_slot :: proc(s: ^Scenes, number: u32, slot: Link_Slot) {
	index, found := find_loaded(s, number)
	if !found {
		return
	}
	links := &s.loaded[index].links
	for i := len(links) - 1; i >= 0; i -= 1 {
		if same_slot(links[i].slot, slot) {
			unordered_remove(links, i)
		}
	}
}

@(private = "file")
same_slot :: proc(a, b: Link_Slot) -> bool {
	switch x in a {
	case Component_Slot:
		y, is_component := b.(Component_Slot)
		return is_component && x == y
	case Behaviour_Slot:
		y, is_behaviour := b.(Behaviour_Slot)
		return is_behaviour && x.entity == y.entity && x.script == y.script && x.field == y.field
	}
	return false
}

// follow_reference gives a field's value for a reference, and keeps the field's link to it. A reference to the
// holder's own scene is the scene's entity, and has no link. One to another scene is its entity if that scene is
// ready, with a link that is bound, and otherwise none, with a link that waits for the scene. The caller writes the
// result into the field. The field's earlier link ends.
@(private)
follow_reference :: proc(l: ^Loader, slot: Link_Slot, v: format.Scene_Value) -> ecs.Entity {
	s := l.scenes
	holder, has_holder := -1, false
	if s != nil {
		release_slot(s, l.number, slot)
		holder, has_holder = find_loaded(s, l.number)
	}
	if v.kind != .Entity || v.entity == 0 {
		return 0
	}
	if v.scene == {} || (has_holder && s.loaded[holder].guid == v.scene) {
		return resolve(l, v.entity)
	}
	if !has_holder {
		warn(l, "it refers to an entity of another scene, which only a loaded scene can follow")
		return 0
	}
	link := Scene_Link {
		slot   = slot,
		target = v.scene,
		id     = v.entity,
		state  = Link_Waiting{},
	}
	entity: ecs.Entity
	if target, ready := ready_scene(s, v.scene, family_of(s, l.number)); ready {
		entity = find(s, l.world, target, v.entity)
		if entity == 0 {
			warn(l, "it refers to %016x, which the scene it names does not have", v.entity)
			return 0
		}
		link.state = Link_Bound{target, entity}
	}
	if behaviour, is_behaviour := link.slot.(Behaviour_Slot); is_behaviour {
		behaviour.field = strings.clone(behaviour.field, allocator_of(s, l.number))
		link.slot = behaviour
	}
	row := &s.loaded[holder]
	if row.links.allocator.procedure == nil {
		row.links = make([dynamic]Scene_Link, allocator_of(s, l.number))
	}
	append(&row.links, link)
	return entity
}

// ready_scene is the scene with the GUID that a field of a scene in the family refers to, if it is ready, and false if
// there is none. The family is a base and its parts (see base_of). A scene of the holder's own family wins, so the
// parts of two loaded copies of one scene each refer to their own (see docs/world/sublevels.md#references). With none
// in the family it is the first ready scene with the GUID, unless the GUID is one of the family's own sublevels: then
// it waits for the family's part. A scene that is still loading does not hold its entities yet.
@(private = "file")
ready_scene :: proc(s: ^Scenes, guid: format.Guid, family: u32) -> (number: u32, found: bool) {
	for row in loaded_scenes(s) {
		if row.guid == guid && family_of(s, row.number) == family {
			_, ready := row.stage.(Scene_Ready)
			return row.number, ready
		}
	}
	if sublevels, known := sublevels_of(s, family); known {
		for sublevel in sublevels {
			if sublevel.guid == guid {
				return 0, false
			}
		}
	}
	return ready_number(s, guid)
}

// ready_number is the first ready scene with the GUID, which a reference from outside any family binds to, such as a
// cutscene's possessed binding (see docs/cinematics/bindings.md#possessed-bindings). A scene that is still loading does
// not count.
ready_number :: proc(s: ^Scenes, guid: format.Guid) -> (number: u32, found: bool) {
	for row in loaded_scenes(s) {
		if _, ready := row.stage.(Scene_Ready); ready && row.guid == guid {
			return row.number, true
		}
	}
	return
}

// family_of is the base of a loaded scene, or the number itself for one that is not loaded.
@(private = "file")
family_of :: proc(s: ^Scenes, number: u32) -> u32 {
	return base_of(s, number) or_else number
}

// links_scene_ready binds the links that wait for the scene with the number, now that it is ready. A link whose field
// has changed since, or whose holder is gone, ends.
@(private)
links_scene_ready :: proc(s: ^Scenes, w: ^ecs.World, number: u32) {
	index, found := find_loaded(s, number)
	if !found {
		return
	}
	guid := s.loaded[index].guid
	for &holder in s.loaded {
		links := &holder.links
		// A holder whose own family has a scene with the GUID waits for that one.
		target, _ := ready_scene(s, guid, family_of(s, holder.number))
		for i := len(links) - 1; i >= 0; i -= 1 {
			link := &links[i]
			if _, waiting := link.state.(Link_Waiting); !waiting || link.target != guid {
				continue
			}
			if target != number {
				continue
			}
			entity := find(s, w, number, link.id)
			if entity == 0 {
				log.warnf(
					"scene: the scene %d does not have the entity %016x that a field of the scene %d refers to",
					number,
					link.id,
					holder.number,
				)
			} else if write_slot(s, w, link.slot, 0, entity) {
				link.state = Link_Bound{number, entity}
				continue
			}
			unordered_remove(links, i)
		}
	}
}

// links_scene_unloading moves the links that are bound to the scene with the number, which has just left the table:
// to the entity of another ready scene with the same GUID if there is one, and otherwise to none, waiting.
@(private)
links_scene_unloading :: proc(s: ^Scenes, w: ^ecs.World, number: u32, guid: format.Guid) {
	for &holder in s.loaded {
		replacement, has_replacement := ready_scene(s, guid, family_of(s, holder.number))
		links := &holder.links
		for i := len(links) - 1; i >= 0; i -= 1 {
			link := &links[i]
			bound, is_bound := link.state.(Link_Bound)
			if !is_bound || bound.scene != number {
				continue
			}
			to: ecs.Entity
			if has_replacement {
				to = find(s, w, replacement, link.id)
			}
			if write_slot(s, w, link.slot, bound.entity, to) {
				if to != 0 {
					link.state = Link_Bound{replacement, to}
				} else {
					link.state = Link_Waiting{}
				}
			} else {
				unordered_remove(links, i)
			}
		}
	}
}

// write_slot sets a field to entity if it holds from now, and gives whether it did.
@(private = "file")
write_slot :: proc(s: ^Scenes, w: ^ecs.World, slot: Link_Slot, from, to: ecs.Entity) -> bool {
	switch v in slot {
	case Component_Slot:
		info := ecs.registry_find(&w.registry, v.component)
		data := ecs.get_raw(w, v.entity, v.component)
		if info == nil || data == nil {
			return false
		}
		for field in component_fields(info.type, w.platform.frame_allocator) {
			if field.kind != .Entity || format.scene_field_hash(field.name) != v.field {
				continue
			}
			at := (^ecs.Entity)(uintptr(data) + uintptr(field.offset))
			if at^ != from {
				return false
			}
			at^ = to
			ecs.mark_changed(w, v.entity, v.component)
			return true
		}
	case Behaviour_Slot:
		return(
			s.scripts != nil &&
			script.swap_behaviour_entity(s.scripts, v.entity, v.script, v.field, from, to) \
		)
	}
	return false
}
