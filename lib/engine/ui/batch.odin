package ui

import "core:log"
import "core:math"
import "core:slice"

import format "cinnabar:engine/asset/format"
import "cinnabar:core/gpu"
import "cinnabar:engine/render"

// A frame's UI draws at most this many instances. Those past it do not draw, and the first frame over it warns.
MAX_UI_INSTANCES :: 16384

// The instances' kinds, which ui.hlsl draws each its own way.
INSTANCE_RECT :: 0
INSTANCE_IMAGE :: 1
INSTANCE_GLYPH :: 2
// A rectangle's fill is a gradient from fill to fill_end.
INSTANCE_GRADIENT :: 0x100

// The selection's color in a field, and the caret's width and the composition's underline in pixels at a UI scale of 1.
SELECTION_ALPHA :: 0.35
CARET_WIDTH :: 1.5
// A caret is on for half of this and off for the other half, in seconds, and on while it moves.
CARET_BLINK :: 1.06
// A field's placeholder draws at this much of its text's alpha.
PLACEHOLDER_ALPHA :: 0.5

// Instance matches Instance in ui.hlsl: one rounded rectangle, image or glyph, in the UI layer's pixels. Its colors are
// RGBA8, sRGB-encoded with straight alpha, as a designer picks them, with the node's opacity in their alpha.
Instance :: struct {
	rect:     [4]f32,
	clip:     [4]f32,
	// A rectangle's or image's corners' radii: top left, top right, bottom right and bottom left.
	radii:    [4]f32,
	uv:       [4]f32,
	fill:     u32,
	fill_end: u32,
	border:   u32,
	kind:     u32,
	texture:  u32,
	// A rectangle's or image's border width, or a glyph's distance range in pixels on the screen.
	width:    f32,
	// A gradient's direction over its extent, so that t = 0.5 + dot(p - center, gradient).
	gradient: [2]f32,
}

#assert(size_of(Instance) == 96)

@(private)
pack :: proc(c: format.Ui_Color, alpha: f32) -> u32 {
	a := u32(math.round(clamp(f32(c.a) * alpha, 0, 255)))
	return u32(c.r) | u32(c.g) << 8 | u32(c.b) << 16 | a << 24
}

// Batch is what build_batch gives: the instances in the order that they draw.
Batch :: struct {
	instances: [dynamic]Instance,
	full:      bool,
	// Something does not draw yet: a font, its atlas or an image is not resident.
	waiting:   bool,
}

@(private)
push :: proc(b: ^Batch, i: Instance) {
	if len(b.instances) >= MAX_UI_INSTANCES {
		b.full = true
		return
	}
	// An instance of no size, or all outside its clip, draws nothing.
	seen := intersect(i.rect, i.clip)
	if i.rect[2] <= i.rect[0] || i.rect[3] <= i.rect[1] || seen[2] <= seen[0] || seen[3] <= seen[1] {
		return
	}
	append(&b.instances, i)
}

// build_batch gives the instances of every document that shows, the lowest order first, each in the order of its tree:
// a node's box, its image, its text, and then its children, which draw over it. now is the real time, for the caret.
// With only, it gives that slot's document alone.
build_batch :: proc(s: ^State, now: f64, allocator := context.allocator, only := -1) -> Batch {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	b := Batch {
		instances = make([dynamic]Instance, 0, 256, allocator),
	}
	// Each document's order and slot, the lowest order first.
	order := make([dynamic][2]int, 0, MAX_DOCUMENTS, context.temp_allocator)
	for &d, i in s.documents {
		if d.used && d.built && len(d.nodes) > 0 && d.nodes[0].shown && (only < 0 || i == only) {
			append(&order, [2]int{int(d.order), i})
		}
	}
	slice.stable_sort_by(order[:], proc(a, b: [2]int) -> bool {return a[0] < b[0]})
	for entry in order {
		batch_node(s, &b, &s.documents[entry[1]], entry[1], 0, now)
	}
	if b.full && !s.warned_full {
		log.warnf("ui: a frame has more than %d instances, and those past them do not draw", MAX_UI_INSTANCES)
		s.warned_full = true
	}
	return b
}

@(private)
batch_node :: proc(s: ^State, b: ^Batch, d: ^Document, index: int, n: u32, now: f64) {
	node := &d.nodes[n]
	if !node.shown {
		return
	}
	st := &node.style
	alpha := node.alpha
	// The box, with its border, which a fill or a border shows.
	if st.fill.colors[0].a > 0 || st.fill.colors[1].a > 0 || (st.border.width > 0 && st.border.color.a > 0) {
		i := Instance {
			rect     = node.rect,
			clip     = node.clip,
			radii    = st.radius * s.scale,
			fill     = pack(st.fill.colors[0], alpha),
			fill_end = pack(st.fill.colors[1], alpha),
			border   = pack(st.border.color, alpha),
			kind     = INSTANCE_RECT,
			width    = st.border.width * s.scale,
		}
		if st.fill.gradient {
			i.kind |= INSTANCE_GRADIENT
			i.gradient = gradient_of(node.rect, st.fill.angle)
		}
		push(b, i)
	}
	batch_image(s, b, node, alpha)
	if node.text.ok {
		batch_text(s, b, d, index, n, now)
	} else if (node.element == .Text || node.element == .Field) && st.font != {} {
		b.waiting = true
	}
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		batch_node(s, b, d, index, c, now)
	}
}

// gradient_of is the vector that a gradient at an angle runs along over a rectangle: its direction, over how far the
// rectangle reaches along it, so that its corners are at 0 and 1.
gradient_of :: proc(rect: [4]f32, angle: f32) -> [2]f32 {
	a := angle * math.RAD_PER_DEG
	dir := [2]f32{math.cos(a), math.sin(a)}
	extent := abs((rect[2] - rect[0]) * dir.x) + abs((rect[3] - rect[1]) * dir.y)
	return extent > 0 ? dir / extent : {}
}

// batch_image draws a node's image: one instance, or nine for a nine-slice, whose corners keep their size.
@(private)
batch_image :: proc(s: ^State, b: ^Batch, node: ^Node, alpha: f32) {
	st := &node.style
	if st.image == {} || s.residency == nil {
		return
	}
	t, ready := render.resident_texture(s.residency, st.image)
	if !ready || t.size.x == 0 || t.size.y == 0 {
		b.waiting = true
		return
	}
	base := Instance {
		clip    = node.clip,
		fill    = pack(st.tint, alpha),
		kind    = INSTANCE_IMAGE,
		texture = gpu.read_index(t.texture),
	}
	if st.slice == {} {
		i := base
		i.rect = node.rect
		i.radii = st.radius * s.scale
		i.uv = {0, 0, 1, 1}
		push(b, i)
		return
	}
	for cell in nine_slice(node.rect, st.slice, s.scale, {f32(t.size.x), f32(t.size.y)}) {
		i := base
		i.rect, i.uv = cell.rect, cell.uv
		push(b, i)
	}
}

Slice_Cell :: struct {
	rect, uv: [4]f32,
}

// nine_slice cuts a rectangle into a nine-slice's cells: its margins, top, right, bottom and left in the texture's
// texels, keep their size at the UI scale in the corners, and the edges and the middle stretch.
nine_slice :: proc(rect: [4]f32, margins: [4]f32, scale: f32, texture: [2]f32) -> (cells: [9]Slice_Cell) {
	m := margins * scale
	xs := [4]f32{rect[0], rect[0] + m[3], rect[2] - m[1], rect[2]}
	ys := [4]f32{rect[1], rect[1] + m[0], rect[3] - m[2], rect[3]}
	us := [4]f32{0, margins[3] / texture.x, 1 - margins[1] / texture.x, 1}
	vs := [4]f32{0, margins[0] / texture.y, 1 - margins[2] / texture.y, 1}
	for y in 0 ..< 3 {
		for x in 0 ..< 3 {
			cells[y * 3 + x] = {{xs[x], ys[y], xs[x + 1], ys[y + 1]}, {us[x], vs[y], us[x + 1], vs[y + 1]}}
		}
	}
	return
}

// batch_text draws a node's glyphs on their lines, and a field's selection, composition and caret.
@(private)
batch_text :: proc(s: ^State, b: ^Batch, d: ^Document, index: int, n: u32, now: f64) {
	node := &d.nodes[n]
	st := &node.style
	text := node.text
	font, ok := font_of(s, text.font)
	if !ok || s.residency == nil {
		b.waiting = true
		return
	}
	atlas, ready := render.resident_texture(s.residency, font.blob.atlas)
	if !ready {
		b.waiting = true
		return
	}
	alpha := node.alpha * (text.placeholder ? PLACEHOLDER_ALPHA : 1)
	content := [4]f32 {
		node.rect[0] + st.padding[3] * s.scale,
		node.rect[1] + st.padding[0] * s.scale,
		node.rect[2] - st.padding[1] * s.scale,
		node.rect[3] - st.padding[2] * s.scale,
	}
	clip := node.clip
	scroll: f32
	editing := false
	if node.element == .Field {
		clip = intersect(node.child_clip, content)
		if focus_d, focus_n, focused := resolve(s, s.input.focus); focused && focus_d == d && focus_n == n && s.input.editing {
			editing = true
			// The field scrolls to keep its caret in view.
			x := caret_x(d, text, s.input.caret)
			width := content[2] - content[0]
			if x - s.input.scroll > width - CARET_WIDTH * s.scale {
				s.input.scroll = x - width + CARET_WIDTH * s.scale
			} else if x < s.input.scroll {
				s.input.scroll = x
			}
			scroll = s.input.scroll
		}
	}
	// A line's glyphs are placed at its alignment, its baseline on a whole pixel.
	room := content[2] - content[0]
	range := max(font.blob.range * text.px / font.blob.em_size, 1)
	atlas_size := [2]f32{f32(font.blob.atlas_size.x), f32(font.blob.atlas_size.y)}
	color := pack(st.color, alpha)
	for line, l in d.lines[text.lines.first:][:text.lines.count] {
		x0 := content[0] - scroll
		switch st.text_align {
		case .Start:
		case .Center:
			x0 += math.round((room - line.width) * 0.5)
		case .End:
			x0 += room - line.width
		}
		top := content[1] + f32(l) * text.line
		baseline := math.round(top + text.baseline)
		if editing && l == 0 {
			batch_selection(s, b, d, text, x0, top, clip, st.color, alpha)
		}
		for g in d.glyphs[line.glyphs.first:][:line.glyphs.count] {
			if .Hard_Break in g.flags {
				continue
			}
			cell, found := format.font_find_glyph(font.data, font.blob, u32(g.id))
			if !found || cell.rect.z == 0 {
				continue
			}
			pen := [2]f32{x0 + g.x + g.offset.x, baseline - g.offset.y}
			push(
				b,
				{
					rect = {pen.x + cell.plane[0] * text.px, pen.y - cell.plane[3] * text.px, pen.x + cell.plane[2] * text.px, pen.y - cell.plane[1] * text.px},
					clip = clip,
					uv = {f32(cell.rect.x) / atlas_size.x, f32(cell.rect.y) / atlas_size.y, f32(cell.rect.x + cell.rect.z) / atlas_size.x, f32(cell.rect.y + cell.rect.w) / atlas_size.y},
					fill = color,
					kind = INSTANCE_GLYPH,
					texture = gpu.read_index(atlas.texture),
					width = range,
				},
			)
		}
		if editing && l == 0 {
			batch_caret(s, b, d, text, x0, top, clip, st.color, alpha, now)
		}
	}
}

// batch_selection draws the selection behind a field's text.
@(private)
batch_selection :: proc(s: ^State, b: ^Batch, d: ^Document, text: Node_Text, x0, top: f32, clip: [4]f32, color: format.Ui_Color, alpha: f32) {
	if s.input.caret == s.input.anchor || text.placeholder {
		return
	}
	from := caret_x(d, text, min(s.input.caret, s.input.anchor))
	to := caret_x(d, text, max(s.input.caret, s.input.anchor))
	push(b, {rect = {x0 + from, top, x0 + to, top + text.line}, clip = clip, fill = pack(color, alpha * SELECTION_ALPHA), fill_end = pack(color, alpha * SELECTION_ALPHA), kind = INSTANCE_RECT})
}

// batch_caret draws a field's caret, blinking, and the IME's composition at it, underlined, as it is not text yet.
@(private)
batch_caret :: proc(s: ^State, b: ^Batch, d: ^Document, text: Node_Text, x0, top: f32, clip: [4]f32, color: format.Ui_Color, alpha: f32, now: f64) {
	x := text.placeholder ? 0 : caret_x(d, text, s.input.caret)
	if s.input.composition != "" {
		// The composition is shaped with the field's font after the caret; its width marks the underline.
		width := f32(len(s.input.composition)) * text.px * 0.5
		if font, ok := font_of(s, text.font); ok {
			tf := begin_text(s)
			first := len(d.glyphs)
			glyphs, w := shape_text(tf, d, font, s.input.composition, text.px)
			width = w
			atlas, ready := render.resident_texture(s.residency, font.blob.atlas)
			baseline := math.round(top + text.baseline)
			pen := x0 + x
			atlas_size := [2]f32{f32(font.blob.atlas_size.x), f32(font.blob.atlas_size.y)}
			for g in d.glyphs[glyphs.first:][:glyphs.count] {
				cell, found := format.font_find_glyph(font.data, font.blob, u32(g.id))
				if found && ready && cell.rect.z > 0 {
					push(
						b,
						{
							rect = {pen + g.offset.x + cell.plane[0] * text.px, baseline - cell.plane[3] * text.px, pen + g.offset.x + cell.plane[2] * text.px, baseline - cell.plane[1] * text.px},
							clip = clip,
							uv = {f32(cell.rect.x) / atlas_size.x, f32(cell.rect.y) / atlas_size.y, f32(cell.rect.x + cell.rect.z) / atlas_size.x, f32(cell.rect.y + cell.rect.w) / atlas_size.y},
							fill = pack(color, alpha),
							kind = INSTANCE_GLYPH,
							texture = gpu.read_index(atlas.texture),
							width = max(font.blob.range * text.px / font.blob.em_size, 1),
						},
					)
				}
				pen += g.advance
			}
			resize(&d.glyphs, first)
		}
		underline := math.round(top + text.line - s.scale)
		push(b, {rect = {x0 + x, underline, x0 + x + width, underline + max(math.round(s.scale), 1)}, clip = clip, fill = pack(color, alpha), fill_end = pack(color, alpha), kind = INSTANCE_RECT})
		return
	}
	if math.mod(now - s.input.caret_time, CARET_BLINK) > CARET_BLINK * 0.5 {
		return
	}
	caret := math.round(x0 + x)
	push(b, {rect = {caret, top, caret + max(CARET_WIDTH * s.scale, 1), top + text.line}, clip = clip, fill = pack(color, alpha), fill_end = pack(color, alpha), kind = INSTANCE_RECT})
}
