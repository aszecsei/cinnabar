package script

import "base:runtime"
import "core:c"

import "cinnabar:core/luau"

// Memory by module (see docs/scripting/embedding.md#embedding). Each module has a Luau memory category, its index + 1, and
// category 0 is the engine. What a module's top level allocates, and what a behaviour's callbacks and coroutines
// allocate, counts toward the module: a coroutine's thread keeps the category of the code that started it. There are
// 255 categories for MAX_MODULES modules, so the last module shares the one before it.

Module_Memory :: struct {
	// The module's source path, or its GUID.
	name:  string,
	bytes: int,
}

// memory is every byte that the VM holds, and the part that each loaded module's code allocated, in allocator. The
// engine's part is the rest.
memory :: proc(r: ^Runtime, allocator: runtime.Allocator) -> (total: int, modules: []Module_Memory) {
	if r.L == nil {
		return
	}
	list := make([dynamic]Module_Memory, allocator)
	for &m, i in r.modules[:r.module_count] {
		if m.state == .Unloaded {
			continue
		}
		append(&list, Module_Memory{name = module_name(r, &m), bytes = int(luau.totalbytes(r.L, category_of(i)))})
	}
	return int(luau.totalbytes(r.L, -1)), list[:]
}

// behaviour_count is the number of live behaviour instances.
behaviour_count :: proc(r: ^Runtime) -> (count: int) {
	for i in r.instances[:r.instance_used] {
		count += int(.Live in i.flags)
	}
	return
}

@(private)
category_of :: proc "contextless" (module_index: int) -> c.int {
	return c.int(min(module_index + 1, luau.MEMORY_CATEGORIES - 1))
}

// set_category makes a thread's allocations count toward a category, and returns the one it had, as the runtime last
// set it.
@(private)
set_category :: proc(r: ^Runtime, L: ^luau.State, category: c.int) -> (previous: c.int) {
	previous = r.category
	r.category = category
	luau.setmemcat(L, category)
	return
}

// class_category is the category of the module that returned the class at idx, or 0 for a class that no module
// returned, such as one that a script built by hand.
@(private)
class_category :: proc(r: ^Runtime, L: ^luau.State, idx: c.int) -> c.int {
	for m, i in r.modules[:r.module_count] {
		if m.state != .Loaded || m.result == luau.NOREF {
			continue
		}
		luau.getref(L, m.result)
		same := luau.rawequal(L, -1, idx)
		luau.pop(L, 1)
		if same {
			return category_of(i)
		}
	}
	return 0
}
