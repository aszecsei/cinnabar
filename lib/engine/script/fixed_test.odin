package script

import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:engine/ecs"

// game_frame runs one frame as the game's frame code does: each tick that is due with its systems, the fixed step
// and the tick's events, then the script phase. It returns the number of ticks.
@(private = "file")
game_frame :: proc(f: ^World_Fixture, dt: time.Duration, input: core.Input = {}) -> int {
	it := ecs.begin_ticks(&f.world, dt)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, nil)
		fixed_update(&f.runtime, &it, input)
		ecs.update_transforms(&f.world)
		fixed_events(&f.runtime)
		ecs.update_transforms(&f.world)
	}
	run_phase(&f.runtime, dt, input)
	return it.count
}

// 50 ms is exactly three ticks at 60 Hz, and 8 ms is less than one.
@(private = "file")
THREE_TICKS :: 50 * time.Millisecond
@(private = "file")
NO_TICK :: 8 * time.Millisecond

// fixed_update runs once per tick, after start, with the tick's delta in Time; update runs once per frame, with
// in_fixed false.
@(test)
fixed_update_runs_once_per_tick :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=stepper", `
local Stepper = Behaviour.define("Stepper")
function Stepper:start() Test.report(3) end
function Stepper:fixed_update(dt)
	local code = 20
	if Time.in_fixed then code += 1 end
	if math.abs(dt - Time.fixed_delta) < 1e-9 then code += 2 end
	if Time.delta == dt then code += 4 end
	Test.report(code)
end
function Stepper:update(dt) Test.report(Time.in_fixed and 41 or 40) end
World.spawn():add(Stepper)
`)
	testing.expect(t, ok)
	testing.expect_value(t, game_frame(f, THREE_TICKS), 3)
	expect_reports(t, f, {3, 27, 27, 27, 40})
	testing.expect_value(t, game_frame(f, NO_TICK), 0)
	expect_reports(t, f, {40})
}

// A disabled instance and one on an inactive entity get no fixed_update, as they get no update.
@(test)
fixed_update_skips_disabled_instances :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=stepper", `
local Stepper = Behaviour.define("Stepper", {code = Field.number(0)})
function Stepper:fixed_update(dt) Test.report(self.code) end
World.spawn():add(Stepper, {code = 1})
World.spawn():add(Stepper, {code = 2, enabled = false})
local inactive = World.spawn()
inactive:add(Stepper, {code = 3})
inactive:set_active(false)
`)
	testing.expect(t, ok)
	game_frame(f, THREE_TICKS)
	expect_reports(t, f, {1, 1, 1})
}

// An input edge reaches the first tick of its frame and no other, and an edge in a frame that ran no tick waits for
// the next tick.
@(test)
input_edges_reach_one_tick :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=jumper", `
local Jumper = Behaviour.define("Jumper")
function Jumper:fixed_update(dt) Test.report(Input.was_pressed(Key.Space) and 1 or 0) end
World.spawn():add(Jumper)
`)
	testing.expect(t, ok)
	space := core.Input{down = {.Space}, pressed = {.Space}}
	game_frame(f, THREE_TICKS, space)
	expect_reports(t, f, {1, 0, 0})
	game_frame(f, NO_TICK, space)
	expect_reports(t, f, {})
	game_frame(f, 16 * time.Millisecond)
	expect_reports(t, f, {1})
	game_frame(f, 17 * time.Millisecond)
	expect_reports(t, f, {0})
}

// wait_fixed resumes once at the end of each tick, after fixed_update, and not in a frame without a tick.
@(test)
wait_fixed_resumes_each_tick :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=pusher", `
local Pusher = Behaviour.define("Pusher")
function Pusher:start()
	self:start_coroutine(function()
		while true do
			Test.report(Time.in_fixed and 31 or 30)
			wait_fixed()
		end
	end)
end
function Pusher:fixed_update(dt) Test.report(20) end
World.spawn():add(Pusher)
`)
	testing.expect(t, ok)
	game_frame(f, 33_400 * time.Microsecond)
	// start runs in the first tick's fixed step, and its coroutine runs to its first wait at once.
	expect_reports(t, f, {31, 20, 31, 20, 31})
	game_frame(f, NO_TICK)
	expect_reports(t, f, {})
}
