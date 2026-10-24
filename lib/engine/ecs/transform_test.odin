package ecs

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:testing"
import "core:time"

import "cinnabar:core/jobs"

@(private = "file")
expect_near :: proc(t: ^testing.T, got, want: [3]f32, loc := #caller_location) {
	testing.expectf(t, linalg.length(got - want) < 1e-4, "got %v, want %v", got, want, loc = loc)
}

@(test)
compose_applies_the_parent_pose :: proc(t: ^testing.T) {
	far := position_from_meters({1e11, -1e11, 3})
	parent := Transform {
		position = far,
		rotation = linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1}),
		scale    = 2,
	}
	child := compose(parent, {offset = {1, 0, 0}, rotation = 1, scale = 1})
	expect_near(t, position_sub(child.position, far), {0, 2, 0})
	testing.expect_value(t, child.scale, [3]f32{2, 2, 2})
}

@(private = "file")
spawn_child :: proc(w: ^World, parent: Entity, offset: [3]f32) -> Entity {
	e := spawn(w)
	add(w, e, TRANSFORM_IDENTITY)
	add(w, e, Local_Transform{offset = offset, rotation = 1, scale = 1})
	add(w, e, Parent{parent})
	return e
}

@(test)
propagation_reaches_every_level :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world

	root := spawn(w)
	add(w, root, Transform{position = position_from_meters({5, 0, 0}), rotation = 1, scale = 1})
	// Spawned deepest first, so storage order is not hierarchy order.
	grandchild := spawn(w)
	child := spawn_child(w, root, {0, 1, 0})
	add(w, grandchild, TRANSFORM_IDENTITY)
	add(w, grandchild, Local_Transform{offset = {0, 0, 1}, rotation = 1, scale = 1})
	add(w, grandchild, Parent{child})

	run_stage(w, .Late, time.Millisecond, nil)
	origin: World_Position
	expect_near(t, position_sub(get(w, child, Transform).position, origin), {5, 1, 0})
	expect_near(t, position_sub(get(w, grandchild, Transform).position, origin), {5, 1, 1})

	// Reparent the grandchild to the root.
	add(w, grandchild, Parent{root})
	run_stage(w, .Late, time.Millisecond, nil)
	expect_near(t, position_sub(get(w, grandchild, Transform).position, origin), {5, 0, 1})

}

@(test)
despawn_takes_the_subtree :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	root := spawn(w)
	add(w, root, TRANSFORM_IDENTITY)
	child := spawn_child(w, root, {})
	grandchild := spawn_child(w, child, {})
	kept := spawn_child(w, root, {})
	other := spawn_child(w, spawn(w), {})

	// A child without its Parent survives.
	remove(w, kept, Parent)
	testing.expect(t, despawn(w, root))
	testing.expect(t, !is_alive(w, child))
	testing.expect(t, !is_alive(w, grandchild))
	testing.expect(t, is_alive(w, kept))
	testing.expect(t, is_alive(w, other))
}

@(test)
apply_despawns_the_subtree_at_the_end :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	root := spawn(w)
	add(w, root, TRANSFORM_IDENTITY)
	child := spawn_child(w, root, {})
	grandchild := spawn_child(w, child, {})

	cb := commands(context.allocator)
	defer delete(cb.data)
	// Spawned under the root in the same apply, so it goes too.
	late := reserve(w)
	command_despawn(&cb, root)
	command_add(&cb, w, late, Parent{child})
	apply(w, {cb})
	for e in ([]Entity{root, child, grandchild, late}) {
		testing.expect(t, !is_alive(w, e))
	}
	testing.expect_value(t, w.entities.free_count, 4)
}

@(private = "file")
Mover :: struct {
	teleport: Entity,
}

@(private = "file")
move_x :: proc(ctx: ^System_Context) {
	it := query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
	for view in query_next(&it) {
		for &pose in column(view, 0, Transform) {
			pose.position = position_offset(pose.position, {1, 0, 0})
		}
	}
	if e := (^Mover)(ctx.user).teleport; e != 0 {
		command_teleport(ctx.commands, e, Transform{position = position_from_meters({100, 0, 0}), rotation = 1, scale = 1})
	}
}

@(test)
fixed_motion_is_interpolated :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world

	e := spawn(w)
	add(w, e, TRANSFORM_IDENTITY)
	add(w, e, Previous_Transform(TRANSFORM_IDENTITY))
	mover: Mover
	register_system(w, {name = "move", stage = .Fixed, procedure = move_x, terms = {write(w, Transform)}})
	set_tick_rate(w, 10)

	// 250 ms at 10 Hz is two ticks and half of the third.
	testing.expect_value(t, run_fixed(w, 250 * time.Millisecond, &mover), 2)
	origin: World_Position
	pose, ok := presented(w, e)
	testing.expect(t, ok)
	expect_near(t, position_sub(pose.position, origin), {1.5, 0, 0})

	mover.teleport = e
	testing.expect_value(t, run_fixed(w, 100 * time.Millisecond, &mover), 1)
	pose, _ = presented(w, e)
	expect_near(t, position_sub(pose.position, origin), {100, 0, 0})
}

@(test)
hierarchy_cycles_are_reported :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world

	context.logger = log.nil_logger()
	a, b := spawn(w), spawn(w)
	for pair in ([][2]Entity{{a, b}, {b, a}}) {
		add(w, pair[0], TRANSFORM_IDENTITY)
		add(w, pair[0], LOCAL_TRANSFORM_IDENTITY)
		add(w, pair[0], Parent{pair[1]})
	}
	run_stage(w, .Late, time.Millisecond, nil)
	testing.expect_value(t, w.levels[MAX_HIERARCHY_DEPTH], 0)
}
