package game

import "core:c"
import "core:mem/virtual"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:core/testlog"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// Script_Sublevel_Fixture is a sublevel_game with a world, and scripts that have the scene and sublevel bindings and
// Test.report.
@(private = "file")
Script_Sublevel_Fixture :: struct {
	arena:   virtual.Arena,
	g:       ^Game,
	reports: [dynamic]f64,
}

// The fixture's reports, for Test.report, which reaches no fixture of its own.
@(private = "file", thread_local)
fixture_reports: ^[dynamic]f64

@(private = "file")
setup_scripts :: proc(t: ^testing.T, f: ^Script_Sublevel_Fixture) -> ^Game {
	testing.expect(t, virtual.arena_init_growing(&f.arena) == nil)
	g := sublevel_game(&f.arena)
	f.g = g
	g.platform.time_seconds = proc() -> f64 {return 0}
	g.platform.script_open = script_host.open
	g.platform.script_close = script_host.close
	g.platform.script_push_binding = script_host.push_binding
	g.platform.script_atom = script_host.atom
	g.platform.script_direct_access = script_host.direct_access
	g.platform.memory_reserve = proc(size: int) -> rawptr {
		data, err := virtual.reserve(uint(size))
		return err == nil ? raw_data(data) : nil
	}
	g.platform.memory_commit = proc(ptr: rawptr, size: int) -> bool {
		return virtual.commit(ptr, uint(size)) == nil
	}
	g.platform.memory_release = proc(ptr: rawptr, size: int) {
		virtual.release(ptr, uint(size))
	}
	f.reports = make([dynamic]f64)
	fixture_reports = &f.reports
	testing.expect(t, ecs.init(&g.world, g.platform))
	ecs.register_engine_components(&g.world.registry)
	script.register_components(&g.world.registry)
	testing.expect(t, script.init(&g.scripts, g.platform, &g.world, nil, register_sublevel_test))
	return g
}

@(private = "file")
register_sublevel_test :: proc(r: ^script.Runtime) {
	define_scene_bindings(r)
	script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
		append(fixture_reports, luau.L_checknumber(L, 1))
		return 0
	})
}

@(private = "file")
teardown_scripts :: proc(f: ^Script_Sublevel_Fixture) {
	script.destroy(&f.g.scripts)
	ecs.destroy(&f.g.world)
	free_sublevel_game(f.g)
	delete(f.reports)
	fixture_reports = nil
	virtual.arena_destroy(&f.arena)
}

@(private = "file")
run_frame :: proc(g: ^Game) {
	script.run_phase(&g.scripts, 16 * time.Millisecond, core.Input{})
}

@(private = "file")
run_source :: proc(t: ^testing.T, g: ^Game, source: string, loc := #caller_location) {
	_, ok := script.spawn_source(&g.scripts, "=sublevel_test", source)
	testing.expect(t, ok, "the script runs", loc = loc)
}

@(private = "file")
expect_reports :: proc(
	t: ^testing.T,
	f: ^Script_Sublevel_Fixture,
	want: []f64,
	loc := #caller_location,
) {
	same := len(f.reports) == len(want)
	for value, i in want {
		same = same && f.reports[i] == value
	}
	testing.expectf(t, same, "reports %v, want %v", f.reports[:], want, loc = loc)
	clear(&f.reports)
}

// Sublevel.set_active queues the change for the next frame: Sublevel.is_active says so at once, and Sublevel.state does
// not change until the change applies.
@(test)
set_active_queues_and_is_active_says_so_at_once :: proc(t: ^testing.T) {
	f: Script_Sublevel_Fixture
	g := setup_scripts(t, &f)
	defer teardown_scripts(&f)

	run_source(
		t,
		g,
		`
local function report(value: boolean) Test.report(if value then 1 else 0) end
report(Sublevel.is_active("night"))
report(Sublevel.is_active("day"))
Sublevel.set_active("day", true)
Sublevel.set_active("night", false)
report(Sublevel.is_active("day"))
report(Sublevel.is_active("night"))
report(Sublevel.state("day") == "inactive")
report(Sublevel.state("night") == "loading")
`,
	)
	expect_reports(t, &f, {1, 0, 1, 0, 1, 1})
	testing.expect_value(t, len(g.scene_requests), 2)

	for request in g.scene_requests {
		apply_sublevel_change(g, request.(Sublevel_Change))
	}
	clear(&g.scene_requests)
	run_source(
		t,
		g,
		`
Test.report(if Sublevel.state("day") == "loading" then 1 else 0)
Test.report(if Sublevel.state("night") == "inactive" then 1 else 0)
Test.report(if Sublevel.is_active("day") then 1 else 0)
Test.report(if Sublevel.is_active("night") then 1 else 0)
`,
	)
	expect_reports(t, &f, {1, 1, 1, 0})
}

// Sublevel.state is the sublevel's state, "ready" once its parts are, and nil for a name that the project does not
// declare. Sublevel.set_active and Sublevel.is_active raise an error for one.
@(test)
state_follows_the_lifecycle_and_unknown_names_fail :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	f: Script_Sublevel_Fixture
	g := setup_scripts(t, &f)
	defer teardown_scripts(&f)

	STATE :: `
local states = { inactive = 1, loading = 2, ready = 3, failed = 4 }
Test.report(states[Sublevel.state("day") :: string])
`
	run_source(t, g, STATE)
	index, _ := sublevel_index(g, "day")
	for to in ([]Sublevel_State{.Loading, .Active, .Failed}) {
		change_sublevel(&g.sublevels, index, to)
		run_source(t, g, STATE)
	}
	expect_reports(t, &f, {1, 2, 3, 4})

	run_source(
		t,
		g,
		`
Test.report(if Sublevel.state("dusk") == nil then 1 else 0)
Test.report(if pcall(Sublevel.set_active, "dusk", true) then 0 else 1)
Test.report(if pcall(Sublevel.is_active, "dusk") then 0 else 1)
`,
	)
	expect_reports(t, &f, {1, 1, 1})
	testing.expect_value(t, len(g.scene_requests), 0)
}

// Each of a sublevel's events goes to every behaviour that has its handler, with the sublevel's name, once.
@(test)
sublevel_events_reach_every_behaviour_with_the_handler :: proc(t: ^testing.T) {
	f: Script_Sublevel_Fixture
	g := setup_scripts(t, &f)
	defer teardown_scripts(&f)

	run_source(
		t,
		g,
		`
local Watcher = Behaviour.define("Watcher", { tag = Field.number(0) })
local function report(self, kind: number, name: string)
	Test.report(self.tag + kind + (if name == "day" then 100 else 0))
end
function Watcher:on_sublevel_loading(name: string) report(self, 1, name) end
function Watcher:on_sublevel_ready(name: string) report(self, 2, name) end
function Watcher:on_sublevel_unloaded(name: string) report(self, 3, name) end
function Watcher:on_sublevel_failed(name: string) report(self, 4, name) end
local Other = Behaviour.define("Other")
World.spawn():add(Watcher, { tag = 10 })
World.spawn():add(Other)
World.spawn():add(Watcher, { tag = 20 })
`,
	)
	// The level began with night loading, which every watcher hears.
	send_sublevel_events(g)
	clear(&g.sublevels.events)
	run_frame(g)
	expect_reports(t, &f, {11, 21})

	index, _ := sublevel_index(g, "day")
	steps := [?]Sublevel_State{.Loading, .Active, .Failed, .Inactive}
	want := [?][2]f64{{111, 121}, {112, 122}, {114, 124}, {113, 123}}
	for to, i in steps {
		testing.expect(t, change_sublevel(&g.sublevels, index, to))
		send_sublevel_events(g)
		clear(&g.sublevels.events)
		run_frame(g)
		expect_reports(t, &f, want[i][:])
	}
	run_frame(g)
	expect_reports(t, &f, {})
}
