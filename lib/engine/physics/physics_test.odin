package physics

import "base:runtime"
import "core:log"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"
import core_physics "cinnabar:core/physics"
import physics_host "cinnabar:core/physics/host"
import physics_jolt "cinnabar:core/physics/jolt"
import physics_null "cinnabar:core/physics/null"
import "cinnabar:engine/ecs"

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
}

@(private = "file")
setup :: proc(t: ^testing.T, null := false, quiet := false) -> ^Fixture {
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
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	testing.expect(t, init(&f.physics, &f.platform))
	register(&f.physics, &f.world)
	return f
}

@(private = "file")
teardown :: proc(t: ^testing.T, f: ^Fixture) {
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
		for ecs.next_tick(&it) {
			ecs.run_tick_systems(&it, nil)
			ecs.update_transforms(&f.world)
			tick(&f.physics, &f.world)
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
