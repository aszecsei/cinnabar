// Package physics keeps a physics backend's world in step with the ECS: the components that say what should exist,
// the bodies that the backend simulates, and the sync between them in each fixed tick. The backend is behind
// Platform_API.physics. See docs/physics/design.md.
package physics

import "base:runtime"

import "cinnabar:core"
import core_physics "cinnabar:core/physics"
import "cinnabar:engine/ecs"

// The physics components' stable IDs, 64 to 79 (see docs/physics/design.md#components).
RIGID_BODY_ID :: ecs.Component_Id(64)
COLLIDER_ID :: ecs.Component_Id(65)
PHYSICS_BODY_ID :: ecs.Component_Id(66)

Motion :: core_physics.Motion

// Rigid_Body makes its entity a body that the simulation moves, or that moves by its Transform: a dynamic body falls
// and is pushed, a kinematic one follows its Transform and pushes, and a static one never moves. Its shape is the
// entity's Collider. An entity with a Collider and no Rigid_Body is a static body.
Rigid_Body :: struct {
	motion:          Motion,
	// In kg. 0 takes the mass from the collider's density.
	mass:            f32 `editor:"range=0,10000"`,
	linear_damping:  f32 `editor:"range=0,1"`,
	angular_damping: f32 `editor:"range=0,1"`,
	gravity_factor:  f32 `editor:"range=-10,10"`,
	// Continuous collision detection, for a fast body that would pass through thin ones.
	ccd:             bool,
	start_asleep:    bool,
	// Its contacts reach Physics_Events and its entity's behaviours (see docs/physics/design.md#events).
	report_contacts: bool,
}

DEFAULT_RIGID_BODY :: Rigid_Body {
	motion          = .Dynamic,
	linear_damping  = 0.05,
	angular_damping = 0.05,
	gravity_factor  = 1,
	report_contacts = true,
}

Shape :: enum u8 {
	Box,
	Sphere,
	// Along the entity's y.
	Capsule,
	// Along the entity's y.
	Cylinder,
}

// Collider is its entity's shape, scaled by its Transform: a box of size meters, a sphere of radius, or a capsule
// or cylinder of radius and height, its whole height along y. offset and rotation place it in the entity. A Collider
// on a descendant of a Rigid_Body, with no Rigid_Body between them, is a part of that body's shape, and the body
// takes its friction, restitution, layer and sensor from its own Collider, or its first part's.
Collider :: struct {
	shape:       Shape,
	size:        [3]f32 `editor:"range=0,1000"`,
	radius:      f32 `editor:"range=0,1000"`,
	height:      f32 `editor:"range=0,1000"`,
	offset:      [3]f32,
	rotation:    quaternion128,
	friction:    f32 `editor:"range=0,2"`,
	restitution: f32 `editor:"range=0,1"`,
	// In kg/m³, which gives a dynamic body's mass when its Rigid_Body's is 0.
	density:     f32 `editor:"range=1,20000"`,
	// A sensor detects bodies and does not touch them (see docs/physics/design.md#events).
	sensor:      bool,
	// A sensor that does not move detects only bodies that move, unless this is set.
	detect_static: bool,
	// The object layer, an index into the project's physics.layers (see docs/physics/design.md#layers).
	layer:       u8 `editor:"range=0,31"`,
}

DEFAULT_COLLIDER :: Collider {
	shape    = .Box,
	size     = 1,
	radius   = 0.5,
	height   = 2,
	rotation = 1,
	friction = 0.5,
	density  = 1000,
}

// Physics_Body is the backend's body of its entity, which the sync adds and keeps. Its first 8 bytes are the handle.
// A nil body means that the entity has a Rigid_Body and no Collider.
Physics_Body :: struct {
	body:             core_physics.Body `editor:"read"`,
	// The pose last sent to the backend or written from it, so that a move by a script or the editor shows.
	position:         ecs.World_Position `editor:"-"`,
	rotation:         quaternion128 `editor:"-"`,
	// A hash of the Rigid_Body, the Collider and the scale that the body was made from.
	source:           u64 `editor:"-"`,
	motion:           Motion `editor:"read"`,
	linear_velocity:  [3]f32 `editor:"read"`,
	angular_velocity: [3]f32 `editor:"read"`,
	asleep:           bool `editor:"read"`,
}

register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Rigid_Body, RIGID_BODY_ID, DEFAULT_RIGID_BODY)
	ecs.register_component(r, Collider, COLLIDER_ID, DEFAULT_COLLIDER)
	ecs.register_component(r, Physics_Body, PHYSICS_BODY_ID)
	register_joint_components(r)
}

// Pool hands out the engine's handles: an index and a generation, which goes up each time the index is freed, so a
// stale handle never matches. Its memory is the host's heap.
Pool :: struct {
	generations: [dynamic]u32,
	free:        [dynamic]u32,
}

pool_alloc :: proc(p: ^Pool) -> core_physics.Handle {
	if n := len(p.free); n > 0 {
		index := pop(&p.free)
		return {index, p.generations[index]}
	}
	append(&p.generations, 1)
	return {u32(len(p.generations) - 1), 1}
}

pool_free :: proc(p: ^Pool, h: core_physics.Handle) {
	g := &p.generations[h.index]
	g^ += 1
	if g^ == 0 {
		g^ = 1
	}
	append(&p.free, h.index)
}

pool_valid :: proc(p: ^Pool, h: core_physics.Handle) -> bool {
	return h.generation != 0 && int(h.index) < len(p.generations) && p.generations[h.index] == h.generation
}

pool_destroy :: proc(p: ^Pool) {
	delete(p.generations)
	delete(p.free)
	p^ = {}
}

// Body_Record is what the engine knows of a live body: its entity, and whether the body is out of the simulation
// because its entity is inactive.
Body_Record :: struct {
	entity:   ecs.Entity,
	disabled: bool,
}

// State is the engine's side of one physics world, in Game_State. The queries are registrations: register makes them
// again after a reload.
State :: struct {
	platform: ^core.Platform_API,
	world:    core_physics.World,
	// Positions cross the boundary as f64 offsets from here (see docs/physics/design.md#positions-and-precision).
	anchor:   ecs.World_Position,
	bodies:   Pool,
	records:  [dynamic]Body_Record,
	joints:   Pool,
	joint_records: [dynamic]Joint_Record,
	// The joints that broke in the last tick.
	breaks:   [dynamic]Joint_Break,
	shapes:   Pool,
	gravity:  [3]f32,
	layers:   Layers,
	// Set_World goes to the backend before the next submit.
	settings_dirty: bool,
	// The contacts of the last tick, and of every tick since begin_frame (see Contact).
	tick_contacts:  [dynamic]Contact,
	frame_contacts: [dynamic]Contact,
	// The effects that gameplay recorded since the last tick (see effects.odin), in the host's heap, and the kind of
	// the systems' jobs' own lists, which the world flushes into it.
	pending:        core_physics.Command_List,
	job_effects:    ecs.Job_Buffer,
	queries:  struct {
		new_colliders: ecs.Query,
		new_bodies:    ecs.Query,
		bodies:        ecs.Query,
		parts:         ecs.Query,
		joints:        [Joint_Kind]ecs.Query,
	},
}

DEFAULT_GRAVITY :: [3]f32{0, -9.81, 0}

// init creates the physics world. Call register after it, and destroy in the game's shutdown.
init :: proc(s: ^State, platform: ^core.Platform_API, desc: core_physics.World_Desc = {}, anchor := ecs.World_Position{}) -> bool {
	desc := desc
	allocator := platform.heap_allocator
	s^ = {
		platform       = platform,
		anchor         = anchor,
		gravity        = DEFAULT_GRAVITY,
		settings_dirty = true,
		bodies         = {generations = make([dynamic]u32, allocator), free = make([dynamic]u32, allocator)},
		shapes         = {generations = make([dynamic]u32, allocator), free = make([dynamic]u32, allocator)},
		records        = make([dynamic]Body_Record, allocator),
		joints         = {generations = make([dynamic]u32, allocator), free = make([dynamic]u32, allocator)},
		joint_records  = make([dynamic]Joint_Record, allocator),
		breaks         = make([dynamic]Joint_Break, allocator),
		tick_contacts  = make([dynamic]Contact, allocator),
		frame_contacts = make([dynamic]Contact, allocator),
		pending        = core_physics.command_list(allocator),
	}
	s.layers = default_layers()
	s.world = platform.physics.world_create(&desc)
	return s.world.generation != 0
}

// register makes the sync's queries. Call it after init and in on_reload, with the world's components registered.
register :: proc(s: ^State, w: ^ecs.World) {
	s.queries.new_colliders = ecs.query(w, {ecs.read(w, ecs.Transform), ecs.read(w, Collider), ecs.without(w, Physics_Body)})
	s.queries.new_bodies = ecs.query(
		w,
		{ecs.read(w, ecs.Transform), ecs.read(w, Rigid_Body), ecs.without(w, Collider), ecs.without(w, Physics_Body)},
	)
	s.queries.bodies = ecs.query(w, {ecs.read(w, ecs.Transform), ecs.write(w, Physics_Body)})
	s.queries.parts = ecs.query(w, {ecs.read(w, Collider), ecs.read(w, ecs.Parent), ecs.without(w, Rigid_Body)})
	for id, kind in JOINT_IDS {
		s.queries.joints[kind] = ecs.query(w, {{id = id, access = .Read}, ecs.optional(ecs.write(w, Physics_Joint))})
	}
	s.job_effects = ecs.register_job_buffer(w, {name = "physics effects", user = s, make = make_job_effects, flush = flush_job_effects})
}

// reload takes the new Platform_API after a code reload. The world and its bodies stay.
reload :: proc(s: ^State, platform: ^core.Platform_API) {
	s.platform = platform
}

destroy :: proc(s: ^State) {
	if s.platform != nil && s.world.generation != 0 {
		submit_pending(s)
		s.platform.physics.world_destroy(s.world)
	}
	pool_destroy(&s.bodies)
	pool_destroy(&s.shapes)
	pool_destroy(&s.joints)
	delete(s.records)
	delete(s.joint_records)
	delete(s.breaks)
	delete(s.tick_contacts)
	delete(s.frame_contacts)
	s^ = {}
}

// set_gravity changes the world's gravity from the next tick.
set_gravity :: proc(s: ^State, gravity: [3]f32) {
	s.gravity = gravity
	s.settings_dirty = true
}

MAX_LAYERS :: core_physics.MAX_LAYERS
MAX_LAYER_NAME :: 31

// Layers are the object layers that the project's settings name (see docs/physics/design.md#layers): physics.layers
// gives their names in order, and physics.ignore the pairs that do not collide. A Collider's layer is an index into
// them. It is plain data, so a code reload keeps it.
Layers :: struct {
	count:    int,
	names:    [MAX_LAYERS][MAX_LAYER_NAME]u8,
	lengths:  [MAX_LAYERS]u8,
	// Each layer's mask of the layers it collides with. Every pair collides unless physics.ignore names it.
	collides: [MAX_LAYERS]u32,
}

// default_layers is one layer, Default, and every layer colliding with every other, as a project without
// physics.layers has.
default_layers :: proc() -> (l: Layers) {
	add_layer(&l, "Default")
	return
}

// add_layer appends a layer that collides with everything. It returns false when the name is empty, too long, taken,
// or there are MAX_LAYERS already.
add_layer :: proc(l: ^Layers, name: string) -> bool {
	if name == "" || len(name) > MAX_LAYER_NAME || l.count == MAX_LAYERS {
		return false
	}
	if _, found := layer_index(l^, name); found {
		return false
	}
	copy(l.names[l.count][:], name)
	l.lengths[l.count] = u8(len(name))
	l.count += 1
	for &mask in l.collides {
		mask = max(u32)
	}
	return true
}

// ignore makes two layers not collide.
ignore :: proc(l: ^Layers, a, b: int) {
	l.collides[a] &~= 1 << u32(b)
	l.collides[b] &~= 1 << u32(a)
}

layer_name :: proc(l: ^Layers, index: int) -> string {
	return string(l.names[index][:l.lengths[index]])
}

layer_index :: proc(l: Layers, name: string) -> (int, bool) {
	l := l
	for i in 0 ..< l.count {
		if layer_name(&l, i) == name {
			return i, true
		}
	}
	return 0, false
}

// set_layers takes the project's layers from the next tick.
set_layers :: proc(s: ^State, layers: Layers) {
	s.layers = layers
	s.settings_dirty = true
}

@(private)
api :: proc(s: ^State) -> ^core_physics.Physics_API {
	return &s.platform.physics
}

@(private)
allocator_of :: proc(s: ^State) -> runtime.Allocator {
	return s.platform.frame_allocator
}
