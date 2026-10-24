package render

import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"

@(private = "file")
Tint :: struct {
	value: f32,
}

@(private = "file")
Hidden :: struct {}

// Matches the layout that a shader would read: the rows, then a payload.
@(private = "file")
Record :: struct {
	rows: [3][4]f32,
	tint: f32,
	_:    [3]f32,
}

@(private = "file")
World_Fixture :: struct {
	arena:    virtual.Arena,
	platform: core.Platform_API,
	world:    ecs.World,
}

@(private = "file")
world_setup :: proc(t: ^testing.T) -> ^World_Fixture {
	f := new(World_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.arena) == nil)
	testing.expect(t, jobs.init(2))
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.arena),
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
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	ecs.register_component(&f.world.registry, Tint)
	ecs.register_component(&f.world.registry, Hidden)
	return f
}

@(private = "file")
world_teardown :: proc(f: ^World_Fixture) {
	ecs.destroy(&f.world)
	jobs.shutdown()
	virtual.arena_destroy(&f.arena)
	free(f)
}

@(test)
extract_writes_relative_poses_in_query_order :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f := world_setup(t)
	defer world_teardown(f)
	w := &f.world

	origin := ecs.position_from_meters({1.5e11, -2e10, 7})
	// Enough entities for several chunks and jobs, in two archetypes: some interpolate and some do not.
	COUNT :: 5000
	for i in 0 ..< COUNT {
		e := ecs.spawn(w)
		pose := ecs.Transform {
			position = ecs.position_offset(origin, {f32(i), 0, 1}),
			rotation = 1,
			scale    = 2,
		}
		ecs.add(w, e, pose)
		ecs.add(w, e, Tint{f32(i)})
		if i % 2 == 0 {
			// Halfway between a previous pose 10 m behind and the current one.
			previous := pose
			previous.position = ecs.position_offset(pose.position, {-10, 0, 0})
			ecs.add(w, e, ecs.Previous_Transform(previous))
		}
	}
	ecs.add(w, ecs.spawn(w), Tint{-1})
	hidden := ecs.spawn(w)
	ecs.add(w, hidden, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, hidden, Tint{-1})
	ecs.add(w, hidden, Hidden{})
	w.clock.alpha = 0.5

	ex := extractor(w, {ecs.read(w, Tint), ecs.without(w, Hidden)})
	count := extract_count(w, ex)
	testing.expect_value(t, count, COUNT)
	records := make([]Record, count)
	defer delete(records)
	chunks := extract(w, ex, origin, ([^]byte)(raw_data(records))[:count * size_of(Record)], size_of(Record))
	for c in chunks {
		for tint, i in ecs.column(c.view, EXTRACT_TERMS, Tint) {
			records[c.first + i].tint = tint.value
		}
	}

	seen := make([]bool, COUNT)
	defer delete(seen)
	for r in records {
		i := int(r.tint)
		seen[i] = true
		x := f32(i) - (i % 2 == 0 ? 5 : 0)
		testing.expect_value(t, r.rows, [3][4]f32{{2, 0, 0, x}, {0, 2, 0, 0}, {0, 0, 2, 1}})
	}
	for s in seen {
		testing.expect(t, s)
	}
}
