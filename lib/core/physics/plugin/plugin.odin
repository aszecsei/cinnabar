// Package physics_plugin loads a physics backend as a plugin: physics_<name>.dll beside the executable, which exports
// cinnabar_physics_api. The development host's physics_backend collection points here, so the backend is the project's
// choice at start, not the build's; release builds point the collection at a backend that they link. See
// docs/physics/backends.md#loading.
package physics_plugin

import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"

import physics "cinnabar:core/physics"
import physics_null "cinnabar:core/physics/null"

// The entry point that a backend exports.
ENTRY_POINT :: "cinnabar_physics_api"

Entry_Point :: #type proc "c" (host: ^physics.Host) -> ^physics.Physics_API

// load gives the table of the backend with this name: none is the null backend, built in, and another name is the
// library physics_<name>.dll beside the executable, or nil when it cannot be loaded, which it logs. An empty name is
// jolt.
load :: proc(host: ^physics.Host, name := "") -> ^physics.Physics_API {
	name := name if name != "" else "jolt"
	if name == "none" {
		return physics_null.load(host)
	}
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {
		log.errorf("physics: cannot find the executable's directory: %v", err)
		return nil
	}
	path, _ := filepath.join({dir, fmt.tprintf("physics_%s.dll", name)}, context.temp_allocator)
	return load_from(host, path)
}

// load_from loads a backend from a library's path. The library stays loaded for the life of the process: its worlds,
// and the code their objects point into, are the host's.
load_from :: proc(host: ^physics.Host, path: string) -> ^physics.Physics_API {
	library, loaded := dynlib.load_library(path)
	if !loaded {
		log.errorf("physics: cannot load the backend %s", path)
		return nil
	}
	symbol, found := dynlib.symbol_address(library, ENTRY_POINT)
	if !found {
		log.errorf("physics: %s does not export %s", path, ENTRY_POINT)
		dynlib.unload_library(library)
		return nil
	}
	return (Entry_Point)(symbol)(host)
}
