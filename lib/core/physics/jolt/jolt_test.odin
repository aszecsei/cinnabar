package physics_jolt

import "core:log"
import "core:sync"
import "core:testing"

import "cinnabar:core/jobs"
import "cinnabar:core/physics"
import "cinnabar:core/physics/conformance"
import physics_host "cinnabar:core/physics/host"

// The scheduler and Jolt's setup are singletons, and the test runner runs tests on several threads.
@(private = "file")
lock: sync.Mutex

@(private = "file")
host: physics.Host

// with_backend runs a conformance test on the host's job system, as the game's frame code would. A quiet host drops
// the backend's log, for tests of what it rejects; the test's own failures still report.
@(private = "file")
with_backend :: proc(t: ^testing.T, test: proc(t: ^testing.T, api: ^physics.Physics_API), quiet := false) {
	sync.guard(&lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	{
		context.logger = log.nil_logger() if quiet else context.logger
		host = physics_host.table()
	}
	api := load(&host)
	testing.expect(t, api != nil)
	physics_host.bind(api)
	info := api.info()
	testing.expect_value(t, string(info.name), "jolt")
	testing.expect(t, .Double_Precision in info.features)
	test(t, api)
	testing.expect_value(t, api.world_destroy_all(), 0)
	testing.expect(t, jobs.drain_frame())
}

@(test)
falling_box :: proc(t: ^testing.T) {
	with_backend(t, conformance.falling_box)
}

@(test)
ray :: proc(t: ^testing.T) {
	with_backend(t, conformance.ray)
}

@(test)
stale_handles :: proc(t: ^testing.T) {
	with_backend(t, conformance.stale_handles, quiet = true)
}

@(test)
deterministic :: proc(t: ^testing.T) {
	with_backend(t, conformance.deterministic)
}

// A soft restart destroys the worlds that the game left, with their bodies.
@(test)
destroy_all :: proc(t: ^testing.T) {
	with_backend(t, proc(t: ^testing.T, api: ^physics.Physics_API) {
		a := api.world_create(nil)
		b := api.world_create(nil)
		testing.expect(t, a != b && a.generation != 0 && b.generation != 0)
		list := physics.command_list(context.temp_allocator)
		physics.cmd_create_shape(&list, {0, 1}, .Sphere, {1, 0, 0})
		physics.cmd_create_body(&list, physics.body_desc({0, 1}, {0, 1}, .Dynamic, {0, 0, 0}))
		testing.expect(t, physics.submit(api, a, list))
		testing.expect_value(t, api.world_destroy_all(), 2)
		testing.expect(t, !api.step(a, 1.0 / 60, 1), "a destroyed world is stale")
		c := api.world_create(nil)
		testing.expect(t, c != a, "a new world in the same slot has a new generation")
		api.world_destroy(c)
	}, quiet = true)
}
