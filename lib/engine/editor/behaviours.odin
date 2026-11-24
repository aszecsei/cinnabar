package editor

import "base:runtime"
import "core:log"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// The edit-mode behaviours' edits (see docs/editor/document-and-scenes.md#behaviours-edits). In Edit, the script runtime
// records what they write to the document's entities. The game turns the records into operations by scene ID and sends
// them to the editor, which applies them to its document and sends them back, as for a game command, and then answers.
// While the answer is due, the frame runs no edit phase (see simulation), so a behaviour sees its own edits before it
// runs again.

// send_behaviour_edits takes what the edit-mode behaviours did since the last call, and queues it for the editor as
// one Behaviour_Operations, which poll sends. It despawns their drafts, whose entities the editor makes. Call it after
// the edit phase, after the frame's hot reload, and after poll's edits, as each can run their code.
send_behaviour_edits :: proc(e: ^Editor, w: ^ecs.World, scripts: ^script.Runtime) {
	if scripts == nil {
		return
	}
	edits := script.take_edits(scripts)
	if len(edits.list) == 0 {
		return
	}
	// The behaviours edited the document, so they ran with the overrides off the world (see overrides.odin).
	if e.session.overrides.layer != .Lifted && len(e.session.overrides.live) > 0 {
		log.errorf(
			"editor: behaviours edited while the overrides were on the world, so their edits are not sent",
		)
		return
	}
	defer for edit in edits.list {
		if spawn, is_spawn := edit.(script.Edit_Spawn); is_spawn && ecs.is_alive(w, spawn.entity) {
			ecs.despawn(w, spawn.entity)
		}
	}
	m, mirrors := &e.session.mirror.?
	if !mirrors {
		return
	}
	operations := operations_of(w, edits, e.platform.frame_allocator, e.scenes)
	if len(operations) == 0 {
		return
	}
	e.session.edit_tickets += 1
	ticket := e.session.edit_tickets
	link.write_message(
		&e.session.outbox,
		link.Behaviour_Operations {
			ticket = ticket,
			scene = m.scene,
			label = "Behaviours" if edits.several else edits.class,
			operations = operations,
		},
	)
	m.batch = Batch_Sent{ticket}
}

// answer_behaviour_operations takes the editor's answer to the behaviours' last edits. One for older edits, or for a
// world that a scene load replaced, changes nothing.
@(private)
answer_behaviour_operations :: proc(e: ^Editor, answer: link.Behaviour_Operations_Answer) {
	m, mirrors := &e.session.mirror.?
	if !mirrors {
		return
	}
	sent, waits := m.batch.(Batch_Sent)
	if !waits || sent.ticket != answer.ticket {
		return
	}
	if answer.applied {
		m.batch = nil
	} else {
		m.batch = Batch_Refused{e.platform.time_seconds() + 1}
	}
}

// operations_of turns the edits into operations by scene ID, in allocator: first the drafts, each after its parent, as
// new entities and instances, then the edits in the order the behaviours made them. With scenes, a reference to an
// entity of another scene names that scene's GUID, except for a field of a root draft, whose scene the game does not
// know.
operations_of :: proc(
	w: ^ecs.World,
	edits: script.Edits,
	allocator: runtime.Allocator,
	scenes: ^scene.Scenes = nil,
) -> []link.Operation {
	ops := make([dynamic]link.Operation, allocator)
	// The drafts' scene IDs, so the edits and the drafts' fields can name them.
	ids := make(map[ecs.Entity]u64, allocator)
	drafts := make([dynamic]script.Edit_Spawn, allocator)
	for edit in edits.list {
		if spawn, is_spawn := edit.(script.Edit_Spawn); is_spawn && ecs.is_alive(w, spawn.entity) {
			ids[spawn.entity] = new_scene_id()
			append(&drafts, spawn)
		}
	}
	// The scene of each draft is its parent's, and a root's is the editor's active scene, 0. Each draft comes after its
	// parent, so the parent's is known.
	numbers := make(map[ecs.Entity]u32, allocator)
	made := make(map[ecs.Entity]bool, allocator)
	for len(made) < len(drafts) {
		progress := false
		for d in drafts {
			parent := parent_of(w, d.entity)
			if made[d.entity] || (parent in ids && !made[parent]) {
				continue
			}
			numbers[d.entity] = number_of(w, parent, numbers)
			op := draft_operation(
				w,
				d,
				ids,
				allocator,
				scenes if numbers[d.entity] != 0 else nil,
				numbers[d.entity],
			)
			op.scene = numbers[d.entity]
			append(&ops, op)
			made[d.entity], progress = true, true
		}
		if !progress {
			break
		}
	}
	for edit in edits.list {
		// The edit's operations name the scene of the entity that it edits.
		start := len(ops)
		number := number_of(w, edited_entity(edit, edits), numbers)
		defer for &op in ops[start:] {
			op.scene = number
		}
		switch v in edit {
		case script.Edit_Component:
			component_operations(
				w,
				edits.components[v.index],
				ids,
				&ops,
				allocator,
				scenes if number != 0 else nil,
				number,
			)
		case script.Edit_Remove:
			append(
				&ops,
				link.Operation {
					kind = .Remove_Component,
					entity = id_of(w, v.entity, ids),
					component = u64(v.id),
				},
			)
		case script.Edit_Destroy:
			append(&ops, link.Operation{kind = .Destroy_Entity, entity = id_of(w, v.entity, ids)})
		case script.Edit_Parent:
			if parent_number := number_of(w, v.parent, numbers);
			   v.parent != 0 && parent_number != number {
				log.warnf(
					"editor: a behaviour set the parent of an entity to one of another scene; the edit is dropped",
				)
				continue
			}
			append(
				&ops,
				link.Operation {
					kind = .Set_Parent,
					entity = id_of(w, v.entity, ids),
					parent = id_of(w, v.parent, ids),
				},
			)
		case script.Edit_Active:
			append(
				&ops,
				link.Operation {
					kind = .Set_Active,
					entity = id_of(w, v.entity, ids),
					active = v.active,
				},
			)
		case script.Edit_Rename:
			append(
				&ops,
				link.Operation{kind = .Rename, entity = id_of(w, v.entity, ids), name = v.name},
			)
		case script.Edit_Attach:
			fields := make([dynamic]link.Scene_Field, allocator)
			for f in v.fields {
				if value, ok := behaviour_value(w, f, ids, scenes if number != 0 else nil, number);
				   ok {
					append(&fields, link.Scene_Field{name = f.name, value = value})
				}
			}
			append(
				&ops,
				link.Operation {
					kind = .Add_Behaviour,
					entity = id_of(w, v.entity, ids),
					script = ([16]u8)(v.script),
					fields = fields[:],
				},
			)
		case script.Edit_Detach:
			append(
				&ops,
				link.Operation {
					kind = .Remove_Behaviour,
					entity = id_of(w, v.entity, ids),
					script = ([16]u8)(v.script),
				},
			)
		case script.Edit_Spawn:
		}
	}
	return ops[:]
}

// component_operations adds the operations of a component that a behaviour wrote or added: the whole component for
// one that it added, and a Set_Field for each field that changed. A child's pose is its Local_Transform, as the editor
// edits it, so its Transform, which propagation computes, is no edit.
@(private = "file")
component_operations :: proc(
	w: ^ecs.World,
	c: script.Edited_Component,
	ids: map[ecs.Entity]u64,
	ops: ^[dynamic]link.Operation,
	allocator: runtime.Allocator,
	scenes: ^scene.Scenes,
	holder: u32,
) {
	info := ecs.registry_find(&w.registry, c.id)
	entity := id_of(w, c.entity, ids)
	if info == nil || entity == 0 {
		return
	}
	if c.before == nil {
		append(
			ops,
			link.Operation {
				kind = .Add_Component,
				entity = entity,
				components = component_of_bytes(
					w,
					info,
					raw_data(c.after),
					ids,
					allocator,
					scenes,
					holder,
				),
			},
		)
		return
	}
	if c.id == ecs.TRANSFORM_ID && is_child(w, c.entity) {
		return
	}
	for f in scene.encode_fields(w, info, raw_data(c.after), raw_data(c.before), ids, allocator, scenes = scenes, holder = holder) {
		fields := make([]link.Scene_Field, 1, allocator)
		fields[0] = link_field(f)
		append(
			ops,
			link.Operation {
				kind = .Set_Field,
				entity = entity,
				component = u64(c.id),
				fields = fields,
			},
		)
	}
}

// draft_operation makes a draft an entity of the document: a new entity with the components that scenes set, or for a
// prefab's stand-in, an instance with its pose.
@(private = "file")
draft_operation :: proc(
	w: ^ecs.World,
	d: script.Edit_Spawn,
	ids: map[ecs.Entity]u64,
	allocator: runtime.Allocator,
	scenes: ^scene.Scenes,
	holder: u32,
) -> link.Operation {
	id := ids[d.entity]
	parent := id_of(w, parent_of(w, d.entity), ids)
	active := !ecs.has(w, d.entity, ecs.Disabled)
	if d.prefab != {} {
		pose := ecs.LOCAL_TRANSFORM_ID if is_child(w, d.entity) else ecs.TRANSFORM_ID
		components := make([]link.Scene_Component, 1, allocator)
		if info := ecs.registry_find(&w.registry, pose); info != nil {
			components[0] =
				component_of_bytes(w, info, ecs.get_raw(w, d.entity, pose), ids, allocator, scenes, holder, all = true)[0]
		}
		return {
			kind = .Create_Instance,
			entity = id,
			parent = parent,
			active = active,
			components = components,
			prefab = ([16]u8)(d.prefab),
		}
	}
	components := make([dynamic]link.Scene_Component, allocator)
	for component in ecs.entity_components(w, d.entity) {
		info := ecs.registry_find(&w.registry, component)
		if info == nil ||
		   info.category == ecs.NO_CATEGORY ||
		   scene.is_derived(component) ||
		   component == ecs.PREVIOUS_TRANSFORM_ID ||
		   (component == ecs.TRANSFORM_ID && is_child(w, d.entity)) {
			continue
		}
		append(
			&components,
			..component_of_bytes(
				w,
				info,
				ecs.get_raw(w, d.entity, component),
				ids,
				allocator,
				scenes,
				holder,
			),
		)
	}
	created := make([]link.Scene_Entity, 1, allocator)
	created[0] = {
		id         = id,
		name       = ecs.name_of(w, d.entity, allocator),
		parent     = parent,
		active     = active,
		components = components[:],
	}
	return {kind = .Create_Entity, entity = id, created = created}
}

// component_of_bytes is a component as a scene sets it: its fields that differ from its defaults, or all of them.
@(private = "file")
component_of_bytes :: proc(
	w: ^ecs.World,
	info: ^ecs.Component_Info,
	data: rawptr,
	ids: map[ecs.Entity]u64,
	allocator: runtime.Allocator,
	scenes: ^scene.Scenes,
	holder: u32,
	all := false,
) -> []link.Scene_Component {
	encoded := scene.encode_fields(
		w,
		info,
		data,
		nil,
		ids,
		allocator,
		all = all,
		scenes = scenes,
		holder = holder,
	)
	fields := make([]link.Scene_Field, len(encoded), allocator)
	for f, i in encoded {
		fields[i] = link_field(f)
	}
	result := make([]link.Scene_Component, 1, allocator)
	result[0] = {
		id     = u64(info.id),
		name   = info.name,
		fields = fields,
	}
	return result
}

// behaviour_value is a behaviour's field as a scene sets it, or false for nil.
@(private = "file")
behaviour_value :: proc(
	w: ^ecs.World,
	f: script.Behaviour_Field,
	ids: map[ecs.Entity]u64,
	scenes: ^scene.Scenes,
	holder: u32,
) -> (
	v: link.Scene_Value,
	ok: bool,
) {
	switch f.kind {
	case .Nil:
		return {}, false
	case .Number:
		v = {
			kind = .Number,
			count = 1,
			floats = {0 = f.number},
		}
	case .Boolean:
		v = {
			kind = .Bool,
			ints = {0 = 1 if f.boolean else 0},
		}
	case .String:
		v = {
			kind = .String,
			text = f.text,
		}
	case .Vector:
		v = {
			kind   = .Number,
			count  = 3,
			floats = {f64(f.vector.x), f64(f.vector.y), f64(f.vector.z), 0},
		}
	case .Entity:
		id, other := scene.encode_entity_ref(w, f.entity, ids, scenes, holder)
		v = {
			kind   = .Entity,
			entity = id,
			scene  = ([16]u8)(other),
		}
	case .Asset:
		v = {
			kind  = .Asset,
			asset = ([16]u8)(f.asset),
		}
	}
	return v, true
}

@(private = "file")
link_field :: proc(f: format.Scene_Field) -> link.Scene_Field {
	v := f.value
	return {
		name = f.name,
		value = {
			kind = link.Scene_Value_Kind(v.kind),
			count = v.count,
			integer = v.integer,
			ints = v.ints,
			floats = v.floats,
			text = v.text,
			entity = v.entity,
			scene = ([16]u8)(v.scene),
			asset = ([16]u8)(v.asset),
		},
	}
}

// number_of is the number of an entity's scene: a draft's, or its own, or 0 for the editor's active scene.
@(private = "file")
number_of :: proc(w: ^ecs.World, entity: ecs.Entity, numbers: map[ecs.Entity]u32) -> u32 {
	if number, ok := numbers[entity]; ok {
		return number
	}
	return scene.key_of(w, entity).scene if entity != 0 else 0
}

// edited_entity is the entity that an edit changes.
@(private = "file")
edited_entity :: proc(edit: script.Edit, edits: script.Edits) -> ecs.Entity {
	switch v in edit {
	case script.Edit_Component:
		return edits.components[v.index].entity
	case script.Edit_Remove:
		return v.entity
	case script.Edit_Destroy:
		return v.entity
	case script.Edit_Parent:
		return v.entity
	case script.Edit_Active:
		return v.entity
	case script.Edit_Rename:
		return v.entity
	case script.Edit_Attach:
		return v.entity
	case script.Edit_Detach:
		return v.entity
	case script.Edit_Spawn:
		return v.entity
	}
	return 0
}

// id_of is an entity's scene ID: a draft's new one, or its own, or 0.
@(private = "file")
id_of :: proc(w: ^ecs.World, entity: ecs.Entity, ids: map[ecs.Entity]u64) -> u64 {
	return scene.scene_id_for(w, entity, ids)
}

@(private = "file")
parent_of :: proc(w: ^ecs.World, entity: ecs.Entity) -> ecs.Entity {
	parent := ecs.get(w, entity, ecs.Parent)
	return parent.entity if parent != nil else 0
}

// is_child is true for an entity whose pose is its Local_Transform.
@(private)
is_child :: proc(w: ^ecs.World, entity: ecs.Entity) -> bool {
	return ecs.has(w, entity, ecs.Parent) && ecs.has(w, entity, ecs.Local_Transform)
}
