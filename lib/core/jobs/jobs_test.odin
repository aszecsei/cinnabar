package jobs

import "base:intrinsics"
import "core:sync"
import "core:testing"
import "core:time"

import "cinnabar:core/profile"

// The scheduler is a singleton, and the test runner runs tests on several threads.
@(private = "file")
scheduler_lock: sync.Mutex

@(private = "file")
add_one :: proc(data: rawptr) {
	sync.atomic_add((^int)(data), 1)
}

@(test)
counter_waits_for_all_jobs :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, init())
	defer shutdown()

	COUNT :: 1000
	total: int
	jobs := make([]Job, COUNT)
	defer delete(jobs)
	for &job in jobs {
		job = {add_one, &total}
	}
	counter: Counter
	run(jobs, &counter)
	wait(&counter)
	testing.expect_value(t, sync.atomic_load(&total), COUNT)
	testing.expect_value(t, counter.value, 0)
	testing.expect(t, drain_frame())
}

@(private = "file")
Nested :: struct {
	total:   ^int,
	scratch: bool,
}

// spawn starts sub-jobs from a job and waits for them, which suspends the job's fiber.
@(private = "file")
spawn :: proc(data: rawptr) {
	n := (^Nested)(data)
	SUB :: 50
	jobs: [SUB]Job
	for &job in jobs {
		job = {add_one, n.total}
	}
	counter: Counter
	run(jobs[:], &counter)
	scratch := make([]int, 1024, context.temp_allocator)
	scratch[len(scratch) - 1] = 7
	wait(&counter)
	// The scratch memory belongs to the fiber, so it survives the wait even if the fiber moved threads.
	n.scratch = scratch[len(scratch) - 1] == 7
}

@(private = "file")
run_nested :: proc(t: ^testing.T, workers: int) {
	testing.expect(t, init(workers))
	defer shutdown()

	OUTER :: 16
	total: int
	nested: [OUTER]Nested
	jobs: [OUTER]Job
	for i in 0 ..< OUTER {
		nested[i] = {total = &total}
		jobs[i] = {spawn, &nested[i]}
	}
	counter: Counter
	run(jobs[:], &counter)
	wait(&counter)
	testing.expect_value(t, sync.atomic_load(&total), OUTER * 50)
	for n in nested {
		testing.expect(t, n.scratch)
	}
}

@(test)
jobs_wait_for_sub_jobs :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	run_nested(t, 0)
}

// With one worker, the main thread must run jobs while the main fiber waits, or the nested waits deadlock.
@(test)
main_thread_runs_jobs_while_waiting :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	run_nested(t, 1)
}

@(test)
drain_frame_waits_for_forgotten_jobs :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, init(2))
	defer shutdown()

	total: int
	jobs := [4]Job{{add_one, &total}, {add_one, &total}, {add_one, &total}, {add_one, &total}}
	forgotten: Counter
	run(jobs[:], &forgotten)
	// The jobs may finish before the drain, so only the result is certain.
	drain_frame()
	testing.expect_value(t, sync.atomic_load(&total), 4)
	testing.expect_value(t, sync.atomic_load(&forgotten.value), 0)

	background: Counter
	run_background(jobs[:1], &background)
	testing.expect(t, drain_frame(), "a background job counted as a frame job")
	wait(&background)
	testing.expect_value(t, sync.atomic_load(&total), 5)
}

// run_and_return waits for a counter on its own stack frame, which the next call reuses.
@(private = "file")
run_and_return :: #force_no_inline proc(total: ^int) {
	counter: Counter
	jobs := [2]Job{{add_one, total}, {add_one, total}}
	run(jobs[:], &counter)
	wait(&counter)
}

// scribble overwrites the stack where the last counter was, so a late write to it shows up as corruption.
@(private = "file")
scribble :: #force_no_inline proc() {
	junk: [64]uintptr
	for &j in junk {
		intrinsics.volatile_store(&j, 0x11)
	}
}

@(private = "file")
reuse_counters :: proc(data: rawptr) {
	for _ in 0 ..< 500 {
		run_and_return((^int)(data))
		scribble()
	}
}

@(test)
counters_can_die_right_after_wait :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, init())
	defer shutdown()

	OUTER :: 8
	total: int
	jobs: [OUTER]Job
	for &job in jobs {
		job = {reuse_counters, &total}
	}
	counter: Counter
	run(jobs[:], &counter)
	reuse_counters(&total)
	wait(&counter)
	testing.expect_value(t, sync.atomic_load(&total), (OUTER + 1) * 500 * 2)
}

@(private = "file")
Locked :: struct {
	mutex: Mutex,
	value: int,
	total: int,
}

// hold_across_wait waits for a sub-job while it holds the lock. With an OS lock and two threads this deadlocks:
// the other thread would block on the lock, and the sub-job would have no thread to run on.
@(private = "file")
hold_across_wait :: proc(data: rawptr) {
	l := (^Locked)(data)
	if guard(&l.mutex) {
		before := l.value
		sub: Counter
		run({{add_one, &l.total}}, &sub)
		wait(&sub)
		l.value = before + 1
	}
}

@(test)
mutex_holds_across_waits :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, init(1))
	defer shutdown()

	COUNT :: 16
	l: Locked
	jobs: [COUNT]Job
	for &job in jobs {
		job = {hold_across_wait, &l}
	}
	counter: Counter
	run(jobs[:], &counter)
	hold_across_wait(&l)
	wait(&counter)
	testing.expect_value(t, l.value, COUNT + 1)
	testing.expect_value(t, sync.atomic_load(&l.total), COUNT + 1)
	testing.expect(t, !l.mutex.locked && l.mutex.waiters == nil)
}

@(private = "file")
increment_locked :: proc(data: rawptr) {
	l := (^Locked)(data)
	for _ in 0 ..< 1000 {
		lock(&l.mutex)
		l.value += 1
		unlock(&l.mutex)
	}
}

@(test)
mutex_excludes_under_contention :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, init())
	defer shutdown()

	COUNT :: 32
	l: Locked
	jobs: [COUNT]Job
	for &job in jobs {
		job = {increment_locked, &l}
	}
	counter: Counter
	run(jobs[:], &counter)
	wait(&counter)
	testing.expect_value(t, l.value, COUNT * 1000)
}

@(private = "file")
Zoned :: struct {
	inner: profile.Name,
}

@(private = "file")
sleep_briefly :: proc(data: rawptr) {
	time.sleep(2 * time.Millisecond)
}

// zoned_wait waits inside a zone, so the zone is split where its fiber suspends.
@(private = "file")
zoned_wait :: proc(data: rawptr) {
	z := (^Zoned)(data)
	profile.zone(z.inner)
	counter: Counter
	run([]Job{{sleep_briefly, nil}}, &counter)
	wait(&counter)
}

when profile.ENABLED {
	@(test)
	zones_follow_fibers_across_waits :: proc(t: ^testing.T) {
		sync.guard(&scheduler_lock)
		testing.expect(t, profile.init())
		defer profile.shutdown()
		testing.expect(t, init(2))
		defer shutdown()

		parent := profile.intern("frame code", .Frame)
		z := Zoned{profile.intern("inner", .User)}
		profile.frame_boundary()
		frame := profile.current_frame()
		profile.begin_zone(parent, 0)
		counter: Counter
		run([]Job{{zoned_wait, &z}}, &counter)
		wait(&counter)
		profile.end_zone()
		profile.frame_boundary()

		c, ok := profile.capture(frame, context.temp_allocator)
		testing.expect(t, ok)
		suspended, resumed, job, sub_job, waited: bool
		inner_fiber: u8
		for zone in c.zones {
			switch {
			case zone.name == z.inner && .Job in zone.flags:
				// The job that the zone started is named after it.
				sub_job = true
			case zone.name == z.inner:
				testing.expect_value(t, zone.depth, 1)
				testing.expect(t, inner_fiber == 0 || inner_fiber == zone.fiber)
				inner_fiber = zone.fiber
				suspended ||= .Suspended in zone.flags
				resumed ||= .Resumed in zone.flags
			case zone.name == parent && .Job in zone.flags:
				testing.expect_value(t, zone.depth, 0)
				job = true
			case zone.name == parent:
				testing.expect_value(t, zone.lane, profile.main_lane())
				waited ||= .Suspended in zone.flags
			}
		}
		testing.expect(t, suspended && resumed && job && sub_job && waited)
		testing.expect(t, inner_fiber != 0)
	}
}
