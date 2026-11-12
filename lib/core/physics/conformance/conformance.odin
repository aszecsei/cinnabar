// Package physics_conformance is the suite that every simulating backend passes, driven through Physics_API with no
// engine world. A backend's tests call each procedure with its table. See docs/physics/backends.md#conformance.
package physics_conformance

import "core:math"
import "core:mem"
import "core:testing"

import physics "cinnabar:core/physics"

STEP :: f32(1) / 60
GRAVITY :: [3]f32{0, -9.81, 0}

GROUND :: physics.Body{0, 1}
BOX :: physics.Body{1, 1}
GROUND_SHAPE :: physics.Shape{0, 1}
BOX_SHAPE :: physics.Shape{1, 1}

// Every layer collides with every other.
@(private)
all_layers :: proc() -> (collides: [physics.MAX_LAYERS]u32) {
	for &mask in collides {
		mask = max(u32)
	}
	return
}

// world makes a world with gravity and a ground whose top is at y = 0, and the box shape, half a meter on a side.
@(private)
world :: proc(t: ^testing.T, api: ^physics.Physics_API) -> physics.World {
	w := api.world_create(&physics.World_Desc{max_bodies = 1024, max_shapes = 64})
	testing.expect(t, w.generation != 0)
	list := physics.command_list(context.temp_allocator)
	physics.cmd_set_world(&list, GRAVITY, all_layers())
	physics.cmd_create_shape(&list, GROUND_SHAPE, .Box, {50, 0.5, 50})
	physics.cmd_create_shape(&list, BOX_SHAPE, .Box, {0.5, 0.5, 0.5})
	physics.cmd_create_body(&list, physics.body_desc(GROUND, GROUND_SHAPE, .Static, {0, -0.5, 0}, user = 1))
	testing.expect(t, physics.submit(api, w, list))
	return w
}

@(private)
state :: proc(api: ^physics.Physics_API, w: physics.World, body: physics.Body) -> (out: physics.Body_State) {
	body := body
	api.body_state(w, &body, 1, &out)
	return
}

// falling_box: a box dropped from 5 m lands on the ground, comes to rest on it, and falls asleep. While it falls, the
// step's results report it with its user value.
falling_box :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(BOX, BOX_SHAPE, .Dynamic, {0, 5, 0}, user = 42))
	testing.expect(t, physics.submit(api, w, list))

	reported := false
	for _ in 0 ..< 240 {
		testing.expect(t, bool(api.step(w, STEP, 1)))
		results: physics.Step_Results
		api.results(w, &results)
		for s in results.moved[:results.moved_count] {
			if s.body == BOX {
				reported = true
				testing.expect_value(t, s.user, 42)
			}
			testing.expect(t, s.body != GROUND, "a static body never moves")
		}
	}
	testing.expect(t, reported, "the falling box was in the step's results")

	s := state(api, w, BOX)
	testing.expect_value(t, s.body, BOX)
	// Resting contacts keep a little penetration: Jolt's is 2 cm.
	testing.expectf(t, math.abs(s.position.y - 0.5) < 0.03, "the box rests on the ground: y = %v", s.position.y)
	testing.expectf(t, math.abs(s.position.x) < 1e-3 && math.abs(s.position.z) < 1e-3, "the box fell straight: %v", s.position)
	testing.expect(t, .Asleep in s.flags, "the box fell asleep")
}

// ray: a ray hits a box's top, with its body, user value, distance, point and normal, and misses when the filter
// leaves out the box's layer, ignores the box, or the box is a sensor, unless the filter includes sensors.
ray :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	SENSOR :: physics.Body{2, 1}
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(BOX, BOX_SHAPE, .Static, {0, 2, 0}, user = 42, layer = 3))
	sensor := physics.body_desc(SENSOR, BOX_SHAPE, .Static, {5, 2, 0}, user = 7)
	sensor.flags = {.Sensor}
	physics.cmd_create_body(&list, sensor)
	testing.expect(t, physics.submit(api, w, list))

	down := physics.Ray{origin = {0, 10, 0}, direction = {0, -1, 0}, max_distance = 20}
	hit: physics.Ray_Hit
	testing.expect(t, bool(api.raycast(w, &down, nil, &hit)))
	testing.expect_value(t, hit.body, BOX)
	testing.expect_value(t, hit.user, 42)
	testing.expectf(t, math.abs(hit.distance - 7.5) < 1e-3, "distance %v", hit.distance)
	testing.expectf(t, math.abs(hit.position.y - 2.5) < 1e-3, "point %v", hit.position)
	testing.expectf(t, math.abs(hit.normal.y - 1) < 1e-3, "normal %v", hit.normal)

	short := down
	short.max_distance = 5
	testing.expect(t, !api.raycast(w, &short, nil, &hit), "a ray that ends above the box misses")

	not_layer_3 := physics.FILTER_ALL
	not_layer_3.layers &~= 1 << 3
	testing.expect(t, bool(api.raycast(w, &down, &not_layer_3, &hit)), "a filter without the box's layer hits the ground")
	testing.expect_value(t, hit.body, GROUND)

	ignore := physics.FILTER_ALL
	ignore.ignore[0] = BOX
	ignore.ignore_count = 1
	testing.expect(t, bool(api.raycast(w, &down, &ignore, &hit)), "an ignored box lets the ray reach the ground")
	testing.expect_value(t, hit.body, GROUND)

	at_sensor := down
	at_sensor.origin.x = 5
	testing.expect(t, bool(api.raycast(w, &at_sensor, nil, &hit)))
	testing.expect_value(t, hit.body, GROUND)
	with_sensors := physics.FILTER_ALL
	with_sensors.flags = {.Include_Sensors}
	testing.expect(t, bool(api.raycast(w, &at_sensor, &with_sensors, &hit)))
	testing.expect_value(t, hit.body, SENSOR)
}

// stale_handles: a command for a destroyed body, an unknown shape or an index outside the world is rejected and logged,
// and the valid commands in the same list still run. The backend logs errors, so run it with a quiet host.
stale_handles :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(BOX, BOX_SHAPE, .Dynamic, {0, 5, 0}))
	physics.cmd_destroy_body(&list, BOX)
	testing.expect(t, physics.submit(api, w, list))

	bad := physics.command_list(context.temp_allocator)
	physics.cmd_set_velocity(&bad, BOX, {1, 0, 0}, {})
	physics.cmd_create_body(&bad, physics.body_desc({3, 1}, {9, 1}, .Dynamic, {0, 5, 0}))
	physics.cmd_create_body(&bad, physics.body_desc({1 << 20, 1}, BOX_SHAPE, .Dynamic, {0, 5, 0}))
	physics.cmd_create_body(&bad, physics.body_desc({4, 1}, BOX_SHAPE, .Dynamic, {3, 5, 0}, user = 4))
	testing.expect(t, !physics.submit(api, w, bad))
	testing.expect_value(t, state(api, w, BOX).body, physics.Body{})
	testing.expect_value(t, state(api, w, {4, 1}).user, 4)

	// A new generation in the same slot is a new body, and the old handle stays stale.
	again := physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&again, physics.body_desc({1, 2}, BOX_SHAPE, .Dynamic, {0, 5, 0}, user = 9))
	testing.expect(t, physics.submit(api, w, again))
	testing.expect_value(t, state(api, w, BOX).body, physics.Body{})
	testing.expect_value(t, state(api, w, {1, 2}).user, 9)
}

// deterministic: two worlds given the same commands, a pile of boxes, report the same poses after two seconds, to the
// bit, and the results are in handle order.
deterministic :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	COUNT :: 40
	run :: proc(t: ^testing.T, api: ^physics.Physics_API) -> (poses: [COUNT]physics.Body_State) {
		w := world(t, api)
		defer api.world_destroy(w)
		list := physics.command_list(context.temp_allocator)
		for i in 0 ..< COUNT {
			x := f64(i % 4) * 0.6 - 0.9
			desc := physics.body_desc({u32(i + 1), 1}, BOX_SHAPE, .Dynamic, {x, 1 + f64(i) * 1.1, f64(i % 3) * 0.3}, user = u64(i))
			desc.rotation = {0, math.sin(f32(i) * 0.1), 0, math.cos(f32(i) * 0.1)}
			physics.cmd_create_body(&list, desc)
		}
		testing.expect(t, physics.submit(api, w, list))
		for _ in 0 ..< 120 {
			api.step(w, STEP, 1)
			results: physics.Step_Results
			api.results(w, &results)
			moved := results.moved[:results.moved_count]
			for i in 1 ..< len(moved) {
				testing.expect(t, moved[i - 1].body.index < moved[i].body.index, "results are in handle order")
			}
		}
		bodies: [COUNT]physics.Body
		for &b, i in bodies {
			b = {u32(i + 1), 1}
		}
		api.body_state(w, &bodies[0], COUNT, &poses[0])
		return
	}
	a := run(t, api)
	b := run(t, api)
	testing.expect(t, mem.compare_ptrs(&a, &b, size_of(a)) == 0, "two runs of the same commands give the same poses")
}

// offset_and_enabled: a shape's offset moves it in its body, and a disabled body neither falls nor is hit until it is
// enabled again.
offset_and_enabled :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	OFFSET_SHAPE :: physics.Shape{2, 1}
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_shape(&list, OFFSET_SHAPE, .Box, {0.5, 0.5, 0.5}, offset = {3, 0, 0})
	physics.cmd_create_body(&list, physics.body_desc(BOX, OFFSET_SHAPE, .Static, {0, 2, 0}, user = 42))
	physics.cmd_release_shape(&list, OFFSET_SHAPE)
	testing.expect(t, physics.submit(api, w, list))
	hit: physics.Ray_Hit
	at_offset := physics.Ray{origin = {3, 10, 0}, direction = {0, -1, 0}, max_distance = 20}
	testing.expect(t, bool(api.raycast(w, &at_offset, nil, &hit)))
	testing.expect_value(t, hit.body, BOX)
	at_origin := physics.Ray{origin = {0, 10, 0}, direction = {0, -1, 0}, max_distance = 20}
	testing.expect(t, bool(api.raycast(w, &at_origin, nil, &hit)))
	testing.expect_value(t, hit.body, GROUND)

	FALLING :: physics.Body{2, 1}
	list = physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(FALLING, BOX_SHAPE, .Dynamic, {-3, 5, 0}))
	physics.cmd_set_enabled(&list, FALLING, false)
	testing.expect(t, physics.submit(api, w, list))
	for _ in 0 ..< 30 {
		api.step(w, STEP, 1)
	}
	testing.expect_value(t, state(api, w, FALLING).position.y, 5)
	above := physics.Ray{origin = {-3, 10, 0}, direction = {0, -1, 0}, max_distance = 20}
	testing.expect(t, bool(api.raycast(w, &above, nil, &hit)))
	testing.expect_value(t, hit.body, GROUND)

	list = physics.command_list(context.temp_allocator)
	physics.cmd_set_enabled(&list, FALLING, true)
	testing.expect(t, physics.submit(api, w, list))
	for _ in 0 ..< 30 {
		api.step(w, STEP, 1)
	}
	testing.expect(t, state(api, w, FALLING).position.y < 5, "an enabled body falls again")
}

@(private)
step_contacts :: proc(api: ^physics.Physics_API, w: physics.World, steps: int, out: ^[dynamic]physics.Contact_Event) {
	for _ in 0 ..< steps {
		api.step(w, STEP, 1)
		results: physics.Step_Results
		api.results(w, &results)
		append(out, ..results.contacts[:results.contact_count])
	}
}

// contacts: a box that reports contacts begins one contact with the ground when it lands, with the normal from the
// ground to the box and an impulse, and ends it when it is destroyed. A body that does not report has none.
contacts :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	QUIET :: physics.Body{2, 1}
	list := physics.command_list(context.temp_allocator)
	desc := physics.body_desc(BOX, BOX_SHAPE, .Dynamic, {0, 3, 0}, user = 42)
	desc.flags = {.Report_Contacts}
	physics.cmd_create_body(&list, desc)
	physics.cmd_create_body(&list, physics.body_desc(QUIET, BOX_SHAPE, .Dynamic, {5, 3, 0}))
	testing.expect(t, physics.submit(api, w, list))
	events := make([dynamic]physics.Contact_Event, context.temp_allocator)
	step_contacts(api, w, 180, &events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		e := events[0]
		testing.expect_value(t, e.kind, physics.Contact_Kind.Begin)
		testing.expect_value(t, e.a, GROUND)
		testing.expect_value(t, e.b, BOX)
		testing.expect_value(t, e.b_user, 42)
		testing.expect(t, !e.sensor)
		testing.expectf(t, e.normal.y > 0.99, "the normal points from the ground to the box: %v", e.normal)
		testing.expectf(t, e.relative_velocity.y < -1, "the box was falling onto the ground: %v", e.relative_velocity)
		testing.expectf(t, e.impulse > 0, "an impulse: %v", e.impulse)
		testing.expectf(t, abs(e.point.y) < 0.05, "at the ground's top: %v", e.point)
	}
	clear(&events)
	list = physics.command_list(context.temp_allocator)
	physics.cmd_destroy_body(&list, BOX)
	testing.expect(t, physics.submit(api, w, list))
	step_contacts(api, w, 1, &events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		testing.expect_value(t, events[0].kind, physics.Contact_Kind.End)
		testing.expect_value(t, events[0].b, BOX)
	}
}

// sensor: a box falls through a sensor, which reports the pair's begin and its end, and does not stop it.
sensor :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	SENSOR :: physics.Body{2, 1}
	list := physics.command_list(context.temp_allocator)
	trigger := physics.body_desc(SENSOR, BOX_SHAPE, .Static, {0, 3, 0}, user = 7)
	trigger.flags = {.Sensor}
	physics.cmd_create_body(&list, trigger)
	physics.cmd_create_body(&list, physics.body_desc(BOX, BOX_SHAPE, .Dynamic, {0, 6, 0}, user = 42))
	testing.expect(t, physics.submit(api, w, list))
	events := make([dynamic]physics.Contact_Event, context.temp_allocator)
	step_contacts(api, w, 120, &events)
	testing.expect_value(t, len(events), 2)
	if len(events) == 2 {
		testing.expect_value(t, events[0].kind, physics.Contact_Kind.Begin)
		testing.expect_value(t, events[1].kind, physics.Contact_Kind.End)
		for e in events {
			testing.expect(t, e.sensor)
			testing.expect_value(t, e.a, BOX)
			testing.expect_value(t, e.b, SENSOR)
		}
	}
	testing.expectf(t, abs(state(api, w, BOX).position.y - 0.5) < 0.03, "the box fell through to the ground")
}

// queries: every hit along a ray by distance, a swept sphere, an overlap, and a batch of rays.
queries :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	HIGH :: physics.Body{2, 1}
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(BOX, BOX_SHAPE, .Static, {0, 2, 0}, user = 42))
	physics.cmd_create_body(&list, physics.body_desc(HIGH, BOX_SHAPE, .Static, {0, 5, 0}, user = 43))
	testing.expect(t, physics.submit(api, w, list))

	down := physics.Ray{origin = {0, 10, 0}, direction = {0, -1, 0}, max_distance = 20}
	hits: [2]physics.Ray_Hit
	testing.expect_value(t, api.raycast_all(w, &down, nil, &hits[0], 2), 3)
	testing.expect_value(t, hits[0].body, HIGH)
	testing.expect_value(t, hits[1].body, BOX)
	testing.expect(t, hits[0].distance < hits[1].distance)

	sweep := physics.Shape_Cast {
		origin    = {0, 10, 0},
		rotation  = {0, 0, 0, 1},
		direction = {0, -1, 0},
		distance  = 20,
		shape     = {kind = .Sphere, size = {0.5, 0, 0}},
	}
	hit: physics.Ray_Hit
	testing.expect(t, bool(api.shape_cast(w, &sweep, nil, &hit)))
	testing.expect_value(t, hit.body, HIGH)
	testing.expectf(t, abs(hit.distance - 4) < 1e-3, "the sphere stops on the box's top: %v", hit.distance)
	testing.expectf(t, abs(hit.position.y - 5.5) < 1e-3, "at its top: %v", hit.position)
	testing.expectf(t, hit.normal.y > 0.99, "facing up: %v", hit.normal)

	query := physics.Overlap_Query{origin = {0, 2, 0.8}, rotation = {0, 0, 0, 1}, shape = {kind = .Sphere, size = {0.5, 0, 0}}}
	found: [4]physics.Overlap_Hit
	testing.expect_value(t, api.overlap(w, &query, nil, &found[0], 4), 1)
	testing.expect_value(t, found[0].body, BOX)
	testing.expect_value(t, found[0].user, 42)

	rays := [2]physics.Ray{down, {origin = {100, 10, 100}, direction = {0, -1, 0}, max_distance = 20}}
	batch: [2]physics.Ray_Hit
	api.raycast_batch(w, &rays[0], 2, nil, &batch[0])
	testing.expect_value(t, batch[0].body, HIGH)
	testing.expect_value(t, batch[1].body, physics.Body{})
}

// A frame whose x is the world's z, for a hinge that swings in the x-y plane.
@(private)
X_TO_Z :: physics.Rotation{0, -0.70710678, 0, 0.70710678}

@(private)
joint_desc :: proc(joint: physics.Joint, kind: physics.Joint_Kind, a, b: physics.Body, at: physics.Position, rotation := physics.Rotation{0, 0, 0, 1}) -> physics.Create_Joint {
	return {joint = joint, kind = kind, a = a, b = b, position_a = at, rotation_a = rotation, position_b = at, rotation_b = rotation}
}

@(private)
distance_to :: proc(api: ^physics.Physics_API, w: physics.World, body: physics.Body, point: physics.Position) -> f64 {
	d := state(api, w, body).position - point
	return math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
}

// joints: a box hinged to the world swings at its distance from the pivot, a disabled joint lets it fall, and a box
// joined to another passes through it unless the joint lets them collide.
joints :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	PIVOT :: physics.Position{0, 5, 0}
	HINGE :: physics.Joint{0, 1}
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(BOX, BOX_SHAPE, .Dynamic, {2, 5, 0}))
	physics.cmd_create_joint(&list, joint_desc(HINGE, .Hinge, BOX, {}, PIVOT, X_TO_Z))
	testing.expect(t, physics.submit(api, w, list))
	for _ in 0 ..< 40 {
		api.step(w, STEP, 1)
	}
	s := state(api, w, BOX)
	testing.expectf(t, s.position.y < 4.5, "the box swung down: %v", s.position)
	testing.expectf(t, abs(distance_to(api, w, BOX, PIVOT) - 2) < 0.05, "at its distance from the pivot: %v", distance_to(api, w, BOX, PIVOT))
	testing.expectf(t, abs(s.position.z) < 1e-3, "in the hinge's plane: %v", s.position)

	list = physics.command_list(context.temp_allocator)
	physics.cmd_set_joint(&list, HINGE, false, .Off, 0, 0)
	testing.expect(t, physics.submit(api, w, list))
	for _ in 0 ..< 60 {
		api.step(w, STEP, 1)
	}
	testing.expectf(t, distance_to(api, w, BOX, PIVOT) > 2.5, "a disabled hinge lets go: %v", state(api, w, BOX).position)

	// Two boxes joined at a distance: without Collide_Connected the upper one falls through the lower one.
	LOWER :: physics.Body{2, 1}
	UPPER :: physics.Body{3, 1}
	list = physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(LOWER, BOX_SHAPE, .Static, {10, 1, 0}))
	physics.cmd_create_body(&list, physics.body_desc(UPPER, BOX_SHAPE, .Dynamic, {10, 3, 0}))
	far := joint_desc({1, 1}, .Distance, UPPER, LOWER, {10, 3, 0})
	far.limit_min, far.limit_max = 0, 10
	physics.cmd_create_joint(&list, far)
	testing.expect(t, physics.submit(api, w, list))
	for _ in 0 ..< 120 {
		api.step(w, STEP, 1)
	}
	testing.expectf(t, abs(state(api, w, UPPER).position.y - 0.5) < 0.03, "it fell through to the ground: %v", state(api, w, UPPER).position)

	// The same with Collide_Connected: it rests on the lower box.
	ABOVE :: physics.Body{4, 1}
	list = physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(ABOVE, BOX_SHAPE, .Dynamic, {10, 3, 5}))
	physics.cmd_create_body(&list, physics.body_desc({5, 1}, BOX_SHAPE, .Static, {10, 1, 5}))
	near := joint_desc({2, 1}, .Distance, ABOVE, {5, 1}, {10, 3, 5})
	near.limit_min, near.limit_max = 0, 10
	near.flags = {.Collide_Connected}
	physics.cmd_create_joint(&list, near)
	testing.expect(t, physics.submit(api, w, list))
	for _ in 0 ..< 120 {
		api.step(w, STEP, 1)
	}
	testing.expectf(t, abs(state(api, w, ABOVE).position.y - 2) < 0.03, "it rests on the lower box: %v", state(api, w, ABOVE).position)
}

// joint_breaks: a joint that carries more than its break force breaks in the step and is reported, and the box falls;
// a destroyed body takes its joints with it, and the joint's handle can still be destroyed.
joint_breaks :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	HOLD :: physics.Joint{0, 1}
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(BOX, BOX_SHAPE, .Dynamic, {0, 5, 0}))
	weak := joint_desc(HOLD, .Point, BOX, {}, {0, 5.5, 0})
	// The box weighs about 9800 N.
	weak.break_force = 1000
	physics.cmd_create_joint(&list, weak)
	testing.expect(t, physics.submit(api, w, list))
	api.step(w, STEP, 1)
	results: physics.Step_Results
	api.results(w, &results)
	testing.expect_value(t, results.broken_count, 1)
	if results.broken_count == 1 {
		testing.expect_value(t, results.broken[0].joint, HOLD)
		testing.expectf(t, results.broken[0].force > 1000, "it carried the box: %v", results.broken[0].force)
	}
	for _ in 0 ..< 30 {
		api.step(w, STEP, 1)
	}
	testing.expectf(t, state(api, w, BOX).position.y < 4, "the box falls: %v", state(api, w, BOX).position)

	OTHER :: physics.Body{2, 1}
	list = physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(OTHER, BOX_SHAPE, .Dynamic, {5, 5, 0}))
	physics.cmd_create_joint(&list, joint_desc({1, 1}, .Fixed, OTHER, {}, {5, 5, 0}))
	physics.cmd_destroy_body(&list, OTHER)
	physics.cmd_destroy_joint(&list, {1, 1})
	testing.expect(t, physics.submit(api, w, list))
	api.step(w, STEP, 1)
}

// motor: a hinge's velocity motor turns its body at the target rate.
motor :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	list := physics.command_list(context.temp_allocator)
	desc := physics.body_desc(BOX, BOX_SHAPE, .Dynamic, {0, 5, 0})
	desc.gravity_factor = 0
	physics.cmd_create_body(&list, desc)
	// A hinge about y, through the box's center.
	spin := joint_desc({0, 1}, .Hinge, BOX, {}, {0, 5, 0}, {0, 0, 0.70710678, 0.70710678})
	spin.motor, spin.motor_target = .Velocity, 2
	physics.cmd_create_joint(&list, spin)
	testing.expect(t, physics.submit(api, w, list))
	for _ in 0 ..< 30 {
		api.step(w, STEP, 1)
	}
	v := state(api, w, BOX).angular_velocity
	testing.expectf(t, abs(abs(v.y) - 2) < 0.05 && abs(v.x) < 1e-3 && abs(v.z) < 1e-3, "it turns at 2 rad/s about y: %v", v)
}

// meshes: a box rests on a ground of two triangles, which a ray from above hits; a dynamic box whose shape is the hull
// of its corners falls and rests on it too; and a dynamic body on a triangle mesh is refused.
meshes :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := api.world_create(&physics.World_Desc{max_bodies = 64, max_shapes = 64})
	defer api.world_destroy(w)
	list := physics.command_list(context.temp_allocator)
	physics.cmd_set_world(&list, GRAVITY, all_layers())
	testing.expect(t, physics.submit(api, w, list))
	// A 20 m square at y = 0, its front faces up.
	quad := [4][3]f32{{-10, 0, -10}, {10, 0, -10}, {10, 0, 10}, {-10, 0, 10}}
	triangles := [2][3]u32{{0, 2, 1}, {0, 3, 2}}
	testing.expect(t, bool(api.create_mesh_shape(w, GROUND_SHAPE, .Mesh, &quad[0], 4, &triangles[0], 2, 1000)))
	corners: [8][3]f32
	for &c, i in corners {
		c = {f32(i & 1) - 0.5, f32((i >> 1) & 1) - 0.5, f32((i >> 2) & 1) - 0.5}
	}
	testing.expect(t, bool(api.create_mesh_shape(w, BOX_SHAPE, .Convex_Hull, &corners[0], 8, nil, 0, 1000)))
	list = physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc(GROUND, GROUND_SHAPE, .Static, {}, user = 1))
	physics.cmd_create_body(&list, physics.body_desc(BOX, BOX_SHAPE, .Dynamic, {0, 3, 0}))
	testing.expect(t, physics.submit(api, w, list))

	down := physics.Ray{origin = {3, 10, 3}, direction = {0, -1, 0}, max_distance = 20}
	hit: physics.Ray_Hit
	testing.expect(t, bool(api.raycast(w, &down, nil, &hit)), "a ray from above hits the mesh's front faces")
	testing.expect_value(t, hit.body, GROUND)
	testing.expectf(t, hit.normal.y > 0.99, "facing up: %v", hit.normal)

	for _ in 0 ..< 180 {
		api.step(w, STEP, 1)
	}
	testing.expectf(t, abs(state(api, w, BOX).position.y - 0.5) < 0.03, "the hull rests on the mesh: %v", state(api, w, BOX).position)

	list = physics.command_list(context.temp_allocator)
	physics.cmd_create_body(&list, physics.body_desc({2, 1}, GROUND_SHAPE, .Dynamic, {0, 5, 0}))
	testing.expect(t, !physics.submit(api, w, list), "a dynamic body on a triangle mesh is refused")
}

// =================================
// Characters
// =================================

@(private)
CHARACTER :: physics.Body{2, 1}

// step_character steps the world, checks that each step's characters are in handle order, and gives the character's
// state from the last step's results, with each step's contacts added to events.
@(private)
step_character :: proc(
	t: ^testing.T,
	api: ^physics.Physics_API,
	w: physics.World,
	body: physics.Body,
	steps: int,
	events: ^[dynamic]physics.Contact_Event = nil,
) -> (
	out: physics.Character_State,
	found: bool,
) {
	for _ in 0 ..< steps {
		testing.expect(t, bool(api.step(w, STEP, 1)))
		results: physics.Step_Results
		api.results(w, &results)
		characters := results.characters[:results.character_count]
		found = false
		for c, i in characters {
			if i > 0 {
				testing.expect(t, characters[i - 1].body.index < c.body.index, "characters are in handle order")
			}
			if c.body == body {
				out, found = c, true
			}
		}
		if events != nil {
			append(events, ..results.contacts[:results.contact_count])
		}
	}
	return
}

// character_moves: a character without the backend's gravity moves by its velocity, high above the ground, and the
// results report it with its user value; a pose teleports it, a disabled one stays, body commands refuse its handle,
// and a destroyed one is stale. The null backend passes it too. The backend logs what it refuses, so run it with a
// quiet host.
character_moves :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	OTHER :: physics.Body{3, 1}
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_character(&list, physics.character_desc(CHARACTER, {0, 20, 0}, user = 42))
	physics.cmd_create_character(&list, physics.character_desc(OTHER, {10, 20, 0}, user = 43))
	physics.cmd_set_character_velocity(&list, CHARACTER, {1, 0, 0})
	physics.cmd_set_character_velocity(&list, OTHER, {})
	testing.expect(t, physics.submit(api, w, list))

	s, found := step_character(t, api, w, CHARACTER, 60)
	testing.expect(t, found, "the character is in the step's results")
	testing.expect_value(t, s.user, 42)
	testing.expect_value(t, s.ground, physics.Ground_State.Air)
	testing.expectf(t, abs(s.position.x - 1) < 0.01 && abs(s.position.y - 20) < 0.01, "it moved a meter: %v", s.position)
	testing.expectf(t, abs(s.velocity.x - 1) < 1e-3, "at its velocity: %v", s.velocity)
	testing.expect_value(t, state(api, w, CHARACTER).user, 42)

	list = physics.command_list(context.temp_allocator)
	physics.cmd_set_character_pose(&list, CHARACTER, {5, 20, 0}, {0, 0, 0, 1})
	physics.cmd_set_enabled(&list, CHARACTER, false)
	testing.expect(t, physics.submit(api, w, list))
	testing.expectf(t, abs(state(api, w, CHARACTER).position.x - 5) < 1e-6, "a pose teleports it: %v", state(api, w, CHARACTER).position)
	_, found = step_character(t, api, w, CHARACTER, 30)
	testing.expect(t, !found, "a disabled character is not in the results")
	testing.expectf(t, abs(state(api, w, CHARACTER).position.x - 5) < 1e-6, "a disabled character stays")

	bad := physics.command_list(context.temp_allocator)
	physics.cmd_set_velocity(&bad, CHARACTER, {1, 0, 0}, {})
	physics.cmd_destroy_body(&bad, CHARACTER)
	physics.cmd_destroy_character(&bad, GROUND)
	testing.expect(t, !physics.submit(api, w, bad), "body commands refuse a character, and character commands a body")

	list = physics.command_list(context.temp_allocator)
	physics.cmd_set_enabled(&list, CHARACTER, true)
	physics.cmd_destroy_character(&list, CHARACTER)
	testing.expect(t, physics.submit(api, w, list))
	testing.expect_value(t, state(api, w, CHARACTER).body, physics.Body{})
	_, found = step_character(t, api, w, OTHER, 1)
	testing.expect(t, found, "the other character is still there")
}

// character_replays: two worlds given the same commands, characters that walk among boxes, report the same characters
// after two seconds, to the bit.
character_replays :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	COUNT :: 4
	run :: proc(t: ^testing.T, api: ^physics.Physics_API) -> (states: [COUNT]physics.Character_State) {
		w := world(t, api)
		defer api.world_destroy(w)
		list := physics.command_list(context.temp_allocator)
		for i in 0 ..< 8 {
			box := physics.body_desc({u32(10 + i), 1}, BOX_SHAPE, .Dynamic, {1.5 + f64(i % 3) * 1.1, 0.5 + f64(i / 3) * 1.05, f64(i % 2) * 0.4})
			box.mass = 5
			physics.cmd_create_body(&list, box)
		}
		for i in 0 ..< COUNT {
			body := physics.Body{u32(2 + i), 1}
			physics.cmd_create_character(&list, physics.character_desc(body, {0, 0.1, f64(i) * 0.7 - 1}, user = u64(i)))
			physics.cmd_set_character_velocity(&list, body, {2, 0, 0.3 * f32(i - 1)}, {.Gravity})
		}
		testing.expect(t, physics.submit(api, w, list))
		for _ in 0 ..< 120 {
			api.step(w, STEP, 1)
		}
		results: physics.Step_Results
		api.results(w, &results)
		testing.expect_value(t, results.character_count, COUNT)
		for c, i in results.characters[:min(results.character_count, COUNT)] {
			states[i] = c
		}
		return
	}
	a := run(t, api)
	b := run(t, api)
	testing.expect(t, mem.compare_ptrs(&a, &b, size_of(a)) == 0, "two runs of the same commands give the same characters")
}

// character_walks_into_wall: a character walks to a wall and stops there on the ground, and a velocity at an angle to
// the wall slides it along.
character_walks_into_wall :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	WALL_SHAPE :: physics.Shape{2, 1}
	list := physics.command_list(context.temp_allocator)
	// Its face is at x = 2.5.
	physics.cmd_create_shape(&list, WALL_SHAPE, .Box, {0.5, 2, 5})
	physics.cmd_create_body(&list, physics.body_desc({3, 1}, WALL_SHAPE, .Static, {3, 2, 0}))
	physics.cmd_create_character(&list, physics.character_desc(CHARACTER, {0, 0.1, 0}))
	physics.cmd_set_character_velocity(&list, CHARACTER, {2, 0, 0}, {.Gravity})
	testing.expect(t, physics.submit(api, w, list))
	s, _ := step_character(t, api, w, CHARACTER, 120)
	testing.expectf(t, s.position.x > 2.1 && s.position.x < 2.21, "it stops at the wall: %v", s.position)
	testing.expectf(t, abs(s.position.y) < 0.05, "on the ground: %v", s.position)
	testing.expect_value(t, s.ground, physics.Ground_State.Ground)
	testing.expect_value(t, s.ground_body, GROUND)
	testing.expect_value(t, s.ground_user, 1)
	testing.expectf(t, s.ground_normal.y > 0.99, "the ground faces up: %v", s.ground_normal)

	list = physics.command_list(context.temp_allocator)
	physics.cmd_set_character_velocity(&list, CHARACTER, {2, 0, 1}, {.Gravity})
	testing.expect(t, physics.submit(api, w, list))
	s, _ = step_character(t, api, w, CHARACTER, 60)
	testing.expectf(t, s.position.z > 0.8 && s.position.x < 2.21, "it slides along the wall: %v", s.position)
}

// character_climbs_step: a character walks up a 0.3 m step, which is under its step_height, and not up a 0.6 m one.
character_climbs_step :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	LOW_SHAPE :: physics.Shape{2, 1}
	HIGH_SHAPE :: physics.Shape{3, 1}
	OTHER :: physics.Body{3, 1}
	list := physics.command_list(context.temp_allocator)
	// Each from x = 1.5 to 5.5.
	physics.cmd_create_shape(&list, LOW_SHAPE, .Box, {2, 0.15, 2})
	physics.cmd_create_shape(&list, HIGH_SHAPE, .Box, {2, 0.3, 2})
	physics.cmd_create_body(&list, physics.body_desc({4, 1}, LOW_SHAPE, .Static, {3.5, 0.15, 0}))
	physics.cmd_create_body(&list, physics.body_desc({5, 1}, HIGH_SHAPE, .Static, {3.5, 0.3, 10}))
	physics.cmd_create_character(&list, physics.character_desc(CHARACTER, {0, 0.1, 0}))
	physics.cmd_create_character(&list, physics.character_desc(OTHER, {0, 0.1, 10}))
	physics.cmd_set_character_velocity(&list, CHARACTER, {2, 0, 0}, {.Gravity})
	physics.cmd_set_character_velocity(&list, OTHER, {2, 0, 0}, {.Gravity})
	testing.expect(t, physics.submit(api, w, list))
	for _ in 0 ..< 90 {
		api.step(w, STEP, 1)
	}
	low, high := state(api, w, CHARACTER), state(api, w, OTHER)
	testing.expectf(t, low.position.x > 2.5 && abs(low.position.y - 0.3) < 0.05, "it climbs the low step: %v", low.position)
	testing.expectf(t, high.position.x < 1.5 && high.position.y < 0.05, "it stops at the high step: %v", high.position)
}

// ramp places a box 6 m long whose top is a ramp at angle radians, rising along x from about the ground at x = 1.
@(private)
ramp :: proc(list: ^physics.Command_List, body: physics.Body, shape: physics.Shape, angle: f32, z: f64) {
	physics.cmd_create_shape(list, shape, .Box, {3, 0.1, 2})
	desc := physics.body_desc(body, shape, .Static, {1 + 3 * f64(math.cos(angle)), 3 * f64(math.sin(angle)), z})
	desc.rotation = {0, 0, math.sin(angle / 2), math.cos(angle / 2)}
	physics.cmd_create_body(list, desc)
}

// character_steep_slope: a character with a max_slope of 45 degrees walks up a 20 degree ramp and not a 60 degree one,
// and one put on the steep ramp stands on steep ground and slides down it.
character_steep_slope :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	STEEP :: f32(math.PI / 3)
	GENTLE :: f32(math.PI / 9)
	CLIMBER :: physics.Body{3, 1}
	SLIDER :: physics.Body{4, 1}
	list := physics.command_list(context.temp_allocator)
	ramp(&list, {5, 1}, {2, 1}, STEEP, 0)
	ramp(&list, {6, 1}, {3, 1}, GENTLE, 10)
	physics.cmd_create_character(&list, physics.character_desc(CHARACTER, {0, 0.1, -1}))
	physics.cmd_create_character(&list, physics.character_desc(CLIMBER, {0, 0.1, 10}))
	// Above the steep ramp's top at its middle, its lower sphere clear of it along the normal.
	center := [2]f64{1 + 3 * f64(math.cos(STEEP)), 3 * f64(math.sin(STEEP))}
	normal := [2]f64{-f64(math.sin(STEEP)), f64(math.cos(STEEP))}
	sphere := center + normal * (0.1 + 0.3 + 0.05)
	physics.cmd_create_character(&list, physics.character_desc(SLIDER, {sphere.x, sphere.y - 0.3, 1.5}))
	physics.cmd_set_character_velocity(&list, CHARACTER, {2, 0, 0}, {.Gravity})
	physics.cmd_set_character_velocity(&list, CLIMBER, {2, 0, 0}, {.Gravity})
	testing.expect(t, physics.submit(api, w, list))

	steep := false
	for _ in 0 ..< 120 {
		s, _ := step_character(t, api, w, SLIDER, 1)
		steep ||= s.ground == .Steep
	}
	testing.expect(t, steep, "the slider stood on steep ground")
	testing.expectf(t, state(api, w, SLIDER).position.y < sphere.y - 1, "it slid down: %v", state(api, w, SLIDER).position)
	walker := state(api, w, CHARACTER)
	testing.expectf(t, walker.position.y < 0.5 && walker.position.x < 1.8, "it does not climb the steep ramp: %v", walker.position)
	climber := state(api, w, CLIMBER)
	testing.expectf(t, climber.position.y > 0.5, "it climbs the gentle ramp: %v", climber.position)
}

// character_moving_platform: a character stands on a kinematic platform that moves at 1 m/s, which carries it, and
// its ground is the platform with the platform's velocity.
character_moving_platform :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	PLATFORM :: physics.Body{3, 1}
	PLATFORM_SHAPE :: physics.Shape{2, 1}
	list := physics.command_list(context.temp_allocator)
	// Its top is at y = 0.6.
	physics.cmd_create_shape(&list, PLATFORM_SHAPE, .Box, {1.5, 0.1, 1.5})
	physics.cmd_create_body(&list, physics.body_desc(PLATFORM, PLATFORM_SHAPE, .Kinematic, {0, 0.5, 0}))
	physics.cmd_create_character(&list, physics.character_desc(CHARACTER, {0, 0.65, 0}))
	testing.expect(t, physics.submit(api, w, list))
	// It lands first.
	step_character(t, api, w, CHARACTER, 20)
	s: physics.Character_State
	for i in 1 ..= 60 {
		list = physics.command_list(context.temp_allocator)
		physics.cmd_move_kinematic(&list, PLATFORM, {f64(i) * f64(STEP), 0.5, 0}, {0, 0, 0, 1}, STEP)
		testing.expect(t, physics.submit(api, w, list))
		s, _ = step_character(t, api, w, CHARACTER, 1)
	}
	testing.expectf(t, abs(s.position.x - 1) < 0.1 && abs(s.position.y - 0.6) < 0.05, "the platform carried it: %v", s.position)
	testing.expect_value(t, s.ground, physics.Ground_State.Ground)
	testing.expect_value(t, s.ground_body, PLATFORM)
	testing.expectf(t, abs(s.ground_velocity.x - 1) < 0.05, "the ground moves at the platform's velocity: %v", s.ground_velocity)
}

// character_pushes_box: a character that walks into a light box pushes it, and one with no push force does not.
character_pushes_box :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	WEAK :: physics.Body{3, 1}
	FAR_BOX :: physics.Body{5, 1}
	list := physics.command_list(context.temp_allocator)
	boxes := [2]physics.Body{BOX, FAR_BOX}
	for b, i in boxes {
		box := physics.body_desc(b, BOX_SHAPE, .Dynamic, {2, 0.5, f64(i) * 10})
		box.mass = 10
		physics.cmd_create_body(&list, box)
	}
	weak := physics.character_desc(WEAK, {0, 0.1, 10})
	weak.max_push_force = 0
	physics.cmd_create_character(&list, physics.character_desc(CHARACTER, {0, 0.1, 0}))
	physics.cmd_create_character(&list, weak)
	physics.cmd_set_character_velocity(&list, CHARACTER, {1.5, 0, 0}, {.Gravity})
	physics.cmd_set_character_velocity(&list, WEAK, {1.5, 0, 0}, {.Gravity})
	testing.expect(t, physics.submit(api, w, list))
	for _ in 0 ..< 120 {
		api.step(w, STEP, 1)
	}
	testing.expectf(t, state(api, w, BOX).position.x > 2.3, "it pushes the box: %v", state(api, w, BOX).position)
	testing.expectf(t, abs(state(api, w, FAR_BOX).position.x - 2) < 0.02, "with no push force it does not: %v", state(api, w, FAR_BOX).position)
	testing.expectf(t, state(api, w, WEAK).position.x < 1.3, "and the box stops it: %v", state(api, w, WEAK).position)
}

// character_is_a_body: a ray hits a character, and skips it when the filter ignores it; a character that reports
// contacts begins one with the ground when it lands; a sensor reports it; and destroying it ends its contacts.
character_is_a_body :: proc(t: ^testing.T, api: ^physics.Physics_API) {
	w := world(t, api)
	defer api.world_destroy(w)
	SENSOR :: physics.Body{3, 1}
	SENSOR_SHAPE :: physics.Shape{2, 1}
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_shape(&list, SENSOR_SHAPE, .Box, {0.5, 1, 0.5})
	trigger := physics.body_desc(SENSOR, SENSOR_SHAPE, .Static, {4, 1, 0}, user = 7)
	trigger.flags = {.Sensor}
	physics.cmd_create_body(&list, trigger)
	desc := physics.character_desc(CHARACTER, {0, 0.5, 0}, user = 42)
	desc.flags = {.Report_Contacts}
	physics.cmd_create_character(&list, desc)
	testing.expect(t, physics.submit(api, w, list))

	down := physics.Ray{origin = {0, 10, 0}, direction = {0, -1, 0}, max_distance = 20}
	hit: physics.Ray_Hit
	testing.expect(t, bool(api.raycast(w, &down, nil, &hit)))
	testing.expect_value(t, hit.body, CHARACTER)
	testing.expect_value(t, hit.user, 42)
	// A backend may keep the capsule a little above its feet: Jolt keeps it its padding, 2 cm, above them.
	testing.expectf(t, abs(hit.position.y - 2.3) < 0.03, "at the top of its capsule: %v", hit.position)
	ignore := physics.FILTER_ALL
	ignore.ignore[0], ignore.ignore_count = CHARACTER, 1
	testing.expect(t, bool(api.raycast(w, &down, &ignore, &hit)))
	testing.expect_value(t, hit.body, GROUND)

	events := make([dynamic]physics.Contact_Event, context.temp_allocator)
	step_character(t, api, w, CHARACTER, 60, &events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		e := events[0]
		testing.expect_value(t, e.kind, physics.Contact_Kind.Begin)
		testing.expect(t, !e.sensor)
		testing.expect_value(t, e.a, GROUND)
		testing.expect_value(t, e.b, CHARACTER)
		testing.expect_value(t, e.b_user, 42)
		testing.expectf(t, e.normal.y > 0.99, "the normal points from the ground to the character: %v", e.normal)
	}

	clear(&events)
	list = physics.command_list(context.temp_allocator)
	physics.cmd_set_character_velocity(&list, CHARACTER, {2, 0, 0}, {.Gravity})
	testing.expect(t, physics.submit(api, w, list))
	step_character(t, api, w, CHARACTER, 180, &events)
	sensed := 0
	for e in events {
		if e.sensor {
			testing.expect_value(t, e.a, CHARACTER)
			testing.expect_value(t, e.b, SENSOR)
			testing.expect_value(t, e.kind, physics.Contact_Kind.Begin if sensed == 0 else physics.Contact_Kind.End)
			sensed += 1
		}
	}
	testing.expect_value(t, sensed, 2)

	clear(&events)
	list = physics.command_list(context.temp_allocator)
	physics.cmd_destroy_character(&list, CHARACTER)
	testing.expect(t, physics.submit(api, w, list))
	step_character(t, api, w, CHARACTER, 1, &events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		testing.expect_value(t, events[0].kind, physics.Contact_Kind.End)
		testing.expect_value(t, events[0].b, CHARACTER)
	}
}
