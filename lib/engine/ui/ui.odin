// Package ui is the UI system: documents of boxes, text and images from UI document assets, put on the screen by the
// Ui_Document component, laid out each frame, drawn in one batch by a signed-distance shader into the UI layer, with
// text shaped by kb_text_shape and drawn from fonts' multi-channel distance fields, focus and gamepad navigation, and
// the Ui library that scripts drive it with. See docs/ui/README.md.
package ui

import "core:hash"
import "core:log"
import "core:mem"
import "core:strings"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// The most documents that show at once, and the most fonts that they use.
MAX_DOCUMENTS :: 32
MAX_FONTS :: 16
// The UI scale is 1 at this output height, and grows and shrinks with it (see docs/ui/design.md#scale).
REFERENCE_HEIGHT :: 1080
// The UI scale is at least this, so a small window keeps its text readable.
MIN_SCALE :: 0.5
// An asset that would not load is tried again after this many seconds.
RETRY_INTERVAL :: 1.0

NONE :: max(u32)

// Str is a string in a document's arena, by its place, so it stays good as the arena grows.
Str :: struct {
	offset, length: u32,
}

Range :: struct {
	first, count: u32,
}

Node_Flag :: enum u8 {
	// The node came from a template, through Ui.add.
	Clone,
	// The node is gone: Ui.remove took it out. It stays in the array, out of its parent's children.
	Removed,
}

Node_Flags :: bit_set[Node_Flag;u8]

// Node is an element of a document as it is on the screen. The nodes are in the order of a walk that visits each
// before its children, but for templates' copies, which come after the document's own nodes.
Node :: struct {
	element:      format.Ui_Element,
	flags:        Node_Flags,
	parent:       u32,
	first_child:  u32,
	last_child:   u32,
	next_sibling: u32,
	id:           Str,
	id_hash:      u64,
	// The node's element in the blob, by its index there: a template's copy has its template's element's.
	source:       u32,
	// The node's own attributes, in the document's props, and its styles, in its style refs.
	props:        Range,
	styles:       Range,
	// What the cascade gave it this frame.
	style:        Style,
	// Layout, in pixels of the UI layer: the size that its content needs, its size, and its rectangle as x0, y0, x1, y1.
	fit:          [2]f32,
	size:         [2]f32,
	rect:         [4]f32,
	// What its drawing is cut to, and what its children's are.
	clip:         [4]f32,
	child_clip:   [4]f32,
	// A scroll box's offset along its direction, in pixels of the UI layer, and how far its content goes past it, which
	// layout sets and clamps the offset to.
	scroll:       f32,
	scroll_max:   f32,
	// Its text this frame, if it has any: the font, its size in pixels, its glyphs and its lines.
	text:         Node_Text,
	// Whether the node shows and is laid out: it and all of its ancestors are visible.
	shown:        bool,
	// Whether input skips it: it or an ancestor is disabled.
	disabled:     bool,
	// Its opacity times its ancestors'.
	alpha:        f32,
}

// Prop is an attribute's value, parsed. Its strings point into the document's copy of its blob, or an override's.
Prop :: struct {
	attr:  format.Ui_Attr,
	value: format.Ui_Value,
}

Style_Def :: struct {
	props:    Range,
	variants: [format.Ui_State]u32,
}

// Override is a value that a script set on an element, by its id, which the cascade applies last. Its string, if it has
// one, is its own, on the heap.
Override :: struct {
	id_hash: u64,
	attr:    format.Ui_Attr,
	value:   format.Ui_Value,
}

Structure_Kind :: enum u8 {
	// A copy of a template under a parent.
	Add,
	// An element of the document taken out.
	Remove,
}

// Structure_Op is a change that a script made to a document's tree. A rebuild replays them in order, so they survive a
// change to the document's asset. Its strings are its own.
Structure_Op :: struct {
	kind:     Structure_Kind,
	// The id of the element that it changes: an Add's parent, or what a Remove takes out.
	target:   string,
	template: string,
	// An Add's copy's id, such as slot#3.
	id:       string,
}

// Binding is the value of a {name} in text. Its strings are its own.
Binding :: struct {
	name, value: string,
}

// Document is a Ui_Document's document, in a slot of the state, while its entity has one.
Document :: struct {
	used:         bool,
	entity:       ecs.Entity,
	guid:         format.Guid,
	handle:       asset.Handle,
	// Whether nodes are built from the blob, from which version, and a count of rebuilds, which a node index is only
	// good within.
	built:        bool,
	version:      u32,
	generation:   u32,
	retry_at:     f64,
	order:        i32,
	visible:      bool,
	// Whether the entity had its Ui_Document this frame.
	seen:         bool,
	// The document's blob, copied, which props' strings point into: the asset runtime frees its own when it swaps it.
	data:         []byte,
	nodes:        [dynamic]Node,
	arena:        [dynamic]u8,
	props:        [dynamic]Prop,
	styles:       [dynamic]Style_Def,
	style_refs:   [dynamic]u32,
	// Node indices by id hash.
	ids:          map[u64]u32,
	overrides:    [dynamic]Override,
	structure:    [dynamic]Structure_Op,
	bindings:     [dynamic]Binding,
	// The next number of a template's copy, which no copy has had.
	next_clone:   u32,
	// The text of the last layout, which input reads: glyphs and lines, in the nodes' ranges.
	glyphs:       [dynamic]Glyph,
	lines:        [dynamic]Line,
	// Ids that a script named that no node has, which it warned of once.
	warned_ids:   map[u64]bool,
	// The states that the editor's preview shows on the nodes of a blob element, by its index there, in place of the
	// player's (see set_forced_states).
	forced_node:  u32,
	forced:       bit_set[format.Ui_State],
	// The styles named scroll_track and scroll_thumb, which scroll bars take, or UI_NONE.
	track_style:  u32,
	thumb_style:  u32,
}

// Font_Slot is a font that text uses: its blob, and kb_text_shape's font placed from it, which a code reload drops,
// as kb_text_shape is code in the game DLL.
Font_Slot :: struct {
	guid:     format.Guid,
	handle:   asset.Handle,
	loaded:   bool,
	version:  u32,
	placed:   bool,
	memory:   []byte,
	retry_at: f64,
	shaper:   Font_Shaper,
	warned:   bool,
}

// State is in Game_State. Every pointer in it is to memory of the host's or of Game_State, so a code reload keeps it.
State :: struct {
	platform:     ^core.Platform_API,
	allocator:    mem.Allocator,
	assets:       ^asset.Assets,
	// Where fonts' atlases and images are resident. Without one, as in tests, nothing draws.
	residency:    ^render.Residency,
	documents:    [MAX_DOCUMENTS]Document,
	fonts:        [MAX_FONTS]Font_Slot,
	// project.settings' ui.scale, which multiplies the scale that the output's height gives.
	scale_factor: f32,
	// This frame's scale and the UI layer's size.
	scale:        f32,
	size:         [2]f32,
	pipeline:     render.Shader_Pipeline,
	sampler:      gpu.Sampler,
	input:        Input_State,
	warned_full:  bool,
}

// init takes the assets that documents and fonts load from, and the residency that their textures are in.
init :: proc(s: ^State, platform: ^core.Platform_API, assets: ^asset.Assets, residency: ^render.Residency = nil) {
	s^ = {
		platform     = platform,
		allocator    = platform.heap_allocator,
		assets       = assets,
		residency    = residency,
		scale_factor = 1,
		scale        = 1,
		pipeline     = render.shader_pipeline(UI_SHADER),
	}
	init_input(s)
}

// on_reload drops what holds pointers into the old DLL: kb_text_shape's fonts. They are placed again when text next
// needs them. The game calls it from its on_reload.
on_reload :: proc(s: ^State, platform: ^core.Platform_API) {
	s.platform = platform
	for &f in s.fonts {
		drop_shaper(s, &f)
	}
}

destroy :: proc(s: ^State) {
	for &d in s.documents {
		if d.used {
			free_document(s, &d)
		}
	}
	for &f in s.fonts {
		drop_shaper(s, &f)
	}
	if s.platform != nil {
		if s.pipeline.pipeline != {} {
			render.destroy_shader_pipeline(&s.pipeline, s.platform)
		}
		if s.sampler != {} {
			s.platform.gpu_destroy_sampler(s.sampler)
		}
	}
	delete(s.input.events)
}

// set_scale_factor sets the project's UI scale, which multiplies the scale of the output's height.
set_scale_factor :: proc(s: ^State, factor: f32) {
	s.scale_factor = factor > 0 ? factor : 1
}

@(private)
str :: proc(d: ^Document, s: Str) -> string {
	return string(d.arena[s.offset:][:s.length])
}

@(private)
add_str :: proc(d: ^Document, text: string) -> Str {
	offset := u32(len(d.arena))
	append(&d.arena, text)
	return {offset, u32(len(text))}
}

@(private)
hash_id :: proc(id: string) -> u64 {
	return hash.fnv64a(transmute([]byte)id)
}

// id_of is a node's id, or "".
id_of :: proc(d: ^Document, n: u32) -> string {
	return str(d, d.nodes[n].id)
}

// find_node is the node of an id that is in the document now.
find_node :: proc(d: ^Document, id: string) -> (n: u32, ok: bool) {
	n, ok = d.ids[hash_id(id)]
	return n, ok && .Removed not_in d.nodes[n].flags
}

// document_of is the document on an entity, if it has one in a slot.
document_of :: proc(s: ^State, e: ecs.Entity) -> ^Document {
	for &d in s.documents {
		if d.used && d.entity == e {
			return &d
		}
	}
	return nil
}

@(private)
free_document :: proc(s: ^State, d: ^Document) {
	for &o in d.overrides {
		free_value(s, o.value)
	}
	for op in d.structure {
		free_op(s, op)
	}
	for b in d.bindings {
		delete(b.name, s.allocator)
		delete(b.value, s.allocator)
	}
	delete(d.data, s.allocator)
	delete(d.nodes)
	delete(d.arena)
	delete(d.props)
	delete(d.styles)
	delete(d.style_refs)
	delete(d.ids)
	delete(d.overrides)
	delete(d.structure)
	delete(d.bindings)
	delete(d.glyphs)
	delete(d.lines)
	delete(d.warned_ids)
	if d.handle != {} {
		asset.unload(s.assets, d.handle)
	}
	forget_document(s, d)
	d^ = {}
}

@(private)
free_value :: proc(s: ^State, v: format.Ui_Value) {
	if text, is_text := v.(string); is_text {
		delete(text, s.allocator)
	}
}

@(private)
free_op :: proc(s: ^State, op: Structure_Op) {
	delete(op.target, s.allocator)
	delete(op.template, s.allocator)
	delete(op.id, s.allocator)
}

// own_value is a copy of a value whose string, if it has one, is on the heap.
@(private)
own_value :: proc(s: ^State, v: format.Ui_Value) -> format.Ui_Value {
	if text, is_text := v.(string); is_text {
		return strings.clone(text, s.allocator)
	}
	return v
}

// sync matches the documents to the world's Ui_Documents, and builds each one whose asset is new or changed, keeping
// what scripts set. Call it each frame before input and scripts.
sync :: proc(s: ^State, w: ^ecs.World) {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	for &d in s.documents {
		d.seen = false
	}
	entities := make([dynamic]ecs.Entity, s.platform.frame_allocator)
	ecs.collect(w, {UI_DOCUMENT_ID}, &entities)
	for e in entities {
		c := ecs.get(w, e, Ui_Document)
		if c == nil || c.document == {} {
			continue
		}
		d := document_of(s, e)
		if d != nil && d.guid != c.document {
			free_document(s, d)
			d = nil
		}
		if d == nil {
			for &slot in s.documents {
				if !slot.used {
					d = &slot
					break
				}
			}
			if d == nil {
				if !s.warned_full {
					log.warnf("ui: more than %d documents show at once", MAX_DOCUMENTS)
					s.warned_full = true
				}
				continue
			}
			d^ = {used = true, entity = e, guid = c.document}
			init_document(s, d)
		}
		d.seen = true
		d.order = c.order
		d.visible = c.visible && ecs.active_in_hierarchy(w, e)
		load_document(s, d)
	}
	for &d in s.documents {
		if d.used && !d.seen {
			free_document(s, &d)
		}
	}
}

@(private)
init_document :: proc(s: ^State, d: ^Document) {
	d.nodes = make([dynamic]Node, s.allocator)
	d.arena = make([dynamic]u8, s.allocator)
	d.props = make([dynamic]Prop, s.allocator)
	d.styles = make([dynamic]Style_Def, s.allocator)
	d.style_refs = make([dynamic]u32, s.allocator)
	d.ids = make(map[u64]u32, s.allocator)
	d.overrides = make([dynamic]Override, s.allocator)
	d.structure = make([dynamic]Structure_Op, s.allocator)
	d.bindings = make([dynamic]Binding, s.allocator)
	d.glyphs = make([dynamic]Glyph, s.allocator)
	d.lines = make([dynamic]Line, s.allocator)
	d.warned_ids = make(map[u64]bool, s.allocator)
}

// load_document loads the document's blob, and builds it when it is new or the cooker wrote it again.
@(private)
load_document :: proc(s: ^State, d: ^Document) {
	if d.handle == {} {
		if s.platform.time_seconds() < d.retry_at {
			return
		}
		handle, ok := asset.load(s.assets, d.guid)
		if !ok {
			d.retry_at = s.platform.time_seconds() + RETRY_INTERVAL
			return
		}
		d.handle = handle
	}
	version := asset.version(s.assets, d.handle)
	if d.built && version == d.version {
		return
	}
	data, ok := asset.data(s.assets, d.handle)
	if !ok {
		return
	}
	if _, valid := format.ui_view(data); !valid {
		log.errorf("ui: the blob of %v is not a UI document of this build's", d.guid)
		d.version = version
		d.built = true
		return
	}
	delete(d.data, s.allocator)
	copied, _ := mem.alloc_bytes_non_zeroed(len(data), format.BLOB_ALIGN, s.allocator)
	copy(copied, data)
	d.data = copied
	d.version = version
	rebuild(s, d)
}

// rebuild makes the document's nodes again from its blob, replays the scripts' changes to its tree, and keeps the
// focus and the scroll boxes' offsets on the elements of the same ids.
@(private)
rebuild :: proc(s: ^State, d: ^Document) {
	focus_id := focused_id_hash(s, d)
	scrolls := make(map[u64]f32, s.platform.frame_allocator)
	for n in d.nodes {
		if n.id_hash != 0 && n.scroll != 0 {
			scrolls[n.id_hash] = n.scroll
		}
	}
	clear(&d.nodes)
	clear(&d.arena)
	clear(&d.props)
	clear(&d.styles)
	clear(&d.style_refs)
	clear(&d.ids)
	clear(&d.glyphs)
	clear(&d.lines)
	d.built = true
	d.generation += 1
	d.track_style, d.thumb_style = format.UI_NONE, format.UI_NONE
	blob, ok := format.ui_view(d.data)
	if !ok {
		return
	}
	data := d.data
	d.track_style, _ = format.ui_find_style(data, blob, TRACK_STYLE)
	d.thumb_style, _ = format.ui_find_style(data, blob, THUMB_STYLE)
	blob_props := format.ui_props(data, blob)
	add_props :: proc(d: ^Document, data: []byte, list: []format.Ui_Prop) -> Range {
		r := Range{u32(len(d.props)), 0}
		for p in list {
			value, message := format.ui_parse_value(p.attr, format.blob_string(data, p.value))
			if message == "" {
				append(&d.props, Prop{p.attr, value})
				r.count += 1
			}
		}
		return r
	}
	for st in format.ui_styles(data, blob) {
		append(&d.styles, Style_Def{add_props(d, data, format.ui_range(blob_props, st.props)), st.variants})
	}
	nodes := format.ui_nodes(data, blob)
	refs := format.ui_style_refs(data, blob)
	// Each blob node's index here, for its children to find their parent.
	built := make([]u32, len(nodes), s.platform.frame_allocator)
	for n, i in nodes {
		built[i] = NONE
		if .Template in n.flags {
			continue
		}
		parent := n.parent == format.UI_NONE ? NONE : built[n.parent]
		if n.parent != format.UI_NONE && parent == NONE {
			continue
		}
		style_range := Range{u32(len(d.style_refs)), n.styles.count}
		append(&d.style_refs, ..format.ui_range(refs, n.styles))
		built[i] = add_node(d, n.element, parent, format.blob_string(data, n.id), add_props(d, data, format.ui_range(blob_props, n.props)), style_range, {}, u32(i))
	}
	for op in d.structure {
		switch op.kind {
		case .Add:
			instantiate(s, d, op)
		case .Remove:
			if n, found := find_node(d, op.target); found {
				unlink(d, n)
			}
		}
	}
	for id_hash, scroll in scrolls {
		if n, found := d.ids[id_hash]; found {
			d.nodes[n].scroll = scroll
		}
	}
	restore_focus(s, d, focus_id)
}

// add_node appends a node as its parent's last child, and gives its index.
@(private)
add_node :: proc(d: ^Document, element: format.Ui_Element, parent: u32, id: string, props, styles: Range, flags: Node_Flags, source: u32) -> u32 {
	index := u32(len(d.nodes))
	n := Node {
		element      = element,
		flags        = flags,
		source       = source,
		parent       = parent,
		first_child  = NONE,
		last_child   = NONE,
		next_sibling = NONE,
		props        = props,
		styles       = styles,
	}
	if id != "" {
		n.id = add_str(d, id)
		n.id_hash = hash_id(id)
		d.ids[n.id_hash] = index
	}
	append(&d.nodes, n)
	if parent != NONE {
		p := &d.nodes[parent]
		if p.last_child == NONE {
			p.first_child = index
		} else {
			d.nodes[p.last_child].next_sibling = index
		}
		p.last_child = index
	}
	return index
}

// unlink takes a node out of its parent's children, and marks it and its subtree removed.
@(private)
unlink :: proc(d: ^Document, n: u32) {
	parent := d.nodes[n].parent
	if parent == NONE {
		return
	}
	p := &d.nodes[parent]
	previous := NONE
	for c := p.first_child; c != NONE; c = d.nodes[c].next_sibling {
		if c == n {
			if previous == NONE {
				p.first_child = d.nodes[c].next_sibling
			} else {
				d.nodes[previous].next_sibling = d.nodes[c].next_sibling
			}
			if p.last_child == n {
				p.last_child = previous
			}
			break
		}
		previous = c
	}
	mark_removed :: proc(d: ^Document, n: u32) {
		d.nodes[n].flags += {.Removed}
		for c := d.nodes[n].first_child; c != NONE; c = d.nodes[c].next_sibling {
			mark_removed(d, c)
		}
	}
	mark_removed(d, n)
}

// instantiate copies a template's element under the op's target, with the op's id for the copy and <id>.<inner> for
// the ids in it. It returns false if the target or the template is not there.
@(private)
instantiate :: proc(s: ^State, d: ^Document, op: Structure_Op) -> bool {
	parent, has_parent := find_node(d, op.target)
	if !has_parent {
		return false
	}
	blob, _ := format.ui_view(d.data)
	data := d.data
	nodes := format.ui_nodes(data, blob)
	template := NONE
	for n, i in nodes {
		if n.element == .Template && format.blob_string(data, n.id) == op.template {
			template = u32(i)
			break
		}
	}
	if template == NONE || nodes[template].subtree_end <= template + 1 {
		return false
	}
	blob_props := format.ui_props(data, blob)
	refs := format.ui_style_refs(data, blob)
	first, end := template + 1, nodes[template].subtree_end
	built := make([]u32, end - first, s.platform.frame_allocator)
	for i in first ..< end {
		n := nodes[i]
		node_parent := i == first ? parent : built[n.parent - first]
		id := op.id
		if i != first {
			inner := format.blob_string(data, n.id)
			id = inner != "" ? strings.concatenate({op.id, ".", inner}, s.platform.frame_allocator) : ""
		}
		props := Range{u32(len(d.props)), 0}
		for p in format.ui_range(blob_props, n.props) {
			value, message := format.ui_parse_value(p.attr, format.blob_string(data, p.value))
			if message == "" {
				append(&d.props, Prop{p.attr, value})
				props.count += 1
			}
		}
		style_range := Range{u32(len(d.style_refs)), n.styles.count}
		append(&d.style_refs, ..format.ui_range(refs, n.styles))
		built[i - first] = add_node(d, n.element, node_parent, id, props, style_range, {.Clone}, i)
	}
	return true
}

// Font_Info is what text needs of a font this frame: its blob and its shaper.
@(private)
Font_Info :: struct {
	slot: ^Font_Slot,
	data: []byte,
	blob: ^format.Font_Blob,
}

// font_of loads a font, places its shaper if it has none, and gives it, or false while it cannot.
@(private)
font_of :: proc(s: ^State, guid: format.Guid) -> (info: Font_Info, ok: bool) {
	if guid == {} {
		return
	}
	slot: ^Font_Slot
	free_slot: ^Font_Slot
	for &f in s.fonts {
		if f.guid == guid {
			slot = &f
			break
		}
		if free_slot == nil && f.guid == {} {
			free_slot = &f
		}
	}
	if slot == nil {
		if free_slot == nil {
			return
		}
		slot = free_slot
		slot^ = {guid = guid}
	}
	if !slot.loaded {
		if s.platform.time_seconds() < slot.retry_at {
			return
		}
		handle, loaded := asset.load(s.assets, guid)
		if !loaded {
			slot.retry_at = s.platform.time_seconds() + RETRY_INTERVAL
			return
		}
		slot.handle, slot.loaded = handle, true
	}
	data := asset.data(s.assets, slot.handle) or_return
	blob, valid := format.font_view(data)
	if !valid {
		if !slot.warned {
			log.errorf("ui: the blob of %v is not a font of this build's", guid)
			slot.warned = true
		}
		return
	}
	if version := asset.version(s.assets, slot.handle); slot.placed && version != slot.version {
		drop_shaper(s, slot)
	}
	if !slot.placed {
		place_shaper(s, slot, data, blob) or_return
		slot.version = asset.version(s.assets, slot.handle)
	}
	return {slot, data, blob}, true
}
