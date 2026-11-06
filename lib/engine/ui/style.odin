package ui

import format "cinnabar:engine/asset/format"

// The largest size that a box takes, in pixels: what an unset max_width or max_height is.
MAX_SIZE :: f32(1e6)

// Style is what the cascade gives a node: every attribute's value, in the units that its document gives it. Layout
// scales the lengths.
Style :: struct {
	width, height:         format.Ui_Length,
	min_width, max_width:   format.Ui_Length,
	min_height, max_height: format.Ui_Length,
	padding:               [4]f32,
	gap:                   f32,
	direction:             format.Ui_Direction,
	align:                 format.Ui_Align,
	cross:                 format.Ui_Cross,
	anchor:                format.Ui_Anchor,
	offset:                [2]f32,
	visible:               bool,
	clip:                  bool,
	fill:                  format.Ui_Paint,
	radius:                [4]f32,
	border:                format.Ui_Border,
	opacity:               f32,
	image:                 format.Guid,
	tint:                  format.Ui_Color,
	slice:                 [4]f32,
	font:                  format.Guid,
	size:                  f32,
	color:                 format.Ui_Color,
	text_align:            format.Ui_Text_Align,
	line_height:           f32,
	wrap:                  bool,
	text:                  string,
	placeholder:           string,
	max_length:            int,
	focusable:             bool,
	disabled:              bool,
	click:                 string,
	changed:               string,
	submit:                string,
	nav:                   [Direction]string,
	cancel:                string,
	focus:                 string,
	modal:                 bool,
}

Direction :: enum u8 {
	Up,
	Down,
	Left,
	Right,
}

// The default size of text, in pixels at a UI scale of 1, and of a field's width.
DEFAULT_TEXT_SIZE :: 18
DEFAULT_FIELD_WIDTH :: 200

// default_style is an element's style before its attributes: what it is without any.
default_style :: proc(element: format.Ui_Element) -> Style {
	st := Style {
		width       = {.Fit, 0},
		height      = {.Fit, 0},
		max_width   = {.Px, MAX_SIZE},
		max_height  = {.Px, MAX_SIZE},
		visible     = true,
		opacity     = 1,
		tint        = {255, 255, 255, 255},
		size        = DEFAULT_TEXT_SIZE,
		color       = {255, 255, 255, 255},
		line_height = 1,
		wrap        = true,
	}
	#partial switch element {
	case .Row:
		st.direction = .Row
	case .Box, .Column:
		st.direction = .Column
	case .Ui, .Stack, .Template:
		st.direction = .Stack
	case .Button:
		st.direction = .Row
		st.align = .Center
		st.cross = .Center
		st.focusable = true
	case .Field:
		st.width = {.Px, DEFAULT_FIELD_WIDTH}
		st.focusable = true
		st.wrap = false
		st.clip = true
	}
	return st
}

// apply sets a style's attribute to a value. A value of the wrong kind, which the parser does not give, changes nothing.
@(private)
apply :: proc(st: ^Style, attr: format.Ui_Attr, value: format.Ui_Value) {
	switch attr {
	case .Width:
		st.width = value.(format.Ui_Length) or_else st.width
	case .Height:
		st.height = value.(format.Ui_Length) or_else st.height
	case .Min_Width:
		st.min_width = value.(format.Ui_Length) or_else st.min_width
	case .Max_Width:
		st.max_width = value.(format.Ui_Length) or_else st.max_width
	case .Min_Height:
		st.min_height = value.(format.Ui_Length) or_else st.min_height
	case .Max_Height:
		st.max_height = value.(format.Ui_Length) or_else st.max_height
	case .Padding:
		st.padding = ([4]f32)(value.(format.Ui_Edges) or_else format.Ui_Edges(st.padding))
	case .Gap:
		st.gap = value.(f32) or_else st.gap
	case .Direction:
		st.direction = value.(format.Ui_Direction) or_else st.direction
	case .Align:
		st.align = value.(format.Ui_Align) or_else st.align
	case .Cross:
		st.cross = value.(format.Ui_Cross) or_else st.cross
	case .Anchor:
		st.anchor = value.(format.Ui_Anchor) or_else st.anchor
	case .Offset:
		st.offset = ([2]f32)(value.(format.Ui_Vec2) or_else format.Ui_Vec2(st.offset))
	case .Visible:
		st.visible = value.(bool) or_else st.visible
	case .Clip:
		st.clip = value.(bool) or_else st.clip
	case .Fill:
		st.fill = value.(format.Ui_Paint) or_else st.fill
	case .Radius:
		st.radius = ([4]f32)(value.(format.Ui_Edges) or_else format.Ui_Edges(st.radius))
	case .Border:
		st.border = value.(format.Ui_Border) or_else st.border
	case .Opacity:
		st.opacity = value.(f32) or_else st.opacity
	case .Image:
		st.image = value.(format.Guid) or_else st.image
	case .Tint:
		st.tint = value.(format.Ui_Color) or_else st.tint
	case .Slice:
		st.slice = ([4]f32)(value.(format.Ui_Edges) or_else format.Ui_Edges(st.slice))
	case .Font:
		st.font = value.(format.Guid) or_else st.font
	case .Size:
		st.size = value.(f32) or_else st.size
	case .Color:
		st.color = value.(format.Ui_Color) or_else st.color
	case .Text_Align:
		st.text_align = value.(format.Ui_Text_Align) or_else st.text_align
	case .Line_Height:
		st.line_height = value.(f32) or_else st.line_height
	case .Wrap:
		st.wrap = value.(bool) or_else st.wrap
	case .Text:
		st.text = value.(string) or_else st.text
	case .Placeholder:
		st.placeholder = value.(string) or_else st.placeholder
	case .Max_Length:
		st.max_length = int(value.(f32) or_else f32(st.max_length))
	case .Focusable:
		st.focusable = value.(bool) or_else st.focusable
	case .Disabled:
		st.disabled = value.(bool) or_else st.disabled
	case .Click:
		st.click = value.(string) or_else st.click
	case .Changed:
		st.changed = value.(string) or_else st.changed
	case .Submit:
		st.submit = value.(string) or_else st.submit
	case .Nav_Up:
		st.nav[.Up] = value.(string) or_else st.nav[.Up]
	case .Nav_Down:
		st.nav[.Down] = value.(string) or_else st.nav[.Down]
	case .Nav_Left:
		st.nav[.Left] = value.(string) or_else st.nav[.Left]
	case .Nav_Right:
		st.nav[.Right] = value.(string) or_else st.nav[.Right]
	case .Cancel:
		st.cancel = value.(string) or_else st.cancel
	case .Focus:
		st.focus = value.(string) or_else st.focus
	case .Modal:
		st.modal = value.(bool) or_else st.modal
	}
}

@(private)
apply_range :: proc(st: ^Style, d: ^Document, r: Range) {
	for p in d.props[r.first:][:r.count] {
		apply(st, p.attr, p.value)
	}
}

// cascade gives a node its style (see docs/ui/design.md#the-cascade): its element's defaults, what it inherits of its
// parent's text, its styles in order, their variants for its states, its own attributes, and last what scripts set on
// it. states are the states that it is in.
cascade :: proc(d: ^Document, n: u32, parent: ^Style, states: bit_set[format.Ui_State]) -> Style {
	node := &d.nodes[n]
	st := default_style(node.element)
	if parent != nil {
		st.font = parent.font
		st.size = parent.size
		st.color = parent.color
		st.text_align = parent.text_align
		st.line_height = parent.line_height
		st.wrap = node.element == .Field ? false : parent.wrap
	}
	refs := d.style_refs[node.styles.first:][:node.styles.count]
	for r in refs {
		apply_range(&st, d, d.styles[r].props)
	}
	for state in format.Ui_State {
		if state not_in states {
			continue
		}
		for r in refs {
			if v := d.styles[r].variants[state]; v != format.UI_NONE && int(v) < len(d.styles) {
				apply_range(&st, d, d.styles[v].props)
			}
		}
	}
	apply_range(&st, d, node.props)
	if node.id_hash != 0 {
		for o in d.overrides {
			if o.id_hash == node.id_hash {
				apply(&st, o.attr, o.value)
			}
		}
	}
	return st
}
