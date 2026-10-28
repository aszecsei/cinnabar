package physics_plugin

import "core:log"
import "core:sync"
import "core:testing"

import "cinnabar:core/jobs"
import physics "cinnabar:core/physics"
import "cinnabar:core/physics/conformance"
import physics_host "cinnabar:core/physics/host"

@(private = "file")
lock: sync.Mutex

@(private = "file")
host: physics.Host

// The Jolt backend that just jolt builds, loaded as a plugin: it has this build's API version and layouts, and its box
// falls and rests as the static build's does.
@(test)
jolt_loads_as_a_plugin :: proc(t: ^testing.T) {
	sync.guard(&lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	host = physics_host.table()
	api := load_from(&host, "build/obj/jolt/shared/out/physics_jolt.dll")
	testing.expect(t, api != nil)
	if api == nil {
		return
	}
	physics_host.bind(api)
	info := api.info()
	testing.expect_value(t, string(info.name), "jolt")
	testing.expect_value(t, info.api_version, physics.API_VERSION)
	testing.expect_value(t, info.layout, physics.layout_signature())
	conformance.falling_box(t, api)
	testing.expect(t, jobs.drain_frame())
}

// none is the null backend, built in, and a backend that is not beside the executable does not load.
@(test)
names_choose_backends :: proc(t: ^testing.T) {
	sync.guard(&lock)
	{
		context.logger = log.nil_logger()
		host = physics_host.table()
	}
	testing.expect_value(t, string(load(&host, "none").info().name), "null")
	context.logger = log.nil_logger()
	testing.expect(t, load(&host, "no_such_backend") == nil)
}
