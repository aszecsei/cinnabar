package script

import "core:testing"

import "cinnabar:engine/ecs"

// A class that runs in the editor's Edit mode, and reports as DOOR does, plus 10 more.
@(private = "file")
TOOL :: `
Tool = Behaviour.define("Tool", {}, {edit_mode = true})
function Tool:awake() Test.report(11) end
function Tool:on_enable() Test.report(12) end
function Tool:start() Test.report(13) end
function Tool:update(dt) Test.report(14) end
function Tool:on_disable() Test.report(15) end
function Tool:on_destroy() Test.report(16) end
`

// edit_phase runs one edit phase, as the game does each frame in the editor's Edit mode.
@(private = "file")
edit_phase :: proc(f: ^World_Fixture) {
	run_edit_phase(&f.runtime, FRAME)
}

@(test)
the_edit_phase_runs_only_the_classes_that_opt_in :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	// As the editor's scene load does: the behaviours attach while nothing runs.
	set_callbacks(&f.runtime, .None)
	testing.expect(t, run(t, f, DOOR + TOOL + "World.spawn():add(Door) World.spawn():add(Tool)"))
	expect_reports(t, f, {})

	set_callbacks(&f.runtime, .Edit_Mode)
	edit_phase(f)
	expect_reports(t, f, {11, 12, 13, 14})
	edit_phase(f)
	expect_reports(t, f, {14})

	// Play: the door wakes, and the tool goes on.
	set_callbacks(&f.runtime, .All)
	phase(f)
	expect_reports(t, f, {1, 2, 3, 4, 14})
}

@(test)
an_edit_mode_behaviour_ends_in_edit :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	set_callbacks(&f.runtime, .Edit_Mode)
	testing.expect(t, run(t, f, TOOL + DOOR + "World.spawn():add(Tool) World.spawn():add(Door)"))
	expect_reports(t, f, {11, 12})
	edit_phase(f)
	expect_reports(t, f, {13, 14})
	found := make([dynamic]ecs.Entity, context.temp_allocator)
	ecs.collect(f.runtime.world, {BEHAVIOURS_ID}, &found)
	for e in found {
		ecs.despawn(f.runtime.world, e)
	}
	edit_phase(f)
	expect_reports(t, f, {15, 16})
	testing.expect_value(t, behaviour_count(&f.runtime), 0)
}

@(test)
the_edit_phase_resumes_only_the_coroutines_of_edit_mode_behaviours :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	set_callbacks(&f.runtime, .Edit_Mode)
	source := `
Looper = Behaviour.define("Looper", {code = Field.number(0)}, {edit_mode = true})
function Looper:start()
	self:start_coroutine(function()
		while true do
			Test.report(self.code)
			coroutine.yield()
		end
	end)
end
local a = World.spawn()
a:add(Looper, {code = 1})
`
	testing.expect(t, run(t, f, source))
	edit_phase(f)
	expect_reports(t, f, {1})
	edit_phase(f)
	expect_reports(t, f, {1})

	// A class without edit_mode starts its coroutine in Play, and Edit leaves it waiting.
	set_callbacks(&f.runtime, .All)
	testing.expect(t, run(t, f, `
Player = Behaviour.define("Player", {})
function Player:start()
	self:start_coroutine(function()
		while true do
			Test.report(2)
			coroutine.yield()
		end
	end)
end
World.spawn():add(Player)
`))
	// The new coroutine runs to its first yield as it starts, before the looper resumes.
	phase(f)
	expect_reports(t, f, {2, 1})
	phase(f)
	expect_reports(t, f, {1, 2})
	set_callbacks(&f.runtime, .Edit_Mode)
	edit_phase(f)
	expect_reports(t, f, {1})
}

@(test)
a_script_asks_whether_it_runs_in_edit_mode :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	set_callbacks(&f.runtime, .Edit_Mode)
	testing.expect(t, run(t, f, `
Asker = Behaviour.define("Asker", {}, {edit_mode = true})
function Asker:update() Test.report(if World.editing() then 1 else 0) end
World.spawn():add(Asker)
`))
	edit_phase(f)
	expect_reports(t, f, {1})
	set_callbacks(&f.runtime, .All)
	phase(f)
	expect_reports(t, f, {0})
}

@(test)
an_option_that_define_does_not_know_is_an_error :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	context.logger = capture_world_errors(f)
	testing.expect(t, !run(t, f, `Behaviour.define("A", {}, {editmode = true})`))
	expect_world_error(t, f, "has an option editmode that Behaviour.define does not know")
	testing.expect(t, !run(t, f, `Behaviour.define("B", {}, {edit_mode = "yes"})`))
	expect_world_error(t, f, "the option edit_mode of B takes a boolean")
	testing.expect(t, !run(t, f, `Behaviour.define("C", {}, {category = 3})`))
	expect_world_error(t, f, "the option category of C takes a string")
}

@(test)
a_hot_reload_gives_and_takes_the_edit_mode :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	set_callbacks(&f.runtime, .Edit_Mode)
	tool := write_script(
		t,
		&f,
		3,
		0,
		`
local Tool = Behaviour.define("Tool", {})
function Tool:awake() Test.report(1) end
function Tool:update() Test.report(2) end
return Tool`,
	)
	e := ecs.spawn(&f.world)
	testing.expect(t, attach_script(&f.runtime, e, tool))
	run_edit_phase(&f.runtime, FRAME)
	expect_reports(t, f, {})

	write_script(
		t,
		&f,
		3,
		1,
		`
local Tool = Behaviour.define("Tool", {}, {edit_mode = true})
function Tool:awake() Test.report(1) end
function Tool:update() Test.report(2) end
function Tool:on_reload() Test.report(9) end
return Tool`,
	)
	hot_reload(&f)
	expect_reports(t, f, {9})
	run_edit_phase(&f.runtime, FRAME)
	expect_reports(t, f, {1, 2})

	write_script(
		t,
		&f,
		3,
		2,
		`
local Tool = Behaviour.define("Tool", {})
function Tool:update() Test.report(2) end
function Tool:on_reload() Test.report(9) end
return Tool`,
	)
	hot_reload(&f)
	run_edit_phase(&f.runtime, FRAME)
	expect_reports(t, f, {})
}
