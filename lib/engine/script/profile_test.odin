package script

import "core:sync"
import "core:testing"

import "cinnabar:core/profile"

// The recorder is a singleton, and the test runner runs tests on several threads.
@(private = "file")
recorder_lock: sync.Mutex

@(private = "file")
PROBE :: `
Probe = Behaviour.define("Probe")
function Probe:update(dt)
	Profile.begin("work")
	Profile.finish()
	-- One finish too many must not close the callback's zone.
	Profile.finish()
	Test.report(Profile.zone("zoned", function(a, b) return a + b end, 2, 3))
	Profile.begin("left open")
end
World.spawn():add(Probe)
`

when profile.ENABLED {
	@(test)
	callbacks_are_zoned_by_class :: proc(t: ^testing.T) {
		sync.guard(&recorder_lock)
		testing.expect(t, profile.init())
		defer profile.shutdown()
		f := setup_world(t)
		defer teardown_world(f)
		context.user_ptr = f
		f.platform.profile = profile.procs()
		thread, ok := spawn_source(&f.runtime, "=probe", PROBE)
		testing.expect(t, ok)
		release(&f.runtime, thread)

		profile.frame_boundary()
		frame := profile.current_frame()
		phase(f)
		profile.frame_boundary()
		expect_reports(t, f, {5})
		testing.expect_value(t, profile.zone_depth(), 0)

		c, captured := profile.capture(frame, context.temp_allocator)
		testing.expect(t, captured)
		class := profile.intern("Probe", .Script)
		callback := -1
		found: bit_set[enum {
			Work,
			Zoned,
			Left_Open,
		}]
		for z in c.zones {
			if z.name == class && z.detail == u16(profile.Callback.Update) {
				callback = int(z.depth)
			}
		}
		testing.expect(t, callback >= 0)
		for z in c.zones {
			text, _ := profile.name_text(z.name)
			switch text {
			case "work":
				found += {.Work}
				testing.expect_value(t, int(z.depth), callback + 1)
			case "zoned":
				found += {.Zoned}
				testing.expect_value(t, int(z.depth), callback + 1)
			case "left open":
				found += {.Left_Open}
				testing.expect(t, .Unbalanced in z.flags)
			}
		}
		testing.expect_value(t, found, bit_set[enum {
			Work,
			Zoned,
			Left_Open,
		}]{.Work, .Zoned, .Left_Open})

		s := profile.take_summary(context.temp_allocator)
		has_update := false
		for cost in s.costs {
			has_update ||= cost.key == {kind = .Script, detail = u16(profile.Callback.Update), name = class}
		}
		testing.expect(t, has_update)
	}
}
