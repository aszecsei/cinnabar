package physics

import core_physics "cinnabar:core/physics"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

Contact_Kind :: core_physics.Contact_Kind

// Contact is a pair of entities whose bodies began or stopped touching in a tick (see docs/physics/design.md#events):
// once per pair, however many shapes touch. a's body has the lower handle. A Begin has the first contact's point,
// its normal from a towards b, b's velocity relative to a's there, and an estimate of the impulse, 0 with a sensor.
// The backend estimates it when the contact is first found, which can be a little before the bodies touch, so a slow
// contact's impulse can be low; it is for sounds and effects, not for gameplay that needs exact numbers.
// An End has only the entities, one of which may be gone.
Contact :: struct {
	kind:              Contact_Kind,
	sensor:            bool,
	a, b:              ecs.Entity,
	point:             ecs.World_Position,
	normal:            [3]f32,
	relative_velocity: [3]f32,
	impulse:           f32,
}

// tick_contacts are the contacts of the last physics tick, which the next tick's Fixed systems see.
tick_contacts :: proc(s: ^State) -> []Contact {
	return s.tick_contacts[:]
}

// frame_contacts are the contacts of every tick since begin_frame, which the frame's Update and Late systems see.
frame_contacts :: proc(s: ^State) -> []Contact {
	return s.frame_contacts[:]
}

// send_events sends the last tick's contacts to the behaviours of the entities in them, as on_collision_enter,
// on_collision_exit, on_trigger_enter and on_trigger_exit, each with the other entity. A collision's enter also has the
// point, the normal from this entity towards the other, the other's velocity relative to this one, and the impulse.
// Call it after tick and before script.fixed_events, which delivers them; it is frame code, where script.send is safe.
send_events :: proc(s: ^State, w: ^ecs.World, r: ^script.Runtime) {
	for c in s.tick_contacts {
		send_one(w, r, c, c.a, c.b, 1)
		send_one(w, r, c, c.b, c.a, -1)
	}
}

@(private)
send_one :: proc(w: ^ecs.World, r: ^script.Runtime, c: Contact, self, other: ecs.Entity, sign: f32) {
	if !ecs.is_alive(w, self) || !ecs.has(w, self, script.Behaviours) {
		return
	}
	switch {
	case c.sensor && c.kind == .Begin:
		script.send(r, self, "trigger_enter", other)
	case c.sensor:
		script.send(r, self, "trigger_exit", other)
	case c.kind == .Begin:
		script.send(r, self, "collision_enter", other, c.point, c.normal * sign, c.relative_velocity * sign, f64(c.impulse))
	case:
		script.send(r, self, "collision_exit", other)
	}
}
