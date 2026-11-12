package script

import "core:testing"
import "core:time"

import "cinnabar:core/testlog"
import "cinnabar:engine/ecs"

// Action.define checks its name and parameters as Behaviour.define checks its fields, and an action class is not a
// behaviour.
@(test)
action_define_checks_its_parameters :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	context.logger = testlog.expected_errors()
	testing.expect(t, !run(t, f, `Action.define(3)`))
	testing.expect(t, !run(t, f, `Action.define("bark", { line = 3 })`))
	testing.expect(t, !run(t, f, `Action.define("bark", { entity = Param.entity() })`))
	testing.expect(t, !run(t, f, `Action.define("bark", { line = Field.string() })`))
	testing.expect(t, run(t, f, `Action.define("bark", { line = Param.string(), at = Param.position() })`))
	testing.expect(t, action_defined(&f.runtime, "bark"))
	testing.expect(t, !action_defined(&f.runtime, "growl"))
	// The first class of a name is kept.
	testing.expect(t, run(t, f, `
		local Again = Action.define("bark")
		Test.report(if Again.__params.line == nil then 1 else 0)
	`))
	expect_reports(t, f, {1})
}

// Action_Hook runs a test's step in the fixed hook.
@(private = "file")
Action_Hook :: struct {
	step:   int,
	entity: ecs.Entity,
	handle: Action_Handle,
	status: [3]Action_Status,
}

// A script action starts with its parameters' defaults and its arguments, ticks with the tick's length, and stops,
// and the coroutines that it started end with it.
@(test)
a_script_action_starts_ticks_and_stops :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	testing.expect(t, run(t, f, `
		local Bark = Action.define("bark", { line = Param.string("hey"), times = Param.number(2), at = Param.entity() })
		function Bark:start()
			Test.report(#self.line)
			Test.report(self.times)
			Test.report(if self.at == self.entity then 1 else 0)
			self.left = self.times
			self:start_coroutine(function()
				while true do
					wait_fixed()
					Test.report(100)
				end
			end)
		end
		function Bark:tick(dt)
			Test.report(math.round(dt * 60))
			self.left -= 1
			return if self.left == 0 then "succeeded" else "running"
		end
		function Bark:stop()
			Test.report(-1)
		end
	`))
	hook := Action_Hook {
		entity = ecs.spawn(&f.world),
	}
	set_fixed_hook(&f.runtime, {proc(r: ^Runtime, data: rawptr) {
		h := (^Action_Hook)(data)
		switch h.step {
		case 0:
			args := []Action_Arg{{"line", "hello"}, {"at", h.entity}}
			h.handle, h.status[0] = start_action(r, "bark", h.entity, args)
		case 1:
			h.status[1] = tick_action(r, h.handle, 1.0 / 60)
		case 2:
			h.status[2] = tick_action(r, h.handle, 1.0 / 60)
			stop_action(r, h.handle)
		}
		h.step += 1
	}, &hook})
	it := ecs.begin_ticks(&f.world, 50 * time.Millisecond)
	for ecs.next_tick(&it) {
		fixed_update(&f.runtime, &it, {})
		fixed_events(&f.runtime)
	}
	// Started with its arguments and times' default; the coroutine at the end of each tick until the stop.
	expect_reports(t, f, {5, 2, 1, 100, 1, 100, 1, -1})
	testing.expect_value(t, hook.status, [3]Action_Status{.Running, .Running, .Succeeded})
	testing.expect_value(t, action_entity(&f.runtime, hook.handle), ecs.Entity(0))
	clear(&f.reports)
	it = ecs.begin_ticks(&f.world, 50 * time.Millisecond)
	for ecs.next_tick(&it) {
		fixed_update(&f.runtime, &it, {})
		fixed_events(&f.runtime)
	}
	expect_reports(t, f, {})
}

// An argument that the action has no parameter for, or of another kind, and a name that no module defined, fail the
// start.
@(test)
a_script_action_with_wrong_arguments_fails :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	context.logger = testlog.expected_errors()
	testing.expect(t, run(t, f, `
		local Bark = Action.define("bark", { line = Param.string() })
		function Bark:start() Test.report(1) end
	`))
	hook: [3]Action_Status
	set_fixed_hook(&f.runtime, {proc(r: ^Runtime, data: rawptr) {
		statuses := (^[3]Action_Status)(data)
		_, statuses[0] = start_action(r, "bark", 0, {{"volume", f64(3)}})
		_, statuses[1] = start_action(r, "bark", 0, {{"line", f64(3)}})
		_, statuses[2] = start_action(r, "growl", 0, {})
	}, &hook})
	it := ecs.begin_ticks(&f.world, 16 * time.Millisecond + 700 * time.Microsecond)
	for ecs.next_tick(&it) {
		fixed_update(&f.runtime, &it, {})
	}
	testing.expect_value(t, hook, [3]Action_Status{.Failed, .Failed, .Failed})
	expect_reports(t, f, {})
}
