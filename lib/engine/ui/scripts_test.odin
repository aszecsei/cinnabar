package ui

import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:engine/script"

@(private = "file")
DOC :: "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5"

@(private = "file")
MENU :: `ui 1
<ui>
	<column id="list">
		<text id="title">Title</text>
		<text id="score">{score} points</text>
		<button id="resume" width="100" height="40" click="resume"/>
	</column>
	<template id="slot"><row><text id="label">Slot</text></row></template>
</ui>`

// frame runs the frame code's UI part around the script phase: the documents, the input and its events, the scripts,
// and the layout.
@(private = "file")
frame :: proc(f: ^Fixture, input: core.Input = {}) {
	free_all(f.platform.frame_allocator)
	sync(&f.ui, &f.world)
	handle_input(&f.ui, input, test_now)
	flush_events(&f.ui, &f.runtime)
	script.run_phase(&f.runtime, time.Millisecond * 16, input)
	layout(&f.ui, {1920, 1080})
}

@(test)
scripts_set_bind_copy_and_take_out_elements :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(t, f)
	f.entity = show(t, f, DOC, MENU)
	frame(f)
	context.user_ptr = f
	_, ok := script.spawn_source(&f.runtime, "=menu", `
local Menu = Behaviour.define("Menu")
function Menu:start()
	Ui.set_text(self.entity, "title", "Paused")
	Ui.bind(self.entity, "score", 42)
	local id = Ui.add(self.entity, "list", "slot")
	Ui.set_text(self.entity, id .. ".label", "Copy")
	Test.report("added", id, Ui.get_text(self.entity, "title"), Ui.get_text(self.entity, "score"), Ui.get_text(self.entity, id .. ".label"))
	Test.report("bad value", (pcall(Ui.set, self.entity, "title", "width", "wide")))
	Test.report("bad attribute", (pcall(Ui.set, self.entity, "title", "colour", "#fff")))
	Test.report("no template", (pcall(Ui.add, self.entity, "list", "nothing")))
	Test.report("no element", Ui.get_text(self.entity, "nothing"))
	Ui.set_visible(self.entity, "score", false)
	Ui.remove(self.entity, id)
	Test.report("removed", Ui.get_text(self.entity, id .. ".label"))
	Test.report("wants", Ui.wants_input())
end
function Menu:on_resume(id)
	Test.report("resume", id)
end
Test.entity():add(Menu)
`)
	testing.expect(t, ok)
	frame(f)
	expected := []string {
		"added slot#1 Paused 42 points Copy",
		"bad value false",
		"bad attribute false",
		"no template false",
		"no element nil",
		"removed nil",
		"wants false",
	}
	testing.expect_value(t, len(f.reports), len(expected))
	for e, i in expected {
		if i < len(f.reports) {
			testing.expect_value(t, f.reports[i], e)
		}
	}
	d := document_of(&f.ui, f.entity)
	score, _ := find_node(d, "score")
	testing.expect(t, !d.nodes[score].shown)

	// A click on the button reaches the behaviour in the same frame's script phase.
	clear(&f.reports)
	frame(f, {mouse_position = {50, 30}, down = {.Mouse_Left}, pressed = {.Mouse_Left}})
	frame(f, {mouse_position = {50, 30}, released = {.Mouse_Left}})
	testing.expect_value(t, len(f.reports), 1)
	if len(f.reports) == 1 {
		testing.expect_value(t, f.reports[0], "resume resume")
	}
}
