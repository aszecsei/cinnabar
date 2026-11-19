package scene

import "core:strings"

import "cinnabar:engine/ecs"

// move_entities moves an entity of the loaded scene from, with its descendants, to the loaded scene to: a part of the
// same scene, for the editor's Set Sublevel (see docs/editor/document-and-scenes.md#parts). They keep their handles.
// Their Scene_Entity, the two scenes' maps of scene IDs, the links that their fields hold, and the links of any scene
// that are bound to them follow. A field that names an entity in the scene that it has just left is not made a link:
// the editor sends such a field again. It gives how many entities moved, or false when either scene is not loaded or
// the entity is not in from.
move_entities :: proc(
	w: ^ecs.World,
	s: ^Scenes,
	root: ecs.Entity,
	from, to: u32,
) -> (
	moved: int,
	ok: bool,
) {
	from_index := find_loaded(s, from) or_return
	if !is_loaded(s, to) || key_of(w, root).scene != from {
		return 0, false
	}
	if from == to {
		return 0, true
	}
	from_handles, to_handles := handles_of(s, from), handles_of(s, to)
	subtree := make(map[ecs.Entity]struct{}, w.platform.frame_allocator)
	for id, entity in from_handles {
		if !descends_from(w, entity, root) {
			continue
		}
		subtree[entity] = {}
		to_handles[id] = entity
	}
	for entity in subtree {
		key := (^Scene_Entity)(ecs.get_raw(w, entity, SCENE_ENTITY_ID))
		delete_key(from_handles, key.id)
		key.scene = to
		ecs.mark_changed(w, entity, SCENE_ENTITY_ID)
	}

	// The links that the moved entities' fields hold go to the new scene's row, in its memory.
	to_index, _ := find_loaded(s, to)
	held := &s.loaded[from_index].links
	to_links := &s.loaded[to_index].links
	allocator := allocator_of(s, to)
	for i := len(held) - 1; i >= 0; i -= 1 {
		link := held[i]
		if _, moving := subtree[slot_entity(link.slot)]; !moving {
			continue
		}
		if behaviour, is_behaviour := link.slot.(Behaviour_Slot); is_behaviour {
			behaviour.field = strings.clone(behaviour.field, allocator)
			link.slot = behaviour
		}
		if to_links.allocator.procedure == nil {
			to_links^ = make([dynamic]Scene_Link, allocator)
		}
		append(to_links, link)
		unordered_remove(held, i)
	}

	// The links bound to them now name the new scene, and its GUID, as the cooker would write them.
	guid := s.loaded[to_index].guid
	for &row in s.loaded {
		for &link in row.links {
			bound, is_bound := link.state.(Link_Bound)
			if !is_bound || bound.scene != from {
				continue
			}
			if _, moving := subtree[bound.entity]; moving {
				link.state = Link_Bound{to, bound.entity}
				link.target = guid
			}
		}
	}
	return len(subtree), true
}

// scene_size is how many entities the map of the scene with the number has.
scene_size :: proc(s: ^Scenes, number: u32) -> int {
	return len(handles_of(s, number))
}

@(private = "file")
descends_from :: proc(w: ^ecs.World, entity, root: ecs.Entity) -> bool {
	for at := entity; at != 0; {
		if at == root {
			return true
		}
		parent := (^ecs.Parent)(ecs.get_raw(w, at, ecs.PARENT_ID))
		if parent == nil {
			return false
		}
		at = parent.entity
	}
	return false
}

@(private = "file")
slot_entity :: proc(slot: Link_Slot) -> ecs.Entity {
	switch v in slot {
	case Component_Slot:
		return v.entity
	case Behaviour_Slot:
		return v.entity
	}
	return 0
}
