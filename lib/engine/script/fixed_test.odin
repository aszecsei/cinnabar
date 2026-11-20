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
	_, ok := spawn_source(
		&f.runtime,
		"=stepper",
		`
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
`,
	)
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
	_, ok := spawn_source(
		&f.runtime,
		"=stepper",
		`
local Stepper = Behaviour.define("Stepper", {code = Field.number(0)})
function Stepper:fixed_update(dt) Test.report(self.code) end
World.spawn():add(Stepper, {code = 1})
World.spawn():add(Stepper, {code = 2, enabled = false})
local inactive = World.spawn()
inactive:add(Stepper, {code = 3})
inactive:set_active(false)
`,
	)
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
	_, ok := spawn_source(
		&f.runtime,
		"=jumper",
		`
local Jumper = Behaviour.define("Jumper")
function Jumper:fixed_update(dt) Test.report(Input.was_pressed(Key.Space) and 1 or 0) end
World.spawn():add(Jumper)
`,
	)
	testing.expect(t, ok)
	space := core.Input {
		down    = {.Space},
		pressed = {.Space},
	}
	game_frame(f, THREE_TICKS, space)
	expect_reports(t, f, {1, 0, 0})
	game_frame(f, NO_TICK, space)
	expect_reports(t, f, {})
	game_frame(f, 16 * time.Millisecond)
	expect_reports(t, f, {1})
	game_frame(f, 17 * time.Millisecond)
	expect_reports(t, f, {0})
}

@(test)
gamepad_edges_and_text_reach_one_tick :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(
		&f.runtime,
		"=typist",
		`
local Typist = Behaviour.define("Typist")
function Typist:fixed_update(dt)
	Test.report(Input.gamepad_was_pressed(1, GamepadButton.A) and 1 or 0)
	Test.report(Input.gamepad_was_released(1, GamepadButton.B) and 1 or 0)
	Test.report(#Input.text)
	Test.report(Input.text == "ab" and 1 or 0)
end
World.spawn():add(Typist)
`,
	)
	testing.expect(t, ok)
	frame_input :: proc(text: string) -> (input: core.Input) {
		input.gamepads[0].pressed = {.A}
		input.gamepads[0].released = {.B}
		core.input_text_append(&input.text, text)
		return
	}
	// The first tick gets them, and the later ticks of the frame do not.
	game_frame(f, THREE_TICKS, frame_input("ab"))
	expect_reports(t, f, {1, 1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0})
	// A frame with no tick keeps them for the next, in the order they were typed.
	game_frame(f, NO_TICK, frame_input("a"))
	expect_reports(t, f, {})
	game_frame(f, 16 * time.Millisecond, frame_input("b"))
	expect_reports(t, f, {1, 1, 2, 1})
	game_frame(f, 17 * time.Millisecond)
	expect_reports(t, f, {0, 0, 0, 0})
}

// wait_fixed resumes once at the end of each tick, after fixed_update, and not in a frame without a tick.
@(test)
wait_fixed_resumes_each_tick :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(
		&f.runtime,
		"=pusher",
		`
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
`,
	)
	testing.expect(t, ok)
	game_frame(f, 33_400 * time.Microsecond)
	// start runs in the first tick's fixed step, and its coroutine runs to its first wait at once.
	expect_reports(t, f, {31, 20, 31, 20, 31})
	game_frame(f, NO_TICK)
	expect_reports(t, f, {})
}

@(test)
an_action_pressed_between_ticks_reaches_the_next_tick :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(
		&f.runtime,
		"=actor",
		`
Input.define_action("jump", { "key:Space", "pad:A", "pad:LeftStickUp" })
local Actor = Behaviour.define("Actor")
function Actor:fixed_update(dt) Test.report(Input.action_pressed("jump") and 1 or 0) end
World.spawn():add(Actor)
`,
	)
	testing.expect(t, ok)
	stick_up := core.Input{}
	stick_up.gamepads[0] = {
		connected         = true,
		direction_down    = {.Left_Stick_Up},
		direction_pressed = {.Left_Stick_Up},
	}
	// The first tick of the frame gets the edge, and the later ticks do not.
	game_frame(f, THREE_TICKS, stick_up)
	expect_reports(t, f, {1, 0, 0})
	// A frame with no tick keeps the edge for the next tick, which gets it once.
	game_frame(f, NO_TICK, stick_up)
	expect_reports(t, f, {})
	held := stick_up
	held.gamepads[0].direction_pressed = {}
	game_frame(f, 16 * time.Millisecond, held)
	expect_reports(t, f, {1})
	game_frame(f, 17 * time.Millisecond, held)
	expect_reports(t, f, {0})
}

// scaled_frame runs a frame whose real duration is real and whose world takes real times scale, as the game's frame
// code does with Game.time_scale. It returns the number of ticks.
@(private = "file")
scaled_frame :: proc(
	f: ^World_Fixture,
	real: time.Duration,
	scale: f32,
	input: core.Input = {},
) -> int {
	set_frame_time(&f.runtime, real, scale)
	step := time.Duration(f64(real) * f64(scale))
	it := ecs.begin_ticks(&f.world, step)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, nil)
		fixed_update(&f.runtime, &it, input)
		ecs.update_transforms(&f.world)
		fixed_events(&f.runtime)
		ecs.update_transforms(&f.world)
	}
	run_phase(&f.runtime, step, input)
	return it.count
}

// A world that takes no time runs no tick, and the edges of its frames wait for the first tick that runs, as they do
// in a pause.
@(test)
a_time_scale_of_zero_runs_no_ticks_and_keeps_the_edges :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(
		&f.runtime,
		"=jumper",
		`
local Jumper = Behaviour.define("Jumper")
function Jumper:fixed_update(dt) Test.report(Input.was_pressed(Key.Space) and 1 or 0) end
World.spawn():add(Jumper)
`,
	)
	testing.expect(t, ok)
	space := core.Input {
		down    = {.Space},
		pressed = {.Space},
	}
	testing.expect_value(t, scaled_frame(f, THREE_TICKS, 0, space), 0)
	testing.expect_value(t, scaled_frame(f, THREE_TICKS, 0), 0)
	expect_reports(t, f, {})
	testing.expect_value(t, f.world.clock.time, 0)
	testing.expect_value(t, scaled_frame(f, 16 * time.Millisecond, 1), 0)
	testing.expect_value(t, scaled_frame(f, 1 * time.Millisecond, 1), 1)
	expect_reports(t, f, {1})
	testing.expect_value(t, scaled_frame(f, THREE_TICKS, 1), 3)
	expect_reports(t, f, {0, 0, 0})
}

// The ticks come from the scaled time: half the time is half the ticks, without a drift in the accumulator.
@(test)
a_time_scale_of_half_runs_half_the_ticks :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	ticks := 0
	for _ in 0 ..< 6 {
		ticks += scaled_frame(f, THREE_TICKS, 0.5)
	}
	testing.expect_value(t, ticks, 9)
	testing.expect_value(t, f.world.clock.time, 150 * time.Millisecond)
}

// Time.real_delta is the frame's real seconds, and Time.scale the game's scale, while Time.delta is the world's step.
@(test)
real_delta_ignores_the_scale :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(
		&f.runtime,
		"=clock",
		`
local Clock = Behaviour.define("Clock")
function Clock:update(dt)
	Test.report(Time.delta)
	Test.report(Time.real_delta)
	Test.report(Time.scale)
	Test.report(Time.time)
end
World.spawn():add(Clock)
`,
	)
	testing.expect(t, ok)
	scaled_frame(f, 20 * time.Millisecond, 0.5)
	expect_reports(t, f, {0.01, 0.02, 0.5, 0.01})
	scaled_frame(f, 20 * time.Millisecond, 0)
	expect_reports(t, f, {0, 0.02, 0, 0.01})
}

// A tap while a context blocks the action, then the pop in the same frame: the next tick gets the tap's edges, and
// they are not a press.
@(test)
a_tap_before_a_pop_does_not_reach_the_next_tick :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(
		&f.runtime,
		"=gate",
		`
Input.define_action("jump", { "key:Space" })
Input.define_context("cutscene", {})
local held = Input.push_context("cutscene")
local Gate = Behaviour.define("Gate")
function Gate:fixed_update() Test.report(Input.action_pressed("jump") and 1 or 0) end
function Gate:update() if held then held:pop(); held = nil end end
World.spawn():add(Gate)
`,
	)
	testing.expect(t, ok)
	tap: core.Input
	tap.pressed = {.Space}
	tap.released = {.Space}
	testing.expect_value(t, game_frame(f, NO_TICK, tap), 0)
	testing.expect_value(t, game_frame(f, 17 * time.Millisecond), 1)
	expect_reports(t, f, {0})
	// A tap after that is a press, in the first tick that has it.
	testing.expect_value(t, game_frame(f, 17 * time.Millisecond, tap), 1)
	expect_reports(t, f, {1})
}
