// Package physics_jolt is the Jolt backend, in jolt_backend.cpp, which lib/core/physics/jolt/CMakeLists.txt builds
// with vendor/jolt. This file links it. See docs/physics/design.md#where-jolt-lives.
package physics_jolt

import "core:log"

import physics "cinnabar:core/physics"
import physics_null "cinnabar:core/physics/null"

// The development host loads physics_jolt.dll as a plugin (see lib/core/physics/plugin); release builds and tests link
// the backend statically, through this package.
foreign import lib {
	"../../../../build/obj/jolt/static/out/physics_jolt.lib",
	"../../../../build/obj/jolt/static/out/Jolt.lib",
}

@(default_calling_convention = "c")
foreign lib {
	// The first call sets Jolt up with the host's memory, log and jobs; host must stay at the same address until
	// shutdown.
	cinnabar_physics_api :: proc(host: ^physics.Host) -> ^physics.Physics_API ---
}

// load gives the backend's table for a build that links Jolt: none is the null backend, as a project without physics
// asks for, and another name is not in this build, which links only Jolt, so it warns and gives Jolt.
load :: proc(host: ^physics.Host, name := "") -> ^physics.Physics_API {
	switch name {
	case "none":
		return physics_null.load(host)
	case "", "jolt":
	case:
		log.warnf("physics: this build links the Jolt backend, so physics.backend = %s is not used", name)
	}
	return cinnabar_physics_api(host)
}
