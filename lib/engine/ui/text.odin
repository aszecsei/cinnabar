package ui

import "core:c"
import "core:log"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import kbts "vendor:kb_text_shape"

import format "cinnabar:engine/asset/format"

// The memory that a frame's shaping takes: kb_text_shape's context, which holds a text's glyphs while it shapes it.
SHAPER_MEMORY :: 1 << 20

// Font_Shaper is kb_text_shape's font, placed from a font blob's file into the slot's memory. It points into the blob,
// so it is placed again when the blob changes, and into kb_text_shape's code, so a code reload drops it.
Font_Shaper :: struct {
	font: kbts.font,
}

Glyph_Flag :: enum u8 {
	// A line may break before the glyph: it is the first after spaces or a hyphen.
	Break_Before,
	// The glyph is a space, which a line's width leaves out at its end.
	Space,
	// The glyph is a line break, which ends its line and draws nothing.
	Hard_Break,
}

// Glyph is a shaped glyph of a node's text, in pixels.
Glyph :: struct {
	id:      u16,
	flags:   bit_set[Glyph_Flag;u8],
	// The byte of the text that its cluster starts at.
	cluster: u32,
	advance: f32,
	offset:  [2]f32,
	// Where its pen is from its line's start.
	x:       f32,
}

// Line is a line of a node's text after wrapping: its glyphs and its width without its trailing spaces.
Line :: struct {
	glyphs: Range,
	width:  f32,
}

// Node_Text is a node's text this frame, in pixels: its font, its size, its line metrics, its glyphs and lines in the
// document's arrays, and its length in bytes. ok is false while it has no font to draw with.
Node_Text :: struct {
	ok:        bool,
	font:      format.Guid,
	px:        f32,
	ascender:  f32,
	// The line's height, with its line_height, and its baseline from the line's top: half of the room that
	// line_height adds, above the ascender.
	line:      f32,
	baseline:  f32,
	glyphs:    Range,
	lines:     Range,
	length:    u32,
	// Its width on one line.
	width:     f32,
	// The text is the field's placeholder.
	placeholder: bool,
}

// Text_Frame is a frame's shaping context, in frame memory.
@(private)
Text_Frame :: struct {
	ctx: ^kbts.shape_context,
}

@(private)
begin_text :: proc(s: ^State) -> Text_Frame {
	memory, err := mem.alloc_bytes_non_zeroed(SHAPER_MEMORY, 16, s.platform.frame_allocator)
	if err != nil {
		return {}
	}
	return {kbts.PlaceShapeContextFixedMemory(memory)}
}

// place_shaper places kb_text_shape's font from a font blob's file into memory of the slot's.
@(private)
place_shaper :: proc(s: ^State, slot: ^Font_Slot, data: []byte, blob: ^format.Font_Blob) -> bool {
	file := format.blob_bytes(data, blob.font_data)
	state: kbts.load_font_state
	scratch_size, output_size, err := kbts.LoadFont(&slot.shaper.font, &state, file, c.int(blob.index))
	if err != .NONE && err != .NEED_TO_CREATE_BLOB {
		if !slot.warned {
			log.errorf("ui: kb_text_shape cannot read font %v: %v", slot.guid, err)
			slot.warned = true
		}
		return false
	}
	scratch, _ := mem.alloc_bytes_non_zeroed(int(scratch_size), 16, s.platform.frame_allocator)
	memory, alloc_err := mem.alloc_bytes_non_zeroed(int(output_size), 16, s.allocator)
	if alloc_err != nil {
		return false
	}
	if place_err := kbts.PlaceBlob(&slot.shaper.font, &state, raw_data(scratch), raw_data(memory)); place_err != .NONE {
		mem.free_bytes(memory, s.allocator)
		if !slot.warned {
			log.errorf("ui: kb_text_shape cannot place font %v: %v", slot.guid, place_err)
			slot.warned = true
		}
		return false
	}
	slot.memory = memory
	slot.placed = true
	return true
}

@(private)
drop_shaper :: proc(s: ^State, slot: ^Font_Slot) {
	if slot.memory != nil {
		mem.free_bytes(slot.memory, s.allocator)
	}
	slot.memory = nil
	slot.placed = false
	slot.shaper = {}
}

// expand gives a text with its bindings' values in place of each {name}, and a brace for each {{ and }}. A binding
// that no script set is empty.
expand :: proc(d: ^Document, text: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(text, '{') < 0 && strings.index_byte(text, '}') < 0 {
		return text
	}
	b := strings.builder_make(allocator)
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		switch c {
		case '{':
			if i + 1 < len(text) && text[i + 1] == '{' {
				strings.write_byte(&b, '{')
				i += 1
				continue
			}
			end := strings.index_byte(text[i:], '}')
			if end < 0 {
				strings.write_string(&b, text[i:])
				return strings.to_string(b)
			}
			name := text[i + 1:][:end - 1]
			for binding in d.bindings {
				if binding.name == name {
					strings.write_string(&b, binding.value)
					break
				}
			}
			i += end
		case '}':
			strings.write_byte(&b, '}')
			if i + 1 < len(text) && text[i + 1] == '}' {
				i += 1
			}
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// shape_text shapes a text with a font at a size in pixels, and appends its glyphs to the document's, each with its
// cluster's byte and where a line may break. It gives the text's width on one line.
@(private)
shape_text :: proc(tf: Text_Frame, d: ^Document, font: Font_Info, text: string, px: f32) -> (glyphs: Range, width: f32) {
	glyphs.first = u32(len(d.glyphs))
	if tf.ctx == nil || text == "" {
		return
	}
	// The byte that each code point starts at, as kb_text_shape gives a glyph its first code point's index.
	starts := make([dynamic]u32, 0, len(text) + 1, context.temp_allocator)
	for i := 0; i < len(text); {
		_, size := utf8.decode_rune_in_string(text[i:])
		append(&starts, u32(i))
		i += size
	}
	append(&starts, u32(len(text)))
	scale := px / f32(font.blob.units_per_em)
	_ = kbts.ShapePushFont(tf.ctx, &font.slot.shaper.font)
	kbts.ShapeBegin(tf.ctx, .DONT_KNOW, .DONT_KNOW)
	kbts.ShapeUtf8(tf.ctx, text, .CODEPOINT_INDEX)
	kbts.ShapeEnd(tf.ctx)
	for run in kbts.ShapeRun(tf.ctx) {
		run := run
		for g in kbts.GlyphIteratorNext(&run.Glyphs) {
			index := clamp(int(g.UserIdOrCodepointIndex), 0, len(starts) - 1)
			cluster := starts[index]
			glyph := Glyph {
				id      = g.Id,
				cluster = cluster,
				advance = f32(g.AdvanceX) * scale,
				offset  = {f32(g.OffsetX) * scale, f32(g.OffsetY) * scale},
			}
			if int(cluster) < len(text) {
				switch text[cluster] {
				case ' ', '\t':
					glyph.flags += {.Space}
				case '\n':
					glyph.flags += {.Hard_Break}
					glyph.advance = 0
				}
				// After spaces or a hyphen, a line may break.
				if cluster > 0 && text[cluster] != ' ' && (text[cluster - 1] == ' ' || text[cluster - 1] == '-' || text[cluster - 1] == '\t') {
					glyph.flags += {.Break_Before}
				}
			}
			append(&d.glyphs, glyph)
			width += glyph.advance
		}
	}
	if err := kbts.ShapeError(tf.ctx); err != .NONE {
		log.warnf("ui: kb_text_shape could not shape %q: %v", text, err)
	}
	_ = kbts.ShapePopFont(tf.ctx)
	glyphs.count = u32(len(d.glyphs)) - glyphs.first
	return
}

// wrap breaks a node's glyphs into lines no wider than width where they may break, or into lines only at line breaks
// without wrap, and sets each glyph's place on its line.
@(private)
wrap :: proc(d: ^Document, text: ^Node_Text, width: f32, wrapping: bool) {
	text.lines = {u32(len(d.lines)), 0}
	glyphs := d.glyphs[text.glyphs.first:][:text.glyphs.count]
	emit :: proc(d: ^Document, text: ^Node_Text, glyphs: []Glyph, first, end: int) {
		x: f32
		visible: f32
		for &g in glyphs[first:end] {
			g.x = x
			x += g.advance
			if .Space not_in g.flags && .Hard_Break not_in g.flags {
				visible = x
			}
		}
		append(&d.lines, Line{{text.glyphs.first + u32(first), u32(end - first)}, visible})
		text.lines.count += 1
	}
	i := 0
	for i < len(glyphs) || text.lines.count == 0 {
		begin := i
		x: f32
		last_break := -1
		hard := false
		for i < len(glyphs) {
			g := glyphs[i]
			if .Hard_Break in g.flags {
				hard = true
				break
			}
			if wrapping && i > begin && .Break_Before in g.flags {
				last_break = i
			}
			if wrapping && x + g.advance > width && last_break > begin && .Space not_in g.flags {
				i = last_break
				break
			}
			x += g.advance
			i += 1
		}
		emit(d, text, glyphs, begin, i)
		if hard {
			i += 1
			if i == len(glyphs) {
				emit(d, text, glyphs, i, i)
			}
		}
		if begin == i && !hard {
			break
		}
	}
}

// measure_text shapes a node's text, the field's value or its placeholder, and sets its metrics, before layout wraps it.
@(private)
measure_text :: proc(s: ^State, tf: Text_Frame, d: ^Document, n: u32) {
	node := &d.nodes[n]
	st := &node.style
	node.text = {}
	text := st.text
	placeholder := false
	if node.element == .Field && text == "" {
		text, placeholder = st.placeholder, true
	}
	if node.element != .Text && node.element != .Field {
		return
	}
	font, ok := font_of(s, st.font)
	if !ok {
		return
	}
	px := st.size * s.scale
	expanded := node.element == .Field && !placeholder ? text : expand(d, text, s.platform.frame_allocator)
	glyphs, width := shape_text(tf, d, font, expanded, px)
	ascender, descender, gap := font.blob.ascender * px, font.blob.descender * px, font.blob.line_gap * px
	line := (ascender - descender + gap) * st.line_height
	node.text = {
		ok          = true,
		font        = st.font,
		px          = px,
		ascender    = ascender,
		line        = line,
		baseline    = (line - (ascender - descender)) * 0.5 + ascender,
		glyphs      = glyphs,
		length      = u32(len(expanded)),
		width       = width,
		placeholder = placeholder,
	}
}

// caret_x is where a caret at a byte of a node's text is from its line's start: at the first glyph whose cluster starts
// there or after, so a caret in a ligature goes to its end.
caret_x :: proc(d: ^Document, text: Node_Text, at: u32) -> f32 {
	if text.lines.count == 0 {
		return 0
	}
	line := d.lines[text.lines.first]
	for g in d.glyphs[line.glyphs.first:][:line.glyphs.count] {
		if g.cluster >= at {
			return g.x
		}
	}
	return line.glyphs.count > 0 ? d.glyphs[line.glyphs.first + line.glyphs.count - 1].x + d.glyphs[line.glyphs.first + line.glyphs.count - 1].advance : 0
}

// caret_at is the byte of a node's first line that a point x from the line's start is nearest to, at a cluster's edge.
caret_at :: proc(d: ^Document, text: Node_Text, x: f32) -> u32 {
	if text.lines.count == 0 || text.placeholder {
		return 0
	}
	line := d.lines[text.lines.first]
	for g in d.glyphs[line.glyphs.first:][:line.glyphs.count] {
		if x < g.x + g.advance * 0.5 {
			return g.cluster
		}
	}
	return text.length
}
