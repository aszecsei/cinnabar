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

// Ui_Preview is a UI preview's state: its document's slot, the blob's key that it was built from, the editor's
// settings, and the bindings, whose strings are on the heap.
@(private)
Ui_Preview :: struct {
	slot:        int,
	open:        bool,
	key:         u64,
	settings:    link.Ui_Preview_Settings,
	bindings:    [dynamic]link.Ui_Preview_Binding,
	// The settings and bindings changed since the document last took them.
	apply:       bool,
	// The last layout: whether the document was laid out since it was built, its scale, and the hash of the last
	// report.
	laid_out:    bool,
	scale:       f32,
	layout_sent: u64,
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
	if u.open {
		ui.close_document(&e.ui, u.slot)
	}
	clear_ui_bindings(e, u)
	delete(u.bindings)
	u^ = {}
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
// and bindings when they changed. It is false while there is no document to draw.
@(private = "file")
sync_ui_preview :: proc(e: ^Editor, p: ^Preview) -> bool {
	u := &p.ui_preview
	if e.ui.platform == nil {
		return false
	}
	// Without a renderer, as in tests, nothing draws, so there is no pipeline to make.
	if e.renderer != nil {
		ui.sync_pipelines(&e.ui)
	}
	data := ui_preview_data(e, p)
	header, valid := format.blob_header(data)
	if valid && header.kind == .Ui && (!u.open || header.key != u.key) {
		if u.open {
			u.open = ui.set_document_data(&e.ui, u.slot, data)
		} else {
			u.slot, u.open = ui.open_document(&e.ui, p.material, data)
		}
		if !u.open {
			return false
		}
		u.key, u.apply, u.laid_out = header.key, true, false
	}
	if !u.open {
		return false
	}
	if u.apply {
		u.apply = false
		d := &e.ui.documents[u.slot]
		ui.set_forced_states(d, u.settings.forced_node, transmute(bit_set[format.Ui_State])u.settings.forced_states)
		ui.clear_bindings(&e.ui, d)
		for b in u.bindings {
			ui.set_binding(&e.ui, d, b.name, b.value)
		}
	}
	return true
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

// draw_ui_preview lays a UI preview's document out on its screen and draws it into the preview's UI layer.
@(private = "file")
draw_ui_preview :: proc(f: ^render.Frame) -> bool {
	draw := (^Ui_Draw)(f.data)
	e, p := draw.e, draw.p
	if !sync_ui_preview(e, p) {
		return false
	}
	u := &p.ui_preview
	s := u.settings
	screen := [2]f32{f32(max(s.screen_width, 1)), f32(max(s.screen_height, 1))}
	scale := s.scale > 0 ? s.scale : max(screen.y / ui.REFERENCE_HEIGHT, ui.MIN_SCALE)
	ui.layout_one(&e.ui, u.slot, screen, scale)
	u.laid_out, u.scale = true, scale
	view := ui.View{scale = s.view_scale > 0 ? s.view_scale : 1, offset = {s.view_x, s.view_y}}
	return ui.add_document_passes(&e.ui, f, u.slot, view)
}

// send_ui_layouts tells the editor where each UI preview's elements went when it last drew, when that changed.
@(private)
send_ui_layouts :: proc(e: ^Editor, out: ^[dynamic]byte, allocator: runtime.Allocator) {
	for &p, id in e.previews {
		u := &p.ui_preview
		if !p.open || !p.ui || !u.open || !u.laid_out {
			continue
		}
		d := &e.ui.documents[u.slot]
		message := link.Ui_Preview_Layout {
			id     = u32(id),
			key    = u.key,
			scale  = u.scale,
			width  = u.settings.screen_width,
			height = u.settings.screen_height,
			nodes  = make([]link.Ui_Layout_Node, len(d.nodes), allocator),
		}
		for n, i in d.nodes {
			pad := n.style.padding * u.scale
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
		if h != u.layout_sent {
			u.layout_sent = h
			append(out, ..encoded[:])
		}
	}
}
