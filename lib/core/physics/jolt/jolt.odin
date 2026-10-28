// Package physics_jolt is the Jolt backend, in jolt_backend.cpp, which lib/core/physics/jolt/CMakeLists.txt builds
// with vendor/jolt. This file links it. See docs/physics/design.md#where-jolt-lives.
package physics_jolt

import physics "cinnabar:core/physics"

// PHYSICS_SHARED links physics_jolt.dll, which the development host loads. Otherwise the backend links statically.
// The game DLL must never link it statically: a second copy of Jolt would not know the host's worlds.
PHYSICS_SHARED :: #config(PHYSICS_SHARED, false)

when PHYSICS_SHARED {
	foreign import lib "../../../../build/obj/jolt/shared/out/physics_jolt.lib"
} else {
	foreign import lib {
		"../../../../build/obj/jolt/static/out/physics_jolt.lib",
		"../../../../build/obj/jolt/static/out/Jolt.lib",
	}
}

@(default_calling_convention = "c")
foreign lib {
	// The first call sets Jolt up with the host's memory, log and jobs; host must stay at the same address until
	// shutdown.
	cinnabar_physics_api :: proc(host: ^physics.Host) -> ^physics.Physics_API ---
}

// load returns the backend's table, or nil if it does not have this API_VERSION.
load :: proc(host: ^physics.Host) -> ^physics.Physics_API {
	api := cinnabar_physics_api(host)
	return api if api != nil && api.info().api_version == physics.API_VERSION else nil
}
