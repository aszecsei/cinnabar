package editor

import "base:runtime"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// apply_operations applies the editor's edits to the world, in order, and adds what it cannot apply to problems.
// The editor's document already has them, so nothing is sent back but the problems.
@(private)
apply_operations :: proc(e: ^Editor, w: ^ecs.World, scripts: ^script.Runtime, operations: []link.Operation, problems: ^[dynamic]scene.Problem) {
	allocator := e.platform.frame_allocator
	if len(e.by_scene_id) == 0 {
		index_by_scene_id(e, w)
	}
	for op in operations {
		if op.kind == .Create_Entity {
			created := make([]format.Scene_Entity, len(op.created), allocator)
			for c, i in op.created {
				created[i] = scene_entity_of(c, allocator)
			}
			scene.add_entities(w, scripts, created, &e.by_scene_id, problems)
			continue
		}
		entity := find_scene_entity(e, w, op.entity)
		if entity == 0 {
			// Destroying a parent destroys its children, so their own operations find nothing.
			if op.kind != .Destroy_Entity {
				append(problems, scene.Problem{op.entity, "the game has no entity with this scene ID, so an edit is not applied"})
			}
			continue
		}
		guid := format.Guid(op.script)
		switch op.kind {
		case .Create_Entity:
		case .Destroy_Entity:
			ecs.despawn(w, entity)
			delete_key(&e.by_scene_id, op.entity)
		case .Rename:
			if op.name == "" {
				ecs.remove(w, entity, ecs.Name)
			} else {
				ecs.add(w, entity, ecs.make_name(op.name))
			}
		case .Set_Parent:
			if op.parent == 0 {
				ecs.remove(w, entity, ecs.Parent)
			} else if parent := find_scene_entity(e, w, op.parent); parent != 0 {
				ecs.add(w, entity, ecs.Parent{parent})
			} else {
				append(problems, scene.Problem{op.entity, "its new parent is not in the game's world"})
			}
		case .Set_Active:
			if op.active {
				ecs.remove(w, entity, ecs.Disabled)
			} else {
				ecs.add(w, entity, ecs.Disabled{})
			}
		case .Add_Component:
			for c in op.components {
				scene.add_component(w, entity, op.entity, component_of(c, allocator), &e.by_scene_id, problems)
			}
		case .Remove_Component:
			if scene.is_derived(ecs.Component_Id(op.component)) {
				append(problems, scene.Problem{op.entity, "the world keeps this component itself, so it is not removed"})
			} else {
				ecs.remove_raw(w, entity, ecs.Component_Id(op.component))
			}
		case .Set_Field, .Reset_Field:
			for f in fields_of(op.fields, allocator) {
				scene.set_field(w, entity, op.entity, op.component, f, op.kind == .Reset_Field, &e.by_scene_id, problems)
			}
		case .Add_Behaviour:
			if scripts == nil {
				continue
			}
			values := make([dynamic]script.Behaviour_Field, allocator)
			for f in fields_of(op.fields, allocator) {
				if field, ok := scene.behaviour_field(w, op.entity, f, &e.by_scene_id, problems); ok {
					append(&values, field)
				}
			}
			if !script.attach_script(scripts, entity, guid, values[:]) {
				append(problems, scene.Problem{op.entity, "its behaviour cannot be attached; the log says why"})
			}
		case .Remove_Behaviour:
			if scripts != nil {
				script.detach_script(scripts, entity, guid)
			}
		case .Set_Behaviour_Field, .Reset_Behaviour_Field:
			if scripts == nil {
				continue
			}
			for f in fields_of(op.fields, allocator) {
				field := script.Behaviour_Field {
					name = f.name,
				}
				if op.kind == .Set_Behaviour_Field {
					ok: bool
					field, ok = scene.behaviour_field(w, op.entity, f, &e.by_scene_id, problems)
					if !ok {
						continue
					}
				}
				if problem := script.set_behaviour_field(scripts, entity, guid, field, reset = op.kind == .Reset_Behaviour_Field); problem != "" {
					append(problems, scene.Problem{op.entity, problem})
				}
			}
		}
	}
	ecs.update_activity(w)
}

// find_scene_entity is the entity with a scene ID, or 0. A handle that the map has but that is gone, or that
// another entity's slot now holds, makes the map be built again.
@(private)
find_scene_entity :: proc(e: ^Editor, w: ^ecs.World, id: u64) -> ecs.Entity {
	if entity, ok := e.by_scene_id[id]; ok && scene_id_of(w, entity) == id {
		return entity
	}
	index_by_scene_id(e, w)
	return e.by_scene_id[id] or_else 0
}

// index_by_scene_id maps every entity that a scene made from its scene ID. The game's own scene load, at init,
// does not fill the map, so the first edit builds it.
@(private)
index_by_scene_id :: proc(e: ^Editor, w: ^ecs.World) {
	clear(&e.by_scene_id)
	it := ecs.world_iter(w)
	for entity in ecs.world_next(&it) {
		if id := scene_id_of(w, entity); id != 0 {
			e.by_scene_id[id] = entity
		}
	}
}

@(private)
scene_id_of :: proc(w: ^ecs.World, entity: ecs.Entity) -> u64 {
	s := (^scene.Scene_Entity)(ecs.get_raw(w, entity, scene.SCENE_ENTITY_ID))
	return s.id if s != nil else 0
}

// The editor's scene types convert to the loader's. Strings and slices still point into the message.

@(private)
scene_of :: proc(m: link.Load_Scene, allocator: runtime.Allocator) -> format.Scene {
	entities := make([]format.Scene_Entity, len(m.entities), allocator)
	for e, i in m.entities {
		entities[i] = scene_entity_of(e, allocator)
	}
	return {entities = entities}
}

@(private)
scene_entity_of :: proc(e: link.Scene_Entity, allocator: runtime.Allocator) -> format.Scene_Entity {
	components := make([]format.Scene_Component, len(e.components), allocator)
	for c, j in e.components {
		components[j] = component_of(c, allocator)
	}
	behaviours := make([]format.Scene_Behaviour, len(e.behaviours), allocator)
	for b, j in e.behaviours {
		behaviours[j] = {script = format.Guid(b.script), fields = fields_of(b.fields, allocator)}
	}
	return {id = e.id, name = e.name, parent = e.parent, active = e.active, components = components, behaviours = behaviours}
}

@(private)
component_of :: proc(c: link.Scene_Component, allocator: runtime.Allocator) -> format.Scene_Component {
	return {id = c.id, name = c.name, fields = fields_of(c.fields, allocator)}
}

@(private)
fields_of :: proc(fields: []link.Scene_Field, allocator: runtime.Allocator) -> []format.Scene_Field {
	result := make([]format.Scene_Field, len(fields), allocator)
	for f, i in fields {
		v := f.value
		result[i] = {
			name = f.name,
			hash = format.scene_field_hash(f.name),
			value = {
				kind = format.Scene_Value_Kind(v.kind),
				count = v.count,
				integer = v.integer,
				ints = v.ints,
				floats = v.floats,
				text = v.text,
				entity = v.entity,
			},
		}
	}
	return result
}

// edit_problems is the message for problems, with their text in allocator.
@(private)
edit_problems :: proc(problems: []scene.Problem, snapshot: bool, allocator: runtime.Allocator) -> link.Edit_Problems {
	result := make([]link.Edit_Problem, len(problems), allocator)
	for p, i in problems {
		result[i] = {entity = p.entity, message = p.message}
	}
	return {snapshot = snapshot, problems = result}
}
