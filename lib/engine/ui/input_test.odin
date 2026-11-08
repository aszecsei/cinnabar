package ui

import "core:fmt"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/ecs"

@(private = "file")
MENU :: "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
@(private = "file")
MODAL :: "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"

// A grid of buttons, two across and three down, 100 by 40 with gaps of 10, and a disabled one under them.
@(private = "file")
GRID :: `ui 1
<ui cancel="back">
	<column gap="10">
		<row gap="10"><button id="a" width="100" height="40" click="pick"/><button id="b" width="100" height="40" click="pick"/></row>
		<row gap="10"><button id="c" width="100" height="40" click="pick"/><button id="d" width="100" height="40" click="pick" nav_down="a"/></row>
		<row gap="10"><button id="e" width="100" height="40" disabled="true"/><button id="f" width="100" height="40"/></row>
	</column>
</ui>`

@(private = "file")
focused :: proc(f: ^Fixture) -> string {
	d, n, ok := resolve(&f.ui, f.ui.input.focus)
	return ok ? id_of(d, n) : ""
}

@(private = "file")
events :: proc(f: ^Fixture) -> string {
	text := ""
	for e in f.ui.input.events {
		text = fmt.tprintf("%s%s(%s", text, e.name, e.id)
		if t, has := e.text.?; has {
			text = fmt.tprintf("%s, %q", text, t)
		}
		text = fmt.tprintf("%s) ", text)
	}
	clear(&f.ui.input.events)
	return text
}

@(private = "file")
key :: proc(k: core.Key, held := false) -> core.Input {
	return held ? {down = {k}} : {down = {k}, pressed = {k}}
}

@(test)
a_click_is_a_press_and_a_release_over_the_same_element :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	show(t, f, MENU, GRID)
	step(f)
	step(f, {mouse_position = {50, 20}})
	testing.expect_value(t, f.ui.input.hovered.node, find_node_of(f, "a"))
	step(f, {mouse_position = {50, 20}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	testing.expect_value(t, focused(f), "a")
	testing.expect_value(t, events(f), "")
	step(f, {mouse_position = {52, 22}, released = {.Mouse_Left}})
	testing.expect_value(t, events(f), "pick(a) ")
	// A press that moves off before its release does not click.
	step(f, {mouse_position = {50, 20}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	step(f, {mouse_position = {160, 20}, released = {.Mouse_Left}})
	testing.expect_value(t, events(f), "")
	// A disabled element does not take the pointer.
	step(f, {mouse_position = {50, 120}})
	testing.expect_value(t, f.ui.input.hovered, NO_NODE)
	// The pointer hides the focus's style; keys show it.
	testing.expect_value(t, f.ui.input.modality, Modality.Pointer)
}

@(private = "file")
find_node_of :: proc(f: ^Fixture, id: string) -> u32 {
	for &d in f.ui.documents {
		if d.used {
			if n, found := find_node(&d, id); found {
				return n
			}
		}
	}
	return NONE
}

@(test)
arrows_and_the_dpad_move_the_focus_to_the_nearest_element_that_way :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	show(t, f, MENU, GRID)
	step(f)
	// The first move focuses the first element.
	step(f, key(.Down))
	testing.expect_value(t, focused(f), "a")
	testing.expect_value(t, f.ui.input.modality, Modality.Keys)
	step(f)
	step(f, key(.Right))
	testing.expect_value(t, focused(f), "b")
	step(f)
	step(f, {gamepads = {0 = {connected = true, down = {.Dpad_Down}, pressed = {.Dpad_Down}}}})
	testing.expect_value(t, focused(f), "d")
	step(f)
	// d's nav_down names a, over f below it.
	step(f, key(.Down))
	testing.expect_value(t, focused(f), "a")
	step(f)
	step(f, key(.Down))
	step(f)
	// From c, down skips the disabled e for nothing: there is nothing else below in its column but f, which is to the side.
	step(f, key(.Down))
	testing.expect_value(t, focused(f), "f")
	step(f)
	step(f, key(.Enter))
	testing.expect_value(t, events(f), "")
	step(f)
	step(f, key(.Up))
	step(f)
	step(f, {gamepads = {0 = {connected = true, down = {.A}, pressed = {.A}}}})
	testing.expect_value(t, events(f), "pick(d) ")
}

@(test)
a_held_direction_repeats_after_a_delay :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	show(t, f, MENU, `ui 1
<ui><column><button id="1" height="20"/><button id="2" height="20"/><button id="3" height="20"/><button id="4" height="20"/></column></ui>`)
	step(f)
	test_now = 10
	step(f, key(.Down))
	testing.expect_value(t, focused(f), "1")
	test_now = 10.3
	step(f, key(.Down, held = true))
	testing.expect_value(t, focused(f), "1")
	test_now = 10.41
	step(f, key(.Down, held = true))
	testing.expect_value(t, focused(f), "2")
	test_now = 10.45
	step(f, key(.Down, held = true))
	testing.expect_value(t, focused(f), "2")
	test_now = 10.52
	step(f, key(.Down, held = true))
	testing.expect_value(t, focused(f), "3")
}

@(test)
the_stick_engages_past_half_and_lets_go_under_a_third :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	show(t, f, MENU, `ui 1
<ui><column><button id="1" height="20"/><button id="2" height="20"/><button id="3" height="20"/></column></ui>`)
	step(f)
	pad :: proc(y: f32) -> core.Input {
		input: core.Input
		input.gamepads[0].connected = true
		input.gamepads[0].axes[.Left_Y] = y
		return input
	}
	test_now = 1
	step(f, pad(-0.45))
	testing.expect_value(t, focused(f), "")
	step(f, pad(-0.6))
	testing.expect_value(t, focused(f), "1")
	// Held at 0.4 it stays engaged, so it repeats after the delay.
	test_now = 1.2
	step(f, pad(-0.4))
	test_now = 1.45
	step(f, pad(-0.4))
	testing.expect_value(t, focused(f), "2")
	// Under 0.35 it lets go, and the next push moves at once.
	step(f, pad(-0.3))
	test_now = 1.46
	step(f, pad(-0.7))
	testing.expect_value(t, focused(f), "3")
}

@(test)
tab_follows_the_tree_and_shift_tab_goes_back :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	show(t, f, MENU, GRID)
	step(f)
	step(f, key(.Tab))
	testing.expect_value(t, focused(f), "a")
	for want in ([]string{"b", "c", "d", "f", "a"}) {
		step(f)
		step(f, key(.Tab))
		testing.expect_value(t, focused(f), want)
	}
	step(f)
	step(f, {down = {.Tab, .Left_Shift}, pressed = {.Tab}})
	testing.expect_value(t, focused(f), "f")
}

@(test)
a_modal_document_takes_the_focus_and_gives_it_back :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	show(t, f, MENU, GRID)
	modal := show(t, f, MODAL, `ui 1
<ui modal="true" cancel="resume" focus="no">
	<column anchor="center"><button id="yes" click="yes">Yes</button><button id="no" click="no">No</button></column>
</ui>`, order = 5)
	ecs.get(&f.world, modal, Ui_Document).visible = false
	step(f)
	step(f, key(.Down))
	step(f)
	step(f, key(.Right))
	testing.expect_value(t, focused(f), "b")
	ecs.get(&f.world, modal, Ui_Document).visible = true
	step(f)
	step(f)
	testing.expect_value(t, focused(f), "no")
	testing.expect(t, wants_input(&f.ui))
	// Escape goes to the modal's cancel, and the menu under it gets nothing.
	step(f, key(.Escape))
	testing.expect_value(t, events(f), "resume() ")
	ecs.get(&f.world, modal, Ui_Document).visible = false
	step(f)
	step(f)
	testing.expect_value(t, focused(f), "b")
	testing.expect(t, !wants_input(&f.ui))
	step(f, key(.Escape))
	testing.expect_value(t, events(f), "back() ")
}

@(test)
a_field_takes_typed_text_and_its_keys :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, MENU, fmt.tprintf(`ui 1
<ui font=$%s><field id="name" width="300" max_length="5" changed="edited" submit="named" placeholder="Name"/></ui>`, TEST_FONT))
	step(f)
	step(f, {mouse_position = {10, 10}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	testing.expect(t, f.ui.input.edit != nil)
	testing.expect(t, wants_input(&f.ui))
	typed := core.Input{}
	core.input_text_append(&typed.text, "Alic")
	step(f, typed)
	testing.expect_value(t, events(f), `edited(name, "Alic") `)
	// What does not fit under max_length is dropped.
	typed = {}
	core.input_text_append(&typed.text, "xyz")
	step(f, typed)
	testing.expect_value(t, events(f), `edited(name, "Alicx") `)
	// Left twice, Shift+Left, and a typed character replaces the selection.
	test_now = 5
	step(f, key(.Left))
	test_now = 5.01
	step(f, {down = {.Left}, pressed = {.Left}})
	test_now = 5.02
	step(f, {down = {.Left, .Left_Shift}, pressed = {.Left}})
	testing.expect_value(t, f.ui.input.edit.?.caret, 2)
	testing.expect_value(t, f.ui.input.edit.?.anchor, 3)
	typed = {}
	core.input_text_append(&typed.text, "e")
	step(f, typed)
	testing.expect_value(t, events(f), `edited(name, "Alecx") `)
	_ = e
	// The IME's composition is not in the value until it commits.
	composing := core.Input{}
	core.input_text_append(&composing.composition, "か")
	step(f, composing)
	testing.expect_value(t, f.ui.input.composition, "か")
	testing.expect_value(t, events(f), "")
	step(f, key(.Backspace))
	testing.expect_value(t, events(f), `edited(name, "Alcx") `)
	step(f, key(.Enter))
	testing.expect_value(t, events(f), `named(name, "Alcx") `)
	testing.expect(t, f.ui.input.edit == nil)
	d := document_of(&f.ui, e)
	text, _ := text_of(&f.ui, d, "name")
	testing.expect_value(t, text, "Alcx")
}

@(test)
escape_or_b_in_a_field_ends_the_edit_and_the_next_cancels :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	show(t, f, MENU, fmt.tprintf(`ui 1
<ui font=$%s cancel="back"><field id="name" width="300" changed="edited"/></ui>`, TEST_FONT))
	step(f)
	click_at :: proc(f: ^Fixture, p: [2]f32) {
		step(f, {mouse_position = p, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
		step(f, {mouse_position = p, released = {.Mouse_Left}})
	}
	click_at(f, {10, 10})
	typed := core.Input{mouse_position = {10, 10}}
	core.input_text_append(&typed.text, "Alic")
	step(f, typed)
	testing.expect_value(t, events(f), `edited(name, "Alic") `)
	// Escape in the field ends its edit, and the document does not cancel.
	step(f, key(.Escape))
	testing.expect(t, f.ui.input.edit == nil)
	testing.expect(t, !wants_input(&f.ui))
	testing.expect_value(t, events(f), "")
	step(f)
	step(f, key(.Escape))
	testing.expect_value(t, events(f), "back() ")
	// So does B.
	click_at(f, {10, 10})
	testing.expect(t, f.ui.input.edit != nil)
	b := core.Input{mouse_position = {10, 10}, gamepads = {0 = {connected = true, down = {.B}, pressed = {.B}}}}
	step(f, b)
	testing.expect(t, f.ui.input.edit == nil)
	testing.expect_value(t, events(f), "")
	step(f)
	step(f, b)
	testing.expect_value(t, events(f), "back() ")
}

@(test)
a_click_in_a_field_places_the_caret_by_that_fields_own_scroll :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, MENU, fmt.tprintf(`ui 1
<ui font=$%s><column gap="10"><field id="a" width="60"/><field id="b" width="300" text="Alic Alic"/></column></ui>`, TEST_FONT))
	step(f)
	a := node_rect(t, f, e, "a")
	b := node_rect(t, f, e, "b")
	middle := (a[1] + a[3]) * 0.5
	step(f, {mouse_position = {a[0] + 5, middle}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	typed := core.Input{}
	core.input_text_append(&typed.text, "Alic Alic Alic Alic")
	step(f, typed)
	// The layout scrolls a to keep its caret in view.
	scroll := f.ui.input.edit.?.scroll
	testing.expectf(t, scroll > 0, "a scrolled %v", scroll)
	// A press in b at its fourth character, as b shows unscrolled, puts the caret there.
	d := document_of(&f.ui, e)
	n, _ := find_node(d, "b")
	x := b[0] + d.nodes[n].style.padding[3] * f.ui.scale + caret_x(d, d.nodes[n].text, 3) + 1
	step(f, {mouse_position = {x, (b[1] + b[3]) * 0.5}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	edit, editing_b := f.ui.input.edit.?
	testing.expect(t, editing_b && edit.field.node == n)
	testing.expect_value(t, edit.caret, 3)
	testing.expect_value(t, edit.scroll, 0)
}

@(test)
a_document_that_goes_away_ends_the_edit_of_its_field :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, MENU, fmt.tprintf(`ui 1
<ui font=$%s><field id="name" width="300"/></ui>`, TEST_FONT))
	step(f)
	step(f, {mouse_position = {10, 10}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	testing.expect(t, f.ui.input.edit != nil)
	ecs.despawn(&f.world, e)
	step(f)
	testing.expect(t, f.ui.input.edit == nil)
	testing.expect(t, !wants_input(&f.ui))
}
