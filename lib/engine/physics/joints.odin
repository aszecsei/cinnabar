package physics

import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"

import core_physics "cinnabar:core/physics"
import "cinnabar:engine/ecs"

// The joints' stable IDs (see docs/physics/design.md#components).
FIXED_JOINT_ID :: ecs.Component_Id(67)
POINT_JOINT_ID :: ecs.Component_Id(68)
HINGE_JOINT_ID :: ecs.Component_Id(69)
SLIDER_JOINT_ID :: ecs.Component_Id(70)
DISTANCE_JOINT_ID :: ecs.Component_Id(71)
CONE_JOINT_ID :: ecs.Component_Id(72)
SIX_DOF_JOINT_ID :: ecs.Component_Id(73)
PHYSICS_JOINT_ID :: ecs.Component_Id(74)

Joint_Kind :: core_physics.Joint_Kind
Motor_Mode :: core_physics.Motor_Mode

// Joint is what every kind of joint has (see docs/physics/design.md#constraints). A joint goes on any entity, and
// joins the body of that entity, or of its nearest ancestor with one, to body_b's, or to the world when body_b is
// none. Its frame is the entity's pose with offset, scaled as a Collider's is, and rotation; the frame's x is a hinge's
// and a slider's axis and a cone's twist axis. Where the frame sits on body_b is where it is when the joint is made,
// unless use_connected_frame places it on body_b's entity. Changing any of it makes the joint again, from the poses
// then; enabled and a motor change in place.
Joint :: struct {
	body_b:              ecs.Entity,
	offset:              [3]f32,
	rotation:            quaternion128,
	use_connected_frame: bool,
	connected_offset:    [3]f32,
	connected_rotation:  quaternion128,
	// The two bodies collide with each other, which most joints do not want.
	collide_connected:   bool,
	// In N and N m: the joint breaks when it carries more for a tick. 0 never breaks it.
	break_force:         f32 `editor:"range=0,1000000"`,
	break_torque:        f32 `editor:"range=0,1000000"`,
	enabled:             bool,
}

DEFAULT_JOINT :: Joint {
	rotation           = 1,
	connected_rotation = 1,
	enabled            = true,
}

// Motor drives a hinge or a slider: at a velocity, in radians or meters a second, or to a position, an angle or a
// distance, which a spring reaches. max is its most torque or force, 0 for no limit.
Motor :: struct {
	mode:   Motor_Mode,
	target: f32,
	max:    f32 `editor:"range=0,1000000"`,
}

// Fixed_Joint holds body_b where it is relative to the joint's body.
Fixed_Joint :: struct {
	joint: Joint,
}

// Point_Joint is a ball and socket.
Point_Joint :: struct {
	joint: Joint,
}

// Hinge_Joint turns about its frame's x, between min_angle and max_angle radians when limit is set. The spring, in Hz
// and a damping ratio, softens the limits, and is the position motor's spring; 0 makes the limits hard.
Hinge_Joint :: struct {
	joint:            Joint,
	limit:            bool,
	min_angle:        f32 `editor:"range=-3.1416,3.1416"`,
	max_angle:        f32 `editor:"range=-3.1416,3.1416"`,
	spring_frequency: f32 `editor:"range=0,60"`,
	spring_damping:   f32 `editor:"range=0,2"`,
	motor:            Motor,
}

// Slider_Joint slides along its frame's x, between min and max meters when limit is set.
Slider_Joint :: struct {
	joint:            Joint,
	limit:            bool,
	min:              f32,
	max:              f32,
	spring_frequency: f32 `editor:"range=0,60"`,
	spring_damping:   f32 `editor:"range=0,2"`,
	motor:            Motor,
}

// Distance_Joint keeps its frame's point on each body between min_distance and max_distance meters apart. A negative
// one is the distance when the joint is made.
Distance_Joint :: struct {
	joint:            Joint,
	min_distance:     f32,
	max_distance:     f32,
	spring_frequency: f32 `editor:"range=0,60"`,
	spring_damping:   f32 `editor:"range=0,2"`,
}

// Cone_Joint is a ball and socket whose body_b keeps its frame's x within half_angle radians of the joint's.
Cone_Joint :: struct {
	joint:      Joint,
	half_angle: f32 `editor:"range=0,3.1416"`,
}

// Six_DOF_Joint limits each axis of the frame on its own: x, y and z of translation and of rotation are free, or
// between their min and max, which are equal for a fixed axis.
Six_DOF_Joint :: struct {
	joint:        Joint,
	free_linear:  [3]bool,
	linear_min:   [3]f32,
	linear_max:   [3]f32,
	free_angular: [3]bool,
	angular_min:  [3]f32,
	angular_max:  [3]f32,
}

// Physics_Joint is the backend's joint of its entity, which the sync adds and keeps. Its first 8 bytes are the
// handle. A broken joint stays broken until it is made again.
Physics_Joint :: struct {
	joint:   core_physics.Joint `editor:"read"`,
	kind:    Joint_Kind `editor:"read"`,
	broken:  bool `editor:"read"`,
	// What the joint was made from, and what Set_Joint last sent.
	source:  u64 `editor:"-"`,
	enabled: bool `editor:"-"`,
	motor:   Motor `editor:"-"`,
}

register_joint_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Fixed_Joint, FIXED_JOINT_ID, Fixed_Joint{DEFAULT_JOINT})
	ecs.register_component(r, Point_Joint, POINT_JOINT_ID, Point_Joint{DEFAULT_JOINT})
	ecs.register_component(r, Hinge_Joint, HINGE_JOINT_ID, Hinge_Joint{joint = DEFAULT_JOINT, min_angle = -math.PI / 2, max_angle = math.PI / 2, spring_damping = 1})
	ecs.register_component(r, Slider_Joint, SLIDER_JOINT_ID, Slider_Joint{joint = DEFAULT_JOINT, min = -1, max = 1, spring_damping = 1})
	ecs.register_component(r, Distance_Joint, DISTANCE_JOINT_ID, Distance_Joint{joint = DEFAULT_JOINT, min_distance = -1, max_distance = -1, spring_damping = 1})
	ecs.register_component(r, Cone_Joint, CONE_JOINT_ID, Cone_Joint{joint = DEFAULT_JOINT, half_angle = math.PI / 4})
	ecs.register_component(r, Six_DOF_Joint, SIX_DOF_JOINT_ID, Six_DOF_Joint{joint = DEFAULT_JOINT, free_angular = true})
	ecs.register_component(r, Physics_Joint, PHYSICS_JOINT_ID)
}

// JOINT_IDS are the joint components' IDs by kind.
@(rodata)
JOINT_IDS := [Joint_Kind]ecs.Component_Id {
	.Fixed    = FIXED_JOINT_ID,
	.Point    = POINT_JOINT_ID,
	.Hinge    = HINGE_JOINT_ID,
	.Slider   = SLIDER_JOINT_ID,
	.Distance = DISTANCE_JOINT_ID,
	.Cone     = CONE_JOINT_ID,
	.Six_DOF  = SIX_DOF_JOINT_ID,
}

// joint_of gives an entity's joint: what every kind has, and its kind. It is the first kind the entity has, which the
// editor draws.
joint_of :: proc(w: ^ecs.World, e: ecs.Entity) -> (^Joint, Joint_Kind, bool) {
	for id, kind in JOINT_IDS {
		if data := ecs.get_raw(w, e, id); data != nil {
			// Every kind starts with its Joint.
			return (^Joint)(data), kind, true
		}
	}
	return nil, .Fixed, false
}

// Joint_Record is what the engine knows of a live joint: its entity and kind.
Joint_Record :: struct {
	entity: ecs.Entity,
	kind:   Joint_Kind,
}

// Joint_Break is a joint that broke in the last tick, for its entity's behaviours (see send_events).
Joint_Break :: struct {
	entity: ecs.Entity,
	force:  f32,
	torque: f32,
}

// sync_joints makes, changes and destroys the backend's joints to match the joint components, after the bodies'
// sync: a joint waits for its bodies, is made again when what it was made from changes, and changes in place when
// only its motor or whether it is enabled does.
@(private)
sync_joints :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, commands: ^ecs.Commands) {
	if !has_feature(s, .Joints, "joints are ignored") {
		return
	}
	check_joints(s, w, list, commands)
	sync_kind(s, w, list, commands, Fixed_Joint, .Fixed)
	sync_kind(s, w, list, commands, Point_Joint, .Point)
	sync_kind(s, w, list, commands, Hinge_Joint, .Hinge)
	sync_kind(s, w, list, commands, Slider_Joint, .Slider)
	sync_kind(s, w, list, commands, Distance_Joint, .Distance)
	sync_kind(s, w, list, commands, Cone_Joint, .Cone)
	sync_kind(s, w, list, commands, Six_DOF_Joint, .Six_DOF)
}

// check_joints destroys the live joints whose entity, Physics_Joint or joint component is gone.
@(private)
check_joints :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, commands: ^ecs.Commands) {
	for record, index in s.joint_records {
		if record.entity == 0 {
			continue
		}
		handle := core_physics.Joint{u32(index), s.joints.generations[index]}
		e := record.entity
		pj := ecs.is_alive(w, e) ? ecs.get(w, e, Physics_Joint) : nil
		if pj == nil || pj.joint != handle {
			destroy_joint(s, list, handle)
			continue
		}
		if !ecs.has_raw(w, e, JOINT_IDS[record.kind]) {
			destroy_joint(s, list, handle)
			ecs.command_remove(commands, w, e, Physics_Joint)
		}
	}
}

@(private)
sync_kind :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, commands: ^ecs.Commands, $T: typeid, kind: Joint_Kind) {
	q := s.queries.joints[kind]
	it := ecs.query_iter(w, q)
	for view in ecs.query_next(&it) {
		joints := ecs.column(view, 0, T)
		physics_joints := ecs.column(view, 1, Physics_Joint)
		for e, row in ecs.entities(view) {
			c := &joints[row]
			pj: ^Physics_Joint = physics_joints != nil ? &physics_joints[row] : nil
			desc, source, ok := describe(s, w, e, c, kind)
			if !ok {
				// A body is missing or not made yet: the joint waits for it.
				if pj != nil && pool_valid(&s.joints, core_physics.Handle(pj.joint)) {
					destroy_joint(s, list, pj.joint)
					pj^ = {kind = kind}
				}
				continue
			}
			enabled := c.joint.enabled && !ecs.has(w, e, ecs.Inactive) && !body_disabled(s, desc.a) && !body_disabled(s, desc.b)
			motor := motor_of(c)
			if pj == nil || source != pj.source || !pool_valid(&s.joints, core_physics.Handle(pj.joint)) {
				if pj != nil && pool_valid(&s.joints, core_physics.Handle(pj.joint)) {
					destroy_joint(s, list, pj.joint)
				}
				handle := core_physics.Joint(pool_alloc(&s.joints))
				desc.joint = handle
				if !enabled {
					desc.flags += {.Disabled}
				}
				desc.motor, desc.motor_target, desc.motor_max = motor.mode, motor.target, motor.max
				core_physics.cmd_create_joint(list, desc)
				for int(handle.index) >= len(s.joint_records) {
					append(&s.joint_records, Joint_Record{})
				}
				s.joint_records[handle.index] = {entity = e, kind = kind}
				made := Physics_Joint{joint = handle, kind = kind, source = source, enabled = enabled, motor = motor}
				if pj == nil {
					ecs.command_add(commands, w, e, made)
				} else {
					pj^ = made
				}
				continue
			}
			if !pj.broken && (enabled != pj.enabled || motor != pj.motor) {
				core_physics.cmd_set_joint(list, pj.joint, enabled, motor.mode, motor.target, motor.max)
				pj.enabled, pj.motor = enabled, motor
			}
		}
	}
}

// describe gives the Create_Joint of an entity's joint, without its handle, and a hash of what it is made from; it
// gives false while a body is missing.
@(private)
describe :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity, c: ^$T, kind: Joint_Kind) -> (desc: core_physics.Create_Joint, source: u64, ok: bool) {
	j := c.joint
	has_body :: proc(w: ^ecs.World, e: ecs.Entity) -> bool {
		pb := ecs.get(w, e, Physics_Body)
		return pb != nil && pb.body.generation != 0
	}
	owner_a, in_a := walk_up(w, e, has_body)
	if owner_a == 0 {
		return
	}
	desc.a = ecs.get(w, owner_a, Physics_Body).body
	if j.body_b != 0 {
		if !ecs.is_alive(w, j.body_b) {
			return
		}
		owner_b, _ := walk_up(w, j.body_b, has_body)
		if owner_b == 0 {
			return
		}
		desc.b = ecs.get(w, owner_b, Physics_Body).body
	}
	desc.kind = kind
	if j.collide_connected {
		desc.flags += {.Collide_Connected}
	}
	desc.break_force, desc.break_torque = j.break_force, j.break_torque

	pose := ecs.get(w, e, ecs.Transform)^
	at := ecs.position_offset(pose.position, linalg.quaternion_mul_vector3(pose.rotation, j.offset * pose.scale))
	desc.position_a, desc.rotation_a = ecs.position_sub_f64(at, s.anchor), to_rotation(pose.rotation * j.rotation)
	desc.position_b, desc.rotation_b = desc.position_a, desc.rotation_a
	if j.use_connected_frame && j.body_b != 0 {
		other := ecs.get(w, j.body_b, ecs.Transform)^
		on_b := ecs.position_offset(other.position, linalg.quaternion_mul_vector3(other.rotation, j.connected_offset * other.scale))
		desc.position_b, desc.rotation_b = ecs.position_sub_f64(on_b, s.anchor), to_rotation(other.rotation * j.connected_rotation)
	}

	when T == Hinge_Joint {
		desc.limit_min, desc.limit_max = c.min_angle, c.max_angle
		desc.spring_frequency, desc.spring_damping = c.spring_frequency, c.spring_damping
		if c.limit {
			desc.flags += {.Has_Limits}
		}
	} else when T == Slider_Joint {
		desc.limit_min, desc.limit_max = c.min, c.max
		desc.spring_frequency, desc.spring_damping = c.spring_frequency, c.spring_damping
		if c.limit {
			desc.flags += {.Has_Limits}
		}
	} else when T == Distance_Joint {
		desc.limit_min, desc.limit_max = c.min_distance, c.max_distance
		desc.spring_frequency, desc.spring_damping = c.spring_frequency, c.spring_damping
	} else when T == Cone_Joint {
		desc.limit_max = c.half_angle
	} else when T == Six_DOF_Joint {
		for i in 0 ..< 3 {
			desc.six_min[i], desc.six_max[i] = c.free_linear[i] ? -max(f32) : c.linear_min[i], c.free_linear[i] ? max(f32) : c.linear_max[i]
			desc.six_min[i + 3], desc.six_max[i + 3] = c.free_angular[i] ? -max(f32) : c.angular_min[i], c.free_angular[i] ? max(f32) : c.angular_max[i]
		}
	}

	// The source is the component without what changes in place, the bodies, and the joint's pose in its body.
	key := c^
	key.joint.enabled = false
	when T == Hinge_Joint || T == Slider_Joint {
		key.motor = {}
	}
	h := hash.fnv64a(([^]byte)(&key)[:size_of(T)])
	bodies := [2]core_physics.Body{desc.a, desc.b}
	h = hash.fnv64a(([^]byte)(&bodies)[:size_of(bodies)], h)
	h = hash.fnv64a(([^]byte)(&in_a)[:size_of(in_a)], h)
	return desc, h, true
}

@(private)
motor_of :: proc(c: ^$T) -> Motor {
	when T == Hinge_Joint || T == Slider_Joint {
		return c.motor
	} else {
		return {}
	}
}

@(private)
body_disabled :: proc(s: ^State, body: core_physics.Body) -> bool {
	return body.generation != 0 && int(body.index) < len(s.records) && s.records[body.index].disabled
}

@(private)
destroy_joint :: proc(s: ^State, list: ^core_physics.Command_List, joint: core_physics.Joint) {
	core_physics.cmd_destroy_joint(list, joint)
	pool_free(&s.joints, core_physics.Handle(joint))
	s.joint_records[joint.index] = {}
}

// note_breaks marks the joints that broke in the step, and keeps them for the entities' behaviours.
@(private)
note_breaks :: proc(s: ^State, w: ^ecs.World, broken: []core_physics.Joint_Break) {
	clear(&s.breaks)
	for b in broken {
		if !pool_valid(&s.joints, core_physics.Handle(b.joint)) {
			continue
		}
		e := s.joint_records[b.joint.index].entity
		if pj := ecs.is_alive(w, e) ? ecs.get(w, e, Physics_Joint) : nil; pj != nil && pj.joint == b.joint {
			pj.broken = true
			append(&s.breaks, Joint_Break{e, b.force, b.torque})
			log.debugf("physics: the joint of %v broke at %v N and %v N m", e, b.force, b.torque)
		}
	}
}
