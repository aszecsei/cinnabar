// Package physics_null is a physics backend that keeps bodies where they are put, steps nothing and hits nothing. It
// checks every command as a real backend does, so it runs the engine's tests of the boundary, and it is the backend of
// a game with physics turned off. See docs/physics/design.md#where-jolt-lives.
package physics_null

import "base:runtime"
import "core:fmt"
import "core:strings"

import physics "cinnabar:core/physics"

MAX_WORLDS :: 16

@(private)
Null_Body :: struct {
	generation: u32,
	user:       u64,
	position:   physics.Position,
	rotation:   physics.Rotation,
	linear:     [3]f32,
	angular:    [3]f32,
}

@(private)
Null_World :: struct {
	generation: u32,
	alive:      bool,
	bodies:     []Null_Body,
	shapes:     []u32,
	joints:     []u32,
}

// The host is one per process, so the backend's state is too.
@(private)
state: struct {
	host:   ^physics.Host,
	worlds: [MAX_WORLDS]Null_World,
}

// load gives the null backend's table. Every loader takes a backend's name; this one has no other.
load :: proc(host: ^physics.Host, name := "") -> ^physics.Physics_API {
	state.host = host
	return &api
}

@(private)
api := physics.Physics_API {
	info              = info,
	world_create      = world_create,
	world_destroy     = world_destroy,
	submit            = submit,
	step              = step,
	results           = results,
	body_state        = body_state,
	create_mesh_shape = create_mesh_shape,
	raycast           = raycast,
	raycast_all       = raycast_all,
	raycast_batch     = raycast_batch,
	shape_cast        = shape_cast,
	overlap           = overlap,
	run_job           = nil,
	world_destroy_all = world_destroy_all,
	shutdown          = shutdown,
}

@(private)
report :: proc(format: string, args: ..any) {
	message := fmt.tprintf(format, ..args)
	state.host.log(.Error, strings.clone_to_cstring(message, context.temp_allocator))
}

@(private)
info :: proc "c" () -> physics.Backend_Info {
	// It takes every command, and simulates none of them.
	return {
		api_version = physics.API_VERSION,
		features = {.Rigid_Bodies, .Joints, .Queries, .Sensors},
		layout = physics.layout_signature(),
		name = "null",
		version = "1",
	}
}

@(private)
find_world :: proc(handle: physics.World) -> ^Null_World {
	if handle.generation == 0 || handle.index >= MAX_WORLDS {
		return nil
	}
	w := &state.worlds[handle.index]
	return w if w.alive && w.generation == handle.generation else nil
}

@(private)
find_body :: proc(w: ^Null_World, handle: physics.Body) -> ^Null_Body {
	if handle.generation == 0 || int(handle.index) >= len(w.bodies) {
		return nil
	}
	b := &w.bodies[handle.index]
	return b if b.generation == handle.generation else nil
}

@(private)
world_create :: proc "c" (desc: ^physics.World_Desc) -> physics.World {
	context = runtime.default_context()
	d := desc^ if desc != nil else {}
	max_bodies := d.max_bodies if d.max_bodies != 0 else physics.DEFAULT_MAX_BODIES
	max_shapes := d.max_shapes if d.max_shapes != 0 else physics.DEFAULT_MAX_SHAPES
	max_joints := d.max_joints if d.max_joints != 0 else physics.DEFAULT_MAX_JOINTS
	for &w, i in state.worlds {
		if w.alive {
			continue
		}
		generation := w.generation + 1 if w.generation + 1 != 0 else 1
		w = {
			generation = generation,
			alive      = true,
			bodies     = make([]Null_Body, max_bodies, runtime.heap_allocator()),
			shapes     = make([]u32, max_shapes, runtime.heap_allocator()),
			joints     = make([]u32, max_joints, runtime.heap_allocator()),
		}
		return {u32(i), generation}
	}
	return {}
}

@(private)
destroy :: proc(w: ^Null_World) {
	delete(w.bodies, runtime.heap_allocator())
	delete(w.shapes, runtime.heap_allocator())
	delete(w.joints, runtime.heap_allocator())
	w^ = {generation = w.generation}
}

@(private)
world_destroy :: proc "c" (handle: physics.World) {
	context = runtime.default_context()
	if w := find_world(handle); w != nil {
		destroy(w)
	}
}

@(private)
world_destroy_all :: proc "c" () -> i32 {
	context = runtime.default_context()
	count: i32
	for &w in state.worlds {
		if w.alive {
			destroy(&w)
			count += 1
		}
	}
	return count
}

@(private)
shutdown :: proc "c" () {
	world_destroy_all()
}

@(private)
submit :: proc "c" (handle: physics.World, data: rawptr, size: u32) -> b32 {
	context = runtime.default_context()
	w := find_world(handle)
	if w == nil {
		report("physics: submit: no world %v", handle)
		return false
	}
	bytes := ([^]byte)(data)[:size]
	ok := true
	offset := 0
	for command in physics.next_command(bytes, &offset) {
		if !run(w, command) {
			report("physics: submit: %v was invalid, and did nothing", command.kind)
			ok = false
		}
	}
	if offset != len(bytes) {
		report("physics: submit: a command at %d is malformed", offset)
		return false
	}
	return b32(ok)
}

@(private)
run :: proc(w: ^Null_World, command: physics.Command) -> bool {
	switch command.kind {
	case .Set_World:
		return true
	case .Create_Shape:
		c := physics.payload(command, physics.Create_Shape)
		if c.shape.generation == 0 || int(c.shape.index) >= len(w.shapes) || c.size.x <= 0 {
			return false
		}
		w.shapes[c.shape.index] = c.shape.generation
		return true
	case .Release_Shape:
		shape := physics.payload(command, physics.Release_Shape).shape
		if shape.generation == 0 || int(shape.index) >= len(w.shapes) || w.shapes[shape.index] != shape.generation {
			return false
		}
		w.shapes[shape.index] = 0
		return true
	case .Create_Body:
		c := physics.payload(command, physics.Create_Body)
		if c.body.generation == 0 || int(c.body.index) >= len(w.bodies) || w.bodies[c.body.index].generation != 0 {
			return false
		}
		if c.shape.generation == 0 || int(c.shape.index) >= len(w.shapes) || w.shapes[c.shape.index] != c.shape.generation {
			return false
		}
		w.bodies[c.body.index] = {
			generation = c.body.generation,
			user       = c.user,
			position   = c.position,
			rotation   = c.rotation,
			linear     = c.linear_velocity,
			angular    = c.angular_velocity,
		}
		return true
	case .Destroy_Body:
		b := find_body(w, physics.payload(command, physics.Destroy_Body).body)
		if b == nil {
			return false
		}
		b^ = {}
		return true
	case .Set_Pose:
		c := physics.payload(command, physics.Set_Pose)
		b := find_body(w, c.body)
		if b == nil {
			return false
		}
		b.position, b.rotation = c.position, c.rotation
		return true
	case .Move_Kinematic:
		c := physics.payload(command, physics.Move_Kinematic)
		b := find_body(w, c.body)
		if b == nil {
			return false
		}
		b.position, b.rotation = c.position, c.rotation
		return true
	case .Set_Velocity:
		c := physics.payload(command, physics.Set_Velocity)
		b := find_body(w, c.body)
		if b == nil {
			return false
		}
		b.linear, b.angular = c.linear, c.angular
		return true
	case .Add_Force, .Add_Torque, .Add_Impulse, .Add_Angular_Impulse:
		return find_body(w, physics.payload(command, physics.Add_Vector).body) != nil
	case .Add_Force_At:
		return find_body(w, physics.payload(command, physics.Add_Force_At).body) != nil
	case .Activate, .Deactivate:
		return find_body(w, physics.payload(command, physics.Body_Command).body) != nil
	case .Set_Enabled:
		return find_body(w, physics.payload(command, physics.Set_Enabled).body) != nil
	case .Create_Joint:
		c := physics.payload(command, physics.Create_Joint)
		if c.joint.generation == 0 || int(c.joint.index) >= len(w.joints) || find_body(w, c.a) == nil {
			return false
		}
		if c.b.generation != 0 && find_body(w, c.b) == nil {
			return false
		}
		w.joints[c.joint.index] = c.joint.generation
		return true
	case .Destroy_Joint, .Set_Joint:
		joint := physics.payload(command, physics.Destroy_Joint).joint
		if joint.generation == 0 || int(joint.index) >= len(w.joints) || w.joints[joint.index] != joint.generation {
			return false
		}
		if command.kind == .Destroy_Joint {
			w.joints[joint.index] = 0
		}
		return true
	case .Create_Compound:
		c := physics.payload(command, physics.Create_Compound)
		if c.shape.generation == 0 || int(c.shape.index) >= len(w.shapes) || c.count == 0 {
			return false
		}
		for child in physics.compound_children(command) {
			if child.generation == 0 || int(child.index) >= len(w.shapes) || w.shapes[child.index] != child.generation {
				return false
			}
		}
		w.shapes[c.shape.index] = c.shape.generation
		return true
	}
	return false
}

@(private)
step :: proc "c" (handle: physics.World, dt: f32, substeps: i32) -> b32 {
	context = runtime.default_context()
	return find_world(handle) != nil
}

@(private)
results :: proc "c" (handle: physics.World, out: ^physics.Step_Results) {
	out^ = {}
}

@(private)
body_state :: proc "c" (handle: physics.World, bodies: [^]physics.Body, count: u32, out: [^]physics.Body_State) {
	context = runtime.default_context()
	w := find_world(handle)
	for i in 0 ..< count {
		out[i] = {}
		if w == nil {
			continue
		}
		if b := find_body(w, bodies[i]); b != nil {
			out[i] = {
				body             = bodies[i],
				user             = b.user,
				position         = b.position,
				rotation         = b.rotation,
				linear_velocity  = b.linear,
				angular_velocity = b.angular,
			}
		}
	}
}

@(private)
create_mesh_shape :: proc "c" (
	handle: physics.World,
	shape: physics.Shape,
	kind: physics.Shape_Kind,
	vertices: [^][3]f32,
	vertex_count: u32,
	triangles: [^][3]u32,
	triangle_count: u32,
	density: f32,
) -> b32 {
	context = runtime.default_context()
	w := find_world(handle)
	if w == nil || shape.generation == 0 || int(shape.index) >= len(w.shapes) || vertex_count == 0 {
		return false
	}
	if kind == .Mesh {
		if triangle_count == 0 {
			return false
		}
		for t in triangles[:triangle_count] {
			if t.x >= vertex_count || t.y >= vertex_count || t.z >= vertex_count {
				return false
			}
		}
	} else if kind != .Convex_Hull {
		return false
	}
	w.shapes[shape.index] = shape.generation
	return true
}

@(private)
raycast_all :: proc "c" (handle: physics.World, ray: ^physics.Ray, filter: ^physics.Query_Filter, out: [^]physics.Ray_Hit, capacity: u32) -> u32 {
	return 0
}

@(private)
raycast_batch :: proc "c" (handle: physics.World, rays: [^]physics.Ray, count: u32, filter: ^physics.Query_Filter, out: [^]physics.Ray_Hit) {
	for i in 0 ..< count {
		out[i] = {}
	}
}

@(private)
shape_cast :: proc "c" (handle: physics.World, sweep: ^physics.Shape_Cast, filter: ^physics.Query_Filter, hit: ^physics.Ray_Hit) -> b32 {
	hit^ = {}
	return false
}

@(private)
overlap :: proc "c" (handle: physics.World, query: ^physics.Overlap_Query, filter: ^physics.Query_Filter, out: [^]physics.Overlap_Hit, capacity: u32) -> u32 {
	return 0
}

@(private)
raycast :: proc "c" (handle: physics.World, ray: ^physics.Ray, filter: ^physics.Query_Filter, hit: ^physics.Ray_Hit) -> b32 {
	hit^ = {}
	return false
}
