package gpu

import "core:sync"

// Pool is a fixed-capacity table of backend resources with generational handles.
// A slot's generation is odd while the slot is live. Removing a slot makes its handles invalid at once,
// but the slot is only reused after pool_free, when the GPU no longer uses its descriptors.
// pool_add, pool_remove and pool_free are thread-safe. pool_get does not lock: a get that races
// with the removal of the same handle is a use-after-destroy.
Pool :: struct($H: typeid, $T: typeid) {
	items:       []T,
	generations: []u32,
	free:        [dynamic]u32,
	count:       u32,
	mutex:       sync.Mutex,
}

pool_init :: proc(pool: ^Pool($H, $T), capacity: int, allocator := context.allocator) {
	pool.items = make([]T, capacity, allocator)
	pool.generations = make([]u32, capacity, allocator)
	pool.free = make([dynamic]u32, allocator)
}

pool_destroy :: proc(pool: ^Pool($H, $T)) {
	delete(pool.items, pool.free.allocator)
	delete(pool.generations, pool.free.allocator)
	delete(pool.free)
	pool^ = {}
}

// pool_add returns the nil handle when the pool is full.
pool_add :: proc(pool: ^Pool($H, $T), item: T) -> H {
	sync.guard(&pool.mutex)
	index: u32
	if n := len(pool.free); n > 0 {
		index = pop(&pool.free)
	} else if int(pool.count) < len(pool.items) {
		index = pool.count
		pool.count += 1
	} else {
		return {}
	}
	pool.generations[index] += 1
	pool.items[index] = item
	return {index = index, generation = pool.generations[index]}
}

pool_get :: proc(pool: ^Pool($H, $T), handle: H) -> ^T {
	if handle.generation & 1 == 0 || int(handle.index) >= len(pool.items) || pool.generations[handle.index] != handle.generation {
		return nil
	}
	return &pool.items[handle.index]
}

// pool_remove invalidates the handle and returns the item. Call pool_free with the handle's index
// when the slot can be reused.
pool_remove :: proc(pool: ^Pool($H, $T), handle: H) -> (item: T, ok: bool) {
	sync.guard(&pool.mutex)
	ptr := pool_get(pool, handle)
	if ptr == nil {
		return
	}
	item = ptr^
	ptr^ = {}
	pool.generations[handle.index] += 1
	return item, true
}

pool_free :: proc(pool: ^Pool($H, $T), index: u32) {
	sync.guard(&pool.mutex)
	assert(pool.generations[index] & 1 == 0, "gpu: freeing a live pool slot")
	append(&pool.free, index)
}

// pool_each calls f on every live item, for shutdown.
pool_each :: proc(pool: ^Pool($H, $T), f: proc(item: ^T)) {
	for i in 0 ..< pool.count {
		if pool.generations[i] & 1 == 1 {
			f(&pool.items[i])
		}
	}
}

// pool_live is the number of live slots.
pool_live :: proc(pool: ^Pool($H, $T)) -> (live: u32) {
	for i in 0 ..< pool.count {
		live += pool.generations[i] & 1
	}
	return
}

// pool_lookup returns a copy of the item.
pool_lookup :: proc(pool: ^Pool($H, $T), handle: H) -> (item: T, ok: bool) {
	ptr := pool_get(pool, handle)
	if ptr == nil {
		return
	}
	return ptr^, true
}

// pool_handle returns the handle of a live slot, for walking a pool by index up to pool.count.
pool_handle :: proc(pool: ^Pool($H, $T), index: u32) -> (handle: H, ok: bool) {
	generation := pool.generations[index]
	if generation & 1 == 0 {
		return
	}
	return {index = index, generation = generation}, true
}
