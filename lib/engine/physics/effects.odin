package physics

import "core:mem"

import core_physics "cinnabar:core/physics"
import "cinnabar:engine/ecs"

// The effects that gameplay has on bodies: forces, impulses, velocities and sleep. Each is recorded, and the next
// physics tick submits it before its own commands, so an effect from fixed_update applies in the same tick, and one
// from update in the next. Call them from frame code, such as the script phase or the fixed step: the recording is not
// safe for jobs. *Later:* native Fixed systems record into lists of their own, which the tick submits in system order.
// Each returns false if the entity has no body.

add_force :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity, force: [3]f32) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_add_force(&s.pending, body, force)
	return true
}

add_force_at :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity, force: [3]f32, point: ecs.World_Position) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_add_force_at(&s.pending, body, force, ecs.position_sub_f64(point, s.anchor))
	return true
}

add_torque :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity, torque: [3]f32) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_add_torque(&s.pending, body, torque)
	return true
}

add_impulse :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity, impulse: [3]f32) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_add_impulse(&s.pending, body, impulse)
	return true
}

add_angular_impulse :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity, impulse: [3]f32) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_add_angular_impulse(&s.pending, body, impulse)
	return true
}

// set_velocity sets a body's linear and angular velocity. The Physics_Body shows them at once.
set_velocity :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity, linear, angular: [3]f32) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_set_velocity(&s.pending, body, linear, angular)
	pb := ecs.get(w, e, Physics_Body)
	pb.linear_velocity, pb.angular_velocity = linear, angular
	return true
}

sleep :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_deactivate(&s.pending, body)
	return true
}

wake :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_activate(&s.pending, body)
	return true
}

@(private)
body_of :: proc(w: ^ecs.World, e: ecs.Entity) -> (core_physics.Body, bool) {
	pb := ecs.is_alive(w, e) ? ecs.get(w, e, Physics_Body) : nil
	if pb == nil || pb.body.generation == 0 {
		return {}, false
	}
	return pb.body, true
}

// submit_pending sends the recorded effects and frees their memory.
@(private)
submit_pending :: proc(s: ^State) {
	if s.pending.first == nil {
		return
	}
	core_physics.submit(api(s), s.world, s.pending)
	for chunk := s.pending.first; chunk != nil; {
		next := chunk.next
		mem.free(chunk, s.pending.allocator)
		chunk = next
	}
	s.pending.first, s.pending.last = nil, nil
}
