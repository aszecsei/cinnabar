package ui

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import "cinnabar:engine/asset"
import "cinnabar:engine/ecs"
import format "cinnabar:engine/asset/format"

@(private = "file")
DOC :: "d0c0d0c0d0c0d0c0d0c0d0c0d0c0d0c0"
@(private = "file")
OTHER :: "0d0c0d0c0d0c0d0c0d0c0d0c0d0c0d0c"

// rewrite writes a document's blob again, as a cook does, and swaps it in as the end of a frame does. The blob's and
// the generation's times move a minute on, as the poll looks for a new time, which a write in the same moment can lack.
@(private = "file")
rewrite :: proc(t: ^testing.T, f: ^Fixture, guid: string, text: string) {
	write_document(t, f, guid, text)
	generation := fmt.tprintf("%s/%s", f.cache, format.GENERATION_FILE)
	testing.expect(t, os.write_entire_file(generation, transmute([]byte)fmt.tprintf("%d", f.generation)) == nil)
	later := time.time_add(time.now(), time.Minute)
	testing.expect(t, os.change_times(fmt.tprintf("%s/%s.blob", f.cache, guid), later, later) == nil)
	testing.expect(t, os.change_times(generation, later, later) == nil)
	testing.expect(t, len(asset.poll(&f.assets)) > 0)
}

@(test)
a_row_gives_fixed_and_percent_sizes_first_and_shares_the_rest_by_weight :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, `ui 1
<ui>
	<row id="bar" width="600" height="40" padding="10" gap="10" cross="stretch">
		<box id="a" width="100"/>
		<box id="b" width="fill"/>
		<box id="c" width="fill 3"/>
		<box id="d" width="25%"/>
	</row>
</ui>`)
	step(f)
	// 580 of content, less 30 of gaps, 100 and 145: 305 shared 1 to 3.
	testing.expect_value(t, node_rect(t, f, e, "bar"), [4]f32{0, 0, 600, 40})
	testing.expect_value(t, node_rect(t, f, e, "a"), [4]f32{10, 10, 110, 30})
	testing.expect_value(t, node_rect(t, f, e, "b"), [4]f32{120, 10, 196, 30})
	testing.expect_value(t, node_rect(t, f, e, "c"), [4]f32{206, 10, 435, 30})
	testing.expect_value(t, node_rect(t, f, e, "d"), [4]f32{445, 10, 590, 30})
	// Each edge is on its own pixel, so neighbors share edges and leave no gaps but the gap.
	b, c := node_rect(t, f, e, "b"), node_rect(t, f, e, "c")
	testing.expect_value(t, c[0] - b[2], 10)
}

@(test)
a_fill_that_its_max_stops_leaves_the_rest_to_the_others :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, `ui 1
<ui>
	<row width="300" height="10">
		<box id="small" width="fill" max_width="50"/>
		<box id="big" width="fill"/>
		<box id="least" width="fill 0.1" min_width="40"/>
	</row>
</ui>`)
	step(f)
	testing.expect_value(t, node_rect(t, f, e, "small"), [4]f32{0, 0, 50, 0})
	testing.expect_value(t, node_rect(t, f, e, "big"), [4]f32{50, 0, 260, 0})
	testing.expect_value(t, node_rect(t, f, e, "least"), [4]f32{260, 0, 300, 0})
}

@(test)
a_column_fits_its_children_and_aligns_them :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, `ui 1
<ui>
	<column id="list" padding="4 8" gap="2" cross="center">
		<box id="wide" width="100" height="20"/>
		<box id="narrow" width="40" height="10"/>
	</column>
	<column id="spread" anchor="right" height="100" width="10" align="space_between">
		<box id="top" height="10"/>
		<box id="bottom" height="10"/>
	</column>
</ui>`)
	step(f)
	testing.expect_value(t, node_rect(t, f, e, "list"), [4]f32{0, 0, 116, 40})
	testing.expect_value(t, node_rect(t, f, e, "wide"), [4]f32{8, 4, 108, 24})
	testing.expect_value(t, node_rect(t, f, e, "narrow"), [4]f32{38, 26, 78, 36})
	testing.expect_value(t, node_rect(t, f, e, "spread"), [4]f32{1910, 490, 1920, 590})
	testing.expect_value(t, node_rect(t, f, e, "bottom"), [4]f32{1910, 580, 1910, 590})
}

@(test)
a_stack_anchors_its_children_and_offsets_them :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, `ui 1
<ui>
	<stack id="s" anchor="bottom_right" width="200" height="100" offset="-20 -10">
		<box id="corner" width="20" height="10" anchor="bottom_right" offset="-5 -5"/>
		<box id="middle" width="50" height="50" anchor="center"/>
		<box id="all" anchor="fill"/>
	</stack>
</ui>`)
	step(f)
	testing.expect_value(t, node_rect(t, f, e, "s"), [4]f32{1700, 970, 1900, 1070})
	testing.expect_value(t, node_rect(t, f, e, "corner"), [4]f32{1875, 1055, 1895, 1065})
	testing.expect_value(t, node_rect(t, f, e, "middle"), [4]f32{1775, 995, 1825, 1045})
	testing.expect_value(t, node_rect(t, f, e, "all"), [4]f32{1700, 970, 1900, 1070})
}

@(test)
the_scale_follows_the_output_height_and_the_project_setting :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, "ui 1\n<ui><box id=\"b\" width=\"300\" height=\"30\" padding=\"6\"/></ui>")
	step(f, size = {1280, 720})
	testing.expect_value(t, node_rect(t, f, e, "b"), [4]f32{0, 0, 200, 20})
	set_scale_factor(&f.ui, 2)
	step(f, size = {3840, 2160})
	testing.expect_value(t, f.ui.scale, 4)
	testing.expect_value(t, node_rect(t, f, e, "b"), [4]f32{0, 0, 1200, 120})
	// A small window keeps its scale at MIN_SCALE.
	set_scale_factor(&f.ui, 1)
	step(f, size = {320, 200})
	testing.expect_value(t, f.ui.scale, f32(MIN_SCALE))
}

@(test)
a_clip_cuts_its_children_and_visible_takes_them_out :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, `ui 1
<ui>
	<row id="r" width="50" height="10" clip="true">
		<box id="in" width="40"/>
		<box id="hidden" width="30" visible="false"/>
		<box id="out" width="40"/>
	</row>
</ui>`)
	step(f)
	d := document_of(&f.ui, e)
	out, _ := find_node(d, "out")
	testing.expect_value(t, d.nodes[out].rect, [4]f32{40, 0, 80, 0})
	testing.expect_value(t, d.nodes[out].clip, [4]f32{0, 0, 50, 10})
	hidden, _ := find_node(d, "hidden")
	testing.expect(t, !d.nodes[hidden].shown)
}

@(test)
the_cascade_applies_kind_styles_listed_styles_variants_inline_and_overrides_in_order :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, `ui 1
<ui color="#123">
	<style name="button" fill="#100" radius="1" gap="1"/>
	<style name="button:focus" fill="#200" radius="2"/>
	<style name="wide" fill="#300" padding="3"/>
	<style name="wide:focus" padding="4"/>
	<button id="b" style="wide" gap="9">Hi</button>
</ui>`)
	step(f)
	d := document_of(&f.ui, e)
	b, _ := find_node(d, "b")
	st := cascade(d, b, nil, {})
	testing.expect_value(t, st.fill.colors[0], format.Ui_Color{0x33, 0, 0, 255})
	testing.expect_value(t, st.radius, [4]f32{1, 1, 1, 1})
	testing.expect_value(t, st.gap, 9)
	// A variant applies after every style's base, in the list's order.
	st = cascade(d, b, nil, {.Focus})
	testing.expect_value(t, st.fill.colors[0], format.Ui_Color{0x22, 0, 0, 255})
	testing.expect_value(t, st.padding, [4]f32{4, 4, 4, 4})
	testing.expect_value(t, st.radius, [4]f32{2, 2, 2, 2})
	// A script's value wins over the element's own.
	testing.expect_value(t, set_attribute(&f.ui, d, "b", "gap", "12"), "")
	testing.expect_value(t, cascade(d, b, nil, {}).gap, 12)
	testing.expect(t, set_attribute(&f.ui, d, "b", "gap", "-1") != "")
	testing.expect(t, set_attribute(&f.ui, d, "b", "colour", "#fff") != "")
	// A child inherits its parent's text attributes.
	text := d.nodes[b].first_child
	testing.expect_value(t, d.nodes[text].style.color, format.Ui_Color{0x11, 0x22, 0x33, 255})
}

@(test)
a_new_version_of_the_document_keeps_what_scripts_set_copied_and_focused :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	text := `ui 1
<ui>
	<column id="list">
		<button id="first">A</button>
	</column>
	<template id="slot"><row><text id="label">Slot</text></row></template>
</ui>`
	e := show(t, f, DOC, text)
	step(f)
	d := document_of(&f.ui, e)
	id, message := add_clone(&f.ui, d, "list", "slot")
	testing.expect_value(t, message, "")
	testing.expect_value(t, id, "slot#1")
	testing.expect_value(t, set_attribute(&f.ui, d, "slot#1.label", "text", "Saved"), "")
	testing.expect_value(t, focus_element(&f.ui, d, "first"), "")
	_, missing := add_clone(&f.ui, d, "list", "nothing")
	testing.expect(t, missing != "")
	_, missing = add_clone(&f.ui, d, "nowhere", "slot")
	testing.expect(t, missing != "")
	step(f)
	label, found := find_node(d, "slot#1.label")
	testing.expect(t, found)
	testing.expect_value(t, d.nodes[label].style.text, "Saved")

	rewrite(t, f, DOC, `ui 1
<ui>
	<column id="list" gap="5">
		<text>New</text>
		<button id="first">A</button>
	</column>
	<template id="slot"><row><text id="label">Slot</text></row></template>
</ui>`)
	generation := d.generation
	step(f)
	testing.expect(t, d.generation > generation)
	label, found = find_node(d, "slot#1.label")
	testing.expect(t, found)
	testing.expect_value(t, d.nodes[label].style.text, "Saved")
	focus_d, focus_n, focused := resolve(&f.ui, f.ui.input.focus)
	testing.expect(t, focused && focus_d == d && id_of(d, focus_n) == "first")

	// A copy that goes takes what was set on it.
	testing.expect_value(t, remove_element(&f.ui, d, "slot#1"), "")
	testing.expect_value(t, len(d.overrides), 0)
	_, found = find_node(d, "slot#1.label")
	testing.expect(t, !found)
	testing.expect(t, remove_element(&f.ui, d, "slot#1") != "")
}

@(test)
documents_come_and_go_with_their_entities :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, "ui 1\n<ui><box id=\"x\"/></ui>")
	other := show(t, f, OTHER, "ui 1\n<ui><box id=\"y\"/></ui>", order = 2)
	step(f)
	testing.expect(t, document_of(&f.ui, e) != nil && document_of(&f.ui, other) != nil)
	ecs.despawn(&f.world, other)
	step(f)
	testing.expect(t, document_of(&f.ui, other) == nil)
	testing.expect(t, document_of(&f.ui, e).built)
}
