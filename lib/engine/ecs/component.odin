package ecs

import "base:runtime"
import "core:hash"
import "core:log"
import "core:slice"

import "cinnabar:core/layout"

MAX_COMPONENTS :: 256
// Larger components fit too few rows in a chunk. Keep large data in an asset or a side table.
MAX_COMPONENT_SIZE :: CHUNK_SIZE / 16
MAX_COMPONENT_ALIGN :: 64

// Component_Id is the stable ID of a component type. Cooked scenes, the editor link and scripts use it.
Component_Id :: distinct u64

Component_Info :: struct {
	id:     Component_Id,
	type:   typeid,
	name:   string,
	size:   int,
	align:  int,
	layout: u64,
}

// Registry maps component types to their stable IDs. It holds typeids and strings from the DLL image, so it is
// rebuilt after every code reload (see reload), and nothing else in the world refers to it by pointer.
//
// Build it with one procedure that the game calls from init, on_reload and layout_hash. layout_hash has no state,
// so it builds a Registry on the stack and mixes in registry_layout_hash.
Registry :: struct {
	infos: [MAX_COMPONENTS]Component_Info,
	count: int,
}

// component_id is the ID of a name. A registered type's default name is "package.Type".
component_id :: proc "contextless" (name: string) -> Component_Id {
	return Component_Id(hash.fnv64a(transmute([]byte)name))
}

// register_component adds T to the registry. The ID is the hash of T's package-qualified name, unless id is given.
// A type without a name needs an explicit id. A duplicate type or ID is a programming error and panics.
register_component :: proc(r: ^Registry, $T: typeid, id := Component_Id(0)) -> Component_Id {
	ti := type_info_of(T)
	name := "(unnamed)"
	component := id
	if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
		name = named.name
		if component == 0 {
			// FNV-1a is sequential, so this is component_id("package.Type") without joining the strings.
			h := hash.fnv64a(transmute([]byte)named.pkg)
			h = hash.fnv64a({'.'}, h)
			component = Component_Id(hash.fnv64a(transmute([]byte)named.name, h))
		}
	}
	if component == 0 {
		log.panicf("ecs: component type %v has no name, so it needs an explicit ID", typeid_of(T))
	}
	if size_of(T) > MAX_COMPONENT_SIZE || align_of(T) > MAX_COMPONENT_ALIGN {
		log.panicf("ecs: component %s is too large or too aligned", name)
	}
	if r.count == MAX_COMPONENTS {
		log.panicf("ecs: more than %d component types", MAX_COMPONENTS)
	}
	for info in r.infos[:r.count] {
		if info.id == component || info.type == T {
			log.panicf("ecs: component %s conflicts with %s", name, info.name)
		}
	}
	r.infos[r.count] = {
		id     = component,
		type   = T,
		name   = name,
		size   = size_of(T),
		align  = align_of(T),
		layout = layout.hash(T),
	}
	r.count += 1
	return component
}

registry_find :: proc "contextless" (r: ^Registry, id: Component_Id) -> ^Component_Info {
	for &info in r.infos[:r.count] {
		if info.id == id {
			return &info
		}
	}
	return nil
}

registry_find_type :: proc "contextless" (r: ^Registry, T: typeid) -> ^Component_Info {
	for &info in r.infos[:r.count] {
		if info.type == T {
			return &info
		}
	}
	return nil
}

// registry_layout_hash hashes the ID and layout of every component. Registration order does not change it.
registry_layout_hash :: proc(r: ^Registry) -> u64 {
	pairs: [MAX_COMPONENTS][2]u64
	for info, i in r.infos[:r.count] {
		pairs[i] = {u64(info.id), info.layout}
	}
	sorted := pairs[:r.count]
	slice.sort_by(sorted, proc(a, b: [2]u64) -> bool {return a[0] < b[0]})
	return hash.fnv64a(slice.to_bytes(sorted))
}
