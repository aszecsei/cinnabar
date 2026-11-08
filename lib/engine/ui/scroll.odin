package ui

import "core:math"

import "cinnabar:core"
import format "cinnabar:engine/asset/format"

// Scroll boxes (see docs/ui/design.md#scrolling): a row or column with overflow="scroll" lays its children out at what
// they need along it, cuts them to its rectangle, and scrolls them by an offset that the wheel, the right stick, Page Up
// and Page Down, its scroll bar and the focus move. Its bar's track and thumb take the document's styles of these names.
TRACK_STYLE :: "scroll_track"
THUMB_STYLE :: "scroll_thumb"

// Pixels at a UI scale of 1 that a notch of the wheel scrolls, and that the right stick scrolls a second, pushed all the
// way.
WHEEL_STEP :: 60
STICK_SCROLL :: 1200
// The right stick's dt is at most this, so a long frame does not throw a list to its end.
MAX_SCROLL_DT :: 0.1
// A thumb is at least this long, in pixels at a UI scale of 1, so it stays something to grab.
MIN_THUMB :: 24
// A bar's track without a style: this thick, this far in from the box's edges, and its corners and its thumb's this
// round. Its thumb is this color.
DEFAULT_TRACK_WIDTH :: 6
DEFAULT_TRACK_INSET :: 2
DEFAULT_BAR_RADIUS :: 3
DEFAULT_THUMB_COLOR :: format.Ui_Color{255, 255, 255, 0x60}

Bar_Part :: enum u8 {
	None,
	Track,
	Thumb,
}

// scroll_axis is the axis that a node scrolls along, or -1: a row's or column's direction when its overflow scrolls.
@(private)
scroll_axis :: proc(st: ^Style) -> int {
	return st.overflow == .Scroll ? main_axis(st) : -1
}

// view_length is how much of a scroll box's content shows along its axis: its rectangle inside its padding.
@(private)
view_length :: proc(s: ^State, node: ^Node, axis: int) -> f32 {
	return max(node.rect[axis + 2] - node.rect[axis] - padding_of(s, &node.style, axis), 0)
}

// Bar is a scroll box's bar as it shows this frame: its track and thumb with their styles, and where the thumb can go:
// from start, along travel.
@(private)
Bar :: struct {
	track, thumb:             [4]f32,
	track_style, thumb_style: Style,
	start, travel:            f32,
}

// bar_states are the states of a box's bar: hovered while the pointer is over the box, its thumb pressed while it is
// dragged, and disabled with the box.
@(private)
bar_states :: proc(s: ^State, d: ^Document, n: u32, part: Bar_Part) -> bit_set[format.Ui_State] {
	if d.nodes[n].disabled {
		return {.Disabled}
	}
	here := ref(s, d, n)
	states: bit_set[format.Ui_State]
	if s.input.scroll_hovered == here {
		states += {.Hover}
	}
	if part == .Thumb && s.input.drag == here {
		states += {.Press}
	}
	return states
}

// bar_style is a part of a box's bar's style: its defaults, then the document's style for it and its variants.
@(private)
bar_style :: proc(s: ^State, d: ^Document, n: u32, part: Bar_Part) -> Style {
	st := default_style(.Box)
	st.radius = DEFAULT_BAR_RADIUS
	style := d.thumb_style
	if part == .Track {
		st.width = {.Px, DEFAULT_TRACK_WIDTH}
		st.padding = DEFAULT_TRACK_INSET
		style = d.track_style
	} else {
		st.fill = {colors = {DEFAULT_THUMB_COLOR, DEFAULT_THUMB_COLOR}}
	}
	if style != format.UI_NONE && int(style) < len(d.styles) {
		apply_styles(&st, d, {style}, bar_states(s, d, n, part))
	}
	return st
}

// bar_of is a node's scroll bar, if it shows: the node scrolls, has more than it shows, and its scroll_bar is on. The
// track runs along the box's end edge, a column's right and a row's bottom, as thick as its width and in from the
// box's edges by its padding. The thumb is in the track, in by its own padding, as long as the part of the content
// that shows.
@(private)
bar_of :: proc(s: ^State, d: ^Document, n: u32) -> (bar: Bar, ok: bool) {
	node := &d.nodes[n]
	axis := scroll_axis(&node.style)
	if axis < 0 || !node.style.scroll_bar || node.scroll_max <= 0 {
		return
	}
	bar.track_style = bar_style(s, d, n, .Track)
	bar.thumb_style = bar_style(s, d, n, .Thumb)
	r := node.rect
	cross := 1 - axis
	thickness := f32(DEFAULT_TRACK_WIDTH) * s.scale
	if px, fixed := resolve_length(s, bar.track_style.width, r[cross + 2] - r[cross]); fixed {
		thickness = px
	}
	pad := bar.track_style.padding * s.scale
	if axis == 1 {
		bar.track = {r[2] - pad[1] - thickness, r[1] + pad[0], r[2] - pad[1], r[3] - pad[2]}
	} else {
		bar.track = {r[0] + pad[3], r[3] - pad[2] - thickness, r[2] - pad[1], r[3] - pad[2]}
	}
	t, inset := bar.track, bar.thumb_style.padding * s.scale
	inner := [4]f32{t[0] + inset[3], t[1] + inset[0], t[2] - inset[1], t[3] - inset[2]}
	length := max(inner[axis + 2] - inner[axis], 0)
	view := view_length(s, node, axis)
	thumb := min(max(length * view / (view + node.scroll_max), MIN_THUMB * s.scale), length)
	bar.start = inner[axis]
	bar.travel = length - thumb
	bar.thumb = inner
	bar.thumb[axis] = bar.start + bar.travel * node.scroll / node.scroll_max
	bar.thumb[axis + 2] = bar.thumb[axis] + thumb
	return bar, true
}

// reveal scrolls the node that the focus has just moved to into view in each scroll box that it is in, the innermost
// first, if it is in this document. It is true if an offset moved, so the document is placed again.
@(private)
reveal :: proc(s: ^State, d: ^Document, index: int) -> bool {
	r := s.input.reveal
	if r.document != i32(index) {
		return false
	}
	s.input.reveal = NO_NODE
	if r.generation != d.generation || int(r.node) >= len(d.nodes) || !d.nodes[r.node].shown {
		return false
	}
	// Where the node is, as the boxes inside each one have scrolled it.
	target := d.nodes[r.node].rect
	moved := false
	for a := d.nodes[r.node].parent; a != NONE; a = d.nodes[a].parent {
		box := &d.nodes[a]
		axis := scroll_axis(&box.style)
		if axis < 0 || box.scroll_max <= 0 {
			continue
		}
		st := &box.style
		low := box.rect[axis] + (axis == 0 ? st.padding[3] : st.padding[0]) * s.scale
		high := box.rect[axis + 2] - (axis == 0 ? st.padding[1] : st.padding[2]) * s.scale
		delta: f32
		if target[axis] < low || target[axis + 2] - target[axis] > high - low {
			delta = target[axis] - low
		} else if target[axis + 2] > high {
			delta = target[axis + 2] - high
		}
		from := math.round(box.scroll)
		to := clamp(from + delta, 0, box.scroll_max)
		if to != box.scroll {
			box.scroll = to
			moved = true
		}
		shift := math.round(to) - from
		target[axis] -= shift
		target[axis + 2] -= shift
	}
	return moved
}

// scroll_chain appends the scroll boxes under a point that have more than they show, each before the boxes in it.
@(private)
scroll_chain :: proc(d: ^Document, n: u32, p: [2]f32, out: ^[dynamic]u32) {
	node := &d.nodes[n]
	if !node.shown {
		return
	}
	if scroll_axis(&node.style) >= 0 && node.scroll_max > 0 && !node.disabled && inside(intersect(node.rect, node.clip), p) {
		append(out, n)
	}
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		scroll_chain(d, c, p, out)
	}
}

// ancestor_chain appends the scroll boxes that a node is in that have more than they show, each before the boxes in it.
@(private)
ancestor_chain :: proc(d: ^Document, n: u32, out: ^[dynamic]u32) {
	first := len(out)
	for a := d.nodes[n].parent; a != NONE; a = d.nodes[a].parent {
		box := &d.nodes[a]
		if scroll_axis(&box.style) >= 0 && box.scroll_max > 0 && !box.disabled {
			append(out, a)
		}
	}
	for i, j := first, len(out) - 1; i < j; i, j = i + 1, j - 1 {
		out[i], out[j] = out[j], out[i]
	}
}

// scroll_by moves the innermost box of a chain that can move: by delta along its axis, and pages of its view. So a
// wheel at the end of a list scrolls the list that it is in. It is true if one moved.
@(private)
scroll_by :: proc(s: ^State, d: ^Document, chain: []u32, delta: [2]f32, pages: f32 = 0) -> bool {
	for i := len(chain) - 1; i >= 0; i -= 1 {
		node := &d.nodes[chain[i]]
		axis := scroll_axis(&node.style)
		if axis < 0 {
			continue
		}
		to := clamp(node.scroll + delta[axis] + pages * view_length(s, node, axis), 0, node.scroll_max)
		if to != node.scroll {
			node.scroll = to
			return true
		}
	}
	return false
}

// press_bar starts dragging a box's thumb, or pages its view toward the pointer on its track.
@(private)
press_bar :: proc(s: ^State, d: ^Document, n: u32, part: Bar_Part, mouse: [2]f32) {
	bar, ok := bar_of(s, d, n)
	if !ok {
		return
	}
	node := &d.nodes[n]
	axis := scroll_axis(&node.style)
	switch part {
	case .None:
	case .Thumb:
		s.input.drag = ref(s, d, n)
		s.input.drag_grab = mouse[axis] - bar.thumb[axis]
	case .Track:
		page := mouse[axis] < bar.thumb[axis] ? f32(-1) : 1
		node.scroll = clamp(node.scroll + page * view_length(s, node, axis), 0, node.scroll_max)
	}
}

// drag_thumb follows the pointer with a dragged thumb, and lets go of it when the button does.
@(private)
drag_thumb :: proc(s: ^State, input: core.Input) {
	d, n, ok := resolve(s, s.input.drag)
	if !ok {
		s.input.drag = NO_NODE
		return
	}
	if bar, shown := bar_of(s, d, n); shown && .Mouse_Left in input.down {
		node := &d.nodes[n]
		axis := scroll_axis(&node.style)
		at := bar.travel > 0 ? (input.mouse_position[axis] - s.input.drag_grab - bar.start) / bar.travel : 0
		node.scroll = clamp(at, 0, 1) * node.scroll_max
	}
	if .Mouse_Left in input.released || .Mouse_Left not_in input.down {
		s.input.drag = NO_NODE
	}
}

// scroll_input moves the scroll boxes by the wheel, over the pointer's, and by the right stick and Page Up and Down, the
// focus's boxes, or else the pointer's. pointer is the document that the pointer is over, or -1. dt is the time since
// the last frame.
@(private)
scroll_input :: proc(s: ^State, input: core.Input, pointer: i32, dt: f32) {
	under := make([dynamic]u32, context.temp_allocator)
	if pointer >= 0 {
		d := &s.documents[pointer]
		scroll_chain(d, 0, input.mouse_position, &under)
		if len(under) > 0 {
			s.input.scroll_hovered = ref(s, d, under[len(under) - 1])
		}
		if input.scroll != 0 {
			step := -input.scroll * WHEEL_STEP * s.scale
			scroll_by(s, d, under[:], {step, step})
		}
	}

	stick: [2]f32
	for p in input.gamepads {
		if p.connected {
			if abs(p.axes[.Right_X]) > abs(stick.x) {
				stick.x = p.axes[.Right_X]
			}
			if abs(p.axes[.Right_Y]) > abs(stick.y) {
				stick.y = p.axes[.Right_Y]
			}
		}
	}
	pages: f32
	if s.input.edit == nil {
		if .Page_Down in input.pressed {
			pages += 1
		}
		if .Page_Up in input.pressed {
			pages -= 1
		}
	}
	if stick == {} && pages == 0 {
		return
	}
	// The stick's up is positive, and scrolls a column back to its start.
	delta := [2]f32{stick.x, -stick.y} * STICK_SCROLL * s.scale * dt
	if d, n, ok := resolve(s, s.input.focus); ok && d.nodes[n].shown {
		chain := make([dynamic]u32, context.temp_allocator)
		ancestor_chain(d, n, &chain)
		if len(chain) > 0 {
			scroll_by(s, d, chain[:], delta, pages)
			return
		}
	}
	if pointer >= 0 {
		scroll_by(s, &s.documents[pointer], under[:], delta, pages)
	}
}
