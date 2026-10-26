package ecs

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
