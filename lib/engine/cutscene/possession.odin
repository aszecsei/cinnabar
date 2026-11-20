package cutscene

import "core:log"

import "cinnabar:core"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/ui"

#assert(format.CUTSCENE_INPUT_CONTEXT_CAPACITY == core.INPUT_ACTION_NAME_CAPACITY)

// Player_Hold is what a player holds of the game while it plays (see docs/cinematics/possession.md#the-whole-cutscene):
// the push of its input context, and the UI documents that it hides. take_hold fills it when a Ready player first
// plays or skips, and release_hold empties it when the player gives the world back. A Ready player holds nothing.
Player_Hold :: struct {
	input:  core.Input_Context_Token,
	// The entities whose Ui_Document the player suspends. Heap memory.
	hidden: [dynamic]ecs.Entity,
}

// take_hold pushes the cutscene's input context for every player, and suspends the Ui_Documents of the documents that
// it hides, active or not. A context that the game did not define is not pushed; the log names it, unless it is the
// default one, which a game without one does not need.
@(private)
take_hold :: proc(s: ^State, w: ^ecs.World, live: ^Player_Live) {
	data, blob, ok := cutscene_data(s, &live.evaluation)
	if !ok {
		return
	}
	hold := &live.hold
	if name := format.blob_string(data, blob.input_context); name != "" && s.input != nil {
		if index := core.input_contexts_find(s.input, name); index > 0 {
			hold.input = core.input_contexts_push(s.input, index, pusher = "cutscene")
			if hold.input == 0 {
				log.errorf(
					"cutscene: the input context %q was not pushed: the stacks are full",
					name,
				)
			}
		} else if name != format.CUTSCENE_INPUT_CONTEXT {
			log.warnf(
				"cutscene: %s: the game defines no input context %q, so the input is not blocked",
				format.blob_string(data, blob.source_path),
				name,
			)
		}
	}
	documents := format.cutscene_hide_ui(data, blob)
	if len(documents) == 0 {
		return
	}
	found := make([dynamic]ecs.Entity, w.platform.frame_allocator)
	ecs.collect(w, {ui.UI_DOCUMENT_ID}, &found)
	ecs.collect(w, {ui.UI_DOCUMENT_ID, ecs.INACTIVE_ID}, &found)
	for e in found {
		document := ecs.get(w, e, ui.Ui_Document)
		for guid in documents {
			if document.document == guid {
				if hold.hidden == nil {
					hold.hidden = make([dynamic]ecs.Entity, w.platform.heap_allocator)
				}
				ecs.suspend(w, e, {.Ui})
				append(&hold.hidden, e)
				break
			}
		}
	}
}

// release_hold pops the player's input context and shows the documents that it hid, while their entities are alive.
@(private)
release_hold :: proc(s: ^State, w: ^ecs.World, hold: ^Player_Hold) {
	if hold.input != 0 && s.input != nil {
		core.input_contexts_pop(s.input, hold.input)
	}
	for e in hold.hidden {
		ecs.resume(w, e, {.Ui})
	}
	delete(hold.hidden)
	hold^ = {}
}
