// Package physics_boundary is the boundary between the engine and a physics backend: handles, descriptions, the command format,
// queries, and the two tables of procedures, Physics_API (what a backend provides) and Host (what the host gives it).
// It is plain data and is compiled into the host, the game DLL and every backend. See docs/physics/design.md#the-boundary.
//
// A backend may be written in C or C++, so everything here has a C layout: procedures use the C calling convention,
// and take pointers and counts, never Odin slices or strings. lib/core/physics/physics.h is the same layout in C,
// and both sides assert the sizes below, so a change here must change it too.
package physics_boundary

import "base:runtime"
import "core:log"
import "core:mem"

import "cinnabar:core/jobs"
import "cinnabar:core/layout"

// The version of Physics_API and the command format. The host refuses a backend whose info reports another one.
API_VERSION :: 6

// A handle with generation 0 is the nil handle. The engine allocates Body and Shape handles itself, before the
// backend knows them, so a command can name a body that an earlier command in the same list creates.
Handle :: struct {
	index:      u32,
	generation: u32,
}

// A physics world. The backend allocates it in world_create.
World :: distinct Handle
Body :: distinct Handle
Shape :: distinct Handle
Joint :: distinct Handle

// The most object layers a world has. A layer's mask is a u32 of the layers it collides with.
MAX_LAYERS :: 32

Feature :: enum u8 {
	Rigid_Bodies,
	Joints,
	Queries,
	Sensors,
	Characters,
	Vehicles,
	Soft_Bodies,
	Cloth,
	Hair,
	Buoyancy,
	Deterministic,
	Double_Precision,
	Save_State,
}

Features :: bit_set[Feature;u32]

// Backend_Info describes a backend. The strings are the backend's, and live as long as it is loaded.
Backend_Info :: struct {
	api_version: u32,
	features:    Features,
	name:        cstring,
	version:     cstring,
}

// World_Desc sizes a world. A zero field takes the default beside it.
World_Desc :: struct {
	// Bodies and shapes are indexed by handle index, which must be below these.
	max_bodies:              u32, // 65536
	max_shapes:              u32, // 16384
	max_body_pairs:          u32, // 65536
	max_contact_constraints: u32, // 16384
	// The per-step scratch memory, in bytes.
	temp_size:               u32, // 8 MiB
	max_joints:              u32, // 16384
}

DEFAULT_MAX_BODIES :: 65536
DEFAULT_MAX_SHAPES :: 16384
DEFAULT_MAX_BODY_PAIRS :: 65536
DEFAULT_MAX_CONTACT_CONSTRAINTS :: 16384
DEFAULT_TEMP_SIZE :: 8 * mem.Megabyte
DEFAULT_MAX_JOINTS :: 16384

Motion :: enum u8 {
	Static,
	Kinematic,
	Dynamic,
}

Shape_Kind :: enum u8 {
	// size is the half extents.
	Box,
	// size.x is the radius.
	Sphere,
	// A capsule along y: size.x is the radius, size.y the half height of the cylinder between the caps.
	Capsule,
	// A cylinder along y: size.x is the radius, size.y the half height.
	Cylinder,
	// Triangles, from create_mesh_shape. Only a static or kinematic body can take one: it has no mass.
	Mesh,
	// The convex hull of points, from create_mesh_shape.
	Convex_Hull,
}

Body_Flag :: enum u16 {
	// Reports contacts and is never pushed or pushes (see docs/physics/design.md#events).
	Sensor,
	// Continuous collision detection, for fast bodies.
	Ccd,
	Start_Asleep,
	// Contacts with the body begin and end in the step's results. A sensor's always do.
	Report_Contacts,
	// A sensor that is static or kinematic detects static and kinematic bodies too, not only dynamic ones.
	Detect_Static,
}

Body_Flags :: bit_set[Body_Flag;u16]

// Positions are offsets in meters from the world's anchor, which only the engine knows (see
// docs/physics/design.md#positions-and-precision). Rotations are quaternions as x, y, z, w.
Position :: [3]f64
Rotation :: [4]f32

// =================================
// Commands
// =================================

Command_Kind :: enum u16 {
	Set_World,
	Create_Shape,
	Release_Shape,
	Create_Body,
	Destroy_Body,
	Set_Pose,
	Move_Kinematic,
	Set_Velocity,
	Add_Force,
	Add_Force_At,
	Add_Torque,
	Add_Impulse,
	Add_Angular_Impulse,
	Activate,
	Deactivate,
	Set_Enabled,
	Create_Compound,
	Create_Joint,
	Destroy_Joint,
	Set_Joint,
}

// size includes the header and the padding after the payload. Payloads start 8-byte aligned.
Command_Header :: struct {
	kind: Command_Kind,
	size: u16,
	_:    u32,
}

// Gravity, and each layer's mask of the layers it collides with. A pair collides when each is in the other's mask.
Set_World :: struct {
	gravity:  [3]f32,
	_:        u32,
	collides: [MAX_LAYERS]u32,
}

// A shape is reference-counted by the backend: each body that uses it holds a reference, and so does the handle
// until Release_Shape. density, in kg/m³, gives a dynamic body's mass when the body's own mass is zero. offset and
// rotation place the shape in its body.
Create_Shape :: struct {
	shape:    Shape,
	kind:     Shape_Kind,
	_:        [3]u8,
	size:     [3]f32,
	density:  f32,
	offset:   [3]f32,
	rotation: Rotation,
}

Release_Shape :: struct {
	shape: Shape,
}

// A shape made of other shapes, each placed by its own offset and rotation. count Shape handles follow the payload.
// The compound holds its children, so their handles can be released after it.
Create_Compound :: struct {
	shape: Shape,
	count: u32,
	_:     u32,
}

MAX_COMPOUND_CHILDREN :: 1024

// user is the engine's value for the body, which is the entity; results and hits return it.
Create_Body :: struct {
	body:             Body,
	shape:            Shape,
	position:         Position,
	rotation:         Rotation,
	linear_velocity:  [3]f32,
	angular_velocity: [3]f32,
	user:             u64,
	motion:           Motion,
	layer:            u8,
	flags:            Body_Flags,
	// Zero takes the mass from the shape's density.
	mass:             f32,
	friction:         f32,
	restitution:      f32,
	linear_damping:   f32,
	angular_damping:  f32,
	gravity_factor:   f32,
	_:                u32,
}

// body_desc gives a Create_Body with the usual defaults: no rotation, friction 0.2, light damping and full gravity.
body_desc :: proc(body: Body, shape: Shape, motion: Motion, position: Position, user: u64 = 0, layer: u8 = 0) -> Create_Body {
	return {
		body = body,
		shape = shape,
		position = position,
		rotation = {0, 0, 0, 1},
		user = user,
		motion = motion,
		layer = layer,
		friction = 0.2,
		linear_damping = 0.05,
		angular_damping = 0.05,
		gravity_factor = 1,
	}
}

Destroy_Body :: struct {
	body: Body,
}

// A teleport. activate wakes the body.
Set_Pose :: struct {
	body:     Body,
	position: Position,
	rotation: Rotation,
	activate: b32,
	_:        u32,
}

// A kinematic body's target pose, which it reaches in dt with the velocity that this sets.
Move_Kinematic :: struct {
	body:     Body,
	position: Position,
	rotation: Rotation,
	dt:       f32,
	_:        u32,
}

Set_Velocity :: struct {
	body:    Body,
	linear:  [3]f32,
	angular: [3]f32,
}

// Add_Force, Add_Torque, Add_Impulse and Add_Angular_Impulse. A force or a torque acts for the next step.
Add_Vector :: struct {
	body:   Body,
	vector: [3]f32,
	_:      u32,
}

// A force at a point, which also gives a torque.
Add_Force_At :: struct {
	body:  Body,
	force: [3]f32,
	_:     u32,
	point: Position,
}

Joint_Kind :: enum u8 {
	// Holds b where it was relative to a.
	Fixed,
	// A ball and socket: the frames' points stay together.
	Point,
	// Turns about the frame's x, between limit_min and limit_max radians with Has_Limits.
	Hinge,
	// Slides along the frame's x, between limit_min and limit_max meters with Has_Limits.
	Slider,
	// Keeps the frames' points between limit_min and limit_max meters apart; a negative one is the distance at
	// creation.
	Distance,
	// A ball and socket whose b x axis stays within limit_max radians of a's.
	Cone,
	// Each axis, x, y and z of translation and then of rotation, free, fixed or limited by six_min and six_max.
	Six_DOF,
}

Joint_Flag :: enum u8 {
	// The two bodies collide with each other. Without it, they pass through each other, as most joints want.
	Collide_Connected,
	// The joint does nothing until Set_Joint enables it.
	Disabled,
	// A hinge's or a slider's limits apply.
	Has_Limits,
}

Joint_Flags :: bit_set[Joint_Flag;u8]

Motor_Mode :: enum u8 {
	Off,
	// motor_target is a velocity: radians a second for a hinge, meters a second for a slider.
	Velocity,
	// motor_target is an angle or a distance, which a spring reaches.
	Position,
}

// Create_Joint joins a and b, or a and the world when b is nil, at two frames in world space, positions offset from
// the world's anchor: the joint's frame on a, and where it sits on b, usually the same. A frame's x is the hinge's and
// the slider's axis, and the cone's twist axis. spring_frequency in Hz and spring_damping soften the limits; 0 makes
// them hard. motor_max is the motor's most force or torque, 0 for no limit. break_force and break_torque, in N and N m,
// break the joint when it carries more for a step; 0 never breaks it.
Create_Joint :: struct {
	joint:            Joint,
	a, b:             Body,
	kind:             Joint_Kind,
	flags:            Joint_Flags,
	motor:            Motor_Mode,
	_:                u8,
	limit_min:        f32,
	limit_max:        f32,
	spring_frequency: f32,
	spring_damping:   f32,
	motor_target:     f32,
	motor_max:        f32,
	break_force:      f32,
	break_torque:     f32,
	_:                u32,
	position_a:       Position,
	rotation_a:       Rotation,
	position_b:       Position,
	rotation_b:       Rotation,
	// A six-DOF joint's limits on each axis: free when min is -max(f32) and max is max(f32), fixed when min >= max.
	six_min:          [6]f32,
	six_max:          [6]f32,
}

Destroy_Joint :: struct {
	joint: Joint,
}

// Set_Joint changes what a joint changes in place: whether it is enabled, and its motor.
Set_Joint :: struct {
	joint:        Joint,
	enabled:      b32,
	motor:        Motor_Mode,
	_:            [3]u8,
	motor_target: f32,
	motor_max:    f32,
}

// Activate and Deactivate.
Body_Command :: struct {
	body: Body,
}

// A body that is not enabled is out of the simulation: nothing hits it and it moves only by Set_Pose. Its entity is
// inactive (see docs/physics/design.md#the-physics-tick).
Set_Enabled :: struct {
	body:    Body,
	enabled: b32,
	_:       u32,
}

// Command_List is a stream of commands in chunks from its allocator, normally frame memory. It has no destroy
// procedure: its memory is freed with the allocator's memory. A backend reads each chunk as bytes (see submit).
Command_List :: struct {
	allocator: runtime.Allocator,
	first:     ^Chunk,
	last:      ^Chunk,
}

COMMAND_CHUNK_SIZE :: 64 * mem.Kilobyte
COMMAND_ALIGN :: 8

Chunk :: struct {
	next: ^Chunk,
	used: int,
	_:    int,
}

command_list :: proc(allocator: runtime.Allocator) -> Command_List {
	return {allocator = allocator}
}

chunk_data :: proc(chunk: ^Chunk) -> []byte {
	return ([^]byte)(chunk)[size_of(Chunk):COMMAND_CHUNK_SIZE]
}

push :: proc(list: ^Command_List, kind: Command_Kind, payload: $T, extra: []byte = nil) {
	#assert(align_of(T) <= COMMAND_ALIGN)
	size := mem.align_forward_int(size_of(Command_Header) + size_of(T) + len(extra), COMMAND_ALIGN)
	assert(size <= COMMAND_CHUNK_SIZE - size_of(Chunk) && size <= int(max(u16)), "physics: command too large")
	if list.last == nil || len(chunk_data(list.last)) - list.last.used < size {
		ptr, err := mem.alloc(COMMAND_CHUNK_SIZE, COMMAND_ALIGN, list.allocator)
		if err != nil {
			log.panicf("physics: command list chunk: %v", err)
		}
		chunk := (^Chunk)(ptr)
		chunk^ = {}
		if list.last == nil {
			list.first = chunk
		} else {
			list.last.next = chunk
		}
		list.last = chunk
	}
	dst := raw_data(chunk_data(list.last)[list.last.used:])
	header := Command_Header{kind = kind, size = u16(size)}
	payload := payload
	mem.zero(dst, size)
	mem.copy(dst, &header, size_of(Command_Header))
	mem.copy(&dst[size_of(Command_Header)], &payload, size_of(T))
	if len(extra) > 0 {
		mem.copy(&dst[size_of(Command_Header) + size_of(T)], raw_data(extra), len(extra))
	}
	list.last.used += size
}

cmd_set_world :: proc(list: ^Command_List, gravity: [3]f32, collides: [MAX_LAYERS]u32) {
	push(list, .Set_World, Set_World{gravity = gravity, collides = collides})
}

cmd_create_shape :: proc(
	list: ^Command_List,
	shape: Shape,
	kind: Shape_Kind,
	size: [3]f32,
	density: f32 = 1000,
	offset: [3]f32 = 0,
	rotation: Rotation = {0, 0, 0, 1},
) {
	push(list, .Create_Shape, Create_Shape{shape = shape, kind = kind, size = size, density = density, offset = offset, rotation = rotation})
}

cmd_create_compound :: proc(list: ^Command_List, shape: Shape, children: []Shape) {
	assert(len(children) <= MAX_COMPOUND_CHILDREN, "physics: too many children in a compound")
	push(list, .Create_Compound, Create_Compound{shape = shape, count = u32(len(children))}, ([^]byte)(raw_data(children))[:len(children) * size_of(Shape)])
}

// compound_children gives the child handles that follow a Create_Compound's payload.
compound_children :: proc(command: Command) -> []Shape {
	c := payload(command, Create_Compound)
	data := command.data[size_of(Create_Compound):]
	assert(len(data) >= int(c.count) * size_of(Shape))
	return ([^]Shape)(raw_data(data))[:c.count]
}

cmd_release_shape :: proc(list: ^Command_List, shape: Shape) {
	push(list, .Release_Shape, Release_Shape{shape})
}

cmd_create_body :: proc(list: ^Command_List, desc: Create_Body) {
	push(list, .Create_Body, desc)
}

cmd_destroy_body :: proc(list: ^Command_List, body: Body) {
	push(list, .Destroy_Body, Destroy_Body{body})
}

cmd_set_pose :: proc(list: ^Command_List, body: Body, position: Position, rotation: Rotation, activate := true) {
	push(list, .Set_Pose, Set_Pose{body = body, position = position, rotation = rotation, activate = b32(activate)})
}

cmd_move_kinematic :: proc(list: ^Command_List, body: Body, position: Position, rotation: Rotation, dt: f32) {
	push(list, .Move_Kinematic, Move_Kinematic{body = body, position = position, rotation = rotation, dt = dt})
}

cmd_set_velocity :: proc(list: ^Command_List, body: Body, linear, angular: [3]f32) {
	push(list, .Set_Velocity, Set_Velocity{body, linear, angular})
}

cmd_add_force :: proc(list: ^Command_List, body: Body, force: [3]f32) {
	push(list, .Add_Force, Add_Vector{body = body, vector = force})
}

cmd_add_force_at :: proc(list: ^Command_List, body: Body, force: [3]f32, point: Position) {
	push(list, .Add_Force_At, Add_Force_At{body = body, force = force, point = point})
}

cmd_add_torque :: proc(list: ^Command_List, body: Body, torque: [3]f32) {
	push(list, .Add_Torque, Add_Vector{body = body, vector = torque})
}

cmd_add_impulse :: proc(list: ^Command_List, body: Body, impulse: [3]f32) {
	push(list, .Add_Impulse, Add_Vector{body = body, vector = impulse})
}

cmd_add_angular_impulse :: proc(list: ^Command_List, body: Body, impulse: [3]f32) {
	push(list, .Add_Angular_Impulse, Add_Vector{body = body, vector = impulse})
}

cmd_activate :: proc(list: ^Command_List, body: Body) {
	push(list, .Activate, Body_Command{body})
}

cmd_deactivate :: proc(list: ^Command_List, body: Body) {
	push(list, .Deactivate, Body_Command{body})
}

cmd_set_enabled :: proc(list: ^Command_List, body: Body, enabled: bool) {
	push(list, .Set_Enabled, Set_Enabled{body = body, enabled = b32(enabled)})
}

cmd_create_joint :: proc(list: ^Command_List, desc: Create_Joint) {
	push(list, .Create_Joint, desc)
}

cmd_destroy_joint :: proc(list: ^Command_List, joint: Joint) {
	push(list, .Destroy_Joint, Destroy_Joint{joint})
}

cmd_set_joint :: proc(list: ^Command_List, joint: Joint, enabled: bool, motor: Motor_Mode, target, max: f32) {
	push(list, .Set_Joint, Set_Joint{joint = joint, enabled = b32(enabled), motor = motor, motor_target = target, motor_max = max})
}

// Command is a command read from a chunk. data is the payload and its padding.
Command :: struct {
	kind: Command_Kind,
	data: []byte,
}

// next_command reads the command at offset in a chunk's bytes, as a backend written in Odin does. Use it as
// `for command in next_command(data, &offset)`.
next_command :: proc(data: []byte, offset: ^int) -> (command: Command, ok: bool) {
	if offset^ + size_of(Command_Header) > len(data) {
		return
	}
	header := (^Command_Header)(raw_data(data[offset^:]))^
	if int(header.size) < size_of(Command_Header) || offset^ + int(header.size) > len(data) {
		return
	}
	command = {header.kind, data[offset^ + size_of(Command_Header):offset^ + int(header.size)]}
	offset^ += int(header.size)
	return command, true
}

// push_command copies a command that next_command read, as when one list's commands move into another.
push_command :: proc(list: ^Command_List, command: Command) {
	push(list, command.kind, struct {}{}, command.data)
}

payload :: proc(command: Command, $T: typeid) -> ^T {
	assert(len(command.data) >= size_of(T))
	return (^T)(raw_data(command.data))
}

// submit hands every chunk of the list to the backend, in order. It returns false if the backend rejected a command;
// the others still ran.
submit :: proc(api: ^Physics_API, world: World, list: Command_List) -> bool {
	ok := true
	for chunk := list.first; chunk != nil; chunk = chunk.next {
		if chunk.used > 0 && !api.submit(world, raw_data(chunk_data(chunk)), u32(chunk.used)) {
			ok = false
		}
	}
	return ok
}

// Format lists every type that crosses the boundary, so format_hash changes when any layout changes.
@(private = "file")
Format :: struct {
	header:         Command_Header,
	set_world:      Set_World,
	create_shape:   Create_Shape,
	release_shape:  Release_Shape,
	compound:       Create_Compound,
	create_joint:   Create_Joint,
	destroy_joint:  Destroy_Joint,
	set_joint:      Set_Joint,
	joint_break:    Joint_Break,
	create_body:    Create_Body,
	destroy_body:   Destroy_Body,
	set_pose:       Set_Pose,
	move_kinematic: Move_Kinematic,
	set_velocity:   Set_Velocity,
	add_vector:     Add_Vector,
	add_force_at:   Add_Force_At,
	body_command:   Body_Command,
	set_enabled:    Set_Enabled,
	world_desc:     World_Desc,
	info:           Backend_Info,
	results:        Step_Results,
	state:          Body_State,
	ray:            Ray,
	filter:         Query_Filter,
	hit:            Ray_Hit,
	contact:        Contact_Event,
	shape_desc:     Shape_Desc,
	shape_cast:     Shape_Cast,
	overlap:        Overlap_Query,
	overlap_hit:    Overlap_Hit,
	api:            Physics_API,
	host:           Host,
	kind:           Command_Kind,
}

// format_hash identifies the boundary's layouts. The game's abi_hash includes it.
format_hash :: proc() -> u64 {
	return layout.hash(Format)
}

// =================================
// Results and queries
// =================================

Body_State_Flag :: enum u32 {
	// The body fell asleep in the step; this is its last pose until it wakes.
	Asleep,
}

Body_State_Flags :: bit_set[Body_State_Flag;u32]

Body_State :: struct {
	body:             Body,
	user:             u64,
	position:         Position,
	rotation:         Rotation,
	linear_velocity:  [3]f32,
	angular_velocity: [3]f32,
	flags:            Body_State_Flags,
	_:                u32,
}

// Step_Results points into the backend's memory, valid until the next submit or step. moved is sorted by body
// handle, so its order is the same on every run.
Step_Results :: struct {
	moved:         [^]Body_State,
	moved_count:   u32,
	contact_count: u32,
	// The contacts that began and ended since the last step, sorted by a, then b, then kind.
	contacts:      [^]Contact_Event,
	// The joints that broke in the step, by handle. A broken joint stays disabled.
	broken:        [^]Joint_Break,
	broken_count:  u32,
	_:             u32,
}

// Joint_Break is a joint that carried more than its break_force or break_torque, with what it carried.
Joint_Break :: struct {
	joint:  Joint,
	force:  f32,
	torque: f32,
}

Contact_Kind :: enum u8 {
	// The two bodies began to touch: the first of their shapes' contacts.
	Begin,
	// They stopped touching, or one of them was destroyed or left the simulation.
	End,
}

// Contact_Event is a body pair that began or stopped touching (see docs/physics/design.md#events). a's handle index is
// below b's. A Begin has the first contact's point, its normal from a towards b, b's velocity relative to a's there,
// and an estimate of the impulse, which is 0 with a sensor.
Contact_Event :: struct {
	kind:              Contact_Kind,
	sensor:            bool,
	_:                 [6]u8,
	a, b:              Body,
	a_user, b_user:    u64,
	point:             Position,
	normal:            [3]f32,
	relative_velocity: [3]f32,
	impulse:           f32,
	_:                 u32,
}

Ray :: struct {
	origin:       Position,
	// A unit vector.
	direction:    [3]f32,
	max_distance: f32,
}

Query_Flag :: enum u32 {
	Include_Sensors,
}

Query_Flags :: bit_set[Query_Flag;u32]

MAX_QUERY_IGNORE :: 8

// Query_Filter is data: a query has no callback. layers is a mask of the object layers to hit.
Query_Filter :: struct {
	layers:       u32,
	flags:        Query_Flags,
	ignore_count: u32,
	_:            u32,
	ignore:       [MAX_QUERY_IGNORE]Body,
}

// A filter that hits every layer, and no sensors.
FILTER_ALL :: Query_Filter{layers = max(u32)}

// Shape_Desc is a query's shape, with the sizes of Create_Shape.
Shape_Desc :: struct {
	kind: Shape_Kind,
	_:    [3]u8,
	size: [3]f32,
}

// Shape_Cast sweeps a shape from origin along direction, a unit vector, for distance meters.
Shape_Cast :: struct {
	origin:    Position,
	rotation:  Rotation,
	direction: [3]f32,
	distance:  f32,
	shape:     Shape_Desc,
}

Overlap_Query :: struct {
	origin:   Position,
	rotation: Rotation,
	shape:    Shape_Desc,
}

Overlap_Hit :: struct {
	body: Body,
	user: u64,
}

Ray_Hit :: struct {
	body:      Body,
	user:      u64,
	position:  Position,
	normal:    [3]f32,
	distance:  f32,
	sub_shape: u32,
	_:         u32,
}

// =================================
// The tables
// =================================

// Physics_API is what a backend provides. world_destroy_all and shutdown are the host's: the game never calls them.
// submit and step run from one job or the frame code at a time; queries run from any number of jobs at once, but
// not during submit or step. See docs/physics/design.md#the-boundary.
Physics_API :: struct {
	info:              proc "c" () -> Backend_Info,
	// Returns the nil world on failure.
	world_create:      proc "c" (desc: ^World_Desc) -> World,
	world_destroy:     proc "c" (world: World),
	// Executes the commands in size bytes at data, in order. It returns false if any was invalid, such as one for a
	// stale handle; the backend logs each and runs the others.
	submit:            proc "c" (world: World, data: rawptr, size: u32) -> b32,
	// One fixed tick of dt seconds, in substeps collision steps. It returns when the step is done.
	step:              proc "c" (world: World, dt: f32, substeps: i32) -> b32,
	results:           proc "c" (world: World, out: ^Step_Results),
	// The state of chosen bodies. A stale handle gives a zeroed state.
	body_state:        proc "c" (world: World, bodies: [^]Body, count: u32, out: [^]Body_State),
	// create_mesh_shape makes a Mesh shape of triangles over vertices, or a Convex_Hull of the vertices alone, under
	// an engine handle that later commands use as a Create_Shape's: mesh data does not fit in a command. Front faces
	// are those whose (b - a) x (c - a) points out. It runs between steps, as submit does, and returns false for a
	// shape that the backend cannot make, which it logs.
	create_mesh_shape: proc "c" (world: World, shape: Shape, kind: Shape_Kind, vertices: [^][3]f32, vertex_count: u32, triangles: [^][3]u32, triangle_count: u32, density: f32) -> b32,
	// The closest hit along the ray. filter may be nil, which is FILTER_ALL.
	raycast:           proc "c" (world: World, ray: ^Ray, filter: ^Query_Filter, hit: ^Ray_Hit) -> b32,
	// Every hit along the ray, by distance: the first capacity of them go to out, and the count is all of them.
	raycast_all:       proc "c" (world: World, ray: ^Ray, filter: ^Query_Filter, out: [^]Ray_Hit, capacity: u32) -> u32,
	// The closest hit of each ray, in order; a miss is a zeroed hit.
	raycast_batch:     proc "c" (world: World, rays: [^]Ray, count: u32, filter: ^Query_Filter, out: [^]Ray_Hit),
	// The first hit of a swept shape: the contact point, the normal of the surface it hit, and the distance swept.
	shape_cast:        proc "c" (world: World, sweep: ^Shape_Cast, filter: ^Query_Filter, hit: ^Ray_Hit) -> b32,
	// The bodies that overlap a shape, by handle: the first capacity of them go to out, and the count is all of them.
	overlap:           proc "c" (world: World, query: ^Overlap_Query, filter: ^Query_Filter, out: [^]Overlap_Hit, capacity: u32) -> u32,
	// The backend runs its jobs through Host.jobs_run, which calls this with each job's data.
	run_job:           proc "c" (data: rawptr),
	// Destroys every world, for a soft restart, and returns how many there were.
	world_destroy_all: proc "c" () -> i32,
	shutdown:          proc "c" (),
}

Log_Level :: enum i32 {
	Debug,
	Info,
	Warning,
	Error,
}

// Host is what the host gives a backend: memory, jobs and the log, all host code. The backend calls nothing else of
// the engine's. jobs_run starts frame jobs, which must finish within the frame; the backend waits for them.
Host :: struct {
	allocate:     proc "c" (size, align: uint) -> rawptr,
	reallocate:   proc "c" (ptr: rawptr, old_size, new_size, align: uint) -> rawptr,
	free:         proc "c" (ptr: rawptr),
	jobs_run:     proc "c" (data: [^]rawptr, count: u32, counter: ^jobs.Counter),
	jobs_wait:    proc "c" (counter: ^jobs.Counter),
	worker_count: proc "c" () -> u32,
	log:          proc "c" (level: Log_Level, message: cstring),
}

// physics.h asserts the same sizes.
#assert(size_of(Command_Header) == 8)
#assert(size_of(Set_World) == 144)
#assert(size_of(Create_Shape) == 56)
#assert(size_of(Set_Enabled) == 16)
#assert(size_of(Create_Compound) == 16)
#assert(size_of(Create_Body) == 120)
#assert(size_of(Set_Pose) == 56)
#assert(size_of(Move_Kinematic) == 56)
#assert(size_of(Set_Velocity) == 32)
#assert(size_of(Add_Vector) == 24)
#assert(size_of(Add_Force_At) == 48)
#assert(size_of(World_Desc) == 24)
#assert(size_of(Backend_Info) == 24)
#assert(size_of(Body_State) == 88)
#assert(size_of(Step_Results) == 40)
#assert(size_of(Create_Joint) == 192)
#assert(size_of(Set_Joint) == 24)
#assert(size_of(Joint_Break) == 16)
#assert(size_of(Contact_Event) == 96)
#assert(size_of(Shape_Desc) == 16)
#assert(size_of(Shape_Cast) == 72)
#assert(size_of(Overlap_Query) == 56)
#assert(size_of(Overlap_Hit) == 16)
#assert(size_of(Ray) == 40)
#assert(size_of(Query_Filter) == 80)
#assert(size_of(Ray_Hit) == 64)
#assert(size_of(Physics_API) == 16 * size_of(rawptr))
#assert(size_of(Host) == 7 * size_of(rawptr))
#assert(size_of(jobs.Counter) == 16)
