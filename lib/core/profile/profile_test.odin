package profile

import "core:sync"
import "core:testing"
// Only the tests with the profiler use it.
@(require) import "core:time"

// The recorder is a singleton, and the test runner runs tests on several threads.
@(private = "file")
recorder_lock: sync.Mutex

@(private = "file")
find_zone :: proc(zones: []Zone, name: Name) -> (Zone, int) {
	for z, i in zones {
		if z.name == name {
			return z, i
		}
	}
	return {}, -1
}

@(private = "file")
find_cost :: proc(s: Summary, key: Cost_Key) -> (Summary_Cost, bool) {
	for c in s.costs {
		if c.key == key {
			return c, true
		}
	}
	return {}, false
}

when ENABLED {
	@(test)
	names_are_interned_by_content :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, init())
		defer shutdown()

		buf := [?]u8{'s', 'p', 'i', 'n'}
		a := intern(string(buf[:]), .System)
		buf[0] = 'x'
		testing.expect_value(t, intern("spin", .Script), a)
		text, category := name_text(a)
		testing.expect_value(t, text, "spin")
		testing.expect_value(t, category, Category.System)
		testing.expect(t, intern("xpin", .System) != a)
		testing.expect_value(t, intern("", .User), NO_NAME)
	}

	@(test)
	too_many_names_share_one :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, init())
		defer shutdown()

		buf: [16]u8
		last: Name
		for i in 0 ..< MAX_NAMES {
			n := 0
			for v := i;; v /= 10 {
				buf[n] = '0' + u8(v % 10)
				n += 1
				if v < 10 {
					break
				}
			}
			last = intern(string(buf[:n]), .User)
		}
		testing.expect_value(t, last, OVERFLOW_NAME)
	}

	@(test)
	zones_nest_in_end_order :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, init())
		defer shutdown()

		outer, inner := intern("outer", .Frame), intern("inner", .Frame)
		frame_boundary()
		frame := current_frame()
		begin_zone(outer, 0)
		begin_zone(inner, 7)
		end_zone()
		end_zone()
		frame_boundary()

		c, ok := capture(frame, context.temp_allocator)
		testing.expect(t, ok)
		o, oi := find_zone(c.zones, outer)
		n, ni := find_zone(c.zones, inner)
		testing.expect(t, oi >= 0 && ni >= 0 && ni < oi)
		testing.expect_value(t, o.depth, 0)
		testing.expect_value(t, n.depth, 1)
		testing.expect_value(t, n.detail, 7)
		testing.expect(t, o.start <= n.start && n.end <= o.end)
		testing.expect_value(t, o.lane, main_lane())
	}

	@(test)
	a_suspended_zone_has_linked_segments :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, init())
		defer shutdown()

		fiber: Fiber_Zones
		init_fiber(&fiber, 4)
		set_fiber(&fiber)
		defer set_fiber(nil)
		job := intern("job", .Job)
		frame_boundary()
		frame := current_frame()
		begin_zone(job, 0)
		fiber_suspend()
		fiber_resume()
		close_zones(0)
		frame_boundary()

		c, _ := capture(frame, context.temp_allocator)
		testing.expect_value(t, len(c.zones), 2)
		if len(c.zones) == 2 {
			first, second := c.zones[0], c.zones[1]
			testing.expect_value(t, first.flags, Zone_Flags{.Suspended})
			testing.expect_value(t, second.flags, Zone_Flags{.Resumed, .Unbalanced})
			testing.expect_value(t, first.fiber, 5)
			testing.expect_value(t, second.fiber, 5)
			testing.expect(t, first.end <= second.start)
		}
	}

	@(test)
	a_full_lane_drops_and_counts :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, init())
		defer shutdown()

		n := intern("tiny", .User)
		frame_boundary()
		frame := current_frame()
		for _ in 0 ..< LANE_CAPACITY + 10 {
			begin_zone(n, 0)
			end_zone()
		}
		frame_boundary()
		r, ok := find_ring(frame)
		testing.expect(t, ok)
		testing.expect_value(t, r.dropped, 10)
		testing.expect_value(t, r.count, LANE_CAPACITY)
	}

	@(test)
	script_time_excludes_nested_callbacks :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, init())
		defer shutdown()

		outer, inner, system := intern("Outer", .Script), intern("Inner", .Script), intern("spin", .System)
		wait := intern("vsync", .Wait)
		frame_boundary()
		begin_zone(outer, u16(Callback.Update))
		begin_zone(inner, u16(Callback.On_Enable))
		time.sleep(4 * time.Millisecond)
		end_zone()
		end_zone()
		begin_zone(system, 0)
		end_zone()
		begin_zone(wait, 0)
		time.sleep(2 * time.Millisecond)
		end_zone()
		frame_boundary()

		s := take_summary(context.temp_allocator)
		testing.expect_value(t, s.frames, 1)
		o, has_outer := find_cost(s, {kind = .Script, detail = u16(Callback.Update), name = outer})
		i, has_inner := find_cost(s, {kind = .Script, detail = u16(Callback.On_Enable), name = inner})
		_, has_system := find_cost(s, {kind = .System, name = system})
		testing.expect(t, has_outer && has_inner && has_system)
		testing.expect(t, i.average >= f64(4 * time.Millisecond))
		testing.expect(t, o.average < f64(2 * time.Millisecond))
		testing.expect_value(t, o.calls, 1)
		testing.expect(t, s.wait_max >= u64(2 * time.Millisecond))
		testing.expect(t, s.cpu_max >= u64(4 * time.Millisecond))
		testing.expect_value(t, take_summary(context.temp_allocator).frames, 0)
	}

	@(test)
	gpu_spans_complete_a_frame :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, init())
		defer shutdown()

		pass := intern("prepass", .Render)
		frame_boundary()
		frame := current_frame()
		frame_boundary()
		exists, ready := frame_state(frame)
		testing.expect(t, exists && !ready)
		add_gpu(frame, {{start = 100, end = 300, name = pass}, {start = 300, end = 400, name = pass, detail = 1}}, 50, 450)
		exists, ready = frame_state(frame)
		testing.expect(t, exists && ready)

		s := take_summary(context.temp_allocator)
		testing.expect_value(t, s.gpu_frames, 1)
		testing.expect_value(t, s.gpu_max, 400)
		testing.expect_value(t, s.gpu_worst_frame, frame)
		c, ok := find_cost(s, {kind = .Pass, name = pass})
		testing.expect(t, ok)
		testing.expect_value(t, c.average, 300)
		testing.expect_value(t, c.calls, 1)
		cap, _ := capture(frame, context.temp_allocator)
		testing.expect_value(t, len(cap.gpu), 2)
	}

	@(test)
	worst_frames_outlive_the_ring :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, init())
		defer shutdown()

		slow := intern("slow", .Frame)
		frame_boundary()
		worst := current_frame()
		begin_zone(slow, 0)
		time.sleep(3 * time.Millisecond)
		end_zone()
		frame_boundary()
		s := take_summary(context.temp_allocator)
		testing.expect_value(t, s.cpu_worst_frame, worst)
		testing.expect_value(t, worst_recent(10), worst)
		add_gpu(worst, nil, 0, 0)
		for _ in 0 ..< FRAME_RING + 8 {
			frame_boundary()
		}
		_, in_ring := find_ring(worst)
		testing.expect(t, !in_ring)
		c, ok := capture(worst, context.temp_allocator)
		testing.expect(t, ok)
		_, i := find_zone(c.zones, slow)
		testing.expect(t, i >= 0)
		_, ok = capture(worst + 1, context.temp_allocator)
		testing.expect(t, !ok)
	}

	@(test)
	nothing_is_recorded_while_off :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, init())
		defer shutdown()

		n := intern("off", .User)
		frame_boundary()
		frame := current_frame()
		set_recording(false)
		begin_zone(n, 0)
		set_recording(true)
		end_zone()
		frame_boundary()
		c, _ := capture(frame, context.temp_allocator)
		testing.expect_value(t, len(c.zones), 0)
	}
} else {
	@(test)
	the_disabled_profiler_records_nothing :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, init())
		defer shutdown()

		p := procs()
		testing.expect_value(t, name(&p, "spin", .System), NO_NAME)
		scope_text(&p, "zone")
		frame_boundary()
		testing.expect_value(t, current_frame(), 0)
		testing.expect_value(t, zone_depth(), 0)
		_, ok := capture(1, context.temp_allocator)
		testing.expect(t, !ok)
	}
}
