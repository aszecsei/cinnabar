package editor

import "base:runtime"
import "core:log"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// apply_operations applies the editor's edits to the world, in order, and adds what it cannot apply to problems.
// The editor's document already has them, so nothing is sent back but the problems.
@(private)
apply_operations :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	operations: []link.Operation,
	reported: ^[dynamic]link.Edit_Problem,
) {
	allocator := e.platform.frame_allocator
	if len(e.by_scene) == 0 {
		index_by_scene_id(e, w)
	}
	found := make([dynamic]scene.Problem, allocator)
	problems := &found
	for op in operations {
		// An operation names its scene, whose IDs its entity, its parent and its references are.
		handles := scene_handles(e, op.scene)
		clear(problems)
		defer for p in problems^ {
			append(
				reported,
				link.Edit_Problem{scene = op.scene, entity = p.entity, message = p.message},
			)
		}
		if op.kind == .Create_Entity {
			created := make([]format.Scene_Entity, len(op.created), allocator)
			for c, i in op.created {
				created[i] = scene_entity_of(c, allocator)
			}
			scene.add_entities(w, scripts, created, handles, problems, op.scene)
			continue
		}
		if op.kind == .Create_Instance {
			// Only the game sends it: the editor sends an instance's entities.
			append(
				problems,
				scene.Problem {
					op.entity,
					"the game does not make a prefab's instance from an edit",
				},
			)
			continue
		}
		entity := find_scene_entity(e, w, op.scene, op.entity)
		if entity == 0 {
			// Destroying a parent destroys its children, so their own operations find nothing.
			if op.kind != .Destroy_Entity {
				append(
					problems,
					scene.Problem {
						op.entity,
						"the game has no entity with this scene ID, so an edit is not applied",
					},
				)
			}
			continue
		}
		guid := format.Guid(op.script)
		switch op.kind {
		case .Create_Entity, .Create_Instance:
		case .Destroy_Entity:
			ecs.despawn(w, entity)
			delete_key(handles, op.entity)
		case .Rename:
			if op.name == "" {
				ecs.remove(w, entity, ecs.Name)
			} else {
				ecs.add(w, entity, ecs.make_name(op.name))
			}
		case .Set_Parent:
			if op.parent == 0 {
				ecs.remove(w, entity, ecs.Parent)
			} else if parent := find_scene_entity(e, w, op.scene, op.parent); parent != 0 {
				ecs.add(w, entity, ecs.Parent{parent})
			} else {
				append(
					problems,
					scene.Problem{op.entity, "its new parent is not in the game's world"},
				)
			}
		case .Set_Active:
			if op.active {
				ecs.remove(w, entity, ecs.Disabled)
			} else {
				ecs.add(w, entity, ecs.Disabled{})
			}
		case .Add_Component:
			for c in op.components {
				scene.add_component(
					w,
					entity,
					op.entity,
					component_of(c, allocator),
					handles,
					problems,
				)
			}
		case .Remove_Component:
			if scene.is_derived(ecs.Component_Id(op.component)) {
				append(
					problems,
					scene.Problem {
						op.entity,
						"the world keeps this component itself, so it is not removed",
					},
				)
			} else {
				ecs.remove_raw(w, entity, ecs.Component_Id(op.component))
			}
		case .Set_Field, .Reset_Field:
			for f in fields_of(op.fields, allocator) {
				scene.set_field(
					w,
					entity,
					op.entity,
					op.component,
					f,
					op.kind == .Reset_Field,
					handles,
					problems,
				)
			}
		case .Add_Behaviour:
			if scripts == nil {
				continue
			}
			values := make([dynamic]script.Behaviour_Field, allocator)
			for f in fields_of(op.fields, allocator) {
				if field, ok := scene.behaviour_field(w, op.entity, f, handles, problems); ok {
					append(&values, field)
				}
			}
			if !script.attach_script(scripts, entity, guid, values[:]) {
				append(
					problems,
					scene.Problem{op.entity, "its behaviour cannot be attached; the log says why"},
				)
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
					field, ok = scene.behaviour_field(w, op.entity, f, handles, problems)
					if !ok {
						continue
					}
				}
				if problem := script.set_behaviour_field(
					scripts,
					entity,
					guid,
					field,
					reset = op.kind == .Reset_Behaviour_Field,
				); problem != "" {
					append(problems, scene.Problem{op.entity, problem})
				}
			}
		}
	}
	ecs.update_activity(w)
}

// load_scenes replaces every entity in the world with the editor's scenes, each with its own scene IDs, and adds what
// the world cannot use to problems. The world's scene GUID is the first scene's, whose navmeshes load (see
// docs/editor/document-and-scenes.md#several-scenes).
@(private)
load_scenes :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	m: link.Load_Scene,
	problems: ^[dynamic]link.Edit_Problem,
) {
	allocator := e.platform.frame_allocator
	ecs.despawn_all(w)
	w.scene = {}
	clear_scene_handles(e)
	found := make([dynamic]scene.Problem, allocator)
	spawned := 0
	for s, i in m.scenes {
		if i == 0 {
			w.scene = format.Guid(s.guid)
		}
		entities := make([]format.Scene_Entity, len(s.entities), allocator)
		for entity, j in s.entities {
			entities[j] = scene_entity_of(entity, allocator)
		}
		clear(&found)
		spawned += scene.add_entities(
			w,
			scripts,
			entities,
			scene_handles(e, s.scene),
			&found,
			s.scene,
		)
		for p in found {
			append(
				problems,
				link.Edit_Problem{scene = s.scene, entity = p.entity, message = p.message},
			)
		}
	}
	log.infof("editor: loaded %d scenes, %d entities", len(m.scenes), spawned)
}

// find_scene_entity is the entity with a scene ID in the scene with the number, or 0. A handle that the map has but
// that is gone, or that another entity's slot now holds, makes the maps be built again.
@(private)
find_scene_entity :: proc(e: ^Editor, w: ^ecs.World, number: u32, id: u64) -> ecs.Entity {
	if handles, ok := e.by_scene[number]; ok {
		if entity, has := handles[id]; has && scene_key_of(w, entity) == {number, id} {
			return entity
		}
	}
	index_by_scene_id(e, w)
	if handles, ok := e.by_scene[number]; ok {
		return handles[id] or_else 0
	}
	return 0
}

// index_by_scene_id maps every entity that a scene made from its scene's number and its scene ID. The game's own
// scene load, at init, does not fill the maps, so the first edit builds them.
@(private)
index_by_scene_id :: proc(e: ^Editor, w: ^ecs.World) {
	clear_scene_handles(e)
	it := ecs.world_iter(w)
	for entity in ecs.world_next(&it) {
		if key := scene_key_of(w, entity); key.id != 0 {
			scene_handles(e, key.scene)[key.id] = entity
		}
	}
}

// scene_handles is the map from scene ID to entity of the scene with the number, made at its first use. It stays
// where it is while the Editor lives, so a new scene's map does not move it.
@(private)
scene_handles :: proc(e: ^Editor, number: u32) -> ^map[u64]ecs.Entity {
	if handles, ok := e.by_scene[number]; ok {
		return handles
	}
	handles := new(map[u64]ecs.Entity, e.platform.heap_allocator)
	handles^ = make(map[u64]ecs.Entity, e.platform.heap_allocator)
	e.by_scene[number] = handles
	return handles
}

// clear_scene_handles empties every scene's map, and keeps their memory.
@(private)
clear_scene_handles :: proc(e: ^Editor) {
	for _, handles in e.by_scene {
		clear(handles)
	}
}

@(private)
delete_scene_handles :: proc(e: ^Editor) {
	for _, handles in e.by_scene {
		delete(handles^)
		free(handles, e.platform.heap_allocator)
	}
	delete(e.by_scene)
}

// Scene_Key is an entity of a scene: the scene's number and the entity's scene ID, which is 0 for an entity that the
// game spawned.
Scene_Key :: struct {
	scene: u32,
	id:    u64,
}

// scene_key_of is an entity's scene and scene ID, or zero for one that the game spawned.
scene_key_of :: proc(w: ^ecs.World, entity: ecs.Entity) -> Scene_Key {
	s := (^scene.Scene_Entity)(ecs.get_raw(w, entity, scene.SCENE_ENTITY_ID))
	return {s.scene, s.id} if s != nil else {}
}

@(private)
scene_id_of :: proc(w: ^ecs.World, entity: ecs.Entity) -> u64 {
	return scene_key_of(w, entity).id
}

// The editor's scene types convert to the loader's. Strings and slices still point into the message.

@(private)
scene_entity_of :: proc(
	e: link.Scene_Entity,
	allocator: runtime.Allocator,
) -> format.Scene_Entity {
	components := make([]format.Scene_Component, len(e.components), allocator)
	for c, j in e.components {
		components[j] = component_of(c, allocator)
	}
	behaviours := make([]format.Scene_Behaviour, len(e.behaviours), allocator)
	for b, j in e.behaviours {
		behaviours[j] = {
			script = format.Guid(b.script),
			fields = fields_of(b.fields, allocator),
		}
	}
	return {
		id = e.id,
		name = e.name,
		parent = e.parent,
		active = e.active,
		components = components,
		behaviours = behaviours,
	}
}

@(private)
component_of :: proc(
	c: link.Scene_Component,
	allocator: runtime.Allocator,
) -> format.Scene_Component {
	return {id = c.id, name = c.name, fields = fields_of(c.fields, allocator)}
}

@(private)
fields_of :: proc(
	fields: []link.Scene_Field,
	allocator: runtime.Allocator,
) -> []format.Scene_Field {
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
				asset = format.Guid(v.asset),
			},
		}
	}
	return result
}

// edit_problems is the message for problems.
@(private)
edit_problems :: proc(problems: []link.Edit_Problem, snapshot: bool) -> link.Edit_Problems {
	return {snapshot = snapshot, problems = problems}
}
