package physics

import "base:runtime"
import "core:c"
import "core:log"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/luau"
import core_physics "cinnabar:core/physics"
import physics_host "cinnabar:core/physics/host"
import physics_jolt "cinnabar:core/physics/jolt"
import physics_null "cinnabar:core/physics/null"
import script_host "cinnabar:core/script"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The scheduler and the backends are singletons, and the test runner runs tests on several threads.
@(private = "file")
lock: sync.Mutex

@(private = "file")
Fixture :: struct {
	frame:    virtual.Arena,
	platform: core.Platform_API,
	host:     core_physics.Host,
	world:    ecs.World,
	physics:  State,
	// With scripts: the runtime, the entity that Test.box gives, and what Test.report reported.
	scripts:  bool,
	runtime:  script.Runtime,
	box:      ecs.Entity,
	reports:  [dynamic]f64,
}

@(private = "file")
setup :: proc(t: ^testing.T, null := false, quiet := false, scripts := false) -> ^Fixture {
	sync.lock(&lock)
	testing.expect(t, jobs.init())
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	{
		context.logger = log.nil_logger() if quiet else context.logger
		f.host = physics_host.table()
	}
	api := physics_null.load(&f.host) if null else physics_jolt.load(&f.host)
	physics_host.bind(api)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		jobs_run = jobs.run,
		jobs_wait = jobs.wait,
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
		physics = api^,
		time_seconds = proc() -> f64 {return 0},
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	testing.expect(t, init(&f.physics, &f.platform))
	register(&f.physics, &f.world)
	if scripts {
		f.scripts = true
		f.reports = make([dynamic]f64)
		script.register_components(&f.world.registry)
		context.user_ptr = f
		testing.expect(t, script.init(&f.runtime, &f.platform, &f.world, nil, register_test_scripts))
	}
	return f
}

@(private = "file")
register_test_scripts :: proc(r: ^script.Runtime) {
	f := (^Fixture)(context.user_ptr)
	register_scripts(r, &f.physics)
	script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
		f := (^Fixture)(context.user_ptr)
		append(&f.reports, luau.L_checknumber(L, 1))
		return 0
	})
	script.define(r, "Test.box", proc(L: ^luau.State) -> c.int {
		script.push_entity(L, (^Fixture)(context.user_ptr).box)
		return 1
	})
}

@(private = "file")
teardown :: proc(t: ^testing.T, f: ^Fixture) {
	if f.scripts {
		script.destroy(&f.runtime)
		delete(f.reports)
	}
	destroy(&f.physics)
	testing.expect_value(t, f.platform.physics.world_destroy_all(), 0)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
	testing.expect(t, jobs.drain_frame())
	jobs.shutdown()
	sync.unlock(&lock)
}

// ticks runs n fixed ticks as the frame code does, with the physics tick between two propagations.
@(private = "file")
ticks :: proc(f: ^Fixture, n: int) {
	for _ in 0 ..< n {
		// To the start of the next tick exactly: a tick's length in nanoseconds is rounded.
		clock := &f.world.clock
		it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
		begin_frame(&f.physics)
		for ecs.next_tick(&it) {
			ecs.run_tick_systems(&it, nil)
			if f.scripts {
				script.fixed_update(&f.runtime, &it, {})
			}
			ecs.update_transforms(&f.world)
			tick(&f.physics, &f.world)
			if f.scripts {
				send_events(&f.physics, &f.world, &f.runtime)
				script.fixed_events(&f.runtime)
			}
			ecs.update_transforms(&f.world)
		}
		free_all(f.platform.frame_allocator)
	}
}

@(private = "file")
spawn_at :: proc(f: ^Fixture, meters: [3]f64) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	pose := ecs.TRANSFORM_IDENTITY
	pose.position = ecs.position_from_meters(meters)
	ecs.add(&f.world, e, pose)
	return e
}

// ground is a static box 20 m wide whose top is at y = 0.
@(private = "file")
ground :: proc(f: ^Fixture) -> ecs.Entity {
	e := spawn_at(f, {0, -0.5, 0})
	c := DEFAULT_COLLIDER
	c.size = {20, 1, 20}
	ecs.add(&f.world, e, c)
	return e
}

@(private = "file")
box :: proc(f: ^Fixture, meters: [3]f64, motion := Motion.Dynamic) -> ecs.Entity {
	e := spawn_at(f, meters)
	rb := DEFAULT_RIGID_BODY
	rb.motion = motion
	ecs.add(&f.world, e, rb)
	ecs.add(&f.world, e, DEFAULT_COLLIDER)
	return e
}

@(private = "file")
height :: proc(f: ^Fixture, e: ecs.Entity) -> f64 {
	return ecs.position_to_meters(ecs.get(&f.world, e, ecs.Transform).position).y
}

// A box with a Rigid_Body and a Collider falls onto a ground that has only a Collider, and rests on it. The sync adds
// the Physics_Body, and a Previous_Transform to the box, which moves, and not to the ground.
@(test)
a_box_falls_and_rests :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	g := ground(f)
	b := box(f, {0, 5, 0})
	ticks(f, 1)
	testing.expect(t, ecs.has(&f.world, b, Physics_Body))
	testing.expect(t, ecs.has(&f.world, b, ecs.Previous_Transform))
	testing.expect(t, ecs.has(&f.world, g, Physics_Body))
	testing.expect(t, !ecs.has(&f.world, g, ecs.Previous_Transform))
	testing.expect_value(t, ecs.get(&f.world, g, Physics_Body).motion, Motion.Static)
	ticks(f, 240)
	testing.expectf(t, abs(height(f, b) - 0.5) < 0.03, "the box rests on the ground: y = %v", height(f, b))
	testing.expect(t, ecs.get(&f.world, b, Physics_Body).asleep, "the box fell asleep")
	testing.expect_value(t, height(f, g), -0.5)
}

// Writing a dynamic body's Transform teleports it, as in Unity, and it falls from there.
@(test)
a_transform_write_teleports :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	ground(f)
	b := box(f, {0, 0.5, 0})
	ticks(f, 10)
	pose := ecs.get(&f.world, b, ecs.Transform)
	pose.position = ecs.position_from_meters({0, 10, 0})
	ticks(f, 1)
	y := height(f, b)
	testing.expectf(t, y < 10 && y > 9.9, "the box falls from where it was put: y = %v", y)
	ticks(f, 240)
	testing.expectf(t, abs(height(f, b) - 0.5) < 0.03, "and lands again: y = %v", height(f, b))
}

// Despawning an entity destroys its body, and so does removing its Collider and Rigid_Body, which also removes the
// Physics_Body.
@(test)
removals_destroy_bodies :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	a := box(f, {0, 5, 0})
	b := box(f, {3, 5, 0})
	ticks(f, 1)
	body_a := ecs.get(&f.world, a, Physics_Body).body
	body_b := ecs.get(&f.world, b, Physics_Body).body
	ecs.despawn(&f.world, a)
	ecs.remove(&f.world, b, Collider)
	ecs.remove(&f.world, b, Rigid_Body)
	ticks(f, 1)
	testing.expect(t, !pool_valid(&f.physics.bodies, core_physics.Handle(body_a)))
	testing.expect(t, !pool_valid(&f.physics.bodies, core_physics.Handle(body_b)))
	testing.expect(t, !ecs.has(&f.world, b, Physics_Body))
	states: [2]core_physics.Body_State
	bodies := [2]core_physics.Body{body_a, body_b}
	f.platform.physics.body_state(f.physics.world, &bodies[0], 2, &states[0])
	testing.expect_value(t, states[0].body, core_physics.Body{})
	testing.expect_value(t, states[1].body, core_physics.Body{})
}

// An inactive entity's body leaves the simulation and stays where it is, and comes back when the entity is active.
@(test)
inactive_bodies_leave_the_simulation :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	b := box(f, {0, 5, 0})
	ticks(f, 1)
	ecs.set_active(&f.world, b, false)
	ticks(f, 30)
	y := height(f, b)
	ticks(f, 30)
	testing.expect_value(t, height(f, b), y)
	ecs.set_active(&f.world, b, true)
	ticks(f, 30)
	testing.expect(t, height(f, b) < y, "an active body falls again")
}

// Changing a Collider, a Rigid_Body or the scale makes the body again, keeping its velocity.
@(test)
changes_make_the_body_again :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	b := box(f, {0, 50, 0})
	ticks(f, 30)
	before := ecs.get(&f.world, b, Physics_Body)^
	ecs.get(&f.world, b, Collider).size = {2, 2, 2}
	ticks(f, 1)
	after := ecs.get(&f.world, b, Physics_Body)^
	testing.expect(t, after.body != before.body, "a new body")
	testing.expect(t, !pool_valid(&f.physics.bodies, core_physics.Handle(before.body)), "the old one is gone")
	testing.expectf(t, after.linear_velocity.y < before.linear_velocity.y, "it keeps falling: %v", after.linear_velocity)
	ecs.get(&f.world, b, ecs.Transform).scale = 2
	ticks(f, 1)
	testing.expect(t, ecs.get(&f.world, b, Physics_Body).body != after.body)
}

// A dynamic body under a parent writes its Local_Transform, which propagation turns into its Transform.
@(test)
a_child_body_writes_its_local_transform :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	parent := spawn_at(f, {10, 0, 0})
	child := box(f, {10, 5, 0})
	ecs.add(&f.world, child, ecs.Parent{parent})
	ecs.add(&f.world, child, ecs.Local_Transform{offset = {0, 5, 0}, rotation = 1, scale = 1})
	ticks(f, 30)
	local := ecs.get(&f.world, child, ecs.Local_Transform)
	testing.expectf(t, local.offset.y < 5, "the child fell: %v", local.offset)
	testing.expectf(t, abs(local.offset.x) < 1e-4, "straight down: %v", local.offset)
	testing.expectf(t, abs(height(f, child) - f64(local.offset.y)) < 1e-4, "its Transform follows")
}

// A kinematic body follows its Transform with a velocity, which stops when the Transform stops.
@(test)
a_kinematic_body_follows_its_transform :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	b := box(f, {0, 5, 0}, .Kinematic)
	ticks(f, 1)
	pose := ecs.get(&f.world, b, ecs.Transform)
	pose.position = ecs.position_from_meters({1, 5, 0})
	ticks(f, 1)
	testing.expectf(t, ecs.get(&f.world, b, Physics_Body).linear_velocity.x > 50, "moves 1 m in a tick: %v", ecs.get(&f.world, b, Physics_Body).linear_velocity)
	testing.expect_value(t, height(f, b), 5)
	ticks(f, 2)
	testing.expect_value(t, ecs.get(&f.world, b, Physics_Body).linear_velocity, [3]f32{})
	testing.expect_value(t, ecs.position_to_meters(ecs.get(&f.world, b, ecs.Transform).position).x, 1)
}

// A Rigid_Body without a Collider has no body, which the sync says once.
@(test)
a_rigid_body_needs_a_collider :: proc(t: ^testing.T) {
	f := setup(t, quiet = true)
	defer teardown(t, f)
	e := spawn_at(f, {0, 5, 0})
	ecs.add(&f.world, e, DEFAULT_RIGID_BODY)
	context.logger = log.nil_logger()
	ticks(f, 2)
	testing.expect_value(t, ecs.get(&f.world, e, Physics_Body).body, core_physics.Body{})
	ecs.add(&f.world, e, DEFAULT_COLLIDER)
	ticks(f, 1)
	testing.expect(t, ecs.get(&f.world, e, Physics_Body).body.generation != 0, "a Collider gives it a body")
}

// On the null backend, the sync runs and nothing moves.
@(test)
the_null_backend_moves_nothing :: proc(t: ^testing.T) {
	f := setup(t, null = true)
	defer teardown(t, f)
	b := box(f, {0, 5, 0})
	ticks(f, 30)
	testing.expect(t, ecs.has(&f.world, b, Physics_Body))
	testing.expect_value(t, height(f, b), 5)
}

@(private = "file")
part :: proc(f: ^Fixture, parent: ecs.Entity, offset: [3]f32, shape := Shape.Sphere) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.TRANSFORM_IDENTITY)
	ecs.add(&f.world, e, ecs.Parent{parent})
	ecs.add(&f.world, e, ecs.Local_Transform{offset = offset, rotation = 1, scale = 1})
	c := DEFAULT_COLLIDER
	c.shape = shape
	ecs.add(&f.world, e, c)
	return e
}

// A Rigid_Body whose colliders are on its children is one body with a compound shape: it falls and rests on the
// parts, a ray at a part hits the body, and the parts have no body of their own.
@(test)
child_colliders_are_one_body :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	ground(f)
	b := spawn_at(f, {0, 5, 0})
	ecs.add(&f.world, b, DEFAULT_RIGID_BODY)
	left := part(f, b, {-1, 0, 0})
	right := part(f, b, {1, 0, 0})
	ticks(f, 240)
	testing.expect(t, !ecs.has(&f.world, left, Physics_Body) && !ecs.has(&f.world, right, Physics_Body))
	testing.expect(t, ecs.get(&f.world, b, Physics_Body).body.generation != 0)
	testing.expectf(t, abs(height(f, b) - 0.5) < 0.03, "the body rests on its spheres: y = %v", height(f, b))
	testing.expectf(t, abs(height(f, right) - height(f, b)) < 0.01, "level, so the parts follow it")
	ray := core_physics.Ray{origin = {1, 10, 0}, direction = {0, -1, 0}, max_distance = 20}
	hit: core_physics.Ray_Hit
	testing.expect(t, bool(f.platform.physics.raycast(f.physics.world, &ray, nil, &hit)))
	testing.expect_value(t, ecs.Entity(hit.user), b)
}

// Removing a part's Collider makes the body again, and a body that becomes a part gives up its own.
@(test)
parts_change_the_body :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	b := box(f, {0, 50, 0})
	extra := part(f, b, {0, 1, 0})
	loose := box(f, {5, 50, 0}, .Static)
	ecs.remove(&f.world, loose, Rigid_Body)
	ticks(f, 1)
	before := ecs.get(&f.world, b, Physics_Body).body
	testing.expect(t, ecs.has(&f.world, loose, Physics_Body))
	loose_body := ecs.get(&f.world, loose, Physics_Body).body

	ecs.remove(&f.world, extra, Collider)
	ecs.add(&f.world, loose, ecs.Parent{b})
	ecs.add(&f.world, loose, ecs.Local_Transform{offset = {2, 0, 0}, rotation = 1, scale = 1})
	ticks(f, 1)
	after := ecs.get(&f.world, b, Physics_Body).body
	testing.expect(t, after != before, "the body was made again")
	testing.expect(t, !ecs.has(&f.world, loose, Physics_Body), "the new part has no Physics_Body")
	testing.expect(t, !pool_valid(&f.physics.bodies, core_physics.Handle(loose_body)), "and its old body is gone")
	ticks(f, 3)
	testing.expect_value(t, ecs.get(&f.world, b, Physics_Body).body, after)
}

// Two layers that ignore each other do not collide: a box on one falls through a ground on the other.
@(test)
ignored_layers_pass_through :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	layers := default_layers()
	testing.expect(t, add_layer(&layers, "Ghost"))
	ignore(&layers, 0, 1)
	set_layers(&f.physics, layers)
	ground(f)
	ghost := box(f, {0, 2, 0})
	ecs.get(&f.world, ghost, Collider).layer = 1
	solid := box(f, {3, 2, 0})
	ticks(f, 120)
	testing.expectf(t, height(f, ghost) < -1, "the ghost fell through: y = %v", height(f, ghost))
	testing.expectf(t, abs(height(f, solid) - 0.5) < 0.03, "the other box rests: y = %v", height(f, solid))
}

// The sample's stack, 1.5e11 m from the origin in a world anchored there: four small boxes fall onto a static box and
// come to rest on it, one on another, as they would at the origin.
@(test)
a_stack_rests_far_from_the_origin :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	ANCHOR :: ecs.World_Position{raw = {2516582400000000000, 0, 0}}
	far := ANCHOR
	destroy(&f.physics)
	testing.expect(t, init(&f.physics, &f.platform, anchor = ANCHOR))
	register(&f.physics, &f.world)
	place :: proc(f: ^Fixture, at: ecs.World_Position, meters: [3]f32, scale: f32) -> ecs.Entity {
		e := ecs.spawn(&f.world)
		ecs.add(&f.world, e, ecs.Transform{position = ecs.position_offset(at, meters), rotation = 1, scale = scale})
		ecs.add(&f.world, e, DEFAULT_COLLIDER)
		return e
	}
	ecs.get(&f.world, place(f, far, {0, -0.5, 0}, 1), ecs.Transform).scale = {4, 1, 4}
	place(f, far, {0.4, 0.3, -0.25}, 0.6)
	boxes: [4]ecs.Entity
	for &b, i in boxes {
		b = place(f, far, {0.4, 0.8 + 0.25 * f32(i), -0.25}, 0.15)
		ecs.add(&f.world, b, DEFAULT_RIGID_BODY)
	}
	ticks(f, 300)
	for b, i in boxes {
		pb := ecs.get(&f.world, b, Physics_Body)
		y := ecs.position_sub(ecs.get(&f.world, b, ecs.Transform).position, far).y
		want := 0.6 + 0.075 + 0.15 * f32(i)
		testing.expectf(t, abs(y - want) < 0.03, "box %d rests on the one below: y = %v, not %v", i, y, want)
		testing.expectf(t, pb.asleep, "box %d is asleep", i)
	}
}

// A box landing on the ground is one contact in the tick's list and the frame's, with the entities and the point in
// world positions; begin_frame starts the frame's again.
@(test)
contacts_reach_the_lists :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	g := ground(f)
	b := box(f, {0, 1, 0})
	begins := 0
	for _ in 0 ..< 60 {
		ticks(f, 1)
		for c in tick_contacts(&f.physics) {
			testing.expect_value(t, c.kind, Contact_Kind.Begin)
			testing.expect(t, c.a == g && c.b == b)
			testing.expectf(t, abs(ecs.position_to_meters(c.point).y) < 0.05, "at the ground's top: %v", c.point)
			begins += 1
		}
		testing.expect_value(t, len(frame_contacts(&f.physics)), len(tick_contacts(&f.physics)))
	}
	testing.expect_value(t, begins, 1)
}

// A box with a behaviour falls through a sensor and onto the ground: it gets on_trigger_enter and on_trigger_exit,
// then on_collision_enter with the normal from it to the ground and an impulse; the ground's behaviour gets
// on_collision_exit when the box is despawned.
@(test)
contacts_reach_behaviours :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(t, f)
	g := ground(f)
	trigger := spawn_at(f, {0, 2, 0})
	c := DEFAULT_COLLIDER
	c.sensor = true
	ecs.add(&f.world, trigger, c)
	f.box = box(f, {0, 4, 0})
	context.user_ptr = f
	_, ok := script.spawn_source(&f.runtime, "=watcher", `
local Watcher = Behaviour.define("Watcher")
function Watcher:on_trigger_enter(other) Test.report(2) end
function Watcher:on_trigger_exit(other) Test.report(3) end
function Watcher:on_collision_enter(other, point, normal, velocity, impulse)
	local code = 1
	if normal.y < -0.9 then code += 10 end
	if impulse > 0 then code += 100 end
	if velocity.y > 0 then code += 1000 end
	Test.report(code)
end
function Watcher:on_collision_exit(other) Test.report(4) end
Test.box():add(Watcher)
`)
	testing.expect(t, ok)
	ticks(f, 120)
	testing.expectf(t, len(f.reports) == 3 && f.reports[0] == 2 && f.reports[1] == 3 && f.reports[2] == 1111, "reports %v", f.reports[:])
	clear(&f.reports)

	falling := f.box
	f.box = g
	_, ok = script.spawn_source(&f.runtime, "=ground", `
local Ground = Behaviour.define("Ground")
function Ground:on_collision_exit(other) Test.report(5) end
Test.box():add(Ground)
`)
	testing.expect(t, ok)
	ecs.despawn(&f.world, falling)
	ticks(f, 1)
	testing.expectf(t, len(f.reports) == 1 && f.reports[0] == 5, "the ground's behaviour sees the box go: %v", f.reports[:])
}

// Queries in world positions: a ray that ignores the first box hits the second, a swept sphere stops on a box, and an
// overlap finds a box's entity.
@(test)
native_queries :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	ground(f)
	low := box(f, {0, 1, 0}, .Static)
	high := box(f, {0, 4, 0}, .Static)
	ticks(f, 1)
	above := ecs.position_from_meters({0, 10, 0})
	hit, ok := raycast(&f.physics, &f.world, above, {0, -1, 0}, 20)
	testing.expect(t, ok && hit.entity == high)
	testing.expectf(t, abs(ecs.position_to_meters(hit.position).y - 4.5) < 1e-3, "the top of the high box: %v", hit.position)
	ignore := []ecs.Entity{high}
	hit, ok = raycast(&f.physics, &f.world, above, {0, -2, 0}, 20, {layers = max(u32), ignore = ignore})
	testing.expect(t, ok && hit.entity == low, "a ray that ignores the high box hits the low one")

	hits: [4]Hit
	testing.expect_value(t, raycast_all(&f.physics, &f.world, above, {0, -1, 0}, 20, hits[:]), 3)
	testing.expect(t, hits[0].entity == high && hits[1].entity == low)

	hit, ok = shape_cast(&f.physics, &f.world, {shape = .Sphere, radius = 0.5}, above, 1, {0, -1, 0}, 20)
	testing.expect(t, ok && hit.entity == high)
	testing.expectf(t, abs(hit.distance - 5) < 1e-3, "the sphere stops on the high box: %v", hit.distance)

	found: [4]ecs.Entity
	n := overlap(&f.physics, &f.world, {shape = .Box, size = 0.5}, ecs.position_from_meters({0, 1, 0.6}), 1, found[:])
	testing.expect(t, n == 1 && found[0] == low)
}

// Scripts query, name layers, and push bodies: an impulse from fixed_update applies in the same tick.
@(test)
scripts_query_and_push :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(t, f)
	ground(f)
	f.box = box(f, {0, 0.5, 0})
	ticks(f, 1)
	context.user_ptr = f
	_, ok := script.spawn_source(&f.runtime, "=query", `
local hit = Physics.raycast(WorldPosition.from_meters(0, 10, 0), vector.create(0, -1, 0))
Test.report(hit and hit.entity == Test.box() and 1 or 0)
Test.report(hit and math.abs(hit.distance - 9) < 0.05 and 1 or 0)
Test.report(#Physics.overlap_sphere(WorldPosition.from_meters(0, 0.5, 0), 0.25))
Test.report(Physics.layers("Default"))
Test.report(Physics.raycast(WorldPosition.from_meters(30, 10, 30), vector.create(0, 1, 0)) == nil and 1 or 0)
local Jumper = Behaviour.define("Jumper")
function Jumper:fixed_update(dt)
	if not self.jumped then
		self.jumped = true
		Physics.add_impulse(self.entity, vector.create(0, 1000, 0))
	end
end
Test.box():add(Jumper)
`)
	testing.expect(t, ok)
	testing.expectf(t, len(f.reports) == 5 && f.reports[0] == 1 && f.reports[1] == 1 && f.reports[2] == 1 && f.reports[3] == 1 && f.reports[4] == 1, "reports %v", f.reports[:])
	ticks(f, 1)
	testing.expectf(t, ecs.get(&f.world, f.box, Physics_Body).linear_velocity.y > 0.5, "the impulse applied in the tick: %v", ecs.get(&f.world, f.box, Physics_Body).linear_velocity)
	ok = native_push(f)
	testing.expect(t, ok)
}

// native_push is the same from native code, and an entity without a body is refused.
@(private = "file")
native_push :: proc(f: ^Fixture) -> bool {
	e := spawn_at(f, {9, 9, 9})
	return !add_impulse(&f.physics, &f.world, e, {0, 1, 0}) && add_impulse(&f.physics, &f.world, f.box, {0, 1, 0})
}

// A script's effect on an entity without a body raises an error, which names it.
@(test)
effects_need_a_body :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(t, f)
	context.user_ptr = f
	context.logger = log.nil_logger()
	_, ok := script.spawn_source(&f.runtime, "=bodiless", `Physics.add_force(World.spawn(), vector.create(0, 1, 0))`)
	testing.expect(t, !ok)
}
