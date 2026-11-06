package ui

import "core:fmt"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/ecs"

@(private = "file")
LIST :: "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5"

// A list 200 by 100 with padding 10, which shows 80 of its content, and a template of a button 30 high. Its 50 copies,
// with gaps of 10, are 1990 high, so it scrolls through 1910.
@(private = "file")
SLOTS :: `ui 1
<ui>
	<column id="list" width="200" height="100" padding="10" gap="10" cross="stretch" align="center" overflow="scroll">
	</column>
	<template id="slot"><button height="30" click="pick"/></template>
</ui>`

// slots shows the list and copies the template into it 50 times, as a script's Ui.add would.
@(private = "file")
slots :: proc(t: ^testing.T, f: ^Fixture, text := SLOTS) -> (ecs.Entity, ^Document) {
	e := show(t, f, LIST, text)
	step(f)
	d := document_of(&f.ui, e)
	for i in 1 ..= 50 {
		id, message := add_clone(&f.ui, d, "list", "slot")
		testing.expect_value(t, message, "")
		testing.expect_value(t, id, fmt.tprintf("slot#%d", i))
	}
	step(f)
	return e, d
}

@(private = "file")
list_node :: proc(d: ^Document, id := "list") -> ^Node {
	n, _ := find_node(d, id)
	return &d.nodes[n]
}

@(private = "file")
focused_id :: proc(f: ^Fixture) -> string {
	d, n, ok := resolve(&f.ui, f.ui.input.focus)
	return ok ? id_of(d, n) : ""
}

@(private = "file")
press :: proc(k: core.Key) -> core.Input {
	return {down = {k}, pressed = {k}}
}

@(test)
a_scroll_box_lays_its_children_out_at_what_they_need_and_scrolls_them :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e, d := slots(t, f)
	list := list_node(d)
	testing.expect_value(t, list.rect, [4]f32{0, 0, 200, 100})
	testing.expect_value(t, list.scroll_max, 1910)
	testing.expect_value(t, list.child_clip, [4]f32{0, 0, 200, 100})
	// What does not fit starts at the start, whatever the alignment.
	testing.expect_value(t, node_rect(t, f, e, "slot#1"), [4]f32{10, 10, 190, 40})
	testing.expect_value(t, node_rect(t, f, e, "slot#50"), [4]f32{10, 1970, 190, 2000})
	list.scroll = 45
	step(f)
	testing.expect_value(t, node_rect(t, f, e, "slot#1"), [4]f32{10, -35, 190, -5})
	testing.expect_value(t, node_rect(t, f, e, "slot#2"), [4]f32{10, 5, 190, 35})
	// The offset stays inside what there is to scroll through, as the content changes.
	list.scroll = 5000
	step(f)
	testing.expect_value(t, list.scroll, 1910)
	testing.expect_value(t, set_attribute(&f.ui, d, "list", "height", "1000"), "")
	step(f)
	testing.expect_value(t, list_node(d).scroll, 1010)
}

@(test)
a_scroll_box_shares_its_content_by_percents_of_what_shows :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, LIST, `ui 1
<ui>
	<column id="pages" width="50" height="100" cross="stretch" overflow="scroll">
		<box id="one" height="100%"/>
		<box id="two" height="50%"/>
		<box id="rest" height="fill"/>
	</column>
	<row id="fits" width="100" height="10" overflow="scroll" align="end"><box id="small" width="40" height="10"/></row>
</ui>`)
	step(f)
	d := document_of(&f.ui, e)
	testing.expect_value(t, node_rect(t, f, e, "one"), [4]f32{0, 0, 50, 100})
	testing.expect_value(t, node_rect(t, f, e, "two"), [4]f32{0, 100, 50, 150})
	testing.expect_value(t, node_rect(t, f, e, "rest"), [4]f32{0, 150, 50, 150})
	testing.expect_value(t, list_node(d, "pages").scroll_max, 50)
	// A box whose content fits does not scroll, and aligns it.
	testing.expect_value(t, list_node(d, "fits").scroll_max, 0)
	testing.expect_value(t, node_rect(t, f, e, "small"), [4]f32{60, 0, 100, 10})
}

@(test)
a_scroll_boxs_offset_outlives_a_new_version_by_its_id :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e, d := slots(t, f)
	list_node(d).scroll = 45
	step(f)
	generation := d.generation
	rebuild(&f.ui, d)
	testing.expect(t, d.generation > generation)
	step(f)
	testing.expect_value(t, list_node(d).scroll, 45)
	testing.expect_value(t, node_rect(t, f, e, "slot#2"), [4]f32{10, 5, 190, 35})
}

@(test)
the_wheel_scrolls_the_box_under_the_pointer_and_then_the_one_that_it_is_in :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, LIST, `ui 1
<ui>
	<column id="outer" width="200" height="100" cross="stretch" overflow="scroll">
		<column id="inner" height="60" overflow="scroll">
			<box height="50"/>
			<box height="50"/>
		</column>
		<box height="200"/>
	</column>
</ui>`)
	step(f)
	d := document_of(&f.ui, e)
	// Over the inner list, a notch toward the player scrolls it 60, as far as it goes.
	step(f, {mouse_position = {100, 30}, scroll = -1})
	testing.expect_value(t, list_node(d, "inner").scroll, 40)
	testing.expect_value(t, list_node(d, "outer").scroll, 0)
	step(f, {mouse_position = {100, 30}, scroll = -1})
	testing.expect_value(t, list_node(d, "inner").scroll, 40)
	testing.expect_value(t, list_node(d, "outer").scroll, 60)
	// The inner list has scrolled out from under the pointer, so away from the player the outer list goes back.
	step(f, {mouse_position = {100, 30}, scroll = 0.5})
	testing.expect_value(t, list_node(d, "inner").scroll, 40)
	testing.expect_value(t, list_node(d, "outer").scroll, 30)
	// Outside both, the wheel scrolls nothing.
	step(f, {mouse_position = {500, 30}, scroll = 1})
	testing.expect_value(t, list_node(d, "outer").scroll, 30)
}

@(test)
the_right_stick_and_page_keys_scroll_the_focuss_box :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	_, d := slots(t, f)
	test_now = 1
	step(f, press(.Down))
	testing.expect_value(t, focused_id(f), "slot#1")
	pad :: proc(y: f32) -> core.Input {
		input: core.Input
		input.gamepads[0].connected = true
		input.gamepads[0].axes[.Right_Y] = y
		return input
	}
	// Down, half way, for 0.05 s: 1200 × 0.5 × 0.05.
	test_now = 1.05
	step(f, pad(-0.5))
	testing.expect_value(t, list_node(d).scroll, 30)
	// The stick does not move the focus, and up scrolls back.
	testing.expect_value(t, focused_id(f), "slot#1")
	test_now = 1.1
	step(f, pad(0.2))
	testing.expect_value(t, list_node(d).scroll, 18)
	// A long frame scrolls no further than MAX_SCROLL_DT does.
	test_now = 5
	step(f, pad(-1))
	testing.expect_value(t, list_node(d).scroll, 138)
	// Page Down and Page Up move it a view at a time.
	step(f)
	step(f, press(.Page_Down))
	testing.expect_value(t, list_node(d).scroll, 218)
	step(f)
	step(f, press(.Page_Up))
	step(f)
	step(f, press(.Page_Up))
	testing.expect_value(t, list_node(d).scroll, 58)
	step(f)
	step(f, press(.Page_Up))
	testing.expect_value(t, list_node(d).scroll, 0)
}

@(test)
moving_the_focus_scrolls_it_into_view :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e, d := slots(t, f)
	// Down from each copy to the next keeps the focused copy inside the list's padding.
	for i in 1 ..= 50 {
		step(f)
		step(f, press(.Down))
		want := fmt.tprintf("slot#%d", i)
		testing.expect_value(t, focused_id(f), want)
		r := node_rect(t, f, e, want)
		testing.expectf(t, r[1] >= 10 && r[3] <= 90, "%s is at %v", want, r)
	}
	testing.expect_value(t, list_node(d).scroll, 1910)
	// Up comes back in at the top.
	for _ in 1 ..= 3 {
		step(f)
		step(f, press(.Up))
	}
	testing.expect_value(t, focused_id(f), "slot#47")
	testing.expect_value(t, node_rect(t, f, e, "slot#47"), [4]f32{10, 10, 190, 40})
	// A script's focus scrolls too.
	testing.expect_value(t, focus_element(&f.ui, d, "slot#2"), "")
	step(f)
	testing.expect_value(t, node_rect(t, f, e, "slot#2"), [4]f32{10, 10, 190, 40})
}

@(test)
the_pointer_hits_what_shows_where_it_has_scrolled_to :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	_, d := slots(t, f)
	slot := proc(d: ^Document, id: string) -> u32 {
		n, _ := find_node(d, id)
		return n
	}
	// Slot 3 is at 90 to 120, cut off at the list's edge at 100.
	step(f, {mouse_position = {100, 95}})
	testing.expect_value(t, f.ui.input.hovered.node, slot(d, "slot#3"))
	step(f, {mouse_position = {100, 110}})
	testing.expect_value(t, f.ui.input.hovered, NO_NODE)
	list_node(d).scroll = 45
	step(f)
	step(f, {mouse_position = {100, 20}})
	testing.expect_value(t, f.ui.input.hovered.node, slot(d, "slot#2"))
	step(f, {mouse_position = {100, 20}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	step(f, {mouse_position = {100, 20}, released = {.Mouse_Left}})
	testing.expect_value(t, len(f.ui.input.events), 1)
	if len(f.ui.input.events) == 1 {
		testing.expect_value(t, f.ui.input.events[0].id, "slot#2")
	}
	// A click focuses where it is, without scrolling what it clicked from under it.
	testing.expect_value(t, focused_id(f), "slot#2")
	testing.expect_value(t, list_node(d).scroll, 45)
}

@(test)
the_thumb_drags_and_the_track_pages :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	_, d := slots(t, f)
	// The track is 192 to 198 across and 2 to 98 down. The thumb is its least, 24, of the 96, so it travels 72.
	bar, ok := bar_of(&f.ui, d, find_index(d, "list"))
	testing.expect(t, ok)
	testing.expect_value(t, bar.track, [4]f32{192, 2, 198, 98})
	testing.expect_value(t, bar.thumb, [4]f32{192, 2, 198, 26})
	step(f, {mouse_position = {195, 10}})
	testing.expect_value(t, f.ui.input.bar_part, Bar_Part.Thumb)
	step(f, {mouse_position = {195, 10}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	// Half of the travel down is half of the scroll.
	step(f, {mouse_position = {195, 46}, down = {.Mouse_Left}})
	testing.expect_value(t, list_node(d).scroll, 955)
	// The drag holds outside the bar, and stops at the end.
	step(f, {mouse_position = {400, 300}, down = {.Mouse_Left}})
	testing.expect_value(t, list_node(d).scroll, 1910)
	step(f, {mouse_position = {195, 46}, down = {.Mouse_Left}})
	step(f, {mouse_position = {195, 46}, released = {.Mouse_Left}})
	testing.expect_value(t, f.ui.input.drag, NO_NODE)
	testing.expect_value(t, list_node(d).scroll, 955)
	// The thumb is at 38 to 62. A click on the track under it pages down, and one over it pages up.
	step(f, {mouse_position = {195, 90}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	step(f, {mouse_position = {195, 90}, released = {.Mouse_Left}})
	testing.expect_value(t, list_node(d).scroll, 1035)
	step(f, {mouse_position = {195, 5}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	step(f, {mouse_position = {195, 5}, released = {.Mouse_Left}})
	testing.expect_value(t, list_node(d).scroll, 955)
	// The bar neither clicks nor focuses.
	testing.expect_value(t, len(f.ui.input.events), 0)
	testing.expect_value(t, focused_id(f), "")
}

@(private = "file")
find_index :: proc(d: ^Document, id: string) -> u32 {
	n, _ := find_node(d, id)
	return n
}

@(private = "file")
BAR :: `ui 1
<ui>
	<style name="scroll_track" fill="#ffffff10" width="8" padding="0"/>
	<style name="scroll_thumb" fill="#ffffff50"/>
	<style name="scroll_thumb:hover" fill="#ffffffa0"/>
	<column id="list" width="100" height="50" cross="stretch" overflow="scroll"><box height="40" fill="#f00"/><box height="40" fill="#0f0"/></column>
</ui>`

@(test)
a_scroll_bar_draws_over_the_content_with_its_styles :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, LIST, BAR)
	step(f)
	b := build_batch(&f.ui, 0, context.temp_allocator)
	testing.expect_value(t, len(b.instances), 4)
	if len(b.instances) == 4 {
		track, thumb := b.instances[2], b.instances[3]
		testing.expect_value(t, track.rect, [4]f32{92, 0, 100, 50})
		testing.expect_value(t, track.fill, 0x10ffffff)
		// Of 50, the thumb is the 50 of 80 that shows.
		testing.expect_value(t, thumb.rect, [4]f32{92, 0, 100, 31})
		testing.expect_value(t, thumb.fill, 0x50ffffff)
		testing.expect_value(t, thumb.radii, [4]f32{3, 3, 3, 3})
		testing.expect_value(t, thumb.clip, [4]f32{0, 0, 1920, 1080})
	}
	// Its variants apply while the pointer is over the box.
	step(f, {mouse_position = {50, 20}})
	b = build_batch(&f.ui, 0, context.temp_allocator)
	if len(b.instances) == 4 {
		testing.expect_value(t, b.instances[3].fill, 0xa0ffffff)
	}
	// scroll_bar="false" hides it, and so does content that fits.
	d := document_of(&f.ui, e)
	testing.expect_value(t, set_attribute(&f.ui, d, "list", "scroll_bar", "false"), "")
	step(f)
	testing.expect_value(t, len(build_batch(&f.ui, 0, context.temp_allocator).instances), 2)
	testing.expect_value(t, set_attribute(&f.ui, d, "list", "scroll_bar", "true"), "")
	testing.expect_value(t, set_attribute(&f.ui, d, "list", "height", "80"), "")
	step(f)
	testing.expect_value(t, len(build_batch(&f.ui, 0, context.temp_allocator).instances), 2)
}

@(test)
a_scroll_bar_without_styles_is_a_thumb :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	show(t, f, LIST, `ui 1
<ui><row width="100" height="20" overflow="scroll"><box width="200" height="10"/></row></ui>`)
	step(f)
	b := build_batch(&f.ui, 0, context.temp_allocator)
	testing.expect_value(t, len(b.instances), 1)
	if len(b.instances) == 1 {
		// A row's bar is along its bottom, 2 in from its edges and 6 thick, its thumb half of it.
		testing.expect_value(t, b.instances[0].rect, [4]f32{2, 12, 50, 18})
		testing.expect_value(t, b.instances[0].fill, 0x60ffffff)
	}
}
