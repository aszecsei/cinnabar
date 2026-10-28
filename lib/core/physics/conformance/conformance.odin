// Package physics_conformance is the suite that every simulating backend passes, driven through Physics_API with no
// engine world. A backend's tests call each procedure with its table. See docs/physics/design.md#tests.
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
