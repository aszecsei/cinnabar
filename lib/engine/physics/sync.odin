package physics

import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"

import core_physics "cinnabar:core/physics"
import "cinnabar:engine/ecs"

// A pose that differs from the one last sent by less than this was not moved by anyone else: propagation recomputes
// a child's Transform, which rounds.
@(private)
MOVED_DISTANCE :: 1e-5
@(private)
MOVED_ANGLE_COS :: 1 - 1e-7

// tick is the physics tick of a fixed tick, after the scripts' fixed_update and the propagation of transforms: it
// syncs the world into the backend, steps it by the tick, and writes the bodies that moved back to their Transforms.
// See docs/physics/design.md#the-physics-tick.
tick :: proc(s: ^State, w: ^ecs.World) {
	dt := 1 / f32(w.clock.tick_rate)
	if !sync(s, w, dt) {
		return
	}
	api(s).step(s.world, dt, 1)
	results: core_physics.Step_Results
	api(s).results(s.world, &results)
	write_back(s, w, results.moved[:results.moved_count])
}

// sync makes the backend's world match the components without stepping it, as the editor's edit mode does, so that
// queries see the scene as it is edited. It returns false if the world is missing.
sync :: proc(s: ^State, w: ^ecs.World, dt: f32 = 1.0 / 60) -> bool {
	if s.world.generation == 0 {
		return false
	}
	list := core_physics.command_list(allocator_of(s))
	commands := ecs.commands(allocator_of(s))
	if s.settings_dirty {
		core_physics.cmd_set_world(&list, s.gravity, s.collides)
		s.settings_dirty = false
	}
	check_bodies(s, w, &list, &commands)
	add_bodies(s, w, &list, &commands)
	update_bodies(s, w, &list, dt)
	ok := core_physics.submit(api(s), s.world, list)
	ecs.apply(w, {commands})
	if !ok {
		log.warn("physics: the backend rejected some commands")
	}
	return true
}

// check_bodies goes through the live bodies: a body whose entity is gone, or whose Physics_Body or authoring
// components were removed, is destroyed, and one whose entity became inactive leaves the simulation until it is
// active again. The world's log has one reader, the script runtime, so the bodies are checked instead.
@(private)
check_bodies :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, commands: ^ecs.Commands) {
	for &record, index in s.records {
		handle := core_physics.Body{u32(index), s.bodies.generations[index]}
		if record.entity == 0 {
			continue
		}
		e := record.entity
		pb := ecs.is_alive(w, e) ? ecs.get(w, e, Physics_Body) : nil
		if pb == nil || pb.body != handle {
			destroy_body(s, list, handle)
			continue
		}
		if !ecs.has(w, e, Rigid_Body) && !ecs.has(w, e, Collider) {
			destroy_body(s, list, handle)
			ecs.command_remove(commands, w, e, Physics_Body)
			continue
		}
		inactive := ecs.has(w, e, ecs.Inactive)
		if inactive != record.disabled {
			core_physics.cmd_set_enabled(list, handle, !inactive)
			record.disabled = inactive
		}
	}
}

// add_bodies makes the bodies of the entities that have a Collider and no Physics_Body yet, and gives an entity
// with a Rigid_Body and no Collider a nil Physics_Body, so that it is warned about once.
@(private)
add_bodies :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, commands: ^ecs.Commands) {
	it := ecs.query_iter(w, s.queries.new_colliders)
	for view in ecs.query_next(&it) {
		transforms := ecs.column(view, 0, ecs.Transform)
		for e, row in ecs.entities(view) {
			pb := Physics_Body{}
			create_body(s, w, list, e, transforms[row], &pb)
			ecs.command_add(commands, w, e, pb)
			if pb.motion != .Static && !ecs.has(w, e, ecs.Previous_Transform) {
				ecs.command_add(commands, w, e, ecs.Previous_Transform(transforms[row]))
			}
		}
	}
	it = ecs.query_iter(w, s.queries.new_bodies)
	for view in ecs.query_next(&it) {
		for e in ecs.entities(view) {
			log.warnf("physics: entity %v has a Rigid_Body and no Collider, so it has no body", e)
			ecs.command_add(commands, w, e, Physics_Body{source = source_hash(w, e)})
		}
	}
}

// update_bodies makes again the bodies whose components changed, and sends the poses that someone else moved: a
// static body is set where it is, a kinematic one moves there in the tick, and a dynamic one is teleported, as in
// Unity.
@(private)
update_bodies :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, dt: f32) {
	it := ecs.query_iter(w, s.queries.bodies)
	for view in ecs.query_next(&it) {
		transforms := ecs.column(view, 0, ecs.Transform)
		bodies := ecs.column(view, 1, Physics_Body)
		for e, row in ecs.entities(view) {
			pb, pose := &bodies[row], transforms[row]
			if source_hash(w, e) != pb.source {
				if pool_valid(&s.bodies, core_physics.Handle(pb.body)) {
					destroy_body(s, list, pb.body)
				}
				create_body(s, w, list, e, pose, pb)
				continue
			}
			if pb.body.generation == 0 || !moved(pb, pose) {
				if pb.motion == .Kinematic && (pb.linear_velocity != 0 || pb.angular_velocity != 0) {
					core_physics.cmd_set_velocity(list, pb.body, 0, 0)
					pb.linear_velocity, pb.angular_velocity = 0, 0
				}
				continue
			}
			position, rotation := ecs.position_sub_f64(pose.position, s.anchor), to_rotation(pose.rotation)
			switch pb.motion {
			case .Static:
				core_physics.cmd_set_pose(list, pb.body, position, rotation, activate = false)
			case .Kinematic:
				core_physics.cmd_move_kinematic(list, pb.body, position, rotation, dt)
			case .Dynamic:
				core_physics.cmd_set_pose(list, pb.body, position, rotation)
			}
			pb.position, pb.rotation = pose.position, pose.rotation
		}
	}
}

// write_back writes the bodies that moved to their entities: the Transform of a root, or the Local_Transform of a
// child, which propagation turns into its Transform. A kinematic body follows its Transform, so only its velocity
// comes back.
@(private)
write_back :: proc(s: ^State, w: ^ecs.World, moved: []core_physics.Body_State) {
	for state in moved {
		e := ecs.Entity(state.user)
		pb := ecs.is_alive(w, e) ? ecs.get(w, e, Physics_Body) : nil
		if pb == nil || pb.body != state.body {
			continue
		}
		pb.linear_velocity, pb.angular_velocity = state.linear_velocity, state.angular_velocity
		pb.asleep = .Asleep in state.flags
		if pb.motion != .Dynamic {
			continue
		}
		pose := ecs.get(w, e, ecs.Transform)
		pose.position = ecs.position_offset_f64(s.anchor, state.position)
		pose.rotation = from_rotation(state.rotation)
		pb.position, pb.rotation = pose.position, pose.rotation
		if parent := ecs.get(w, e, ecs.Parent); parent != nil {
			if local := ecs.get(w, e, ecs.Local_Transform); local != nil {
				if parent_pose := ecs.get(w, parent.entity, ecs.Transform); parent_pose != nil {
					local^ = local_from_world(parent_pose^, pose^, local.scale)
				}
			}
		}
	}
}

// create_body sends the commands that make e's body from its components, and fills pb with it. The shape's handle is
// released at once: the body holds the shape.
@(private)
create_body :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, e: ecs.Entity, pose: ecs.Transform, pb: ^Physics_Body) {
	velocity, spin := pb.linear_velocity, pb.angular_velocity
	pb^ = {source = source_hash(w, e), position = pose.position, rotation = pose.rotation}
	collider := ecs.get(w, e, Collider)
	if collider == nil {
		return
	}
	rb := ecs.get(w, e, Rigid_Body)
	body := rb^ if rb != nil else Rigid_Body{motion = .Static}

	shape := core_physics.Shape(pool_alloc(&s.shapes))
	kind, size := shape_size(collider^, pose.scale)
	offset := collider.offset * pose.scale
	core_physics.cmd_create_shape(list, shape, kind, size, collider.density, offset, to_rotation(collider.rotation))

	handle := core_physics.Body(pool_alloc(&s.bodies))
	desc := core_physics.body_desc(handle, shape, body.motion, ecs.position_sub_f64(pose.position, s.anchor), u64(e), collider.layer)
	desc.rotation = to_rotation(pose.rotation)
	desc.mass = body.mass
	desc.friction = collider.friction
	desc.restitution = collider.restitution
	desc.linear_damping = body.linear_damping
	desc.angular_damping = body.angular_damping
	desc.gravity_factor = body.gravity_factor
	if body.motion == .Dynamic {
		desc.linear_velocity, desc.angular_velocity = velocity, spin
	}
	if collider.sensor {
		desc.flags += {.Sensor}
	}
	if body.ccd {
		desc.flags += {.Ccd}
	}
	if body.start_asleep {
		desc.flags += {.Start_Asleep}
	}
	core_physics.cmd_create_body(list, desc)
	core_physics.cmd_release_shape(list, shape)
	pool_free(&s.shapes, core_physics.Handle(shape))

	for int(handle.index) >= len(s.records) {
		append(&s.records, Body_Record{})
	}
	s.records[handle.index] = {entity = e}
	if ecs.has(w, e, ecs.Inactive) {
		core_physics.cmd_set_enabled(list, handle, false)
		s.records[handle.index].disabled = true
	}
	pb.body = handle
	pb.motion = body.motion
}

@(private)
destroy_body :: proc(s: ^State, list: ^core_physics.Command_List, body: core_physics.Body) {
	core_physics.cmd_destroy_body(list, body)
	pool_free(&s.bodies, core_physics.Handle(body))
	s.records[body.index] = {}
}

// shape_size gives the backend's shape for a collider at a scale. Scale is applied to the dimensions, so no shape
// needs a scaled wrapper: a sphere takes the largest axis, and a capsule or cylinder the largest of x and z for its
// radius.
@(private)
shape_size :: proc(c: Collider, pose_scale: [3]f32) -> (core_physics.Shape_Kind, [3]f32) {
	scale := linalg.abs(pose_scale)
	switch c.shape {
	case .Box:
		return .Box, linalg.max(c.size * scale * 0.5, 1e-3)
	case .Sphere:
		return .Sphere, {max(c.radius * max(scale.x, scale.y, scale.z), 1e-3), 0, 0}
	case .Capsule:
		radius := max(c.radius * max(scale.x, scale.z), 1e-3)
		half := max(c.height * scale.y * 0.5 - radius, 1e-3)
		return .Capsule, {radius, half, 0}
	case .Cylinder:
		return .Cylinder, {max(c.radius * max(scale.x, scale.z), 1e-3), max(c.height * scale.y * 0.5, 1e-3), 0}
	}
	return .Box, 1
}

// source_hash is what a body is made from: the Rigid_Body, the Collider and the entity's scale.
@(private)
source_hash :: proc(w: ^ecs.World, e: ecs.Entity) -> u64 {
	h := hash.fnv64a({})
	if rb := ecs.get(w, e, Rigid_Body); rb != nil {
		h = hash.fnv64a(([^]byte)(rb)[:size_of(Rigid_Body)], h)
	} else {
		h = hash.fnv64a({0}, h)
	}
	if c := ecs.get(w, e, Collider); c != nil {
		h = hash.fnv64a(([^]byte)(c)[:size_of(Collider)], h)
	} else {
		h = hash.fnv64a({1}, h)
	}
	if pose := ecs.get(w, e, ecs.Transform); pose != nil {
		scale := pose.scale
		h = hash.fnv64a(([^]byte)(&scale)[:size_of(scale)], h)
	}
	return h
}

@(private)
moved :: proc(pb: ^Physics_Body, pose: ecs.Transform) -> bool {
	d := ecs.position_sub(pose.position, pb.position)
	if linalg.dot(d, d) > MOVED_DISTANCE * MOVED_DISTANCE {
		return true
	}
	return math.abs(linalg.dot(pose.rotation, pb.rotation)) < MOVED_ANGLE_COS
}

// local_from_world is the Local_Transform that puts a child at a world pose under its parent, keeping its scale.
@(private)
local_from_world :: proc(parent, pose: ecs.Transform, scale: [3]f32) -> ecs.Local_Transform {
	inverse := linalg.quaternion_inverse(parent.rotation)
	offset := linalg.quaternion_mul_vector3(inverse, ecs.position_sub(pose.position, parent.position))
	return {offset = offset / parent.scale, rotation = linalg.normalize(inverse * pose.rotation), scale = scale}
}

@(private)
to_rotation :: proc(q: quaternion128) -> core_physics.Rotation {
	return {imag(q), jmag(q), kmag(q), real(q)}
}

@(private)
from_rotation :: proc(r: core_physics.Rotation) -> quaternion128 {
	return quaternion(w = r[3], x = r[0], y = r[1], z = r[2])
}
