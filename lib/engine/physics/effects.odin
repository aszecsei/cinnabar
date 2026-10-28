package physics

import "base:runtime"
import "core:mem"

import core_physics "cinnabar:core/physics"
import "cinnabar:engine/ecs"

// The effects that gameplay has on bodies: forces, impulses, velocities and sleep. Each records a command into an
// Effects, and the next physics tick submits them before its own commands, so an effect from fixed_update or a Fixed
// system applies in the same tick, and one from update or an Update system in the next. Frame code records into
// effects(s); a system's job records into job_effects(s, ctx), its own list, which the world flushes after the stage in
// system order and then job order, so the commands keep an order that does not depend on the jobs' timing. Each
// returns false if the entity has no body.

// Effects is where effects are recorded.
Effects :: struct {
	list:   ^core_physics.Command_List,
	anchor: ecs.World_Position,
}

// effects is frame code's: the state's pending list.
effects :: proc(s: ^State) -> Effects {
	return {&s.pending, s.anchor}
}

// job_effects is a system's job's own list, which it makes the first time the job asks.
job_effects :: proc(s: ^State, ctx: ^ecs.System_Context) -> Effects {
	return {(^core_physics.Command_List)(ecs.job_buffer(ctx, s.job_effects)), s.anchor}
}

add_force :: proc(to: Effects, w: ^ecs.World, e: ecs.Entity, force: [3]f32) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_add_force(to.list, body, force)
	return true
}

add_force_at :: proc(to: Effects, w: ^ecs.World, e: ecs.Entity, force: [3]f32, point: ecs.World_Position) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_add_force_at(to.list, body, force, ecs.position_sub_f64(point, to.anchor))
	return true
}

add_torque :: proc(to: Effects, w: ^ecs.World, e: ecs.Entity, torque: [3]f32) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_add_torque(to.list, body, torque)
	return true
}

add_impulse :: proc(to: Effects, w: ^ecs.World, e: ecs.Entity, impulse: [3]f32) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_add_impulse(to.list, body, impulse)
	return true
}

add_angular_impulse :: proc(to: Effects, w: ^ecs.World, e: ecs.Entity, impulse: [3]f32) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_add_angular_impulse(to.list, body, impulse)
	return true
}

// set_velocity sets a body's linear and angular velocity. Its Physics_Body shows them after the next tick.
set_velocity :: proc(to: Effects, w: ^ecs.World, e: ecs.Entity, linear, angular: [3]f32) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_set_velocity(to.list, body, linear, angular)
	return true
}

sleep :: proc(to: Effects, w: ^ecs.World, e: ecs.Entity) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_deactivate(to.list, body)
	return true
}

wake :: proc(to: Effects, w: ^ecs.World, e: ecs.Entity) -> bool {
	body := body_of(w, e) or_return
	core_physics.cmd_activate(to.list, body)
	return true
}

@(private)
make_job_effects :: proc(user: rawptr, allocator: runtime.Allocator) -> rawptr {
	list := new(core_physics.Command_List, allocator)
	list^ = core_physics.command_list(allocator)
	return list
}

// flush_job_effects moves the jobs' commands into the pending list, in the order the world gives them. The jobs' lists
// are frame memory, and the next tick may be a frame away.
@(private)
flush_job_effects :: proc(user: rawptr, buffers: []rawptr) {
	s := (^State)(user)
	for b in buffers {
		list := (^core_physics.Command_List)(b)
		for chunk := list.first; chunk != nil; chunk = chunk.next {
			data := core_physics.chunk_data(chunk)[:chunk.used]
			offset := 0
			for command in core_physics.next_command(data, &offset) {
				core_physics.push_command(&s.pending, command)
			}
		}
	}
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
