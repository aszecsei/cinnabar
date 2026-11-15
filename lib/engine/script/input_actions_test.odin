package script

import "core:testing"
import "core:time"

import "cinnabar:core"

@(test)
scripts_define_query_set_and_reset_actions :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	input: core.Input
	input.down = {.W}
	input.pressed = {.W}
	input.gamepads[1] = {
		connected         = true,
		down              = {.A},
		direction_down    = {.Left_Trigger},
		direction_pressed = {.Left_Trigger},
	}
	input.gamepads[1].axes[.Left_Trigger] = 0.75
	begin_phase(&f.runtime, 16 * time.Millisecond, input)
	thread, ok := spawn_source(
		&f.runtime,
		"=actions",
		`
Input.define_action("forward", { "key:W", "pad:LeftStickUp" })
Input.define_action("accept", { "pad:A" })
Input.define_action("brake", { "pad:LeftTrigger" })
local function report(b) Test.report(b and 1 or 0) end
report(Input.action_down("forward"))
report(Input.action_pressed("forward"))
report(Input.action_released("forward"))
Test.report(Input.action_value("forward"))
report(Input.action_down("forward", 2))
report(Input.action_down("accept"))
report(Input.action_down("accept", 1))
report(Input.action_down("accept", 2))
Test.report(Input.action_value("brake", 2))
report(Input.action_pressed("brake"))
report(Input.gamepad_direction_down(2, GamepadDirection.LeftTrigger))
report(Input.gamepad_direction_pressed(2, GamepadDirection.LeftTrigger))
report(Input.gamepad_direction_down(2, GamepadDirection.RightTrigger))
report(table.concat(Input.bindings("forward"), ",") == "key:W,pad:LeftStickUp")
Input.set_bindings("forward", { "key:Up" })
report(table.concat(Input.bindings("forward"), ",") == "key:Up")
report(Input.action_down("forward"))
Input.set_bindings("accept", {})
report(#Input.bindings("accept") == 0)
Input.reset_bindings("forward")
report(table.concat(Input.bindings("forward"), ",") == "key:W,pad:LeftStickUp")
Input.set_bindings("forward", { "key:Up" })
Input.set_bindings("accept", {})
Input.reset_bindings()
report(table.concat(Input.bindings("forward"), ",") == "key:W,pad:LeftStickUp")
report(table.concat(Input.bindings("accept"), ",") == "pad:A")
report(Input.any_pressed() == "key:W")
report(Input.any_pressed("keyboard") == "key:W")
report(Input.any_pressed("gamepad") == "pad:LeftTrigger")
report(not pcall(Input.any_pressed, "mouse"))
`,
	)
	testing.expect(t, ok)
	end_phase(&f.runtime)
	expect_reports(
		t,
		f,
		{1, 1, 0, 1, 0, 1, 0, 1, 0.75, 1, 1, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1},
	)
	release(&f.runtime, thread)
}

@(test)
defining_an_action_again_keeps_its_bindings :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(
		&f.runtime,
		"=again",
		`
local function joined(name) return table.concat(Input.bindings(name), ",") end
Input.define_action("jump", { "key:Space" })
Input.set_bindings("jump", { "pad:B", "key:Enter" })
Input.define_action("jump", { "key:Space", "pad:A" })
Test.report(joined("jump") == "pad:B,key:Enter" and 1 or 0)
Input.reset_bindings("jump")
Test.report(joined("jump") == "key:Space,pad:A" and 1 or 0)
`,
	)
	testing.expect(t, ok)
	expect_reports(t, f, {1, 1})
}

@(test)
set_bindings_raises_on_a_bad_binding :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(
		&f.runtime,
		"=bad",
		`
Input.define_action("jump", { "key:Space" })
local function check(fn, needle)
	local ok, err = pcall(fn)
	Test.report((not ok and string.find(tostring(err), needle, 1, true)) and 1 or 0)
end
check(function() Input.set_bindings("jump", { "key:Spacebar" }) end, "key:Spacebar")
check(function() Input.set_bindings("jump", { "pad:Z" }) end, "pad:Z")
check(function() Input.set_bindings("jump", { 3 }) end, "not a string")
check(function() Input.set_bindings("jump", { "key:A", "key:B", "key:C", "key:D", "key:E", "key:F", "key:G", "key:H", "key:I" }) end, "at most 8")
check(function() Input.define_action("jump", { "nope" }) end, "nope")
Test.report(table.concat(Input.bindings("jump"), ",") == "key:Space" and 1 or 0)
`,
	)
	testing.expect(t, ok)
	expect_reports(t, f, {1, 1, 1, 1, 1, 1})
}

@(test)
an_unknown_action_raises_with_its_name :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(
		&f.runtime,
		"=unknown",
		`
Input.define_action("jump", { "key:Space" })
local function check(fn)
	local ok, err = pcall(fn)
	Test.report((not ok and string.find(tostring(err), "jumpp", 1, true)) and 1 or 0)
end
check(function() return Input.action_down("jumpp") end)
check(function() return Input.action_pressed("jumpp") end)
check(function() return Input.action_released("jumpp") end)
check(function() return Input.action_value("jumpp") end)
check(function() return Input.bindings("jumpp") end)
check(function() Input.set_bindings("jumpp", {}) end)
check(function() Input.reset_bindings("jumpp") end)
Test.report(pcall(Input.action_down, "jump", 5) and 1 or 0)
Test.report(pcall(Input.define_action, "", {}) and 1 or 0)
Test.report(pcall(Input.define_action, "a name that is far too long", {}) and 1 or 0)
`,
	)
	testing.expect(t, ok)
	expect_reports(t, f, {1, 1, 1, 1, 1, 1, 1, 0, 0, 0})
}
