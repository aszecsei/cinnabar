package core

import "core:testing"

@(private = "file")
define_action :: proc(actions: ^Input_Actions, name: string, binding: string) -> int {
	b, ok := binding_parse(binding)
	assert(ok)
	index, _ := input_actions_define(actions, name, {b})
	return index
}

@(private = "file")
define_context :: proc(
	actions: ^Input_Actions,
	name: string,
	mode: Input_Context_Mode,
	allows: Input_Action_Set,
) -> int {
	index, err := input_contexts_define(&actions.contexts, name, mode, allows)
	assert(err == .None)
	return index
}

@(test)
a_context_blocks_the_actions_that_it_does_not_allow :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "key:Space")
	skip := define_action(&actions, "skip", "key:Escape")
	cutscene := define_context(&actions, "cutscene", .Only, {skip})
	input: Input
	input_key_down(&input, .Space)
	input_key_down(&input, .Escape)
	token := input_contexts_push(&actions.contexts, cutscene, pusher = "test")
	testing.expect(t, token != 0)
	testing.expect(t, !action_down(&actions, &input, jump))
	testing.expect(t, !action_pressed(&actions, &input, jump))
	testing.expect_value(t, action_value(&actions, &input, jump), 0)
	testing.expect(t, action_down(&actions, &input, skip))
	testing.expect(t, action_pressed(&actions, &input, skip))
	testing.expect_value(t, action_value(&actions, &input, skip), 1)
}

@(test)
a_pop_takes_off_its_push_wherever_it_is :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "key:Space")
	skip := define_action(&actions, "skip", "key:Escape")
	menu := define_action(&actions, "menu", "key:Tab")
	a := define_context(&actions, "a", .Only, {skip})
	b := define_context(&actions, "b", .Only, {menu})
	input: Input
	input_key_down(&input, .Space)
	input_key_down(&input, .Tab)
	ta := input_contexts_push(&actions.contexts, a, pusher = "first")
	tb := input_contexts_push(&actions.contexts, b, pusher = "second")
	testing.expect(t, input_contexts_pop(&actions.contexts, ta))
	testing.expect(t, input_contexts_pushed(&actions.contexts, ta) == nil)
	pushed := input_contexts_pushed(&actions.contexts, tb)
	testing.expect(t, pushed != nil && input_context_pusher(pushed) == "second")
	testing.expect_value(t, actions.contexts.push_count, 1)
	// B still decides: menu goes through and jump does not.
	testing.expect(t, action_down(&actions, &input, menu))
	testing.expect(t, !action_down(&actions, &input, jump))
	testing.expect(t, input_contexts_pop(&actions.contexts, tb))
	testing.expect(t, action_down(&actions, &input, jump))
}

@(test)
a_stale_token_pops_nothing :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "key:Space")
	cutscene := define_context(&actions, "cutscene", .Only, {})
	input: Input
	input_key_down(&input, .Space)
	stale := input_contexts_push(&actions.contexts, cutscene)
	testing.expect(t, input_contexts_pop(&actions.contexts, stale))
	live := input_contexts_push(&actions.contexts, cutscene)
	testing.expect(t, live != stale)
	testing.expect(t, !input_contexts_pop(&actions.contexts, stale))
	testing.expect(t, !input_contexts_pop(&actions.contexts, 0))
	testing.expect_value(t, actions.contexts.push_count, 1)
	testing.expect(t, !action_down(&actions, &input, jump))
}

@(test)
a_key_held_through_a_pop_is_down_but_not_pressed :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "key:Space")
	cutscene := define_context(&actions, "cutscene", .Only, {})
	input: Input
	token := input_contexts_push(&actions.contexts, cutscene)
	input_key_down(&input, .Space)
	input_contexts_settle(&actions, &input)
	input_begin_frame(&input)
	input_contexts_settle(&actions, &input)
	input_contexts_pop(&actions.contexts, token)
	testing.expect(t, action_down(&actions, &input, jump))
	testing.expect(t, !action_pressed(&actions, &input, jump))
	testing.expect_value(t, action_value(&actions, &input, jump), 1)
}

@(test)
a_key_pressed_in_the_frame_of_the_pop_is_not_pressed :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "key:Space")
	cutscene := define_context(&actions, "cutscene", .Only, {})
	input: Input
	token := input_contexts_push(&actions.contexts, cutscene)
	input_contexts_settle(&actions, &input)
	// The key goes down in the frame, and the cutscene ends later in it.
	input_key_down(&input, .Space)
	input_contexts_settle(&actions, &input)
	input_contexts_pop(&actions.contexts, token)
	testing.expect(t, action_down(&actions, &input, jump))
	testing.expect(t, !action_pressed(&actions, &input, jump))
	// It stays held while the key is down, and its release is not reported either.
	input_begin_frame(&input)
	input_contexts_settle(&actions, &input)
	testing.expect(t, !action_pressed(&actions, &input, jump))
	input_begin_frame(&input)
	input_key_up(&input, .Space)
	input_contexts_settle(&actions, &input)
	testing.expect(t, !action_released(&actions, &input, jump))
	// A quiet frame lets go, and the next press is a press.
	input_begin_frame(&input)
	input_contexts_settle(&actions, &input)
	testing.expect(t, jump not_in actions.contexts.held[0])
	input_begin_frame(&input)
	input_key_down(&input, .Space)
	input_contexts_settle(&actions, &input)
	testing.expect(t, action_pressed(&actions, &input, jump))
}

@(test)
a_press_while_blocked_does_not_fire_after_the_pop :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "key:Space")
	cutscene := define_context(&actions, "cutscene", .Only, {})
	input: Input
	token := input_contexts_push(&actions.contexts, cutscene)
	// A tap while blocked: down and up in one frame leaves both edges.
	input_key_down(&input, .Space)
	input_key_up(&input, .Space)
	input_contexts_settle(&actions, &input)
	input_contexts_pop(&actions.contexts, token)
	testing.expect(t, !action_pressed(&actions, &input, jump))
	testing.expect(t, !action_released(&actions, &input, jump))
}

@(test)
a_context_can_pass_what_it_does_not_name_to_the_one_below :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "key:Space")
	skip := define_action(&actions, "skip", "key:Escape")
	confirm := define_action(&actions, "confirm", "key:Enter")
	cutscene := define_context(&actions, "cutscene", .Only, {skip})
	dialog := define_context(&actions, "dialog", .Pass, {confirm})
	input: Input
	input_key_down(&input, .Space)
	input_key_down(&input, .Escape)
	input_key_down(&input, .Enter)
	input_contexts_push(&actions.contexts, cutscene)
	input_contexts_push(&actions.contexts, dialog)
	testing.expect(t, action_down(&actions, &input, confirm))
	testing.expect(t, action_down(&actions, &input, skip))
	testing.expect(t, !action_down(&actions, &input, jump))
	// Over the default alone, a pass blocks nothing.
	actions.contexts.push_count = 0
	input_contexts_push(&actions.contexts, dialog)
	testing.expect(t, action_down(&actions, &input, jump))
}

@(test)
each_player_has_a_stack :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "pad:A")
	fire := define_action(&actions, "fire", "key:F")
	cutscene := define_context(&actions, "cutscene", .Only, {})
	input: Input
	input_key_down(&input, .F)
	input_gamepad_set(&input, 0, {connected = true, buttons = {.A}})
	input_gamepad_set(&input, 1, {connected = true, buttons = {.A}})
	input_contexts_push(&actions.contexts, cutscene, {1})
	testing.expect(t, action_down(&actions, &input, jump, 0))
	testing.expect(t, !action_down(&actions, &input, jump, 1))
	// Without a pad, a player that allows it is enough. The keys are the first player's.
	testing.expect(t, action_down(&actions, &input, jump))
	testing.expect(t, action_down(&actions, &input, fire))
	input_contexts_push(&actions.contexts, cutscene, {0})
	testing.expect(t, !action_down(&actions, &input, jump))
	testing.expect(t, !action_down(&actions, &input, fire))
}

@(test)
an_owner_pops_its_pushes :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "key:Space")
	cutscene := define_context(&actions, "cutscene", .Only, {})
	input: Input
	input_key_down(&input, .Space)
	input_contexts_push(&actions.contexts, cutscene, owner = {1, 7, 1})
	input_contexts_push(&actions.contexts, cutscene, owner = {1, 7, 1})
	kept := input_contexts_push(&actions.contexts, cutscene, owner = {1, 9, 1})
	input_contexts_pop_owned(&actions.contexts, {1, 7, 1})
	testing.expect_value(t, actions.contexts.push_count, 1)
	testing.expect(t, input_contexts_pushed(&actions.contexts, kept) != nil)
	input_contexts_clear(&actions.contexts)
	testing.expect_value(t, actions.contexts.push_count, 0)
	testing.expect(t, action_down(&actions, &input, jump))
}

@(test)
the_default_is_under_every_stack :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "key:Space")
	cutscene := define_context(&actions, "cutscene", .Only, {})
	input: Input
	input_key_down(&input, .Space)
	testing.expect_value(t, input_contexts_find(&actions.contexts, "default"), 0)
	_, err := input_contexts_define(&actions.contexts, "default", .Only, {})
	testing.expect_value(t, err, Input_Context_Error.Default)
	input_contexts_push(&actions.contexts, cutscene)
	// The default pushed over a cutscene, as a menu might, allows every action again.
	input_contexts_push(&actions.contexts, 0)
	testing.expect(t, action_down(&actions, &input, jump))
	testing.expect(t, input_contexts_push(&actions.contexts, 5) == 0)
	testing.expect(t, input_contexts_push(&actions.contexts, cutscene, {}) == 0)
}

@(test)
a_definition_that_allows_more_holds_like_a_pop :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := define_action(&actions, "jump", "key:Space")
	cutscene := define_context(&actions, "cutscene", .Only, {})
	input: Input
	input_key_down(&input, .Space)
	input_contexts_push(&actions.contexts, cutscene)
	define_context(&actions, "cutscene", .Only, {jump})
	testing.expect(t, action_down(&actions, &input, jump))
	testing.expect(t, !action_pressed(&actions, &input, jump))
}
