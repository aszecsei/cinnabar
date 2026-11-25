package script

import "core:c"
import "core:fmt"
import "core:log"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

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
set_behaviour_field :: proc(
	r: ^Runtime,
	e: ecs.Entity,
	guid: format.Guid,
	field: Behaviour_Field,
	reset := false,
) -> (
	problem: string,
) {
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
			class, instance: c.int
			class, instance, d.problem = behaviour_of(d.r, L, d.e, d.guid)
			if d.problem != "" {
				return 0
			}
			luau.rawgetfield(L, class, "__fields")
			schema := luau.gettop(L)
			if d.reset {
				luau.pushodinstring(L, d.field.name)
				if luau.rawget(L, schema) != .TABLE {
					d.problem = fmt.aprintf(
						"%s has no field %s",
						class_name(d.r, L, class),
						d.field.name,
						allocator = frame(d.r),
					)
					return 0
				}
				luau.rawgetfield(L, -1, "default")
			} else {
				push_value(d.r, L, field_value(d.field))
				if d.problem = field_problem(d.r, L, class, schema, d.field.name, -1);
				   d.problem != "" {
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

// behaviour_of pushes a script's class and the entity's instance of it, and gives their indices on the stack, or what
// keeps it from finding them.
@(private = "file")
behaviour_of :: proc(
	r: ^Runtime,
	L: ^luau.State,
	e: ecs.Entity,
	guid: format.Guid,
) -> (
	class, instance: c.int,
	problem: string,
) {
	push_module(r, L, guid)
	class = luau.gettop(L)
	if !is_class(L, class) {
		problem = fmt.aprintf(
			"%s does not return a Behaviour class",
			guid_text(r, guid),
			allocator = frame(r),
		)
		return
	}
	push_record(r, L, e, false)
	if luau.istable(L, -1) {
		luau.pushvalue(L, class)
		if luau.rawget(L, -2) == .TABLE {
			return class, luau.gettop(L), ""
		}
	}
	problem = fmt.aprintf("the entity has no %s", class_name(r, L, class), allocator = frame(r))
	return
}

// swap_behaviour_entity sets an entity field of an entity's behaviour to to, if it holds from now, and gives whether
// it did. Either can be 0, which is nil. A field that the behaviour no longer has, or that something else set since,
// is left as it is. It calls no script code.
swap_behaviour_entity :: proc(
	r: ^Runtime,
	e: ecs.Entity,
	guid: format.Guid,
	field: string,
	from, to: ecs.Entity,
) -> bool {
	Data :: struct {
		r:       ^Runtime,
		e:       ecs.Entity,
		guid:    format.Guid,
		field:   string,
		from:    ecs.Entity,
		to:      ecs.Entity,
		swapped: bool,
	}
	data := Data{r, e, guid, field, from, to, false}
	status := luau.cpcall(r.L, proc "c" (L: ^luau.State) -> c.int {
			d := (^Data)(luau.touserdata(L, 1))
			context = d.r.bindings.ctx
			class, instance, problem := behaviour_of(d.r, L, d.e, d.guid)
			if problem != "" {
				return 0
			}
			luau.rawgetfield(L, class, "__fields")
			luau.pushodinstring(L, d.field)
			if luau.rawget(L, -2) != .TABLE {
				return 0
			}
			luau.pop(L, 2)
			luau.pushodinstring(L, d.field)
			luau.rawget(L, instance)
			if (!luau.isnil(L, -1) && to_entity(L, -1) == 0) || to_entity(L, -1) != d.from {
				return 0
			}
			luau.pop(L, 1)
			luau.pushodinstring(L, d.field)
			if d.to == 0 {
				luau.pushnil(L)
			} else {
				push_entity(L, d.to)
			}
			luau.rawset(L, instance)
			d.swapped = true
			return 0
		}, &data)
	if status != .OK {
		log.errorf("script: cannot set %s: %s", field, luau.toodinstring(r.L, -1))
		luau.pop(r.L, 1)
		return false
	}
	return data.swapped
}
