package physics_null

import "core:log"
import "core:sync"
import "core:testing"

import physics "cinnabar:core/physics"
import physics_host "cinnabar:core/physics/host"

// The backend's state is one per process, and the test runner runs tests on several threads.
@(private = "file")
lock: sync.Mutex

@(private = "file")
host: physics.Host

@(private = "file")
setup :: proc(quiet := false) -> ^physics.Physics_API {
	{
		context.logger = log.nil_logger() if quiet else context.logger
		host = physics_host.table()
	}
	return load(&host)
}

// Bodies stay where they are put: a step moves nothing, results are empty, and a ray hits nothing.
@(test)
keeps_bodies :: proc(t: ^testing.T) {
	sync.guard(&lock)
	api := setup()
	w := api.world_create(nil)
	defer api.world_destroy(w)
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_shape(&list, {0, 1}, .Box, {0.5, 0.5, 0.5})
	physics.cmd_create_body(&list, physics.body_desc({0, 1}, {0, 1}, .Dynamic, {0, 5, 0}, user = 42))
	physics.cmd_set_pose(&list, {0, 1}, {1, 2, 3}, {0, 0, 0, 1})
	physics.cmd_add_force(&list, {0, 1}, {0, 100, 0})
	testing.expect(t, physics.submit(api, w, list))
	testing.expect(t, bool(api.step(w, 1.0 / 60, 1)))

	results: physics.Step_Results
	api.results(w, &results)
	testing.expect_value(t, results.moved_count, 0)
	body := physics.Body{0, 1}
	s: physics.Body_State
	api.body_state(w, &body, 1, &s)
	testing.expect_value(t, s.user, 42)
	testing.expect_value(t, s.position, physics.Position{1, 2, 3})

	ray := physics.Ray{origin = {1, 10, 3}, direction = {0, -1, 0}, max_distance = 20}
	hit: physics.Ray_Hit
	testing.expect(t, !api.raycast(w, &ray, nil, &hit))
	testing.expect_value(t, string(api.info().name), "null")
}

// It rejects what a real backend rejects, so the engine's tests catch a stale handle with it.
@(test)
rejects_stale_handles :: proc(t: ^testing.T) {
	sync.guard(&lock)
	api := setup(quiet = true)
	w := api.world_create(nil)
	defer api.world_destroy(w)
	list := physics.command_list(context.temp_allocator)
	physics.cmd_create_shape(&list, {0, 1}, .Box, {0.5, 0.5, 0.5})
	physics.cmd_create_body(&list, physics.body_desc({0, 1}, {0, 1}, .Dynamic, {}))
	physics.cmd_destroy_body(&list, {0, 1})
	testing.expect(t, physics.submit(api, w, list))

	bad := physics.command_list(context.temp_allocator)
	physics.cmd_add_impulse(&bad, {0, 1}, {1, 0, 0})
	physics.cmd_create_body(&bad, physics.body_desc({1, 1}, {7, 1}, .Dynamic, {}))
	physics.cmd_release_shape(&bad, {0, 2})
	testing.expect(t, !physics.submit(api, w, bad))
	testing.expect(t, !api.submit({w.index, w.generation + 1}, nil, 0), "a stale world")
}

// A soft restart destroys the worlds that the game left.
@(test)
destroy_all :: proc(t: ^testing.T) {
	sync.guard(&lock)
	api := setup()
	a := api.world_create(nil)
	api.world_create(nil)
	testing.expect_value(t, api.world_destroy_all(), 2)
	testing.expect(t, !api.step(a, 1.0 / 60, 1))
	testing.expect_value(t, api.world_destroy_all(), 0)
}
