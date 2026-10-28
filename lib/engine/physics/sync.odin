package physics

import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"

import core_physics "cinnabar:core/physics"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
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
	note_breaks(s, w, results.broken[:results.broken_count])
	clear(&s.tick_contacts)
	for e in results.contacts[:results.contact_count] {
		c := Contact {
			kind              = e.kind,
			sensor            = e.sensor,
			a                 = ecs.Entity(e.a_user),
			b                 = ecs.Entity(e.b_user),
			point             = ecs.position_offset_f64(s.anchor, e.point),
			normal            = e.normal,
			relative_velocity = e.relative_velocity,
			impulse           = e.impulse,
		}
		append(&s.tick_contacts, c)
		append(&s.frame_contacts, c)
	}
}

// begin_frame starts the frame's contacts. Call it before the frame's ticks.
begin_frame :: proc(s: ^State) {
	clear(&s.frame_contacts)
}

// sync makes the backend's world match the components without stepping it, as the editor's edit mode does, so that
// queries see the scene as it is edited. It returns false if the world is missing.
sync :: proc(s: ^State, w: ^ecs.World, dt: f32 = 1.0 / 60) -> bool {
	if s.world.generation == 0 {
		return false
	}
	// Before the sync's own commands, which may destroy the bodies that the effects name.
	submit_pending(s)
	list := core_physics.command_list(allocator_of(s))
	commands := ecs.commands(allocator_of(s))
	if s.settings_dirty {
		core_physics.cmd_set_world(&list, s.gravity, s.layers.collides)
		s.settings_dirty = false
	}
	parts := collect_parts(s, w)
	check_bodies(s, w, &list, &commands)
	add_bodies(s, w, &list, &commands, &parts)
	update_bodies(s, w, &list, &commands, &parts, dt)
	// The joints need the Physics_Body of a body that this sync made.
	ecs.apply(w, {commands})
	commands = ecs.commands(allocator_of(s))
	sync_joints(s, w, &list, &commands)
	ok := core_physics.submit(api(s), s.world, list)
	for shape in s.released_shapes {
		pool_free(&s.shapes, core_physics.Handle(shape))
	}
	clear(&s.released_shapes)
	ecs.apply(w, {commands})
	if !ok {
		log.warn("physics: the backend rejected some commands")
	}
	return true
}

// Part is a Collider of a body's compound shape, on a descendant of the body's entity: its pose in the body's
// unscaled space, composed from the Local_Transforms between them, so it does not change while the body moves.
@(private)
Part :: struct {
	entity:   ecs.Entity,
	collider: Collider,
	offset:   [3]f32,
	rotation: quaternion128,
	scale:    [3]f32,
}

@(private)
Parts :: struct {
	by_body: map[ecs.Entity][dynamic]Part,
	// The body that each part belongs to.
	owner:   map[ecs.Entity]ecs.Entity,
}

// collect_parts finds the parts of every body: each Collider without a Rigid_Body that has an ancestor with one, the
// nearest. The world keeps no child lists, so this is a walk up from each such Collider, in query order.
@(private)
collect_parts :: proc(s: ^State, w: ^ecs.World) -> (parts: Parts) {
	allocator := allocator_of(s)
	parts.by_body = make(map[ecs.Entity][dynamic]Part, allocator)
	parts.owner = make(map[ecs.Entity]ecs.Entity, allocator)
	it := ecs.query_iter(w, s.queries.parts)
	for view in ecs.query_next(&it) {
		colliders := ecs.column(view, 0, Collider)
		for e, row in ecs.entities(view) {
			owner, pose := walk_up(w, e, proc(w: ^ecs.World, e: ecs.Entity) -> bool {return ecs.has(w, e, Rigid_Body)})
			if owner == 0 || owner == e {
				continue
			}
			list, found := &parts.by_body[owner]
			if !found {
				parts.by_body[owner] = make([dynamic]Part, allocator)
				list = &parts.by_body[owner]
			}
			append(list, Part{entity = e, collider = colliders[row], offset = pose.offset, rotation = pose.rotation, scale = pose.scale})
			parts.owner[e] = owner
		}
	}
	return
}

// walk_up finds the nearest of e and its ancestors that stop accepts, and e's pose in that entity's unscaled space,
// composed from the Local_Transforms between them, so it does not change while they move together. It gives 0 when
// none is found within the hierarchy's depth limit.
@(private)
walk_up :: proc(w: ^ecs.World, e: ecs.Entity, stop: proc(w: ^ecs.World, e: ecs.Entity) -> bool) -> (owner: ecs.Entity, pose: ecs.Local_Transform) {
	pose = ecs.LOCAL_TRANSFORM_IDENTITY
	current := e
	for _ in 0 ..< ecs.MAX_HIERARCHY_DEPTH {
		if stop(w, current) {
			return current, pose
		}
		if local := ecs.get(w, current, ecs.Local_Transform); local != nil {
			pose.offset = local.offset + linalg.quaternion_mul_vector3(local.rotation, local.scale * pose.offset)
			pose.rotation = local.rotation * pose.rotation
			pose.scale = local.scale * pose.scale
		}
		parent := ecs.get(w, current, ecs.Parent)
		if parent == nil {
			break
		}
		current = parent.entity
	}
	return 0, pose
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

// add_bodies makes the bodies of the entities that have a Collider or a Rigid_Body and no Physics_Body yet, except the
// parts of other bodies. A Rigid_Body with no Collider and no parts gets a nil Physics_Body, so that it is warned
// about once.
@(private)
add_bodies :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, commands: ^ecs.Commands, parts: ^Parts) {
	add :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, commands: ^ecs.Commands, parts: ^Parts, e: ecs.Entity, pose: ecs.Transform) {
		pb := Physics_Body{}
		create_body(s, w, list, e, pose, &pb, parts.by_body[e][:])
		if pb.body.generation == 0 {
			log.warnf("physics: entity %v has no collider that makes a shape, so it has no body", e)
		}
		ecs.command_add(commands, w, e, pb)
		if pb.motion != .Static && !ecs.has(w, e, ecs.Previous_Transform) {
			ecs.command_add(commands, w, e, ecs.Previous_Transform(pose))
		}
	}
	it := ecs.query_iter(w, s.queries.new_colliders)
	for view in ecs.query_next(&it) {
		transforms := ecs.column(view, 0, ecs.Transform)
		for e, row in ecs.entities(view) {
			if e not_in parts.owner {
				add(s, w, list, commands, parts, e, transforms[row])
			}
		}
	}
	it = ecs.query_iter(w, s.queries.new_bodies)
	for view in ecs.query_next(&it) {
		transforms := ecs.column(view, 0, ecs.Transform)
		for e, row in ecs.entities(view) {
			add(s, w, list, commands, parts, e, transforms[row])
		}
	}
}

// update_bodies makes again the bodies whose components or parts changed, and sends the poses that someone else
// moved: a static body is set where it is, a kinematic one moves there in the tick, and a dynamic one is teleported,
// as in Unity. An entity that became a part of another body gives up its own.
@(private)
update_bodies :: proc(s: ^State, w: ^ecs.World, list: ^core_physics.Command_List, commands: ^ecs.Commands, parts: ^Parts, dt: f32) {
	it := ecs.query_iter(w, s.queries.bodies)
	for view in ecs.query_next(&it) {
		transforms := ecs.column(view, 0, ecs.Transform)
		bodies := ecs.column(view, 1, Physics_Body)
		for e, row in ecs.entities(view) {
			pb, pose := &bodies[row], transforms[row]
			if e in parts.owner {
				if pool_valid(&s.bodies, core_physics.Handle(pb.body)) {
					destroy_body(s, list, pb.body)
				}
				ecs.command_remove(commands, w, e, Physics_Body)
				continue
			}
			body_parts := parts.by_body[e][:]
			if source_hash(s, w, e, body_parts) != pb.source {
				if pool_valid(&s.bodies, core_physics.Handle(pb.body)) {
					destroy_body(s, list, pb.body)
				}
				create_body(s, w, list, e, pose, pb, body_parts)
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

// create_body sends the commands that make e's body from its Collider and its parts, and fills pb with it. One
// collider is the body's shape; several are the children of a compound. The shapes' handles are released at once:
// the body holds its shape. Without a collider, the body is nil.
@(private)
create_body :: proc(
	s: ^State,
	w: ^ecs.World,
	list: ^core_physics.Command_List,
	e: ecs.Entity,
	pose: ecs.Transform,
	pb: ^Physics_Body,
	parts: []Part,
) {
	velocity, spin := pb.linear_velocity, pb.angular_velocity
	pb^ = {source = source_hash(s, w, e, parts), position = pose.position, rotation = pose.rotation}
	own := ecs.get(w, e, Collider)
	if own == nil && len(parts) == 0 {
		return
	}
	rb := ecs.get(w, e, Rigid_Body)
	body := rb^ if rb != nil else Rigid_Body{motion = .Static}
	material := own^ if own != nil else parts[0].collider

	dynamic_body := body.motion == .Dynamic
	children := make([dynamic]core_physics.Shape, allocator_of(s))
	if own != nil {
		if child, ok := child_shape(s, list, e, own^, own.offset * pose.scale, own.rotation, pose.scale, dynamic_body); ok {
			append(&children, child)
		}
	}
	for part in parts {
		if len(children) == core_physics.MAX_COMPOUND_CHILDREN {
			log.warnf("physics: entity %v has more than %d colliders; the rest are left out", e, core_physics.MAX_COMPOUND_CHILDREN)
			break
		}
		c := part.collider
		offset := pose.scale * (part.offset + linalg.quaternion_mul_vector3(part.rotation, part.scale * c.offset))
		if child, ok := child_shape(s, list, part.entity, c, offset, part.rotation * c.rotation, pose.scale * part.scale, dynamic_body); ok {
			append(&children, child)
		}
	}
	if len(children) == 0 {
		// Every collider's mesh is missing; the warnings said why.
		return
	}
	shape: core_physics.Shape
	if len(children) == 1 {
		shape = children[0]
	} else {
		shape = core_physics.Shape(pool_alloc(&s.shapes))
		core_physics.cmd_create_compound(list, shape, children[:])
		for child in children {
			core_physics.cmd_release_shape(list, child)
			append(&s.released_shapes, child)
		}
	}

	handle := core_physics.Body(pool_alloc(&s.bodies))
	desc := core_physics.body_desc(handle, shape, body.motion, ecs.position_sub_f64(pose.position, s.anchor), u64(e), material.layer)
	desc.rotation = to_rotation(pose.rotation)
	desc.mass = body.mass
	desc.friction = material.friction
	desc.restitution = material.restitution
	desc.linear_damping = body.linear_damping
	desc.angular_damping = body.angular_damping
	desc.gravity_factor = body.gravity_factor
	if body.motion == .Dynamic {
		desc.linear_velocity, desc.angular_velocity = velocity, spin
	}
	if material.sensor {
		desc.flags += {.Sensor}
	}
	if material.detect_static {
		desc.flags += {.Detect_Static}
	}
	if body.report_contacts {
		desc.flags += {.Report_Contacts}
	}
	if body.ccd {
		desc.flags += {.Ccd}
	}
	if body.start_asleep {
		desc.flags += {.Start_Asleep}
	}
	core_physics.cmd_create_body(list, desc)
	core_physics.cmd_release_shape(list, shape)
	append(&s.released_shapes, shape)

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

// child_shape makes a collider's shape at an offset and a rotation in its body, with its dimensions scaled: a primitive
// through a command, and a mesh at once, from its collision data with the offset, the rotation and the scale applied
// to its vertices. A dynamic body takes a mesh's convex hull. It returns false, with a warning, when the mesh is
// missing.
@(private)
child_shape :: proc(
	s: ^State,
	list: ^core_physics.Command_List,
	e: ecs.Entity,
	c: Collider,
	offset: [3]f32,
	rotation: quaternion128,
	scale: [3]f32,
	dynamic_body: bool,
) -> (
	core_physics.Shape,
	bool,
) {
	if c.shape != .Mesh && c.shape != .Convex_Mesh {
		shape := core_physics.Shape(pool_alloc(&s.shapes))
		kind, size := collider_size(c, scale)
		core_physics.cmd_create_shape(list, shape, kind, size, c.density, offset, to_rotation(rotation))
		return shape, true
	}
	data, blob, ok := mesh_data(s, c.mesh)
	if !ok {
		log.warnf("physics: entity %v's collider has no mesh %v loaded", e, c.mesh)
		return {}, false
	}
	positions := format.mesh_collision_positions(data, blob)
	triangles := format.mesh_collision_triangles(data, blob)
	if len(positions) == 0 || len(triangles) == 0 {
		log.warnf("physics: mesh %v has no collision data: its collision import setting is false", c.mesh)
		return {}, false
	}
	kind := core_physics.Shape_Kind.Mesh if c.shape == .Mesh else .Convex_Hull
	if kind == .Mesh && dynamic_body {
		log.warnf("physics: entity %v is dynamic, so its mesh collider is the mesh's convex hull", e)
		kind = .Convex_Hull
	}
	placed := make([][3]f32, len(positions), allocator_of(s))
	for p, i in positions {
		placed[i] = offset + linalg.quaternion_mul_vector3(rotation, p * scale)
	}
	shape := core_physics.Shape(pool_alloc(&s.shapes))
	if !api(s).create_mesh_shape(s.world, shape, kind, raw_data(placed), u32(len(placed)), raw_data(triangles), u32(len(triangles)), c.density) {
		pool_free(&s.shapes, core_physics.Handle(shape))
		return {}, false
	}
	return shape, true
}

// mesh_data is a mesh asset's blob, which it loads if it is not loaded.
@(private)
mesh_data :: proc(s: ^State, guid: format.Guid) -> (data: []byte, blob: ^format.Mesh_Blob, ok: bool) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.load(s.assets, guid) or_return
	data = asset.data(s.assets, h) or_return
	blob = format.mesh_view(data) or_return
	return data, blob, true
}

// mesh_version is how many times hot reload swapped a collider's mesh, so that a body made from it is made again.
@(private)
mesh_version :: proc(s: ^State, c: ^Collider) -> u32 {
	if s.assets == nil || (c.shape != .Mesh && c.shape != .Convex_Mesh) {
		return 0
	}
	h, loaded := asset.find(s.assets, c.mesh)
	return asset.version(s.assets, h) if loaded else 0
}

@(private)
destroy_body :: proc(s: ^State, list: ^core_physics.Command_List, body: core_physics.Body) {
	core_physics.cmd_destroy_body(list, body)
	pool_free(&s.bodies, core_physics.Handle(body))
	s.records[body.index] = {}
}

// collider_size gives the backend's shape for a collider at a scale: a box's half extents, a sphere's radius in x, a
// capsule's or a cylinder's radius in x and the half height of its cylinder in y, and a mesh's scale. Scale is applied to the
// dimensions, so no shape needs a scaled wrapper: a sphere takes the largest axis, and a capsule or cylinder the
// largest of x and z for its radius. The editor draws colliders with it.
collider_size :: proc(c: Collider, pose_scale: [3]f32) -> (core_physics.Shape_Kind, [3]f32) {
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
	case .Mesh:
		return .Mesh, scale
	case .Convex_Mesh:
		return .Convex_Hull, scale
	}
	return .Box, 1
}

// source_hash is what a body is made from: the Rigid_Body, the Collider, the entity's scale, and each part's
// Collider and pose in the body, with the version of each mesh that a collider names.
@(private)
source_hash :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity, parts: []Part) -> u64 {
	bytes :: proc(p: ^$T) -> []byte {
		return ([^]byte)(p)[:size_of(T)]
	}
	h := hash.fnv64a({})
	if rb := ecs.get(w, e, Rigid_Body); rb != nil {
		h = hash.fnv64a(bytes(rb), h)
	} else {
		h = hash.fnv64a({0}, h)
	}
	if c := ecs.get(w, e, Collider); c != nil {
		h = hash.fnv64a(bytes(c), h)
		version := mesh_version(s, c)
		h = hash.fnv64a(bytes(&version), h)
	} else {
		h = hash.fnv64a({1}, h)
	}
	if pose := ecs.get(w, e, ecs.Transform); pose != nil {
		scale := pose.scale
		h = hash.fnv64a(bytes(&scale), h)
	}
	for &part in parts {
		h = hash.fnv64a(bytes(&part.collider), h)
		version := mesh_version(s, &part.collider)
		h = hash.fnv64a(bytes(&version), h)
		h = hash.fnv64a(bytes(&part.offset), h)
		h = hash.fnv64a(bytes(&part.rotation), h)
		h = hash.fnv64a(bytes(&part.scale), h)
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
