package game

import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"

import "cinnabar:core"
import script_host "cinnabar:core/script"
import "cinnabar:core/testlog"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

@(private = "file")
Test_State :: struct {
	count: int,
	speed: f32,
}

@(private = "file")
Other_State :: struct {
	count: int,
	speed: f64,
}

@(private = "file")
Test_Component :: struct {
	value: f32,
}

@(private = "file")
TEST_COMPONENT_ID :: ecs.Component_Id(9001)

@(private = "file")
register_test_component :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Test_Component, TEST_COMPONENT_ID)
}

@(test)
the_layout_hash_covers_the_projects_state_and_components :: proc(t: ^testing.T) {
	none := game_layout_hash({})
	with_state := game_layout_hash({State = Test_State})
	testing.expect(t, none != with_state, "a project's state changes the hash")
	testing.expect(
		t,
		with_state != game_layout_hash({State = Other_State}),
		"a change of the state's layout changes the hash",
	)
	testing.expect_value(t, game_layout_hash({State = Test_State}), with_state)
	testing.expect(
		t,
		none != game_layout_hash({register_components = register_test_component}),
		"a project's component changes the hash",
	)
}

@(test)
the_projects_state_follows_game_aligned :: proc(t: ^testing.T) {
	testing.expect_value(t, USER_OFFSET % core.GAME_STATE_ALIGN, 0)
	testing.expect(t, USER_OFFSET >= size_of(Game))
	testing.expect_value(t, state_bytes({}), size_of(Game))
	testing.expect_value(t, state_bytes({State = Test_State}), USER_OFFSET + size_of(Test_State))

	g := new(Game)
	defer free(g)
	testing.expect_value(t, uintptr(user(g, Test_State)) - uintptr(g), uintptr(USER_OFFSET))
}

@(private = "file")
register_test_scripts :: proc(r: ^script.Runtime) {
	register_scripts(r)
	script.expose(r, Test_Component)
}

@(test)
the_standard_games_scripts_have_every_engine_binding :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	platform := core.Platform_API {
		frame_allocator = virtual.arena_allocator(&arena),
		permanent_allocator = virtual.arena_allocator(&arena),
		time_seconds = proc() -> f64 {return 0},
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
	}
	text := game_script_types(
		&platform,
		{register_components = register_test_component},
		register_test_scripts,
	)
	expect :: proc(t: ^testing.T, text, fragment: string, loc := #caller_location) {
		testing.expectf(
			t,
			strings.contains(text, fragment),
			"the definitions have no %q",
			fragment,
			loc = loc,
		)
	}
	// The engine's bindings that a game used to choose are all there: physics, audio, animation, sprites, the UI and
	// perception.
	for name in ([]string{"declare Physics:", "declare Audio:", "declare Animator:", "declare Sprites:", "declare Tint:", "declare Ui:", "declare Render:", "declare Perception:", "declare Save:"}) {
		expect(t, text, name)
	}
	expect(t, text, "\tset_paused: (paused: boolean) -> (),")
	// The time scale, its frame times, and the camera.
	expect(t, text, "\tset_time_scale: (scale: number) -> (),")
	expect(t, text, "\treal_delta: number,")
	expect(t, text, "\tscale: number,")
	expect(t, text, "declare Camera:")
	// The scenes that stream: a scene by its number, and its stage.
	expect(t, text, "	state: (scene: number) -> string?,")
	// And the scene that a field waits for, as an asset that Scene.load takes.
	expect(t, text, "	pending: (behaviour: any, field: string) -> Asset?,")
	// The sublevels: a scene's base, and a sublevel to activate, whether it is asked to be active, and its state.
	expect(t, text, "	base: (scene: number) -> number?,")
	expect(t, text, "declare Sublevel:")
	expect(t, text, "	set_active: (name: string, active: boolean) -> (),")
	expect(t, text, "	is_active: (name: string) -> boolean,")
	expect(t, text, "	state: (name: string) -> string?,")
	testing.expect(
		t,
		!strings.contains(text, "set_sublevel"),
		"Sublevel replaces Game.set_sublevel",
	)
	// And the project's.
	expect(t, text, "declare TestComponent:")
}

@(test)
a_quit_ends_the_loop :: proc(t: ^testing.T) {
	g := new(Game)
	defer free(g)
	testing.expect_value(t, g.run, Run_State.Running)
	request_quit(g)
	testing.expect_value(t, g.run, Run_State.Quitting)
}

@(test)
a_quit_under_an_editor_does_nothing :: proc(t: ^testing.T) {
	g := new(Game)
	defer free(g)
	g.editor.session.connection = 1
	request_quit(g)
	testing.expect_value(t, g.run, Run_State.Running)
}

// The time scale is kept between 0 and 4, not a number is 1, and 1 is stored as nil, so a zeroed Game is unscaled. A
// pause takes the world's whole step, and the editor's own steps take no scale.
@(test)
set_time_scale_clamps :: proc(t: ^testing.T) {
	g := new(Game)
	defer free(g)
	testing.expect_value(t, time_scale_of(g), 1)
	want := [?][2]f32{{0.5, 0.5}, {-3, 0}, {100, 4}, {math.nan_f32(), 1}, {0, 0}, {1, 1}}
	for pair in want {
		set_time_scale(g, pair[0])
		testing.expect_value(t, time_scale_of(g), pair[1])
	}
	testing.expect(t, g.time_scale == nil, "a scale of 1 is stored as nil")
	set_time_scale(g, 0.5)
	step := 20 * time.Millisecond
	testing.expect_value(t, world_step(g, step, true), 10 * time.Millisecond)
	testing.expect_value(t, world_step(g, step, false), step)
	g.paused = true
	testing.expect_value(t, world_step(g, step, true), 0)
}

@(private = "file")
Callback_State :: struct {
	count:  int,
	on_hit: proc(),
}

@(private = "file")
hit :: proc() {}

@(test)
the_pointer_audit_names_the_projects_field :: proc(t: ^testing.T) {
	buffer := make([]byte, USER_OFFSET + size_of(Callback_State), context.temp_allocator)
	g := (^Game)(raw_data(buffer))
	user(g, Callback_State).on_hit = hit
	address := uintptr(rawptr(hit))
	findings := game_pointer_audit(
		g,
		{State = Callback_State},
		{address, address + 1},
		context.temp_allocator,
	)
	testing.expect_value(t, len(findings), 1)
	if len(findings) == 1 {
		testing.expect_value(t, findings[0].path, "Callback_State.on_hit")
	}
}

@(private, thread_local)
sublevel_level: u64

// sublevel_game is a Game whose project declares a night sublevel that starts active and a day one that does not.
@(private)
sublevel_game :: proc(arena: ^virtual.Arena) -> ^Game {
	g := new(Game)
	g.platform = new(core.Platform_API)
	g.platform.frame_allocator = virtual.arena_allocator(arena)
	g.platform.level_generation = proc() -> u64 {return sublevel_level}
	g.scenes.platform = g.platform
	sublevel_level = 1
	format.sublevel_default(&g.project.settings.sublevels, "night", true)
	format.sublevel_default(&g.project.settings.sublevels, "day", false)
	return g
}

@(private)
free_sublevel_game :: proc(g: ^Game) {
	delete(g.scene_requests)
	delete(g.sublevels.events)
	free(g.platform)
	free(g)
}

// Each level starts with the project's sublevels: those that start active are loading until their parts are ready. A
// new level starts from the settings again, whatever the last one changed.
@(test)
a_level_starts_with_the_projects_sublevels :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	g := sublevel_game(&arena)
	defer free_sublevel_game(g)

	night, known := sublevel_state(g, "night")
	testing.expect(t, known)
	testing.expect_value(t, night, Sublevel_State.Loading)
	day, _ := sublevel_state(g, "day")
	testing.expect_value(t, day, Sublevel_State.Inactive)
	active := active_sublevels(g)
	testing.expect_value(t, len(active), 1)
	testing.expect_value(t, active[0], "night")

	apply_sublevel_change(g, {format.sublevel_name("day"), true})
	apply_sublevel_change(g, {format.sublevel_name("night"), false})
	testing.expect_value(t, len(active_sublevels(g)), 1)
	sublevel_level += 1
	night, _ = sublevel_state(g, "night")
	day, _ = sublevel_state(g, "day")
	testing.expect_value(t, night, Sublevel_State.Loading)
	testing.expect_value(t, day, Sublevel_State.Inactive)
}

// set_sublevel queues a change, which applies with the scene requests, and refuses a sublevel that the project does not
// declare. A change to the state that a sublevel has does nothing.
@(test)
set_sublevel_queues_a_change :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	g := sublevel_game(&arena)
	defer free_sublevel_game(g)

	testing.expect(t, set_sublevel(g, "day", true))
	testing.expect(t, !set_sublevel(g, "dusk", true))
	// The level began with night active, and said so.
	testing.expect_value(t, len(sublevel_events(g)), 1)
	clear(&g.sublevels.events)
	testing.expect_value(t, len(g.scene_requests), 1)
	day, _ := sublevel_state(g, "day")
	testing.expect_value(t, day, Sublevel_State.Inactive)

	change, is_change := g.scene_requests[0].(Sublevel_Change)
	testing.expect(t, is_change)
	testing.expect(t, apply_sublevel_change(g, change))
	day, _ = sublevel_state(g, "day")
	testing.expect_value(t, day, Sublevel_State.Loading)
	testing.expect(t, !apply_sublevel_change(g, change))
	events := sublevel_events(g)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].kind, Sublevel_Event_Kind.Loading)
	testing.expect_value(t, format.sublevel_name_text(&events[0].sublevel), "day")
}

// A sublevel goes from inactive to loading, between loading, active and failed, and from any of them to inactive, and
// no other way.
@(test)
a_sublevel_changes_only_as_its_lifecycle_allows :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	s: Sublevels
	defer delete(s.events)
	s.count = 1
	s.names[0] = format.sublevel_name("night")
	testing.expect(t, !change_sublevel(&s, 0, .Active))
	testing.expect(t, change_sublevel(&s, 0, .Loading))
	testing.expect(t, !change_sublevel(&s, 0, .Loading))
	testing.expect(t, change_sublevel(&s, 0, .Active))
	testing.expect(t, change_sublevel(&s, 0, .Loading))
	testing.expect(t, change_sublevel(&s, 0, .Inactive))
	testing.expect(t, !change_sublevel(&s, 0, .Inactive))
	testing.expect(t, !change_sublevel(&s, 0, .Failed))
	testing.expect(t, change_sublevel(&s, 0, .Loading))
	testing.expect(t, change_sublevel(&s, 0, .Failed))
	testing.expect(t, change_sublevel(&s, 0, .Inactive))
	kinds := [?]Sublevel_Event_Kind {
		.Loading,
		.Ready,
		.Loading,
		.Unloaded,
		.Loading,
		.Failed,
		.Unloaded,
	}
	testing.expect_value(t, len(s.events), len(kinds))
	for kind, i in kinds {
		testing.expect_value(t, s.events[i].kind, kind)
	}
}
