package physics

import "core:hash"
import "core:log"
import "core:math"

import core_physics "cinnabar:core/physics"
import "cinnabar:engine/ecs"

// The characters' stable IDs (see docs/physics/design.md#components).
CHARACTER_ID :: ecs.Component_Id(75)
PHYSICS_CHARACTER_ID :: ecs.Component_Id(76)

Ground_State :: core_physics.Ground_State

// Character makes its entity a character controller (see docs/physics/design.md#characters): a capsule that walks,
// climbs steps, sticks to slopes and stops at walls, moved by the velocity that character_move gives it. Its Transform
// is its feet, and the capsule of radius and height, its whole height, stands upright above them, in meters, whatever
// the entity's scale. It is its entity's body: an entity with a Character has no other, and its Rigid_Body and
// Collider are ignored, with a warning.
Character :: struct {
	radius:          f32 `editor:"range=0.05,10"`,
	height:          f32 `editor:"range=0.1,20"`,
	// In degrees: steeper ground is a wall, which it slides down.
	max_slope:       f32 `editor:"range=0,90"`,
	// The tallest step that it walks up, and how far down it follows the ground, in meters.
	step_height:     f32 `editor:"range=0,2"`,
	stick_to_floor:  f32 `editor:"range=0,2"`,
	// In kg: its weight on what it stands on.
	mass:            f32 `editor:"range=0,10000"`,
	// In N: the most that it pushes a dynamic body with.
	max_push_force:  f32 `editor:"range=0,100000"`,
	// The object layer, as a Collider's (see docs/physics/design.md#layers).
	layer:           u8 `editor:"range=0,31"`,
	// Its contacts reach Physics_Events and its entity's behaviours (see docs/physics/design.md#events).
	report_contacts: bool,
}

DEFAULT_CHARACTER :: Character {
	radius          = 0.3,
	height          = 1.8,
	max_slope       = 45,
	step_height     = 0.4,
	stick_to_floor  = 0.5,
	mass            = 70,
	max_push_force  = 100,
	report_contacts = true,
}

// Physics_Character is the backend's character of its entity, which the sync adds and keeps. Its first 8 bytes are the
// handle, a Body's, so queries and contacts name it as a body. It holds what the last tick found.
Physics_Character :: struct {
	body:            core_physics.Body `editor:"read"`,
	// The pose last sent to the backend or written from it, so that a move by a script or the editor shows.
	position:        ecs.World_Position `editor:"-"`,
	rotation:        quaternion128 `editor:"-"`,
	// A hash of the Character that it was made from.
	source:          u64 `editor:"-"`,
	velocity:        [3]f32 `editor:"read"`,
	// What it stands on: the ground's normal, its velocity under the character, and its entity. They are zero in the air.
	ground:          Ground_State `editor:"read"`,
	ground_normal:   [3]f32 `editor:"read"`,
	ground_velocity: [3]f32 `editor:"read"`,
	ground_entity:   ecs.Entity `editor:"read"`,
}

register_character_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Character, CHARACTER_ID, DEFAULT_CHARACTER)
	ecs.register_component(r, Physics_Character, PHYSICS_CHARACTER_ID)
}

// character_size is the capsule that a Character makes: its radius and its whole height, which holds the two halves of
// its sphere. The editor draws characters with it.
character_size :: proc(c: Character) -> (radius, height: f32) {
	radius = max(c.radius, 0.01)
	height = max(c.height, 2 * radius + 0.01)
	return
}

// add_characters makes the characters of the entities that have a Character and no Physics_Character yet.
@(private)
add_characters :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, commands: ^ecs.Commands) {
	it := ecs.query_iter(w, s.queries.new_characters)
	for view in ecs.query_next(&it) {
		transforms := ecs.column(view, 0, ecs.Transform)
		for e, row in ecs.entities(view) {
			pc := Physics_Character{}
			create_character(s, w, list, e, transforms[row], &pc)
			ecs.command_add(commands, w, e, pc)
			if !ecs.has(w, e, ecs.Previous_Transform) {
				ecs.command_add(commands, w, e, ecs.Previous_Transform(transforms[row]))
			}
		}
	}
}

// update_characters makes again the characters whose Character changed, and teleports those that someone else moved,
// a script or the editor.
@(private)
update_characters :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List) {
	it := ecs.query_iter(w, s.queries.characters)
	for view in ecs.query_next(&it) {
		transforms := ecs.column(view, 0, ecs.Transform)
		characters := ecs.column(view, 1, Physics_Character)
		for e, row in ecs.entities(view) {
			pc, pose := &characters[row], transforms[row]
			if character_hash(w, e) != pc.source {
				if pool_valid(&s.bodies, core_physics.Handle(pc.body)) {
					destroy_character(s, list, pc.body)
				}
				create_character(s, w, list, e, pose, pc)
				continue
			}
			if pc.body.generation == 0 || !moved(pc.position, pc.rotation, pose) {
				continue
			}
			core_physics.cmd_set_character_pose(list, pc.body, ecs.position_sub_f64(pose.position, s.anchor), to_rotation(pose.rotation))
			pc.position, pc.rotation = pose.position, pose.rotation
		}
	}
}

// create_character sends the command that makes e's character, and fills pc with it. Without the backend's
// Characters, the character is nil.
@(private)
create_character :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, e: ecs.Entity, pose: ecs.Transform, pc: ^Physics_Character) {
	pc^ = {position = pose.position, rotation = pose.rotation, source = character_hash(w, e)}
	if !has_feature(s, .Characters, "a Character makes no character") {
		return
	}
	if ecs.has(w, e, Rigid_Body) || ecs.has(w, e, Collider) {
		log.warnf("physics: entity %v has a Character, which is its body, so its Rigid_Body and Collider make none", e)
	}
	c := ecs.get(w, e, Character)^
	handle := core_physics.Body(pool_alloc(&s.bodies))
	desc := core_physics.character_desc(handle, ecs.position_sub_f64(pose.position, s.anchor), u64(e), c.layer)
	desc.rotation = to_rotation(pose.rotation)
	desc.radius, desc.height = character_size(c)
	desc.max_slope = math.to_radians(c.max_slope)
	desc.step_height = c.step_height
	desc.stick_to_floor = c.stick_to_floor
	desc.mass = c.mass
	desc.max_push_force = c.max_push_force
	if c.report_contacts {
		desc.flags += {.Report_Contacts}
	}
	core_physics.cmd_create_character(list, desc)
	for int(handle.index) >= len(s.records) {
		append(&s.records, Body_Record{})
	}
	s.records[handle.index] = {entity = e, kind = .Character}
	if ecs.has(w, e, ecs.Inactive) {
		core_physics.cmd_set_enabled(list, handle, false)
		s.records[handle.index].disabled = true
	}
	pc.body = handle
}

@(private)
destroy_character :: proc(s: ^State, list: ^core_physics.Command_List, body: core_physics.Body) {
	core_physics.cmd_destroy_character(list, body)
	pool_free(&s.bodies, core_physics.Handle(body))
	s.records[body.index] = {}
}

// write_back_characters writes each character after the step to its entity: its pose, when it moved, its velocity
// and its ground.
@(private)
write_back_characters :: proc(s: ^State, w: ^ecs.World, states: []core_physics.Character_State) {
	for state in states {
		e := ecs.Entity(state.user)
		pc := ecs.is_alive(w, e) ? ecs.get_write(w, e, Physics_Character) : nil
		if pc == nil || pc.body != state.body {
			continue
		}
		pc.velocity = state.velocity
		pc.ground = state.ground
		pc.ground_normal = state.ground_normal
		pc.ground_velocity = state.ground_velocity
		pc.ground_entity = ecs.Entity(state.ground_user)
		position, rotation := ecs.position_offset_f64(s.anchor, state.position), from_rotation(state.rotation)
		if !moved(pc.position, pc.rotation, {position = position, rotation = rotation}) {
			continue
		}
		pose := write_pose(s, w, e, state.position, state.rotation)
		pc.position, pc.rotation = pose.position, pose.rotation
	}
}

// character_hash is what a character is made from: its Character.
@(private)
character_hash :: proc(w: ^ecs.World, e: ecs.Entity) -> u64 {
	c := ecs.get(w, e, Character)
	if c == nil {
		return 0
	}
	return hash.fnv64a(([^]byte)(c)[:size_of(Character)])
}

@(private)
character_of :: proc(w: ^ecs.World, e: ecs.Entity) -> (core_physics.Body, bool) {
	pc := ecs.is_alive(w, e) ? ecs.get(w, e, Physics_Character) : nil
	if pc == nil || pc.body.generation == 0 {
		return {}, false
	}
	return pc.body, true
}
