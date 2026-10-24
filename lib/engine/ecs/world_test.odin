package ecs

import "core:log"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"

Health :: struct {
	value: i32,
}

Velocity :: struct {
	value: [3]f32,
}

Player :: struct {}

// The job system is a singleton, and the test runner runs tests on several threads. Every test that starts it holds
// this lock.
@(private)
scheduler_lock: sync.Mutex

Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    World,
}

// The world is large, so a fixture lives on the heap. The platform's address must not change after init.
@(private)
setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		// Only tests that start the job system call these.
		jobs_run = jobs.run,
		jobs_wait = jobs.wait,
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
	}
	testing.expect(t, init(&f.world, &f.platform))
	register_components(&f.world.registry)
	return f
}

@(private)
teardown :: proc(f: ^Fixture) {
	destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
}

@(private)
register_components :: proc(r: ^Registry) {
	register_engine_components(r)
	register_component(r, Health)
	register_component(r, Velocity)
	register_component(r, Player)
}

@(test)
handles_detect_reuse :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	a := spawn(w)
	testing.expect(t, is_alive(w, a))
	testing.expect(t, !is_alive(w, 0))
	testing.expect(t, despawn(w, a))
	testing.expect(t, !is_alive(w, a))
	testing.expect(t, !despawn(w, a))

	b := spawn(w)
	testing.expect_value(t, entity_index(b), entity_index(a))
	testing.expect_value(t, entity_generation(b), entity_generation(a) + 1)
	testing.expect(t, is_alive(w, b))
	testing.expect(t, !is_alive(w, a))
}

@(test)
exhausted_generation_retires_slot :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	a := spawn(w)
	records(w)[entity_index(a)].generation = max(u32)
	a = make_entity(entity_index(a), max(u32))
	testing.expect(t, despawn(w, a))
	testing.expect(t, entity_index(spawn(w)) != entity_index(a))
}

@(test)
reserve_takes_free_slots_then_fresh_ones :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	old: [4]Entity
	for &e in old {
		e = spawn(w)
	}
	despawn(w, old[1])
	despawn(w, old[2])

	reserved: [5]Entity
	for &e in reserved {
		e = reserve(w)
		testing.expect(t, !is_alive(w, e))
	}
	flush_reserved(w)
	for e, i in reserved {
		testing.expect(t, is_alive(w, e))
		for other in reserved[:i] {
			testing.expect(t, entity_index(e) != entity_index(other))
		}
	}
	testing.expect_value(t, w.entities.count, 7)
	testing.expect_value(t, w.entities.free_count, 0)
	testing.expect(t, !is_alive(w, old[1]))
	testing.expect(t, is_alive(w, old[3]))
}

@(test)
components_survive_moves :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	e := spawn(w)
	testing.expect(t, add(w, e, Health{10}))
	testing.expect(t, add(w, e, Velocity{{1, 2, 3}}))
	testing.expect(t, add(w, e, Player{}))
	testing.expect_value(t, get(w, e, Health).value, 10)
	testing.expect_value(t, get(w, e, Velocity).value, [3]f32{1, 2, 3})

	testing.expect(t, add(w, e, Health{11}))
	testing.expect(t, remove(w, e, Velocity))
	testing.expect(t, !remove(w, e, Velocity))
	testing.expect(t, !has(w, e, Velocity))
	testing.expect(t, has(w, e, Player))
	testing.expect_value(t, get(w, e, Health).value, 11)
}

@(test)
component_sets_share_an_archetype :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	a, b := spawn(w), spawn(w)
	add(w, a, Health{})
	add(w, a, Velocity{})
	add(w, b, Velocity{})
	add(w, b, Health{})
	testing.expect_value(t, records(w)[entity_index(a)].archetype, records(w)[entity_index(b)].archetype)
	// The empty archetype, {Health}, {Velocity} and {Health, Velocity}.
	testing.expect_value(t, w.archetype_count, 4)
}

@(test)
rows_span_chunks_and_free_them :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	entities := make([]Entity, 5000)
	defer delete(entities)
	for &e, i in entities {
		e = spawn(w)
		add(w, e, Health{i32(i)})
	}
	health := archetype(w, records(w)[entity_index(entities[0])].archetype)
	testing.expect(t, health.chunk_count > 1)

	// Removing rows moves others into their place. Every remaining entity must keep its own value.
	for e, i in entities {
		if i % 3 != 0 {
			despawn(w, e)
		}
	}
	for e, i in entities {
		if i % 3 == 0 {
			testing.expect_value(t, get(w, e, Health).value, i32(i))
		}
	}

	for e, i in entities {
		if i % 3 == 0 {
			despawn(w, e)
		}
	}
	testing.expect_value(t, health.count, 0)
	testing.expect_value(t, health.chunk_count, 0)

	used := w.chunks.used
	for &e in entities {
		e = spawn(w)
		add(w, e, Health{})
	}
	testing.expect_value(t, w.chunks.used, used)
}

@(test)
columns_fit_in_a_chunk :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	e := spawn(w)
	add(w, e, Health{})
	add(w, e, Velocity{})
	add(w, e, Player{})
	a := archetype(w, records(w)[entity_index(e)].archetype)
	testing.expect_value(t, a.capacity, u32(CHUNK_SIZE / (size_of(Entity) + size_of(Health) + size_of(Velocity))))
	for column in 0 ..< a.component_count {
		testing.expect(t, int(a.offsets[column] + a.sizes[column] * a.capacity) <= CHUNK_SIZE)
	}
}

@(test)
registry_ids_are_stable :: proc(t: ^testing.T) {
	r: Registry
	testing.expect_value(t, register_component(&r, Health), component_id("ecs.Health"))
	testing.expect_value(t, register_component(&r, Velocity, 42), Component_Id(42))
	testing.expect_value(t, registry_find(&r, 42).type, typeid_of(Velocity))

	reordered: Registry
	register_component(&reordered, Velocity, 42)
	register_component(&reordered, Health)
	testing.expect_value(t, registry_layout_hash(&reordered), registry_layout_hash(&r))

	Changed :: struct {
		value: i64,
	}
	changed: Registry
	register_component(&changed, Health)
	register_component(&changed, Changed, 42)
	testing.expect(t, registry_layout_hash(&changed) != registry_layout_hash(&r))
}

@(test)
unregistered_components_are_rejected :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	Unknown :: struct {
		x: int,
	}
	// The test runner fails a test that logs an error, and these errors are expected.
	context.logger = log.nil_logger()
	e := spawn(w)
	testing.expect(t, !add(w, e, Unknown{}))
	testing.expect(t, get(w, e, Unknown) == nil)
	testing.expect(t, !add_raw(w, e, 7, nil))
}

@(test)
despawn_all_reuses_slots_from_the_lowest :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	old: [4]Entity
	for &e in old {
		e = spawn(w)
	}
	add(w, old[1], Parent{old[0]})
	despawn(w, old[2])

	despawn_all(w)

	for e in old {
		testing.expect(t, !is_alive(w, e))
	}
	for i in 0 ..< 5 {
		testing.expect_value(t, entity_index(spawn(w)), u32(i))
	}
}
