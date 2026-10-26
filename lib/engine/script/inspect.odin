package script

import "base:runtime"
import "core:c"
import "core:slice"
import "core:strings"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

Behaviour_Field_Kind :: enum u8 {
	Nil,
	Number,
	Boolean,
	String,
	Vector,
	Entity,
}

// Behaviour_Field is a declared field's value. Only the member for its kind is set.
Behaviour_Field :: struct {
	name:    string,
	kind:    Behaviour_Field_Kind,
	number:  f64,
	boolean: bool,
	text:    string,
	vector:  [3]f32,
	entity:  ecs.Entity,
}

Behaviour_Snapshot :: struct {
	class:   string,
	// The script asset whose module returns the class, or zero for a class that no module returns.
	script:  format.Guid,
	enabled: bool,
	// Sorted by name.
	fields:  []Behaviour_Field,
}

// inspect reads an entity's behaviours and the values of their declared fields, for the editor (see
// docs/editor/shell-and-panels.md#properties). It calls no script code. Strings and slices are in allocator. Call it outside the
// script phase.
inspect :: proc(r: ^Runtime, e: ecs.Entity, allocator: runtime.Allocator) -> []Behaviour_Snapshot {
	handles := entity_instances(r, e)
	snapshots := make([dynamic]Behaviour_Snapshot, 0, len(handles), allocator)
	L := r.L
	top := luau.gettop(L)
	defer luau.settop(L, top)
	for h in handles {
		i := instance_at(r, h)
		if i == nil {
			continue
		}
		luau.settop(L, top)
		luau.getref(L, i.table)
		instance := luau.gettop(L)
		if !luau.getmetatable(L, instance) {
			continue
		}
		class := luau.gettop(L)
		luau.rawgetfield(L, class, "__behaviour")
		name := strings.clone(luau.toodinstring(L, -1), allocator)
		luau.rawgetfield(L, class, "__fields")
		schema := luau.gettop(L)
		fields := make([dynamic]Behaviour_Field, allocator)
		if luau.istable(L, schema) {
			luau.pushnil(L)
			for luau.next(L, schema) {
				// The key is at -2 and the field's spec at -1. The key stays for next.
				luau.pop(L, 1)
				field := Behaviour_Field {
					name = strings.clone(luau.toodinstring(L, -1), allocator),
				}
				luau.pushvalue(L, -1)
				read_field(L, instance, &field, allocator)
				append(&fields, field)
			}
		}
		slice.sort_by(fields[:], proc(a, b: Behaviour_Field) -> bool {return a.name < b.name})
		append(&snapshots, Behaviour_Snapshot{class = name, script = script_of(r, L, class), enabled = .Enabled in i.flags, fields = fields[:]})
	}
	return snapshots[:]
}

// script_of is the script asset whose module returned the class at idx, or zero.
@(private = "file")
script_of :: proc(r: ^Runtime, L: ^luau.State, idx: c.int) -> format.Guid {
	for m in r.modules[:r.module_count] {
		if m.state != .Loaded || m.result == luau.NOREF {
			continue
		}
		luau.getref(L, m.result)
		same := luau.rawequal(L, -1, idx)
		luau.pop(L, 1)
		if same {
			return m.guid
		}
	}
	return {}
}

// read_field pops a key and reads the instance's value for it, without metamethods.
@(private = "file")
read_field :: proc(L: ^luau.State, instance: i32, field: ^Behaviour_Field, allocator: runtime.Allocator) {
	luau.rawget(L, instance)
	defer luau.pop(L, 1)
	#partial switch luau.type(L, -1) {
	case .NUMBER:
		field.kind = .Number
		field.number = luau.tonumber(L, -1)
	case .BOOLEAN:
		field.kind = .Boolean
		field.boolean = bool(luau.toboolean(L, -1))
	case .STRING:
		field.kind = .String
		field.text = strings.clone(luau.toodinstring(L, -1), allocator)
	case .VECTOR:
		v := luau.tovector(L, -1)
		field.kind = .Vector
		field.vector = {v[0], v[1], v[2]}
	case .LIGHTUSERDATA:
		if entity := to_entity(L, -1); entity != 0 {
			field.kind = .Entity
			field.entity = entity
		}
	}
}
