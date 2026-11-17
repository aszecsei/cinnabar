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
	if !scene.has_maps(e.scenes) {
		scene.index(e.scenes, w)
	}
	found := make([dynamic]scene.Problem, allocator)
	problems := &found
	for op in operations {
		// An operation names its scene, whose IDs its entity, its parent and its references are.
		handles := scene.handles_of(e.scenes, op.scene)
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
			scene.add_entities(w, scripts, created, handles, problems, op.scene, e.scenes)
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
		entity := scene.find(e.scenes, w, op.scene, op.entity)
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
			scene.release_slots(e.scenes, w, entity)
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
			} else if parent := scene.find(e.scenes, w, op.scene, op.parent); parent != 0 {
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
					e.scenes,
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
				scene.release_slots(e.scenes, w, entity, ecs.Component_Id(op.component))
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
					e.scenes,
				)
			}
		case .Add_Behaviour:
			if scripts == nil {
				continue
			}
			values := make([dynamic]script.Behaviour_Field, allocator)
			for f in fields_of(op.fields, allocator) {
				if field, ok := scene.behaviour_field(
					w,
					op.entity,
					f,
					handles,
					problems,
					e.scenes,
					entity,
					guid,
				); ok {
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
				scene.release_behaviour_slots(e.scenes, w, entity, guid)
				script.detach_script(scripts, entity, guid)
			}
		case .Set_Behaviour_Field, .Reset_Behaviour_Field:
			if scripts == nil {
				continue
			}
			for f in fields_of(op.fields, allocator) {
				if problem := scene.set_behaviour_field(
					w,
					scripts,
					e.scenes,
					entity,
					op.entity,
					guid,
					f,
					op.kind == .Reset_Behaviour_Field,
					handles,
					problems,
				); problem != "" {
					append(problems, scene.Problem{op.entity, problem})
				}
			}
		}
	}
	ecs.update_activity(w)
}

// load_scenes unloads the level and replaces every entity in the world with the editor's scenes, each with its own
// number and scene IDs, and adds what the world cannot use to problems. The world lists each scene's GUID, and the
// navmeshes of each load (see docs/editor/document-and-scenes.md#several-scenes).
@(private)
load_scenes :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	m: link.Load_Scene,
	problems: ^[dynamic]link.Edit_Problem,
) {
	allocator := e.platform.frame_allocator
	scene.unload_level(w, e.scenes)
	found := make([dynamic]scene.Problem, allocator)
	for s in m.scenes {
		entities := make([]format.Scene_Entity, len(s.entities), allocator)
		for entity, j in s.entities {
			entities[j] = scene_entity_of(entity, allocator)
		}
		clear(&found)
		scene.add_scene(
			w,
			scripts,
			e.scenes,
			format.Scene{entities = entities, guid = format.Guid(s.guid)},
			s.scene,
			&found,
		)
		for p in found {
			append(
				problems,
				link.Edit_Problem{scene = s.scene, entity = p.entity, message = p.message},
			)
		}
	}
	log.infof("editor: loaded %d scenes, %d entities", len(m.scenes), ecs.entity_count(w))
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
				scene = format.Guid(v.scene),
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
