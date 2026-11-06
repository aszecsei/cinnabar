package ui

import "core:math"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/render"

// layout lays out every document that shows, at the UI layer's size, which sets the UI scale (see
// docs/ui/design.md#layout). It runs each frame after scripts, so what they set shows in the same frame.
layout :: proc(s: ^State, size: [2]f32) {
	// Temporary memory here is the frame's, which the platform frees each frame.
	context.temp_allocator = s.platform.frame_allocator
	s.size = size
	s.scale = max(size.y / REFERENCE_HEIGHT, MIN_SCALE) * s.scale_factor
	tf := begin_text(s)
	for &d, i in s.documents {
		if d.used && d.built && len(d.nodes) > 0 {
			layout_document(s, tf, &d, i)
		}
	}
}

@(private)
layout_document :: proc(s: ^State, tf: Text_Frame, d: ^Document, index: int) {
	clear(&d.glyphs)
	clear(&d.lines)
	style_tree(s, d, index, 0, nil)
	if !d.visible {
		d.nodes[0].shown = false
	}
	if !d.nodes[0].shown {
		return
	}
	measure_tree(s, tf, d, 0)
	fit_tree(s, d, 0, 0)
	root := &d.nodes[0]
	root.size = s.size
	resolve_tree(s, d, 0, 0)
	wrap_tree(s, d, 0)
	fit_tree(s, d, 0, 1)
	resolve_tree(s, d, 0, 1)
	everything := [4]f32{0, 0, s.size.x, s.size.y}
	root.clip = everything
	place_tree(s, d, 0, everything)
}

// style_tree runs the cascade on a node and its subtree, and works out which of them show and which take input.
@(private)
style_tree :: proc(s: ^State, d: ^Document, index: int, n: u32, parent: ^Node) {
	node := &d.nodes[n]
	parent_style := parent != nil ? &parent.style : nil
	node.style = cascade(d, n, parent_style, {})
	if states := node_states(s, index, d, n); states != {} {
		node.style = cascade(d, n, parent_style, states)
	}
	node.shown = node.style.visible && .Removed not_in node.flags && (parent == nil || parent.shown)
	node.disabled = node.style.disabled || (parent != nil && parent.disabled)
	node.alpha = node.style.opacity * (parent != nil ? parent.alpha : 1)
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		style_tree(s, d, index, c, &d.nodes[n])
	}
}

@(private)
measure_tree :: proc(s: ^State, tf: Text_Frame, d: ^Document, n: u32) {
	if !d.nodes[n].shown {
		return
	}
	measure_text(s, tf, d, n)
	for c := d.nodes[n].first_child; c != NONE; c = d.nodes[c].next_sibling {
		measure_tree(s, tf, d, c)
	}
}

// wrap_tree breaks each text into lines at the width that its node resolved to.
@(private)
wrap_tree :: proc(s: ^State, d: ^Document, n: u32) {
	node := &d.nodes[n]
	if !node.shown {
		return
	}
	if node.text.ok {
		width := node.size.x - (node.style.padding[1] + node.style.padding[3]) * s.scale
		wrap(d, &node.text, width, node.style.wrap)
	}
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		wrap_tree(s, d, c)
	}
}

// main_axis is the axis that a node lays its children out along, or -1 for a stack.
@(private)
main_axis :: proc(st: ^Style) -> int {
	switch st.direction {
	case .Row:
		return 0
	case .Column:
		return 1
	case .Stack:
	}
	return -1
}

@(private)
padding_of :: proc(s: ^State, st: ^Style, axis: int) -> f32 {
	return (axis == 0 ? st.padding[1] + st.padding[3] : st.padding[0] + st.padding[2]) * s.scale
}

@(private)
length_on :: proc(st: ^Style, axis: int) -> (size, low, high: format.Ui_Length) {
	if axis == 0 {
		return st.width, st.min_width, st.max_width
	}
	return st.height, st.min_height, st.max_height
}

// resolve_length is a length in pixels in a parent's content of a size, or ok false for fit and fill.
@(private)
resolve_length :: proc(s: ^State, l: format.Ui_Length, content: f32) -> (px: f32, ok: bool) {
	#partial switch l.unit {
	case .Px:
		return l.value >= MAX_SIZE ? MAX_SIZE : l.value * s.scale, true
	case .Percent:
		return l.value * 0.01 * max(content, 0), true
	}
	return
}

@(private)
clamp_size :: proc(s: ^State, st: ^Style, axis: int, size, content: f32) -> f32 {
	_, low, high := length_on(st, axis)
	lo := resolve_length(s, low, content) or_else 0
	hi := resolve_length(s, high, content) or_else MAX_SIZE
	return max(min(size, hi), lo)
}

// natural_image_size is the size of a node's image at the UI scale, once it is resident.
@(private)
natural_image_size :: proc(s: ^State, st: ^Style) -> (size: [2]f32, ok: bool) {
	if st.image == {} || s.residency == nil {
		return
	}
	t, ready := render.resident_texture(s.residency, st.image)
	if !ready {
		return
	}
	return {f32(t.size.x), f32(t.size.y)} * s.scale, true
}

// fit_tree works out, after its children, the size that each node's content needs along an axis: its fit.
@(private)
fit_tree :: proc(s: ^State, d: ^Document, n: u32, axis: int) {
	node := &d.nodes[n]
	if !node.shown {
		return
	}
	st := &node.style
	content: f32
	children := 0
	along := main_axis(st) == axis
	gap := st.gap * s.scale
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		fit_tree(s, d, c, axis)
		child := &d.nodes[c]
		if !child.shown {
			continue
		}
		size, _, _ := length_on(&child.style, axis)
		part := child.fit[axis]
		if size.unit == .Px {
			part = clamp_size(s, &child.style, axis, size.value * s.scale, 0)
		} else if size.unit == .Percent {
			part = 0
		}
		if along {
			content += part + (children > 0 ? gap : 0)
		} else {
			content = max(content, part)
		}
		children += 1
	}
	if node.text.ok {
		if axis == 0 {
			content = max(content, node.text.width)
		} else {
			lines := max(node.text.lines.count, 1)
			content = max(content, f32(lines) * node.text.line)
		}
	}
	if natural, ok := natural_image_size(s, st); ok && node.element == .Image {
		if axis == 0 || natural.x <= 0 {
			content = max(content, natural[axis])
		} else {
			// An image keeps its shape at the width that it resolved to.
			content = max(content, natural.y * (node.size.x - padding_of(s, st, 0)) / natural.x)
		}
	}
	node.fit[axis] = clamp_size(s, st, axis, content + padding_of(s, st, axis), 0)
}

// resolve_tree gives each child of a node its size along an axis, from the node's, which is resolved.
@(private)
resolve_tree :: proc(s: ^State, d: ^Document, n: u32, axis: int) {
	node := &d.nodes[n]
	if !node.shown {
		return
	}
	st := &node.style
	content := max(node.size[axis] - padding_of(s, st, axis), 0)
	if main_axis(st) == axis {
		resolve_main(s, d, node, axis, content)
	} else {
		for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
			child := &d.nodes[c]
			if !child.shown {
				continue
			}
			size, _, _ := length_on(&child.style, axis)
			px, fixed := resolve_length(s, size, content)
			if !fixed {
				stretch := size.unit == .Fill
				if size.unit == .Fit {
					stretch = main_axis(st) < 0 ? child.style.anchor == .Fill : st.cross == .Stretch
				}
				px = stretch ? content : child.fit[axis]
			}
			child.size[axis] = clamp_size(s, &child.style, axis, px, content)
		}
	}
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		resolve_tree(s, d, c, axis)
	}
}

// resolve_main sizes a row's or a column's children along it: fixed, percent and fit sizes first, then what is left
// shared among the fills by weight. A fill that its min or max stops takes that size, and the rest is shared again.
@(private)
resolve_main :: proc(s: ^State, d: ^Document, node: ^Node, axis: int, content: f32) {
	gap := node.style.gap * s.scale
	free := content
	weight: f32
	count := 0
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		child := &d.nodes[c]
		if !child.shown {
			continue
		}
		if count > 0 {
			free -= gap
		}
		count += 1
		size, _, _ := length_on(&child.style, axis)
		if size.unit == .Fill {
			weight += size.value
			child.size[axis] = -1
			continue
		}
		px, fixed := resolve_length(s, size, content)
		if !fixed {
			px = child.fit[axis]
		}
		child.size[axis] = clamp_size(s, &child.style, axis, px, content)
		free -= child.size[axis]
	}
	// Each pass freezes the fills that their limits stop, until the shares fit them all.
	for weight > 0 {
		frozen := false
		share := max(free, 0) / weight
		for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
			child := &d.nodes[c]
			if !child.shown || child.size[axis] >= 0 {
				continue
			}
			size, _, _ := length_on(&child.style, axis)
			want := share * size.value
			got := clamp_size(s, &child.style, axis, want, content)
			if got != want {
				child.size[axis] = got
				free -= got
				weight -= size.value
				frozen = true
			}
		}
		if frozen {
			continue
		}
		for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
			child := &d.nodes[c]
			if child.shown && child.size[axis] < 0 {
				size, _, _ := length_on(&child.style, axis)
				child.size[axis] = share * size.value
			}
		}
		break
	}
}

@(private)
snap :: proc(r: [4]f32) -> [4]f32 {
	return {math.round(r[0]), math.round(r[1]), math.round(r[2]), math.round(r[3])}
}

@(private)
intersect :: proc(a, b: [4]f32) -> [4]f32 {
	return {max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])}
}

// place_tree gives a node its rectangle, each edge on whole pixels, and places its children in its content.
@(private)
place_tree :: proc(s: ^State, d: ^Document, n: u32, rect: [4]f32) {
	node := &d.nodes[n]
	st := &node.style
	node.rect = snap(rect)
	if node.parent != NONE {
		node.clip = d.nodes[node.parent].child_clip
	}
	node.child_clip = st.clip ? intersect(node.clip, node.rect) : node.clip
	content := [4]f32 {
		rect[0] + st.padding[3] * s.scale,
		rect[1] + st.padding[0] * s.scale,
		rect[2] - st.padding[1] * s.scale,
		rect[3] - st.padding[2] * s.scale,
	}
	axis := main_axis(st)
	if axis < 0 {
		for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
			child := &d.nodes[c]
			if !child.shown {
				continue
			}
			at := anchored(child.style.anchor, content, child.size) + child.style.offset * s.scale
			place_tree(s, d, c, {at.x, at.y, at.x + child.size.x, at.y + child.size.y})
		}
		return
	}
	cross := 1 - axis
	gap := st.gap * s.scale
	total: f32
	count := 0
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		if d.nodes[c].shown {
			total += d.nodes[c].size[axis] + (count > 0 ? gap : 0)
			count += 1
		}
	}
	free := (content[axis + 2] - content[axis]) - total
	cursor := content[axis]
	switch st.align {
	case .Start:
	case .Center:
		cursor += free * 0.5
	case .End:
		cursor += free
	case .Space_Between:
		if count > 1 && free > 0 {
			gap += free / f32(count - 1)
		}
	}
	room := content[cross + 2] - content[cross]
	for c := node.first_child; c != NONE; c = d.nodes[c].next_sibling {
		child := &d.nodes[c]
		if !child.shown {
			continue
		}
		at: [2]f32
		at[axis] = cursor
		at[cross] = content[cross]
		switch st.cross {
		case .Start, .Stretch:
		case .Center:
			at[cross] += (room - child.size[cross]) * 0.5
		case .End:
			at[cross] += room - child.size[cross]
		}
		at += child.style.offset * s.scale
		place_tree(s, d, c, {at.x, at.y, at.x + child.size.x, at.y + child.size.y})
		cursor += child.size[axis] + gap
	}
}

// anchored is where a box of a size goes in a stack's content by its anchor.
@(private)
anchored :: proc(anchor: format.Ui_Anchor, content: [4]f32, size: [2]f32) -> [2]f32 {
	room := [2]f32{content[2] - content[0], content[3] - content[1]} - size
	fraction: [2]f32
	switch anchor {
	case .Top_Left, .Fill:
		fraction = {0, 0}
	case .Top:
		fraction = {0.5, 0}
	case .Top_Right:
		fraction = {1, 0}
	case .Left:
		fraction = {0, 0.5}
	case .Center:
		fraction = {0.5, 0.5}
	case .Right:
		fraction = {1, 0.5}
	case .Bottom_Left:
		fraction = {0, 1}
	case .Bottom:
		fraction = {0.5, 1}
	case .Bottom_Right:
		fraction = {1, 1}
	}
	return {content[0], content[1]} + room * fraction
}
