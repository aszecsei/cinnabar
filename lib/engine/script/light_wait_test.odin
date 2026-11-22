package script

import "core:c"
import "core:testing"
import "core:time"

import "cinnabar:core/luau"

// Whether the test's handle has ended, which its poll reads.
@(private = "file", thread_local)
handle_ended: bool

@(private = "file")
HANDLE :: Light_Value{.Cutscene, 42}

// register_without_poll is the world test's registration with a handle and a binding that waits on it, as a build of a
// package that owns the type would have, before it registers the type's poll.
@(private = "file")
register_without_poll :: proc(r: ^Runtime) {
	register_world_test(r)
	define(r, "Test.handle", proc(L: ^luau.State) -> c.int {
		push_light(L, HANDLE)
		return 1
	})
	define(r, "Test.wait", proc(L: ^luau.State) -> c.int {
		return wait_light(L, {.Cutscene, check_light(L, 1, .Cutscene, "Cutscene")})
	})
}

@(private = "file")
register_with_poll :: proc(r: ^Runtime) {
	register_without_poll(r)
	light_poll(r, .Cutscene, proc(L: ^luau.State, payload: u64) -> (done: bool, results: c.int) {
		if payload != HANDLE.payload || !handle_ended {
			return false, 0
		}
		luau.pushnumber(L, 7)
		luau.pushstring(L, "ended")
		return true, 2
	})
}

// A coroutine that waits on a light userdata resumes, with what the poll gives, once the poll says that the wait is
// over. A code reload clears the poll: the wait goes on until the new build registers it again.
@(test)
a_wait_on_a_light_userdata_ends_when_its_poll_says_across_a_reload :: proc(t: ^testing.T) {
	handle_ended = false
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	reload(&f.runtime, &f.platform, register_with_poll)
	_, ok := spawn_source(
		&f.runtime,
		"=light_wait",
		`
local Waiter = Behaviour.define("Waiter")
function Waiter:start()
	self:start_coroutine(function()
		local n, text = Test.wait(Test.handle())
		Test.report(n)
		Test.report(if text == "ended" then 1 else 0)
	end)
end
World.spawn():add(Waiter)
`,
	)
	testing.expect(t, ok)
	run_phase(&f.runtime, 16 * time.Millisecond, {})
	testing.expect_value(t, len(f.reports), 0)

	reload(&f.runtime, &f.platform, register_without_poll)
	handle_ended = true
	run_phase(&f.runtime, 16 * time.Millisecond, {})
	testing.expect_value(t, len(f.reports), 0)

	reload(&f.runtime, &f.platform, register_with_poll)
	run_phase(&f.runtime, 16 * time.Millisecond, {})
	testing.expect_value(t, len(f.reports), 2)
	if len(f.reports) == 2 {
		testing.expect_value(t, f.reports[0], 7)
		testing.expect_value(t, f.reports[1], 1)
	}
}
