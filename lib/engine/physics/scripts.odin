package physics

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The Physics library that scripts see (see docs/physics/design.md#scripts): queries, the layers, gravity, and the
// effects on bodies, which take the entity first.

@(private = "file")
REGISTRY_KEY :: "cinnabar.physics"

// register_scripts defines the Physics library, which reaches s, and exposes Rigid_Body and Collider. A game's
// Register_Proc calls it, so init and every reload define them again.
register_scripts :: proc(r: ^script.Runtime, s: ^State) {
	luau.pushlightuserdata(r.L, s)
	luau.setfield(r.L, luau.REGISTRYINDEX, REGISTRY_KEY)
	script.expose(r, Rigid_Body, DEFAULT_RIGID_BODY)
	script.expose(r, Collider, DEFAULT_COLLIDER)

	script.define(r, "Physics.raycast", raycast_binding, "(origin: WorldPosition, direction: vector, max_distance: number?, layers: number?) -> RaycastHit?")
	script.define(r, "Physics.raycast_all", raycast_all_binding, "(origin: WorldPosition, direction: vector, max_distance: number?, layers: number?) -> { RaycastHit }")
	script.define(r, "Physics.sphere_cast", sphere_cast_binding, "(origin: WorldPosition, radius: number, direction: vector, distance: number, layers: number?) -> RaycastHit?")
	script.define(r, "Physics.box_cast", box_cast_binding, "(origin: WorldPosition, size: vector, rotation: Quaternion?, direction: vector, distance: number, layers: number?) -> RaycastHit?")
	script.define(r, "Physics.capsule_cast", capsule_cast_binding, "(origin: WorldPosition, radius: number, height: number, rotation: Quaternion?, direction: vector, distance: number, layers: number?) -> RaycastHit?")
	script.define(r, "Physics.overlap_sphere", overlap_sphere_binding, "(center: WorldPosition, radius: number, layers: number?) -> { Entity }")
	script.define(r, "Physics.overlap_box", overlap_box_binding, "(center: WorldPosition, size: vector, rotation: Quaternion?, layers: number?) -> { Entity }")
	script.define(r, "Physics.overlap_capsule", overlap_capsule_binding, "(center: WorldPosition, radius: number, height: number, rotation: Quaternion?, layers: number?) -> { Entity }")
	script.define(r, "Physics.layers", layers_binding, "(...string) -> number")
	script.define(r, "Physics.gravity", proc(L: ^luau.State) -> c.int {
		script.push_vector(L, state_of(L).gravity)
		return 1
	}, "() -> vector")
	script.define(r, "Physics.set_gravity", proc(L: ^luau.State) -> c.int {
		set_gravity(state_of(L), script.check_vector(L, 1))
		return 0
	}, "(gravity: vector) -> ()")

	script.define(r, "Physics.add_force", proc(L: ^luau.State) -> c.int {
		s, w, e := body_args(L)
		add_force(s, w, e, script.check_vector(L, 2))
		return 0
	}, "(entity: Entity, force: vector) -> ()")
	script.define(r, "Physics.add_force_at", proc(L: ^luau.State) -> c.int {
		s, w, e := body_args(L)
		add_force_at(s, w, e, script.check_vector(L, 2), script.check_position(L, 3))
		return 0
	}, "(entity: Entity, force: vector, point: WorldPosition) -> ()")
	script.define(r, "Physics.add_torque", proc(L: ^luau.State) -> c.int {
		s, w, e := body_args(L)
		add_torque(s, w, e, script.check_vector(L, 2))
		return 0
	}, "(entity: Entity, torque: vector) -> ()")
	script.define(r, "Physics.add_impulse", proc(L: ^luau.State) -> c.int {
		s, w, e := body_args(L)
		add_impulse(s, w, e, script.check_vector(L, 2))
		return 0
	}, "(entity: Entity, impulse: vector) -> ()")
	script.define(r, "Physics.add_angular_impulse", proc(L: ^luau.State) -> c.int {
		s, w, e := body_args(L)
		add_angular_impulse(s, w, e, script.check_vector(L, 2))
		return 0
	}, "(entity: Entity, impulse: vector) -> ()")
	script.define(r, "Physics.velocity", proc(L: ^luau.State) -> c.int {
		_, w, e := body_args(L)
		script.push_vector(L, ecs.get(w, e, Physics_Body).linear_velocity)
		return 1
	}, "(entity: Entity) -> vector")
	script.define(r, "Physics.angular_velocity", proc(L: ^luau.State) -> c.int {
		_, w, e := body_args(L)
		script.push_vector(L, ecs.get(w, e, Physics_Body).angular_velocity)
		return 1
	}, "(entity: Entity) -> vector")
	script.define(r, "Physics.set_velocity", proc(L: ^luau.State) -> c.int {
		s, w, e := body_args(L)
		pb := ecs.get(w, e, Physics_Body)
		set_velocity(s, w, e, script.check_vector(L, 2), pb.angular_velocity)
		return 0
	}, "(entity: Entity, velocity: vector) -> ()")
	script.define(r, "Physics.set_angular_velocity", proc(L: ^luau.State) -> c.int {
		s, w, e := body_args(L)
		pb := ecs.get(w, e, Physics_Body)
		set_velocity(s, w, e, pb.linear_velocity, script.check_vector(L, 2))
		return 0
	}, "(entity: Entity, velocity: vector) -> ()")
	script.define(r, "Physics.sleep", proc(L: ^luau.State) -> c.int {
		s, w, e := body_args(L)
		sleep(s, w, e)
		return 0
	}, "(entity: Entity) -> ()")
	script.define(r, "Physics.wake", proc(L: ^luau.State) -> c.int {
		s, w, e := body_args(L)
		wake(s, w, e)
		return 0
	}, "(entity: Entity) -> ()")
	script.define(r, "Physics.is_sleeping", proc(L: ^luau.State) -> c.int {
		_, w, e := body_args(L)
		luau.pushboolean(L, b32(ecs.get(w, e, Physics_Body).asleep))
		return 1
	}, "(entity: Entity) -> boolean")
}

@(private = "file")
state_of :: proc(L: ^luau.State) -> ^State {
	luau.getfield(L, luau.REGISTRYINDEX, REGISTRY_KEY)
	s := (^State)(luau.tolightuserdata(L, -1))
	luau.pop(L, 1)
	return s
}

// body_args reads the entity in the first argument, and raises an error unless it has a body.
@(private = "file")
body_args :: proc(L: ^luau.State) -> (^State, ^ecs.World, ecs.Entity) {
	s, w, e := state_of(L), script.runtime_of(L).world, script.check_entity(L, 1)
	if _, ok := body_of(w, e); !ok {
		script.raise(L, fmt.tprintf("entity %v has no body: give it a Collider", e))
	}
	return s, w, e
}

@(private = "file")
layers_arg :: proc(L: ^luau.State, idx: c.int) -> Filter {
	if luau.isnoneornil(L, idx) {
		return FILTER_ALL
	}
	return {layers = u32(luau.L_checkinteger(L, idx))}
}

@(private = "file")
push_hit :: proc(L: ^luau.State, h: Hit) {
	luau.createtable(L, 0, 4)
	script.push_entity(L, h.entity)
	luau.rawsetfield(L, -2, "entity")
	script.push_position(L, h.position)
	luau.rawsetfield(L, -2, "position")
	script.push_vector(L, h.normal)
	luau.rawsetfield(L, -2, "normal")
	luau.pushnumber(L, f64(h.distance))
	luau.rawsetfield(L, -2, "distance")
}

// The default length of a ray that names none, in meters.
@(private = "file")
DEFAULT_RAY_LENGTH :: 1000

@(private = "file")
raycast_binding :: proc(L: ^luau.State) -> c.int {
	s, w := state_of(L), script.runtime_of(L).world
	origin, direction := script.check_position(L, 1), script.check_vector(L, 2)
	hit, ok := raycast(s, w, origin, direction, f32(luau.L_optnumber(L, 3, DEFAULT_RAY_LENGTH)), layers_arg(L, 4))
	if !ok {
		return 0
	}
	push_hit(L, hit)
	return 1
}

@(private = "file")
MAX_SCRIPT_HITS :: 256

@(private = "file")
raycast_all_binding :: proc(L: ^luau.State) -> c.int {
	s, w := state_of(L), script.runtime_of(L).world
	origin, direction := script.check_position(L, 1), script.check_vector(L, 2)
	hits: [MAX_SCRIPT_HITS]Hit
	count := raycast_all(s, w, origin, direction, f32(luau.L_optnumber(L, 3, DEFAULT_RAY_LENGTH)), hits[:], layers_arg(L, 4))
	count = min(count, MAX_SCRIPT_HITS)
	luau.createtable(L, c.int(count), 0)
	for i in 0 ..< count {
		push_hit(L, hits[i])
		luau.rawseti(L, -2, c.int(i + 1))
	}
	return 1
}

// rotation_arg is an optional Quaternion, or no rotation.
@(private = "file")
rotation_arg :: proc(L: ^luau.State, idx: c.int) -> quaternion128 {
	return luau.isnoneornil(L, idx) ? 1 : script.check_quaternion(L, idx)
}

@(private = "file")
sweep :: proc(L: ^luau.State, shape: Collider, rotation: quaternion128, first: c.int) -> c.int {
	s, w := state_of(L), script.runtime_of(L).world
	direction, distance := script.check_vector(L, first), f32(luau.L_checknumber(L, first + 1))
	hit, ok := shape_cast(s, w, shape, script.check_position(L, 1), rotation, direction, distance, layers_arg(L, first + 2))
	if !ok {
		return 0
	}
	push_hit(L, hit)
	return 1
}

@(private = "file")
sphere_cast_binding :: proc(L: ^luau.State) -> c.int {
	return sweep(L, {shape = .Sphere, radius = f32(luau.L_checknumber(L, 2))}, 1, 3)
}

@(private = "file")
box_cast_binding :: proc(L: ^luau.State) -> c.int {
	return sweep(L, {shape = .Box, size = script.check_vector(L, 2)}, rotation_arg(L, 3), 4)
}

@(private = "file")
capsule_cast_binding :: proc(L: ^luau.State) -> c.int {
	shape := Collider{shape = .Capsule, radius = f32(luau.L_checknumber(L, 2)), height = f32(luau.L_checknumber(L, 3))}
	return sweep(L, shape, rotation_arg(L, 4), 5)
}

@(private = "file")
overlap_shape :: proc(L: ^luau.State, shape: Collider, rotation: quaternion128, layers: c.int) -> c.int {
	s, w := state_of(L), script.runtime_of(L).world
	found: [MAX_SCRIPT_HITS]ecs.Entity
	count := min(overlap(s, w, shape, script.check_position(L, 1), rotation, found[:], layers_arg(L, layers)), MAX_SCRIPT_HITS)
	luau.createtable(L, c.int(count), 0)
	for i in 0 ..< count {
		script.push_entity(L, found[i])
		luau.rawseti(L, -2, c.int(i + 1))
	}
	return 1
}

@(private = "file")
overlap_sphere_binding :: proc(L: ^luau.State) -> c.int {
	return overlap_shape(L, {shape = .Sphere, radius = f32(luau.L_checknumber(L, 2))}, 1, 3)
}

@(private = "file")
overlap_box_binding :: proc(L: ^luau.State) -> c.int {
	return overlap_shape(L, {shape = .Box, size = script.check_vector(L, 2)}, rotation_arg(L, 3), 4)
}

@(private = "file")
overlap_capsule_binding :: proc(L: ^luau.State) -> c.int {
	shape := Collider{shape = .Capsule, radius = f32(luau.L_checknumber(L, 2)), height = f32(luau.L_checknumber(L, 3))}
	return overlap_shape(L, shape, rotation_arg(L, 4), 5)
}

// Physics.layers("Player", "Enemy") is the mask of the named layers, for a query's layers argument.
@(private = "file")
layers_binding :: proc(L: ^luau.State) -> c.int {
	s := state_of(L)
	mask: u32
	for i in 1 ..= luau.gettop(L) {
		luau.L_checkstring(L, i)
		name := luau.toodinstring(L, i)
		index, found := layer_index(s.layers, name)
		if !found {
			script.raise(L, fmt.tprintf("there is no physics layer %q", name))
		}
		mask |= 1 << u32(index)
	}
	luau.pushnumber(L, f64(mask))
	return 1
}
