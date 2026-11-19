package editor

import "base:runtime"
import "core:fmt"
import "core:log"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// apply_operations applies the editor's edits to the world, in order, and adds what it cannot apply to problems.
// The editor's document already has them, so nothing is sent back but the problems. It gives whether a part that
// Set_Sublevel emptied unloaded, which the systems that keep data by entity must then hear of, as for Remove_Scene.
@(private)
apply_operations :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	operations: []link.Operation,
	reported: ^[dynamic]link.Edit_Problem,
) -> (
	unloaded: bool,
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
		case .Set_Sublevel:
			if set_sublevel(e, w, scripts, op, entity, problems) {
				unloaded = true
			}
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
	return
}

// set_sublevel moves an entity of a part, with its descendants, to another part of the same scene's base, and keeps
// their handles (see docs/editor/document-and-scenes.md#parts). The part that it moves to loads, empty, if it is not
// loaded, and the part that it leaves unloads if it has no entity left. It gives whether that part unloaded.
@(private = "file")
set_sublevel :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	op: link.Operation,
	entity: ecs.Entity,
	problems: ^[dynamic]scene.Problem,
) -> (
	unloaded: bool,
) {
	base, has_base := scene.base_of(e.scenes, op.scene)
	if !has_base {
		append(problems, scene.Problem{op.entity, "its scene is not in the game's world"})
		return
	}
	if !scene.is_loaded(e.scenes, op.target) {
		if op.sublevel == "" {
			append(
				problems,
				scene.Problem{op.entity, "the base that it moves to is not in the game's world"},
			)
			return
		}
		of := scene.Part_Of{base, format.sublevel_name(op.sublevel)}
		if _, ok := scene.add_scene(
			w,
			scripts,
			e.scenes,
			format.Scene{guid = format.Guid(op.guid)},
			op.target,
			nil,
			of,
		); !ok {
			append(
				problems,
				scene.Problem{op.entity, "the game cannot add the part of its new sublevel"},
			)
			return
		}
	}
	if target_base, _ := scene.base_of(e.scenes, op.target); target_base != base {
		append(problems, scene.Problem{op.entity, "the part that it moves to is another scene's"})
		return
	}
	if _, ok := scene.move_entities(w, e.scenes, entity, op.scene, op.target); !ok {
		append(problems, scene.Problem{op.entity, "the game cannot move it to its new part"})
		return
	}
	if _, is_part := scene.sublevel_of(e.scenes, op.scene);
	   is_part && scene.scene_size(e.scenes, op.scene) == 0 {
		scene.unload_scene(w, e.scenes, op.scene)
		unloaded = true
	}
	return
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
	scene.unload_level(w, e.scenes)
	for s in m.scenes {
		add_editor_scene(e, w, scripts, s, problems)
	}
	log.infof("editor: loaded %d scenes, %d entities", len(m.scenes), ecs.entity_count(w))
}

// add_editor_scene adds one of the editor's scenes to the world with its number, beside the scenes that are loaded,
// whose entities stay as they are. What the world cannot use goes to problems, and so does a scene that the world
// refuses (see scene.add_scene), which adds nothing.
@(private)
add_editor_scene :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	s: link.Loaded_Scene,
	problems: ^[dynamic]link.Edit_Problem,
) -> bool {
	allocator := e.platform.frame_allocator
	entities := make([]format.Scene_Entity, len(s.entities), allocator)
	for entity, j in s.entities {
		entities[j] = scene_entity_of(entity, allocator)
	}
	found := make([dynamic]scene.Problem, allocator)
	// A part names its base, which the editor sends before it (see docs/editor/document-and-scenes.md#parts).
	of: Maybe(scene.Part_Of)
	if s.base != 0 {
		of = scene.Part_Of{s.base, format.sublevel_name(s.sublevel)}
	}
	_, ok := scene.add_scene(
		w,
		scripts,
		e.scenes,
		format.Scene{entities = entities, guid = format.Guid(s.guid)},
		s.scene,
		&found,
		of,
	)
	for p in found {
		append(
			problems,
			link.Edit_Problem{scene = s.scene, entity = p.entity, message = p.message},
		)
	}
	if !ok {
		append(
			problems,
			link.Edit_Problem {
				scene = s.scene,
				message = fmt.aprintf(
					"the game cannot add the scene %d: a scene with its number is loaded, its base is not, or as many scenes are loaded as it holds",
					s.scene,
					allocator = allocator,
				),
			},
		)
	}
	return ok
}

// remove_editor_scene despawns the entities of one of the editor's scenes, and what they own, and the other scenes'
// entities stay as they are. It reports whether the scene was loaded. The systems that keep data by entity must forget
// the despawned ones before the next frame (see game.forget_despawned).
@(private)
remove_editor_scene :: proc(e: ^Editor, w: ^ecs.World, number: u32) -> bool {
	if !scene.is_loaded(e.scenes, number) {
		log.warnf("editor: the scene %d is not loaded", number)
		return false
	}
	despawned := scene.unload_scene(w, e.scenes, number)
	log.infof("editor: removed scene %d, %d entities", number, despawned)
	return true
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
