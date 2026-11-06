package ui

import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
PREVIEW_DOC :: "11111111111111111111111111111111"

@(private = "file")
PREVIEW_TEXT :: `ui 1
<ui>
	<style name="button" fill="#101010"/>
	<style name="button:hover" fill="#202020"/>
	<style name="button:disabled" fill="#303030"/>
	<column id="menu" anchor="center" width="300" padding="10" gap="4">
		<button id="ok" height="40">OK</button>
		<box id="b" height="20"/>
	</column>
	<template id="slot"><box id="x"/></template>
</ui>`

// preview_blob is the document's blob, in temporary memory.
@(private = "file")
preview_blob :: proc(t: ^testing.T, text: string) -> []byte {
	document, problems, ok := format.ui_parse(text)
	testing.expectf(t, ok, "%v", problems)
	return format.ui_write({guid = guid_of(PREVIEW_DOC), key = 1, document = document}, context.temp_allocator)
}

@(test)
a_preview_document_knows_each_nodes_element_in_its_blob :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	data := preview_blob(t, PREVIEW_TEXT)
	index, ok := open_document(&f.ui, guid_of(PREVIEW_DOC), data)
	testing.expect(t, ok)
	defer close_document(&f.ui, index)
	d := &f.ui.documents[index]
	blob, _ := format.ui_view(d.data)
	nodes := format.ui_nodes(d.data, blob)
	// ui, menu, ok, its text, b, and not the template's.
	testing.expect_value(t, len(d.nodes), 5)
	for n in d.nodes {
		testing.expect_value(t, n.element, nodes[n.source].element)
		testing.expect_value(t, str(d, n.id), format.blob_string(d.data, nodes[n.source].id))
	}
	// A template's copy has its template's element's.
	_, message := add_clone(&f.ui, d, "menu", "slot")
	testing.expect_value(t, message, "")
	copy_node := d.nodes[len(d.nodes) - 1]
	testing.expect_value(t, nodes[copy_node.source].element, format.Ui_Element.Box)
	testing.expect(t, .Template in nodes[copy_node.source].flags)
}

@(test)
a_preview_lays_out_a_screen_of_its_own_as_the_game_would :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, PREVIEW_DOC, PREVIEW_TEXT)
	step(f, size = {3840, 2160})
	game := document_of(&f.ui, e)
	rects := make([dynamic][4]f32, context.temp_allocator)
	for n in game.nodes {
		append(&rects, n.rect)
	}

	preview: State
	init(&preview, &f.platform, &f.assets)
	defer destroy(&preview)
	index, ok := open_document(&preview, guid_of(PREVIEW_DOC), preview_blob(t, PREVIEW_TEXT))
	testing.expect(t, ok)
	layout_one(&preview, index, {3840, 2160}, 2)
	d := &preview.documents[index]
	testing.expect_value(t, len(d.nodes), len(rects))
	for n, i in d.nodes {
		testing.expect_value(t, n.rect, rects[i])
	}
}

@(test)
a_preview_shows_the_states_that_the_editor_picks :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	index, ok := open_document(&f.ui, guid_of(PREVIEW_DOC), preview_blob(t, PREVIEW_TEXT))
	testing.expect(t, ok)
	defer close_document(&f.ui, index)
	d := &f.ui.documents[index]
	button, _ := find_node(d, "ok")
	fill :: proc(d: ^Document, n: u32) -> u8 {
		return d.nodes[n].style.fill.colors[0].r
	}
	layout_one(&f.ui, index, {1920, 1080}, 1)
	testing.expect_value(t, fill(d, button), 0x10)
	set_forced_states(d, d.nodes[button].source, {.Hover})
	layout_one(&f.ui, index, {1920, 1080}, 1)
	testing.expect_value(t, fill(d, button), 0x20)
	// Disabled is a state alone, as it is in play.
	set_forced_states(d, d.nodes[button].source, {.Hover, .Disabled})
	layout_one(&f.ui, index, {1920, 1080}, 1)
	testing.expect_value(t, fill(d, button), 0x30)
	set_forced_states(d, NONE, {.Hover})
	layout_one(&f.ui, index, {1920, 1080}, 1)
	testing.expect_value(t, fill(d, button), 0x10)
}

@(test)
a_new_blob_builds_a_preview_again_with_its_bindings :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	index, ok := open_document(&f.ui, guid_of(PREVIEW_DOC), preview_blob(t, PREVIEW_TEXT))
	testing.expect(t, ok)
	defer close_document(&f.ui, index)
	d := &f.ui.documents[index]
	set_binding(&f.ui, d, "name", "Ada")
	testing.expect(t, set_document_data(&f.ui, index, preview_blob(t, "ui 1\n<ui><box id=\"only\"/></ui>")))
	_, found := find_node(d, "only")
	testing.expect(t, found)
	testing.expect_value(t, len(d.bindings), 1)
	clear_bindings(&f.ui, d)
	testing.expect_value(t, len(d.bindings), 0)
	testing.expect(t, !set_document_data(&f.ui, index, {1, 2, 3}))
}
