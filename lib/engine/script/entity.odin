package script

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// register_world defines Entity's methods and the World library. See docs/scripting/api.md#the-entity-and-component-view.
@(private)
register_world :: proc(r: ^Runtime) {
	light_method(r, .Entity, "get", entity_get)
	light_method(r, .Entity, "has", entity_has)
	light_method(r, .Entity, "add", entity_add)
	light_method(r, .Entity, "remove", entity_remove)
	light_method(r, .Entity, "destroy", entity_destroy)
	light_method(r, .Entity, "is_alive", entity_is_alive)
	light_method(r, .Entity, "teleport", entity_teleport)
	light_method(r, .Entity, "offset_to", entity_offset_to)
	light_method(r, .Entity, "move", entity_move)
	light_method(r, .Entity, "set_parent", entity_set_parent)
	light_method(r, .Entity, "set_active", entity_set_active)
	light_method(r, .Entity, "send", send_binding)

	define(r, "World.spawn", world_spawn)
	define(r, "World.query", world_query)

	expose(r, ecs.Transform, ecs.TRANSFORM_IDENTITY)
	expose(r, ecs.Local_Transform, ecs.LOCAL_TRANSFORM_IDENTITY)
	expose(r, ecs.Parent)
}

// world_of is the world of a binding. It raises an error if the runtime has no world, as in some tests.
@(private)
world_of :: proc(L: ^luau.State) -> (^Runtime, ^ecs.World) {
	r := runtime_of(L)
	if r.world == nil {
		raise(L, "this runtime has no world")
	}
	return r, r.world
}

// alive_entity checks the entity at idx, and raises an error if it is destroyed, like Unity's
// MissingReferenceException.
@(private)
alive_entity :: proc(L: ^luau.State, idx: c.int) -> ecs.Entity {
	_, w := world_of(L)
	e := check_entity(L, idx)
	if !ecs.is_alive(w, e) {
		raise(L, "the entity is destroyed")
	}
	return e
}

@(private)
entity_text :: proc(r: ^Runtime, e: ecs.Entity) -> string {
	return fmt.aprintf("%d:%d", ecs.entity_index(e), ecs.entity_generation(e), allocator = frame(r))
}

// light_index is the __index of every light userdata.
@(private)
light_index :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	key, _ := key_atom(L, 2)
	switch Light_Tag(luau.lightuserdatatag(L, 1)) {
	case .Entity:
		e := alive_entity(L, 1)
		switch key {
		case "transform":
			if ecs.has_raw(r.world, e, ecs.TRANSFORM_ID) {
				push_userdata(L, .Component_Ref, Component_Ref{e, ecs.TRANSFORM_ID})
			} else {
				luau.pushnil(L)
			}
			return 1
		case "parent":
			parent := ecs.get(r.world, e, ecs.Parent)
			push_entity(L, parent.entity if parent != nil else 0)
			return 1
		case "active_self":
			luau.pushboolean(L, b32(ecs.active_self(r.world, e)))
			return 1
		case "active_in_hierarchy":
			luau.pushboolean(L, b32(ecs.active_in_hierarchy(r.world, e)))
			return 1
		}
		raise(L, fmt.aprintf("Entity has no field %s", key, allocator = frame(r)))
	case .Component_Type:
		id := check_component_type(L, 1)
		switch key {
		case "name":
			luau.pushodinstring(L, component_name(r, id))
			return 1
		case "id":
			luau.pushinteger64(L, i64(id))
			return 1
		}
		raise(L, fmt.aprintf("ComponentType has no field %s", key, allocator = frame(r)))
	case .Asset:
		if key == "guid" {
			buffer: [32]u8
			luau.pushodinstring(L, format.guid_format(to_asset(r, L, 1), &buffer))
			return 1
		}
		raise(L, fmt.aprintf("Asset has no field %s", key, allocator = frame(r)))
	case .None, .Instance_Key:
	}
	raise(L, "this value has no fields")
}

// light_namecall is the __namecall of every light userdata.
@(private)
light_namecall :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	atom: c.int
	name := string(luau.namecallatom(L, &atom))
	tag := Light_Tag(luau.lightuserdatatag(L, 1))
	if tag < min(Light_Tag) || tag > max(Light_Tag) {
		raise(L, "this value has no methods")
	}
	procedure := find_method(&r.light_methods[tag], atom, name)
	if procedure == nil {
		raise(L, fmt.aprintf("%v has no method %s", tag, name, allocator = frame(r)))
	}
	return procedure(L)
}

@(private)
light_tostring :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	switch Light_Tag(luau.lightuserdatatag(L, 1)) {
	case .Entity:
		luau.pushodinstring(L, fmt.aprintf("Entity(%s)", entity_text(r, to_entity(L, 1)), allocator = frame(r)))
	case .Component_Type:
		luau.pushodinstring(L, fmt.aprintf("ComponentType(%s)", component_name(r, check_component_type(L, 1)), allocator = frame(r)))
	case .Asset:
		buffer: [32]u8
		luau.pushodinstring(L, fmt.aprintf("Asset(%s)", format.guid_format(to_asset(r, L, 1), &buffer), allocator = frame(r)))
	case .None, .Instance_Key:
		luau.pushstring(L, "lightuserdata")
	}
	return 1
}

@(private = "file")
entity_get :: proc(L: ^luau.State) -> c.int {
	r, w := world_of(L)
	e := alive_entity(L, 1)
	if is_class(L, 2) {
		push_record(r, L, e, false)
		if !luau.isnil(L, -1) {
			luau.pushvalue(L, 2)
			luau.rawget(L, -2)
		}
		return 1
	}
	id := check_component_type(L, 2)
	if ecs.has_raw(w, e, id) {
		push_userdata(L, .Component_Ref, Component_Ref{e, id})
	} else {
		luau.pushnil(L)
	}
	return 1
}

@(private = "file")
entity_has :: proc(L: ^luau.State) -> c.int {
	if is_class(L, 2) {
		entity_get(L)
		luau.pushboolean(L, !luau.isnil(L, -1))
		return 1
	}
	_, w := world_of(L)
	luau.pushboolean(L, b32(ecs.has_raw(w, alive_entity(L, 1), check_component_type(L, 2))))
	return 1
}

// entity_add adds a component at once, from its default, and then from the optional table of field values. It
// returns the component. Adding a component that the entity has resets it.
@(private = "file")
entity_add :: proc(L: ^luau.State) -> c.int {
	r, w := world_of(L)
	e := alive_entity(L, 1)
	if is_class(L, 2) {
		if !luau.isnoneornil(L, 3) {
			luau.L_checktype(L, 3, .TABLE)
		}
		attach(r, L, e, 2, luau.isnoneornil(L, 3) ? 0 : 3, immediate = true)
		return 1
	}
	id := check_component_type(L, 2)
	x := find_exposed(r, id)
	if x == nil {
		raise(L, fmt.aprintf("%s is not exposed to scripts", component_name(r, id), allocator = frame(r)))
	}
	if !luau.isnoneornil(L, 3) {
		luau.L_checktype(L, 3, .TABLE)
	}
	if id == ecs.LOCAL_TRANSFORM_ID || id == ecs.PARENT_ID {
		raise(L, "use entity:set_parent to change the hierarchy")
	}
	ecs.add_raw(w, e, id, x.default[:x.size])
	ref := Component_Ref{e, id}
	if !luau.isnoneornil(L, 3) {
		fill_fields(r, L, ref, x, 3)
	}
	push_userdata(L, .Component_Ref, ref)
	return 1
}

@(private = "file")
entity_remove :: proc(L: ^luau.State) -> c.int {
	r, w := world_of(L)
	e := alive_entity(L, 1)
	if is_class(L, 2) {
		luau.pushboolean(L, b32(detach(r, L, e, 2)))
		return 1
	}
	id := check_component_type(L, 2)
	if id == ecs.LOCAL_TRANSFORM_ID || id == ecs.PARENT_ID {
		raise(L, "use entity:set_parent(nil) to change the hierarchy")
	}
	luau.pushboolean(L, b32(ecs.remove_raw(w, e, id)))
	return 1
}

// entity_set_active activates or deactivates the entity and its descendants, like Unity's SetActive. The callbacks
// run before it returns.
@(private = "file")
entity_set_active :: proc(L: ^luau.State) -> c.int {
	r, w := world_of(L)
	ecs.set_active(w, alive_entity(L, 1), bool(luau.L_checkboolean(L, 2)))
	drain_log(r)
	return 0
}

// entity_destroy despawns the entity and its descendants at the end of the script phase, like Unity's Destroy.
@(private = "file")
entity_destroy :: proc(L: ^luau.State) -> c.int {
	r, _ := world_of(L)
	ecs.command_despawn(script_commands(r), alive_entity(L, 1))
	return 0
}

@(private = "file")
entity_is_alive :: proc(L: ^luau.State) -> c.int {
	_, w := world_of(L)
	luau.pushboolean(L, b32(ecs.is_alive(w, check_entity(L, 1))))
	return 1
}

// entity_teleport moves an entity without interpolation. The rotation stays if it is not given.
@(private = "file")
entity_teleport :: proc(L: ^luau.State) -> c.int {
	r, w := world_of(L)
	e := alive_entity(L, 1)
	pose := (^ecs.Transform)(component_data(r, L, {e, ecs.TRANSFORM_ID}))^
	pose.position = check_position(L, 2)
	if !luau.isnoneornil(L, 3) {
		pose.rotation = check_quaternion(L, 3)
	}
	set_pose(r, L, e, pose)
	ecs.teleport(w, e, pose)
	return 0
}

// entity_offset_to is the vector from this entity to another, without making WorldPosition values.
@(private = "file")
entity_offset_to :: proc(L: ^luau.State) -> c.int {
	r, _ := world_of(L)
	from := (^ecs.Transform)(component_data(r, L, {alive_entity(L, 1), ecs.TRANSFORM_ID}))
	to := (^ecs.Transform)(component_data(r, L, {alive_entity(L, 2), ecs.TRANSFORM_ID}))
	push_vector(L, ecs.position_sub(to.position, from.position))
	return 1
}

// entity_move moves an entity by a vector, without making WorldPosition values.
@(private = "file")
entity_move :: proc(L: ^luau.State) -> c.int {
	r, _ := world_of(L)
	e := alive_entity(L, 1)
	pose := (^ecs.Transform)(component_data(r, L, {e, ecs.TRANSFORM_ID}))^
	pose.position = ecs.position_offset(pose.position, check_vector(L, 2))
	set_pose(r, L, e, pose)
	return 0
}

// entity_set_parent makes the entity a child of another, keeping its world pose, like Unity's SetParent. nil makes it
// a root.
@(private = "file")
entity_set_parent :: proc(L: ^luau.State) -> c.int {
	r, w := world_of(L)
	e := alive_entity(L, 1)
	pose := (^ecs.Transform)(component_data(r, L, {e, ecs.TRANSFORM_ID}))^
	if luau.isnoneornil(L, 2) {
		ecs.remove_raw(w, e, ecs.PARENT_ID)
		ecs.remove_raw(w, e, ecs.LOCAL_TRANSFORM_ID)
		ecs.update_activity(w)
		drain_log(r)
		return 0
	}
	parent := alive_entity(L, 2)
	if parent == e {
		raise(L, "an entity cannot be its own parent")
	}
	parent_pose := (^ecs.Transform)(component_data(r, L, {parent, ecs.TRANSFORM_ID}))^
	ecs.add(w, e, ecs.Parent{parent})
	ecs.add(w, e, local_from_world(parent_pose, pose))
	// A new parent can make the entity inactive, or active.
	ecs.update_activity(w)
	drain_log(r)
	return 0
}

// world_spawn creates an entity with a Transform at once, like Unity's Instantiate without a prefab. With a prefab
// first, it spawns an instance of it, as Unity's Instantiate with one: every behaviour in it wakes, in the prefab's
// entity order, before it returns the root (see docs/editor/prefabs.md#spawning-at-run-time).
@(private = "file")
world_spawn :: proc(L: ^luau.State) -> c.int {
	r, w := world_of(L)
	prefab := to_asset(r, L, 1)
	first: c.int = prefab != {} ? 2 : 1
	pose := ecs.TRANSFORM_IDENTITY
	if !luau.isnoneornil(L, first) {
		pose.position = check_position(L, first)
	}
	if !luau.isnoneornil(L, first + 1) {
		pose.rotation = check_quaternion(L, first + 1)
	}
	if prefab != {} {
		spawn_prefab_now(r, L, prefab, pose)
		return 1
	}
	e := ecs.spawn(w)
	ecs.add(w, e, pose)
	push_entity(L, e)
	return 1
}

// world_query returns an array of the entities that have every component given. It collects them before it
// returns, so a loop over the array can change the world.
@(private = "file")
world_query :: proc(L: ^luau.State) -> c.int {
	r, w := world_of(L)
	n := luau.gettop(L)
	if n == 0 {
		raise(L, "World.query needs at least one component type")
	}
	ids := make([]ecs.Component_Id, n, frame(r))
	for i in 0 ..< n {
		ids[i] = check_component_type(L, c.int(i + 1))
	}
	found := make([dynamic]ecs.Entity, frame(r))
	ecs.collect(w, ids, &found)
	luau.createtable(L, c.int(len(found)), 0)
	for e, i in found {
		push_entity(L, e)
		luau.rawseti(L, -2, c.int(i + 1))
	}
	return 1
}

// script_commands is the command buffer of the script phase, which the game applies with end_phase's result.
@(private)
script_commands :: proc(r: ^Runtime) -> ^ecs.Commands {
	if r.commands.data.allocator.procedure == nil {
		r.commands = ecs.commands(frame(r))
	}
	return &r.commands
}
