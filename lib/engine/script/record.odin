package script

import "core:c"
import "core:strings"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// In the editor's Edit mode, the scene is the editor's document, so an edit-mode behaviour's writes to the document's
// entities do not change the world: the runtime records them, and the editor package turns them into operations on
// the document, which come back as edits (see docs/scripting/behaviours.md#writes-in-edit-mode). The records are plain
// data in frame memory: the game takes them in the frame that made them.

// Edited_Component is a component of a document entity that an edit-mode behaviour wrote or added: its bytes as the
// world has them, nil for one that it added, and as the script left them. Reads and writes go to after.
Edited_Component :: struct {
	entity: ecs.Entity,
	id:     ecs.Component_Id,
	before: []byte,
	after:  []byte,
}

// Edit is one thing that an edit-mode behaviour did to the document, in the order it did them.
Edit :: union {
	// A component that it wrote or added: an index into Edits.components, at the first write.
	Edit_Component,
	Edit_Remove,
	Edit_Destroy,
	Edit_Parent,
	Edit_Active,
	Edit_Attach,
	Edit_Detach,
	// A new entity: a draft in the world until the game takes the edits.
	Edit_Spawn,
}

Edit_Component :: struct {
	index: int,
}

Edit_Remove :: struct {
	entity: ecs.Entity,
	id:     ecs.Component_Id,
}

// Edit_Destroy destroys the entity and its descendants.
Edit_Destroy :: struct {
	entity: ecs.Entity,
}

// Edit_Parent gives the entity a new parent, or none (0), keeping its pose in the world.
Edit_Parent :: struct {
	entity: ecs.Entity,
	parent: ecs.Entity,
}

Edit_Active :: struct {
	entity: ecs.Entity,
	active: bool,
}

Edit_Attach :: struct {
	entity: ecs.Entity,
	script: format.Guid,
	fields: []Behaviour_Field,
}

Edit_Detach :: struct {
	entity: ecs.Entity,
	script: format.Guid,
}

// Edit_Spawn is an entity that World.spawn made: a draft whose components the game reads, or for a prefab, a stand-in
// whose pose, parent and active state the instance takes.
Edit_Spawn :: struct {
	entity: ecs.Entity,
	prefab: format.Guid,
}

// Edits are what the edit-mode behaviours did since the game last took them, and the class that did them, for the undo
// entry's label. several is true when more than one class did.
Edits :: struct {
	components: [dynamic]Edited_Component,
	list:       [dynamic]Edit,
	class:      string,
	several:    bool,
}

// set_document_component names the component that the document's entities have, scene.Scene_Entity, so the runtime
// tells them from the game's own. It is a registration: call it in the game's Register_Proc.
set_document_component :: proc(r: ^Runtime, id: ecs.Component_Id) {
	r.document_component = id
}

// take_edits gives the edits since the last call, in frame memory, and forgets them. The drafts are still in the world:
// the caller reads them, and then despawns them.
take_edits :: proc(r: ^Runtime) -> Edits {
	edits := r.edits
	r.edits = {}
	return edits
}

// drop_edits forgets the edits, as when the editor leaves Edit mode.
@(private)
drop_edits :: proc(r: ^Runtime) {
	r.edits = {}
}

// writing is true while an edit-mode behaviour's code runs in Edit mode, so its writes to the document are recorded.
@(private)
writing :: proc(r: ^Runtime) -> bool {
	return r.callbacks == .Edit_Mode && instance_at(r, r.writer) != nil
}

// records_writes_to is true when a write to the entity now is recorded: an edit-mode behaviour writes to an entity of
// the document.
@(private)
records_writes_to :: proc(r: ^Runtime, e: ecs.Entity) -> bool {
	return(
		writing(r) &&
		r.document_component != 0 &&
		r.world != nil &&
		ecs.has_raw(r.world, e, r.document_component) \
	)
}

// edited finds the edited component of an entity, or nil.
@(private)
edited :: proc(r: ^Runtime, e: ecs.Entity, id: ecs.Component_Id) -> ^Edited_Component {
	for &c in r.edits.components {
		if c.entity == e && c.id == id {
			return &c
		}
	}
	return nil
}

// edit_component gives the edited copy of a component that the world has, and makes it at the first write.
@(private)
edit_component :: proc(r: ^Runtime, e: ecs.Entity, id: ecs.Component_Id, data: rawptr) -> [^]byte {
	if c := edited(r, e, id); c != nil {
		return raw_data(c.after)
	}
	info := ecs.registry_find(&r.world.registry, id)
	size := info.size if info != nil else 0
	world := ([^]byte)(data)[:size]
	before := make([]byte, size, frame(r))
	after := make([]byte, size, frame(r))
	copy(before, world)
	copy(after, world)
	return raw_data(add_edited(r, {entity = e, id = id, before = before, after = after}).after)
}

// add_component_edit records a component that the script adds to a document entity, from its default.
@(private)
add_component_edit :: proc(r: ^Runtime, e: ecs.Entity, id: ecs.Component_Id, default: []byte) {
	after := make([]byte, len(default), frame(r))
	copy(after, default)
	if c := edited(r, e, id); c != nil {
		c.after = after
		return
	}
	add_edited(r, {entity = e, id = id, after = after})
}

@(private = "file")
add_edited :: proc(r: ^Runtime, c: Edited_Component) -> ^Edited_Component {
	if r.edits.components == nil {
		r.edits.components = make([dynamic]Edited_Component, frame(r))
	}
	append(&r.edits.components, c)
	record_edit(r, Edit_Component{len(r.edits.components) - 1})
	return &r.edits.components[len(r.edits.components) - 1]
}

// record_edit adds an edit, and notes the class of the behaviour that made it.
@(private)
record_edit :: proc(r: ^Runtime, edit: Edit) {
	if r.edits.list == nil {
		r.edits.list = make([dynamic]Edit, frame(r))
	}
	append(&r.edits.list, edit)
	class := writer_class(r)
	switch {
	case r.edits.class == "":
		r.edits.class = class
	case r.edits.class != class:
		r.edits.several = true
	}
}

// is_stand_in is true for a prefab's stand-in, which only carries a pose.
@(private)
is_stand_in :: proc(r: ^Runtime, e: ecs.Entity) -> bool {
	for edit in r.edits.list {
		if s, ok := edit.(Edit_Spawn); ok && s.entity == e && s.prefab != {} {
			return true
		}
	}
	return false
}

// writer_class is the class name of the behaviour whose code runs, in frame memory.
@(private = "file")
writer_class :: proc(r: ^Runtime) -> string {
	i := instance_at(r, r.writer)
	if i == nil {
		return ""
	}
	L := r.L
	luau.getref(L, i.table)
	defer luau.pop(L, 2)
	luau.getmetatable(L, -1)
	return strings.clone(class_name(r, L, luau.gettop(L)), frame(r))
}

// attach_edit records a behaviour that the script adds to a document entity: the class at class_idx, with the values
// of the table at values_idx (0 for none). The class must be a module's.
@(private)
attach_edit :: proc(r: ^Runtime, L: ^luau.State, e: ecs.Entity, class_idx, values_idx: c.int) {
	guid := script_of(r, L, luau.absindex(L, class_idx))
	if guid == {} {
		raise(L, "in Edit mode, a behaviour that is added to the scene must be a script's class")
	}
	fields := make([dynamic]Behaviour_Field, frame(r))
	if values_idx != 0 {
		values := luau.absindex(L, values_idx)
		luau.pushnil(L)
		for luau.next(L, values) {
			// The key stays for next: read_field pops the copy.
			luau.pop(L, 1)
			field := Behaviour_Field {
				name = strings.clone(luau.toodinstring(L, -1), frame(r)),
			}
			luau.pushvalue(L, -1)
			read_field(r, L, values, &field, frame(r))
			append(&fields, field)
		}
	}
	record_edit(r, Edit_Attach{entity = e, script = guid, fields = fields[:]})
}

// detach_edit records a behaviour that the script removes from a document entity, and reports whether it has one.
@(private)
detach_edit :: proc(r: ^Runtime, L: ^luau.State, e: ecs.Entity, class_idx: c.int) -> bool {
	class := luau.absindex(L, class_idx)
	push_record(r, L, e, false)
	defer luau.pop(L, 1)
	if luau.isnil(L, -1) {
		return false
	}
	luau.pushvalue(L, class)
	has := luau.rawget(L, -2) != .NIL
	luau.pop(L, 1)
	if has {
		record_edit(r, Edit_Detach{entity = e, script = script_of(r, L, class)})
	}
	return has
}
