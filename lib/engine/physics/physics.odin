// Package physics keeps a physics backend's world in step with the ECS: the components that say what should exist,
// the bodies that the backend simulates, and the sync between them in each fixed tick. The backend is behind
// Platform_API.physics. See docs/physics/design.md.
package physics

import "base:runtime"
import "core:log"

import "cinnabar:core"
import core_physics "cinnabar:core/physics"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The physics components' stable IDs, 64 to 79 (see docs/physics/design.md#components).
RIGID_BODY_ID :: ecs.Component_Id(64)
COLLIDER_ID :: ecs.Component_Id(65)
PHYSICS_BODY_ID :: ecs.Component_Id(66)

// Motion, Rigid_Body, Shape and Collider are defined in format, with their defaults, so the cooker reads a scene's
// colliders as the registry does (see docs/physics/design.md#components).
Motion :: format.Motion
Rigid_Body :: format.Rigid_Body
DEFAULT_RIGID_BODY :: format.DEFAULT_RIGID_BODY
Shape :: format.Collider_Shape
Collider :: format.Collider
DEFAULT_COLLIDER :: format.DEFAULT_COLLIDER

#assert(int(Motion.Static) == int(core_physics.Motion.Static) && int(Motion.Kinematic) == int(core_physics.Motion.Kinematic))
#assert(int(Motion.Dynamic) == int(core_physics.Motion.Dynamic) && len(Motion) == len(core_physics.Motion))
#assert(RIGID_BODY_ID == format.SCENE_RIGID_BODY_ID && COLLIDER_ID == format.SCENE_COLLIDER_ID)

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
	register_character_components(r)
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

// Body_Kind is what a body handle names: a body of a Physics_Body, or a character of a Physics_Character.
Body_Kind :: enum u8 {
	Body,
	Character,
}

// Body_Record is what the engine knows of a live body: its entity, what it is, and whether it is out of the simulation
// because its entity is inactive.
Body_Record :: struct {
	entity:   ecs.Entity,
	kind:     Body_Kind,
	disabled: bool,
}

// State is the engine's side of one physics world, in Game_State. The queries are registrations: register makes them
// again after a reload.
State :: struct {
	platform: ^core.Platform_API,
	// Where mesh colliders' meshes load from, or nil for a world without them.
	assets:   ^asset.Assets,
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
	// Shape handles that this sync released, which go back to the pool after its commands are submitted: a mesh
	// shape is made at once, and must not take a handle that a command still in the list releases.
	released_shapes: [dynamic]core_physics.Shape,
	gravity:  [3]f32,
	layers:   Layers,
	// Set_World goes to the backend before the next submit.
	settings_dirty: bool,
	// What the backend does (see docs/physics/backends.md#features). A component that needs a feature it lacks is
	// ignored, and warned about once.
	features: core_physics.Features,
	warned:   core_physics.Features,
	// The contacts of the last tick, and of every tick since begin_frame (see Contact).
	tick_contacts:  [dynamic]Contact,
	frame_contacts: [dynamic]Contact,
	// The effects that gameplay recorded since the last tick (see effects.odin), in the host's heap, and the kind of
	// the systems' jobs' own lists, which the world flushes into it.
	pending:        core_physics.Command_List,
	job_effects:    ecs.Job_Buffer,
	queries:  struct {
		new_colliders:  ecs.Query,
		new_bodies:     ecs.Query,
		bodies:         ecs.Query,
		parts:          ecs.Query,
		joints:         [Joint_Kind]ecs.Query,
		new_characters: ecs.Query,
		characters:     ecs.Query,
	},
}

DEFAULT_GRAVITY :: [3]f32{0, -9.81, 0}

// init creates the physics world. Call register after it, and destroy in the game's shutdown.
init :: proc(s: ^State, platform: ^core.Platform_API, desc: core_physics.World_Desc = {}, anchor := ecs.World_Position{}, assets: ^asset.Assets = nil) -> bool {
	desc := desc
	allocator := platform.heap_allocator
	s^ = {
		platform       = platform,
		assets         = assets,
		anchor         = anchor,
		released_shapes = make([dynamic]core_physics.Shape, allocator),
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
	info := platform.physics.info()
	s.features = info.features
	s.world = platform.physics.world_create(&desc)
	return s.world.generation != 0
}

// register makes the sync's queries. Call it after init and in on_reload, with the world's components registered.
register :: proc(s: ^State, w: ^ecs.World) {
	// A Character is its entity's body, and its Rigid_Body and Collider make none.
	s.queries.new_colliders = ecs.query(
		w,
		{ecs.read(w, ecs.Transform), ecs.read(w, Collider), ecs.without(w, Physics_Body), ecs.without(w, Character)},
	)
	s.queries.new_bodies = ecs.query(
		w,
		{
			ecs.read(w, ecs.Transform),
			ecs.read(w, Rigid_Body),
			ecs.without(w, Collider),
			ecs.without(w, Physics_Body),
			ecs.without(w, Character),
		},
	)
	s.queries.new_characters = ecs.query(w, {ecs.read(w, ecs.Transform), ecs.read(w, Character), ecs.without(w, Physics_Character)})
	s.queries.characters = ecs.query(w, {ecs.read(w, ecs.Transform), ecs.write(w, Physics_Character), ecs.read(w, Character)})
	// The sync removes a character's Physics_Body, and a Physics_Character without its Character, by commands: until
	// then, they are left alone.
	s.queries.bodies = ecs.query(w, {ecs.read(w, ecs.Transform), ecs.write(w, Physics_Body), ecs.without(w, Character)})
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
	delete(s.released_shapes)
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

// has_feature says whether the backend does a feature, and warns once when it does not.
@(private)
has_feature :: proc(s: ^State, feature: core_physics.Feature, what: string) -> bool {
	if feature in s.features {
		return true
	}
	if feature not_in s.warned {
		s.warned += {feature}
		log.warnf("physics: the %s backend does not do %v, so %s", s.platform.physics.info().name, feature, what)
	}
	return false
}

@(private)
api :: proc(s: ^State) -> ^core_physics.Physics_API {
	return &s.platform.physics
}

@(private)
allocator_of :: proc(s: ^State) -> runtime.Allocator {
	return s.platform.frame_allocator
}
