package editor

import "base:runtime"
import "core:hash"
import "core:strings"

import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"
import "cinnabar:engine/ui"

// UI previews (see docs/editor/ui-editor.md#the-games-side): the UI editor's canvas is a preview that shows a UI document,
// its unsaved text as the cook daemon cooked it or its cooked blob, laid out on a screen of a size and a UI scale that
// the editor picks, and drawn through a view that zooms and pans it. The document is in a slot of the editor's own
// ui.State, which no world syncs and no input reaches, so the game's UI is not touched. Where each element went goes
// back to the editor, which outlines and picks elements by it.

// Ui_Preview is a UI preview's state: its document, while it has one, or the key of a blob that did not build, the
// editor's settings, and the bindings, whose strings are on the heap.
@(private)
Ui_Preview :: struct {
	document: union {
		Ui_Document,
		Ui_Build_Failed,
	},
	settings: link.Ui_Preview_Settings,
	bindings: [dynamic]link.Ui_Preview_Binding,
	// The settings and bindings changed since the document last took them.
	apply:    bool,
}

// Ui_Document is a UI preview's document: its slot, the blob's key that it was built from, and the last layout:
// whether the document was laid out since it was built, its scale, and the hash of the last report.
@(private)
Ui_Document :: struct {
	slot:        int,
	key:         u64,
	laid_out:    bool,
	scale:       f32,
	layout_sent: u64,
}

// Ui_Build_Failed is a blob that did not build, by its key. It is not built again until a blob of another key comes,
// and the preview draws nothing.
@(private)
Ui_Build_Failed :: struct {
	key: u64,
}

// set_ui_preview_settings keeps the editor's settings of a UI preview, which take the place of Preview_Settings.
@(private)
set_ui_preview_settings :: proc(e: ^Editor, p: ^Preview, m: link.Ui_Preview_Settings) {
	u := &p.ui_preview
	clear_ui_bindings(e, u)
	if u.bindings == nil {
		u.bindings = make([dynamic]link.Ui_Preview_Binding, e.platform.heap_allocator)
	}
	for b in m.bindings {
		append(&u.bindings, link.Ui_Preview_Binding{strings.clone(b.name, e.platform.heap_allocator), strings.clone(b.value, e.platform.heap_allocator)})
	}
	u.settings = m
	u.settings.bindings = nil
	u.apply = true
	p.settings.id, p.settings.width, p.settings.height = m.id, m.width, m.height
	p.has_settings, p.dirty = true, true
}

@(private = "file")
clear_ui_bindings :: proc(e: ^Editor, u: ^Ui_Preview) {
	for b in u.bindings {
		delete(b.name, e.platform.heap_allocator)
		delete(b.value, e.platform.heap_allocator)
	}
	clear(&u.bindings)
}

// close_ui_preview frees a preview's document and its bindings.
@(private)
close_ui_preview :: proc(e: ^Editor, p: ^Preview) {
	u := &p.ui_preview
	drop_ui_document(e, u)
	clear_ui_bindings(e, u)
	delete(u.bindings)
	u^ = {}
}

// drop_ui_document frees a UI preview's document, when it has one, and keeps its settings and bindings.
@(private)
drop_ui_document :: proc(e: ^Editor, u: ^Ui_Preview) {
	if doc, ok := u.document.(Ui_Document); ok {
		ui.close_document(&e.ui, doc.slot)
	}
	u.document = nil
}

// ui_preview_data is the blob that a UI preview shows: its unsaved one, or its cooked one.
@(private = "file")
ui_preview_data :: proc(e: ^Editor, p: ^Preview) -> []byte {
	if p.data != nil {
		return p.data
	}
	h, loaded := asset.find(e.assets, p.material)
	if !loaded {
		return nil
	}
	data, _ := asset.data(e.assets, h)
	return data
}

// sync_ui_preview builds a UI preview's document from its blob when the blob is new, and gives it the editor's states
// and bindings when they changed. It is nil while there is no document to draw.
@(private = "file")
sync_ui_preview :: proc(e: ^Editor, p: ^Preview) -> ^Ui_Document {
	u := &p.ui_preview
	if e.ui.platform == nil {
		return nil
	}
	// Without a renderer, as in tests, nothing draws, so there is no pipeline to make.
	if e.renderer != nil {
		ui.sync_pipelines(&e.ui)
	}
	data := ui_preview_data(e, p)
	if header, valid := format.blob_header(data); valid && header.kind == .Ui {
		build_ui_document(e, p, data, header.key)
	}
	doc, ok := &u.document.(Ui_Document)
	if !ok {
		return nil
	}
	if u.apply {
		u.apply = false
		d := &e.ui.documents[doc.slot]
		ui.set_forced_states(d, u.settings.forced_node, transmute(bit_set[format.Ui_State])u.settings.forced_states)
		ui.clear_bindings(&e.ui, d)
		for b in u.bindings {
			ui.set_binding(&e.ui, d, b.name, b.value)
		}
	}
	return doc
}

// build_ui_document builds a UI preview's document from a blob of a key that it has not built or tried. A document
// that is open builds again in its slot; one that does not build frees its slot.
@(private = "file")
build_ui_document :: proc(e: ^Editor, p: ^Preview, data: []byte, key: u64) {
	u := &p.ui_preview
	switch &d in u.document {
	case Ui_Document:
		if d.key == key {
			return
		}
		if ui.set_document_data(&e.ui, d.slot, data) {
			d.key, d.laid_out, u.apply = key, false, true
			return
		}
		drop_ui_document(e, u)
		u.document = Ui_Build_Failed{key}
		return
	case Ui_Build_Failed:
		if d.key == key {
			return
		}
	}
	slot, ok := ui.open_document(&e.ui, p.material, data)
	if !ok {
		u.document = Ui_Build_Failed{key}
		return
	}
	u.document = Ui_Document{slot = slot, key = key}
	u.apply = true
}

// Ui_Draw is what a UI preview's hook draws, in frame memory.
@(private = "file")
Ui_Draw :: struct {
	e: ^Editor,
	p: ^Preview,
}

// ui_preview_desc is what the renderer draws of a UI preview: its background, and its document through the hook.
@(private)
ui_preview_desc :: proc(e: ^Editor, p: ^Preview, id: int, target: gpu.Preview_Target) -> render.Preview_Desc {
	draw := new(Ui_Draw, e.platform.frame_allocator)
	draw^ = {e, p}
	background: [4]f32
	if p.ui_preview.settings.background == .Light {
		background = {0.5, 0.5, 0.5, 1}
	}
	return {
		target = target.texture,
		size = target.size,
		id = id,
		material = p.material,
		complete = &p.complete,
		ui = draw_ui_preview,
		ui_data = draw,
		background = background,
	}
}

// draw_ui_preview lays a UI preview's document out on its screen and draws it into the preview's UI layer. A blob that
// did not build draws nothing, and that drawing is complete.
@(private = "file")
draw_ui_preview :: proc(f: ^render.Frame) -> bool {
	draw := (^Ui_Draw)(f.data)
	e, p := draw.e, draw.p
	u := &p.ui_preview
	doc := sync_ui_preview(e, p)
	if doc == nil {
		_, failed := u.document.(Ui_Build_Failed)
		return failed
	}
	s := u.settings
	screen := [2]f32{f32(max(s.screen_width, 1)), f32(max(s.screen_height, 1))}
	scale := s.scale > 0 ? s.scale : max(screen.y / ui.REFERENCE_HEIGHT, ui.MIN_SCALE)
	ui.layout_one(&e.ui, doc.slot, screen, scale)
	doc.laid_out, doc.scale = true, scale
	view := ui.View{scale = s.view_scale > 0 ? s.view_scale : 1, offset = {s.view_x, s.view_y}}
	return ui.add_document_passes(&e.ui, f, doc.slot, view)
}

// send_ui_layouts tells the editor where each UI preview's elements went when it last drew, when that changed.
@(private)
send_ui_layouts :: proc(e: ^Editor, out: ^[dynamic]byte, allocator: runtime.Allocator) {
	for &p, id in e.session.previews {
		u := &p.ui_preview
		doc, ok := &u.document.(Ui_Document)
		if !p.open || p.kind != .Ui || !ok || !doc.laid_out {
			continue
		}
		d := &e.ui.documents[doc.slot]
		message := link.Ui_Preview_Layout {
			id     = u32(id),
			key    = doc.key,
			scale  = doc.scale,
			width  = u.settings.screen_width,
			height = u.settings.screen_height,
			nodes  = make([]link.Ui_Layout_Node, len(d.nodes), allocator),
		}
		for n, i in d.nodes {
			pad := n.style.padding * doc.scale
			message.nodes[i] = {
				source  = n.source,
				shown   = n.shown,
				rect    = n.rect,
				content = {n.rect[0] + pad[3], n.rect[1] + pad[0], n.rect[2] - pad[1], n.rect[3] - pad[2]},
				clip    = n.clip,
			}
		}
		encoded := make([dynamic]byte, allocator)
		link.write_message(&encoded, message)
		h := max(hash.fnv64a(encoded[link.HEADER_SIZE:]), 1)
		if h != doc.layout_sent {
			doc.layout_sent = h
			append(out, ..encoded[:])
		}
	}
}
