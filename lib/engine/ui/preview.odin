package ui

import "core:mem"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/render"

// The editor's preview of a document (see docs/editor/ui-editor.md#the-games-side) keeps it in a slot of a State of its
// own, with no entity: it builds it from a blob's bytes, lays it out at a screen's size and scale that the editor picks,
// and draws it alone, through a view. Its State never syncs with a world or takes input.

// open_document puts a document that no entity has in a free slot, built from a blob's bytes, which it copies.
open_document :: proc(s: ^State, guid: format.Guid, data: []byte) -> (index: int, ok: bool) {
	for &d, i in s.documents {
		if d.used {
			continue
		}
		d = {used = true, guid = guid, visible = true, forced_node = NONE}
		init_document(s, &d)
		if !set_document_data(s, i, data) {
			free_document(s, &d)
			return -1, false
		}
		return i, true
	}
	return -1, false
}

// set_document_data builds an open document again from a new blob's bytes, keeping its bindings.
set_document_data :: proc(s: ^State, index: int, data: []byte) -> bool {
	d := &s.documents[index]
	if !d.used {
		return false
	}
	if _, valid := format.ui_view(data); !valid {
		return false
	}
	delete(d.data, s.allocator)
	copied, _ := mem.alloc_bytes_non_zeroed(len(data), format.BLOB_ALIGN, s.allocator)
	copy(copied, data)
	d.data = copied
	rebuild(s, d)
	return true
}

// close_document frees an open document's slot.
close_document :: proc(s: ^State, index: int) {
	if index >= 0 && index < MAX_DOCUMENTS && s.documents[index].used {
		free_document(s, &s.documents[index])
	}
}

// set_forced_states shows states on the nodes of a blob element, by its index in the blob, as though the player
// hovered, focused, pressed or disabled it. No states, or NONE, shows the element as it is.
set_forced_states :: proc(d: ^Document, source: u32, states: bit_set[format.Ui_State]) {
	d.forced_node, d.forced = source, states
	if source == NONE {
		d.forced = {}
	}
}

// clear_bindings forgets every value that set_binding gave.
clear_bindings :: proc(s: ^State, d: ^Document) {
	for b in d.bindings {
		delete(b.name, s.allocator)
		delete(b.value, s.allocator)
	}
	clear(&d.bindings)
}

// layout_one lays out the document in a slot alone, on a screen of a size at a UI scale.
layout_one :: proc(s: ^State, index: int, size: [2]f32, scale: f32) {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	s.size = size
	s.scale = scale
	d := &s.documents[index]
	if d.used && d.built && len(d.nodes) > 0 {
		layout_document(s, begin_text(s), d, index)
	}
}

// add_document_passes draws the document in a slot, as layout_one laid it out, into the frame's UI layer through a view.
// It is false while a font, an atlas or an image that it draws is not resident, or the pipeline is not ready.
add_document_passes :: proc(s: ^State, f: ^render.Frame, index: int, view: View) -> (ready: bool) {
	return add_batch_pass(s, f, index, view)
}
