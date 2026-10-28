package script

import "core:c"
import "core:fmt"
import "core:log"

import "cinnabar:core/luau"
import "cinnabar:engine/ecs"
import format "cinnabar:engine/asset/format"

// detach_script removes an entity's behaviour from a script asset, as the editor's operations do. Its on_disable and
// on_destroy run at once. It returns false if the entity has no such behaviour.
detach_script :: proc(r: ^Runtime, e: ecs.Entity, guid: format.Guid) -> bool {
	Data :: struct {
		r:        ^Runtime,
		e:        ecs.Entity,
		guid:     format.Guid,
		detached: bool,
	}
	data := Data{r, e, guid, false}
	status := luau.cpcall(r.L, proc "c" (L: ^luau.State) -> c.int {
		d := (^Data)(luau.touserdata(L, 1))
		context = d.r.bindings.ctx
		push_module(d.r, L, d.guid)
		if is_class(L, -1) {
			d.detached = detach(d.r, L, d.e, -1)
		}
		return 0
	}, &data)
	if status != .OK {
		log.errorf("script: cannot detach %s: %s", guid_text(r, guid), luau.toodinstring(r.L, -1))
		luau.pop(r.L, 1)
		return false
	}
	return data.detached
}

// set_behaviour_field sets a declared field of an entity's behaviour from a script asset, as the editor's operations
// do. With reset, the field gets its class's default, and only the field's name is used. It calls no script code,
// and returns what keeps it from setting the field, or "".
set_behaviour_field :: proc(r: ^Runtime, e: ecs.Entity, guid: format.Guid, field: Behaviour_Field, reset := false) -> (problem: string) {
	Data :: struct {
		r:       ^Runtime,
		e:       ecs.Entity,
		guid:    format.Guid,
		field:   Behaviour_Field,
		reset:   bool,
		problem: string,
	}
	data := Data{r, e, guid, field, reset, ""}
	status := luau.cpcall(r.L, proc "c" (L: ^luau.State) -> c.int {
		d := (^Data)(luau.touserdata(L, 1))
		context = d.r.bindings.ctx
		push_module(d.r, L, d.guid)
		class := luau.gettop(L)
		if !is_class(L, class) {
			d.problem = fmt.aprintf("%s does not return a Behaviour class", guid_text(d.r, d.guid), allocator = frame(d.r))
			return 0
		}
		push_record(d.r, L, d.e, false)
		if !luau.istable(L, -1) {
			d.problem = fmt.aprintf("the entity has no %s", class_name(d.r, L, class), allocator = frame(d.r))
			return 0
		}
		luau.pushvalue(L, class)
		if luau.rawget(L, -2) != .TABLE {
			d.problem = fmt.aprintf("the entity has no %s", class_name(d.r, L, class), allocator = frame(d.r))
			return 0
		}
		instance := luau.gettop(L)
		luau.rawgetfield(L, class, "__fields")
		schema := luau.gettop(L)
		if d.reset {
			luau.pushodinstring(L, d.field.name)
			if luau.rawget(L, schema) != .TABLE {
				d.problem = fmt.aprintf("%s has no field %s", class_name(d.r, L, class), d.field.name, allocator = frame(d.r))
				return 0
			}
			luau.rawgetfield(L, -1, "default")
		} else {
			push_behaviour_field(d.r, L, d.field)
			if d.problem = field_problem(d.r, L, class, schema, d.field.name, -1); d.problem != "" {
				return 0
			}
		}
		luau.pushodinstring(L, d.field.name)
		luau.insert(L, -2)
		luau.rawset(L, instance)
		return 0
	}, &data)
	if status != .OK {
		problem = fmt.aprintf("%s", luau.toodinstring(r.L, -1), allocator = frame(r))
		luau.pop(r.L, 1)
		return
	}
	return data.problem
}
