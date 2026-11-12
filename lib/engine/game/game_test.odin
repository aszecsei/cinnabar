package game

import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "cinnabar:core"
import script_host "cinnabar:core/script"
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
	testing.expect(t, with_state != game_layout_hash({State = Other_State}), "a change of the state's layout changes the hash")
	testing.expect_value(t, game_layout_hash({State = Test_State}), with_state)
	testing.expect(t, none != game_layout_hash({register_components = register_test_component}), "a project's component changes the hash")
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
		frame_allocator      = virtual.arena_allocator(&arena),
		permanent_allocator  = virtual.arena_allocator(&arena),
		time_seconds         = proc() -> f64 {return 0},
		script_open          = script_host.open,
		script_close         = script_host.close,
		script_push_binding  = script_host.push_binding,
		script_atom          = script_host.atom,
		script_direct_access = script_host.direct_access,
		memory_reserve       = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit        = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release       = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
	}
	text := game_script_types(&platform, {register_components = register_test_component}, register_test_scripts)
	expect :: proc(t: ^testing.T, text, fragment: string, loc := #caller_location) {
		testing.expectf(t, strings.contains(text, fragment), "the definitions have no %q", fragment, loc = loc)
	}
	// The engine's bindings that a game used to choose are all there: physics, audio, animation, sprites, the UI and
	// perception.
	for name in ([]string{"declare Physics:", "declare Audio:", "declare Animator:", "declare Sprites:", "declare Ui:", "declare Render:", "declare Perception:"}) {
		expect(t, text, name)
	}
	expect(t, text, "\tset_paused: (paused: boolean) -> (),")
	// And the project's.
	expect(t, text, "declare TestComponent:")
}
