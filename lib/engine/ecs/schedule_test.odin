package ecs

import "base:runtime"
import "core:log"
import "core:sync"
import "core:testing"
import "core:time"

import "cinnabar:core/jobs"
import "cinnabar:core/profile"

@(private = "file")
Resources :: struct {
	// The order in which the systems started, as names.
	log:   [8]string,
	count: int,
	mutex: sync.Mutex,
	ticks: int,
}

@(private = "file")
note :: proc(r: ^Resources, name: string) {
	sync.guard(&r.mutex)
	r.log[r.count] = name
	r.count += 1
}

@(private = "file")
heal :: proc(ctx: ^System_Context) {
	it := query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
	for view in query_next(&it) {
		for &h in column(view, 0, Health) {
			h.value += 1
		}
	}
}

// Copies Health into Velocity, so it shows whether heal ran first.
@(private = "file")
copy_health :: proc(ctx: ^System_Context) {
	it := query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
	for view in query_next(&it) {
		health := column(view, 0, Health)
		for &v, i in column(view, 1, Velocity) {
			v.value.x = f32(health[i].value)
		}
	}
}

@(test)
conflicting_systems_run_in_order :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world

	COUNT :: 10000
	for i in 0 ..< COUNT {
		e := spawn(w)
		add(w, e, Health{i32(i)})
		add(w, e, Velocity{})
	}
	testing.expect(t, register_system(w, {name = "heal", stage = .Update, procedure = heal, terms = {write(w, Health)}}))
	testing.expect(
		t,
		register_system(
			w,
			{name = "copy", stage = .Update, procedure = copy_health, terms = {read(w, Health), write(w, Velocity)}, batch_chunks = 1},
		),
	)
	run_stage(w, .Update, time.Millisecond, nil)

	q := query(w, {read(w, Health), read(w, Velocity)})
	it := query_iter(w, q)
	checked := 0
	for view in query_next(&it) {
		health := column(view, 0, Health)
		for v, i in column(view, 1, Velocity) {
			testing.expect_value(t, v.value.x, f32(health[i].value))
			checked += 1
		}
	}
	testing.expect_value(t, checked, COUNT)
}

@(private = "file")
first :: proc(ctx: ^System_Context) {
	note((^Resources)(ctx.user), "first")
}

@(private = "file")
second :: proc(ctx: ^System_Context) {
	note((^Resources)(ctx.user), "second")
}

@(private = "file")
spawner :: proc(ctx: ^System_Context) {
	e := reserve(ctx.world)
	command_add(ctx.commands, ctx.world, e, Health{42})
}

@(test)
after_orders_systems_and_commands_apply :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world

	r: Resources
	// Registered in the opposite order to the one that after asks for.
	register_system(w, {name = "second", stage = .Late, procedure = second, after = {"first"}})
	register_system(w, {name = "first", stage = .Late, procedure = first})
	register_system(w, {name = "spawner", stage = .Late, procedure = spawner})
	run_stage(w, .Late, time.Millisecond, &r)

	testing.expect_value(t, r.count, 2)
	testing.expect_value(t, r.log[0], "first")
	testing.expect_value(t, r.log[1], "second")
	q := query(w, {read(w, Health)})
	testing.expect_value(t, query_entity_count(w, q), 1)
}

@(private = "file")
count_tick :: proc(ctx: ^System_Context) {
	r := (^Resources)(ctx.user)
	sync.guard(&r.mutex)
	r.ticks += 1
}

@(test)
fixed_ticks_follow_the_clock :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world

	r: Resources
	register_system(w, {name = "count", stage = .Fixed, procedure = count_tick})

	// 50 ms is exactly three ticks at 60 Hz.
	testing.expect_value(t, run_fixed(w, 50 * time.Millisecond, &r), 3)
	testing.expect_value(t, w.clock.alpha, 0)
	testing.expect_value(t, run_fixed(w, 8 * time.Millisecond, &r), 0)
	testing.expect(t, w.clock.alpha > 0.47 && w.clock.alpha < 0.49)

	// A frame duration that does not divide the tick does not drift: after 6000 frames of 1/60 s rounded up to the
	// nanosecond, the tick count is exact.
	set_tick_rate(w, 60)
	ticks := 0
	for _ in 0 ..< 6000 {
		ticks += run_fixed(w, 16_666_667 * time.Nanosecond, &r)
		free_all(f.platform.frame_allocator)
	}
	testing.expect_value(t, ticks, 6000)
	testing.expect_value(t, r.ticks, 6003)
}

@(test)
fixed_ticks_are_capped :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world

	context.logger = log.nil_logger()
	testing.expect_value(t, run_fixed(w, time.Second, nil), MAX_TICKS_PER_FRAME)
	testing.expect_value(t, w.clock.time, tick_start(&w.clock, MAX_TICKS_PER_FRAME))
	testing.expect_value(t, run_fixed(w, 0, nil), 0)
}

// The tick iterator runs the ticks that run_fixed runs, one at a time: the clock's tick is the running tick's number,
// tick_time is the world time at its end, and only the first tick of a frame is first.
@(test)
ticks_run_one_at_a_time :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world

	r: Resources
	register_system(w, {name = "count", stage = .Fixed, procedure = count_tick})
	it := begin_ticks(w, 50 * time.Millisecond)
	n := 0
	for next_tick(&it) {
		testing.expect_value(t, first_tick(&it), n == 0)
		testing.expect_value(t, w.clock.tick, u64(n))
		testing.expect_value(t, tick_time(w), tick_start(&w.clock, u64(n + 1)))
		run_tick_systems(&it, &r)
		testing.expect_value(t, r.ticks, n + 1)
		n += 1
	}
	testing.expect_value(t, n, 3)
	testing.expect_value(t, it.count, 3)
	testing.expect_value(t, w.clock.tick, 3)
	testing.expect_value(t, w.clock.alpha, 0)
	testing.expect(t, !next_tick(&it), "a finished iterator stays finished")

	// A frame shorter than a tick runs none, and leaves alpha at the fraction that passed.
	it = begin_ticks(w, 8 * time.Millisecond)
	testing.expect(t, !next_tick(&it))
	testing.expect(t, w.clock.alpha > 0.47 && w.clock.alpha < 0.49)
}

@(test)
after_cycles_are_rejected :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	context.logger = log.nil_logger()
	register_system(w, {name = "a", stage = .Update, procedure = first, after = {"b"}})
	register_system(w, {name = "b", stage = .Update, procedure = second, after = {"a"}})
	testing.expect(t, !register_system(w, {name = "a", stage = .Update, procedure = first}))
	run_stage(w, .Update, time.Millisecond, nil)
	testing.expect(t, w.schedule.failed)
}

when profile.ENABLED {
	@(test)
	system_batches_are_zoned_by_system :: proc(t: ^testing.T) {
		sync.guard(&scheduler_lock)
		testing.expect(t, profile.init())
		defer profile.shutdown()
		testing.expect(t, jobs.init())
		defer jobs.shutdown()
		f := setup(t)
		defer teardown(f)
		w := &f.world
		f.platform.profile = profile.procs()

		r: Resources
		register_system(w, {name = "first", stage = .Late, procedure = first})
		profile.frame_boundary()
		frame := profile.current_frame()
		run_stage(w, .Late, time.Millisecond, &r)
		profile.frame_boundary()

		c, _ := profile.capture(frame, context.temp_allocator)
		system := profile.intern("first", .System)
		zoned := false
		for z in c.zones {
			zoned ||= z.name == system && .Job not_in z.flags
		}
		testing.expect(t, zoned)
		s := profile.take_summary(context.temp_allocator)
		counted := false
		for cost in s.costs {
			counted ||= cost.key == {kind = .System, name = system} && cost.calls == 1
		}
		testing.expect(t, counted)
	}
}

@(private = "file")
Chunk_Log :: struct {
	kind:    Job_Buffer,
	flushed: [dynamic]int,
}

// note_chunk asks for its job's buffer, except in the second chunk's job, and writes the job's first chunk in it.
@(private = "file")
note_chunk :: proc(ctx: ^System_Context) {
	if ctx.first_chunk == 1 {
		return
	}
	l := (^Chunk_Log)(ctx.user)
	(^int)(job_buffer(ctx, l.kind))^ = ctx.first_chunk
}

// A job's buffer is made when it asks, and the stage's buffers reach flush in job order, only from the jobs that
// asked. A reload clears the kinds.
@(test)
job_buffers_flush_in_job_order :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init())
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world

	// Three archetypes, so three chunks and, at one chunk a job, three jobs.
	for _ in 0 ..< 3 {
		e := spawn(w)
		add(w, e, Health{1})
	}
	player := spawn(w)
	add(w, player, Health{2})
	add(w, player, Player{})
	e := spawn(w)
	add(w, e, Health{3})
	add(w, e, Velocity{})

	l := Chunk_Log{flushed = make([dynamic]int, context.temp_allocator)}
	l.kind = register_job_buffer(w, {
		name = "chunks",
		user = &l,
		make = proc(user: rawptr, allocator: runtime.Allocator) -> rawptr {
			return new(int, allocator)
		},
		flush = proc(user: rawptr, buffers: []rawptr) {
			l := (^Chunk_Log)(user)
			for b in buffers {
				append(&l.flushed, (^int)(b)^)
			}
		},
	})
	testing.expect(t, l.kind != 0)
	register_system(w, {name = "note", stage = .Update, procedure = note_chunk, terms = {read(w, Health)}, batch_chunks = 1})
	run_stage(w, .Update, 0, &l)
	testing.expect_value(t, len(l.flushed), 2)
	if len(l.flushed) == 2 {
		testing.expect_value(t, l.flushed[0], 0)
		testing.expect_value(t, l.flushed[1], 2)
	}
	testing.expect(t, jobs.drain_frame())

	reload(w, &f.platform)
	testing.expect_value(t, w.schedule.job_buffer_count, 0)
}
