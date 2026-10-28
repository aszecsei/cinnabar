package physics

import "core:math/linalg"

import core_physics "cinnabar:core/physics"
import "cinnabar:engine/ecs"

// Filter chooses what a query hits: layers is a mask of object layers, sensors are left out unless include_sensors is
// set, and the bodies of the ignore entities are skipped, up to core_physics.MAX_QUERY_IGNORE of them. A query has no
// callback: everything it filters on is data.
Filter :: struct {
	layers:          u32,
	include_sensors: bool,
	ignore:          []ecs.Entity,
}

FILTER_ALL :: Filter{layers = max(u32)}

// Hit is where a query hit a body: its entity, the point, the surface's normal, and the distance along the ray or the
// sweep. The zero Hit is a miss.
Hit :: struct {
	entity:    ecs.Entity,
	position:  ecs.World_Position,
	normal:    [3]f32,
	distance:  f32,
	sub_shape: u32,
}

Ray :: struct {
	origin:       ecs.World_Position,
	direction:    [3]f32,
	max_distance: f32,
}

// Queries run at any time outside the physics tick, from any number of jobs at once, and see the world as the last
// tick or sync left it (see docs/physics/design.md#queries). A backend without Queries misses every one.

// raycast gives the closest hit along a ray. direction need not be a unit vector.
raycast :: proc(s: ^State, w: ^ecs.World, origin: ecs.World_Position, direction: [3]f32, max_distance: f32, filter := FILTER_ALL) -> (hit: Hit, ok: bool) {
	if .Queries not_in s.features {
		return
	}
	ray := to_ray(s, {origin, direction, max_distance})
	f := to_filter(w, filter)
	result: core_physics.Ray_Hit
	if !api(s).raycast(s.world, &ray, &f, &result) {
		return
	}
	return from_hit(s, result), true
}

// raycast_all gives every hit along a ray, by distance: the first len(out) of them go to out, and the count is all
// of them, so a caller can ask again with more room.
raycast_all :: proc(s: ^State, w: ^ecs.World, origin: ecs.World_Position, direction: [3]f32, max_distance: f32, out: []Hit, filter := FILTER_ALL) -> int {
	if .Queries not_in s.features {
		return 0
	}
	ray := to_ray(s, {origin, direction, max_distance})
	f := to_filter(w, filter)
	results := make([]core_physics.Ray_Hit, len(out), allocator_of(s))
	count := api(s).raycast_all(s.world, &ray, &f, raw_data(results), u32(len(out)))
	for i in 0 ..< min(int(count), len(out)) {
		out[i] = from_hit(s, results[i])
	}
	return int(count)
}

// raycast_batch gives the closest hit of each ray in out, a zero Hit for a miss, in one call to the backend. A system
// that casts many rays a tick, such as sight lines, uses it.
raycast_batch :: proc(s: ^State, w: ^ecs.World, rays: []Ray, out: []Hit, filter := FILTER_ALL) {
	assert(len(out) >= len(rays))
	if .Queries not_in s.features {
		for &h in out[:len(rays)] {
			h = {}
		}
		return
	}
	f := to_filter(w, filter)
	sent := make([]core_physics.Ray, len(rays), allocator_of(s))
	for r, i in rays {
		sent[i] = to_ray(s, r)
	}
	results := make([]core_physics.Ray_Hit, len(rays), allocator_of(s))
	api(s).raycast_batch(s.world, raw_data(sent), u32(len(rays)), &f, raw_data(results))
	for i in 0 ..< len(rays) {
		out[i] = results[i].body.generation != 0 ? from_hit(s, results[i]) : {}
	}
}

// shape_cast sweeps a primitive shape, sized as a Collider is at scale 1, from origin along direction for distance meters, and
// gives the first hit: the contact point, the normal of the surface it hit, and the distance swept. The Collider's
// offset and rotation are not used; rotation is the shape's.
shape_cast :: proc(
	s: ^State,
	w: ^ecs.World,
	shape: Collider,
	origin: ecs.World_Position,
	rotation: quaternion128,
	direction: [3]f32,
	distance: f32,
	filter := FILTER_ALL,
) -> (
	hit: Hit,
	ok: bool,
) {
	if .Queries not_in s.features {
		return
	}
	sweep := core_physics.Shape_Cast {
		origin    = ecs.position_sub_f64(origin, s.anchor),
		rotation  = to_rotation(rotation),
		direction = linalg.normalize0(direction),
		distance  = distance,
		shape     = shape_desc(shape),
	}
	f := to_filter(w, filter)
	result: core_physics.Ray_Hit
	if !api(s).shape_cast(s.world, &sweep, &f, &result) {
		return
	}
	return from_hit(s, result), true
}

// overlap gives the entities whose bodies overlap a shape at a pose, in the order of their bodies' handles: the first
// len(out) of them go to out, and the count is all of them.
overlap :: proc(s: ^State, w: ^ecs.World, shape: Collider, origin: ecs.World_Position, rotation: quaternion128, out: []ecs.Entity, filter := FILTER_ALL) -> int {
	if .Queries not_in s.features {
		return 0
	}
	query := core_physics.Overlap_Query {
		origin   = ecs.position_sub_f64(origin, s.anchor),
		rotation = to_rotation(rotation),
		shape    = shape_desc(shape),
	}
	f := to_filter(w, filter)
	results := make([]core_physics.Overlap_Hit, len(out), allocator_of(s))
	count := api(s).overlap(s.world, &query, &f, raw_data(results), u32(len(out)))
	for i in 0 ..< min(int(count), len(out)) {
		out[i] = ecs.Entity(results[i].user)
	}
	return int(count)
}

@(private)
to_ray :: proc(s: ^State, r: Ray) -> core_physics.Ray {
	return {origin = ecs.position_sub_f64(r.origin, s.anchor), direction = linalg.normalize0(r.direction), max_distance = r.max_distance}
}

@(private)
from_hit :: proc(s: ^State, h: core_physics.Ray_Hit) -> Hit {
	return {
		entity = ecs.Entity(h.user),
		position = ecs.position_offset_f64(s.anchor, h.position),
		normal = h.normal,
		distance = h.distance,
		sub_shape = h.sub_shape,
	}
}

@(private)
to_filter :: proc(w: ^ecs.World, f: Filter) -> (out: core_physics.Query_Filter) {
	out.layers = f.layers
	if f.include_sensors {
		out.flags += {.Include_Sensors}
	}
	for e in f.ignore {
		if out.ignore_count == core_physics.MAX_QUERY_IGNORE {
			break
		}
		if pb := ecs.is_alive(w, e) ? ecs.get(w, e, Physics_Body) : nil; pb != nil && pb.body.generation != 0 {
			out.ignore[out.ignore_count] = pb.body
			out.ignore_count += 1
		}
	}
	return
}

@(private)
shape_desc :: proc(c: Collider) -> core_physics.Shape_Desc {
	kind, size := collider_size(c, 1)
	return {kind = kind, size = size}
}
