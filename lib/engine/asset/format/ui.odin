package asset_format

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

import "cinnabar:core/layout"

// UI documents are .ui files: a tree of boxes, text and images in a pseudo-XML, with named styles, which the UI lays
// out and draws (see docs/content/kinds/ui-documents.md#ui-documents). The cooker parses and checks one with ui_parse
// and writes a Ui blob, which keeps each attribute's value as its text: the runtime parses it with ui_parse_value, as
// it does a value that a script sets, so there is one parser of values.
UI_EXTENSION :: ".ui"
UI_TEXT_VERSION :: 1

// A document has at most this many elements, and they nest at most this deep.
MAX_UI_NODES :: 4096
MAX_UI_DEPTH :: 64

// UI_NONE is no node and no style.
UI_NONE :: max(u32)

// Ui_Element is what an element is. A style is not one: it is a set of attributes that elements take.
Ui_Element :: enum u16 {
	// The root: a stack as large as the UI.
	Ui,
	// A box whose direction attribute lays its children out: a column unless it says otherwise.
	Box,
	Row,
	Column,
	// A box whose children each fill it, placed by their anchors.
	Stack,
	Text,
	Image,
	// A row that takes focus and clicks. Text in it is a text element of its own.
	Button,
	// One line of text that the player edits.
	Field,
	// An element that scripts copy into the document with Ui.add, which is not in the document itself.
	Template,
}

Ui_Elements :: bit_set[Ui_Element;u16]

UI_ELEMENT_NAMES := [Ui_Element]string {
	.Ui       = "ui",
	.Box      = "box",
	.Row      = "row",
	.Column   = "column",
	.Stack    = "stack",
	.Text     = "text",
	.Image    = "image",
	.Button   = "button",
	.Field    = "field",
	.Template = "template",
}

// The element of a style that holds attributes, which is not a node.
UI_STYLE_ELEMENT :: "style"

// Ui_State is a state of an element that a style's variant applies in: a style named "button:focus" is button's
// variant for Focus.
Ui_State :: enum u8 {
	Hover,
	Focus,
	Press,
	Disabled,
}

UI_STATE_NAMES := [Ui_State]string {
	.Hover    = "hover",
	.Focus    = "focus",
	.Press    = "press",
	.Disabled = "disabled",
}

// Ui_Attr is an attribute of an element or a style, but for id, style and name, which say what an element or a style
// is.
Ui_Attr :: enum u16 {
	// Layout.
	Width,
	Height,
	Min_Width,
	Max_Width,
	Min_Height,
	Max_Height,
	Padding,
	Gap,
	Direction,
	Align,
	Cross,
	Anchor,
	Offset,
	Visible,
	Clip,
	Overflow,
	Scroll_Bar,
	// Paint.
	Fill,
	Radius,
	Border,
	Opacity,
	Image,
	Tint,
	Slice,
	// Text, which children inherit.
	Font,
	Size,
	Color,
	Text_Align,
	Line_Height,
	Wrap,
	// Content.
	Text,
	Placeholder,
	Max_Length,
	// Interaction.
	Focusable,
	Disabled,
	Click,
	Changed,
	Submit,
	Nav_Up,
	Nav_Down,
	Nav_Left,
	Nav_Right,
	// The root's.
	Cancel,
	Focus,
	Modal,
}

// Ui_Value_Kind is what text an attribute takes, and so which variant of Ui_Value it parses to.
Ui_Value_Kind :: enum u8 {
	// A number in the attribute's range: f32.
	Number,
	// A whole number from 0: f32.
	Count,
	// true or false: bool.
	Boolean,
	// Any text, in which {name} is a binding and {{ and }} are braces: string.
	Text,
	// The name of a script event, such as resume, whose handler is on_resume: string.
	Event,
	// An element's id: string.
	Id,
	// An asset, as $ and 32 hex digits: Guid.
	Guid,
	// A size: Ui_Length.
	Length,
	// One to four numbers from 0, top, right, bottom and left as CSS takes them: Ui_Edges.
	Edges,
	// One to four numbers from 0, for the top left, top right, bottom right and bottom left corners: Ui_Edges.
	Corners,
	// One or two numbers, x and y: Ui_Vec2.
	Offset,
	Color,
	Paint,
	Border,
	Direction,
	Align,
	Cross,
	Anchor,
	Text_Align,
	Overflow,
}

// Ui_Length is a size: pixels at a UI scale of 1, a percent of the parent's, what the content needs, or a share of what
// is left in the parent, by weight.
Ui_Length_Unit :: enum u8 {
	Px,
	Percent,
	Fit,
	Fill,
}

Ui_Length :: struct {
	unit:  Ui_Length_Unit,
	// Pixels, a percent, or a fill's weight.
	value: f32,
}

Ui_Edges :: distinct [4]f32
Ui_Vec2 :: distinct [2]f32
// Ui_Color is a color as a designer picks it: sRGB-encoded, with straight alpha.
Ui_Color :: distinct [4]u8

// Ui_Paint is a fill: one color, or a gradient from the first color to the second along angle degrees, 0 left to right
// and 90 top to bottom.
Ui_Paint :: struct {
	colors:   [2]Ui_Color,
	angle:    f32,
	gradient: bool,
}

Ui_Border :: struct {
	width: f32,
	color: Ui_Color,
}

Ui_Direction :: enum u8 {
	Column,
	Row,
	Stack,
}

// Ui_Align is where a row or column puts its children along its direction.
Ui_Align :: enum u8 {
	Start,
	Center,
	End,
	Space_Between,
}

// Ui_Cross is where a row or column puts its children across its direction.
Ui_Cross :: enum u8 {
	Start,
	Center,
	End,
	Stretch,
}

// Ui_Anchor is where a stack's child is in it: at a corner, an edge's middle, the middle, or filling it.
Ui_Anchor :: enum u8 {
	Top_Left,
	Top,
	Top_Right,
	Left,
	Center,
	Right,
	Bottom_Left,
	Bottom,
	Bottom_Right,
	Fill,
}

Ui_Text_Align :: enum u8 {
	Start,
	Center,
	End,
}

// Ui_Overflow is what a row or column does with children that need more room than it has: let them out, or scroll
// them along its direction.
Ui_Overflow :: enum u8 {
	Visible,
	Scroll,
}

Ui_Value :: union {
	f32,
	bool,
	string,
	Guid,
	Ui_Length,
	Ui_Edges,
	Ui_Vec2,
	Ui_Color,
	Ui_Paint,
	Ui_Border,
	Ui_Direction,
	Ui_Align,
	Ui_Cross,
	Ui_Anchor,
	Ui_Text_Align,
	Ui_Overflow,
}

// Ui_Attr_Info is what an attribute is called, what it takes, which elements it means something on, and whether
// children inherit it. A number is from min to max.
Ui_Attr_Info :: struct {
	name:      string,
	kind:      Ui_Value_Kind,
	on:        Ui_Elements,
	inherited: bool,
	min, max:  f32,
}

@(private = "file")
UI_BOXES :: Ui_Elements{.Box, .Row, .Column, .Stack, .Text, .Image, .Button, .Field}
@(private = "file")
UI_CONTAINERS :: Ui_Elements{.Box, .Row, .Column, .Stack, .Button}
@(private = "file")
UI_ANY :: Ui_Elements{.Ui, .Box, .Row, .Column, .Stack, .Text, .Image, .Button, .Field}
@(private = "file")
UI_BIG :: f32(1e6)

UI_ATTRS := [Ui_Attr]Ui_Attr_Info {
	.Width       = {name = "width", kind = .Length, on = UI_BOXES},
	.Height      = {name = "height", kind = .Length, on = UI_BOXES},
	.Min_Width   = {name = "min_width", kind = .Length, on = UI_BOXES},
	.Max_Width   = {name = "max_width", kind = .Length, on = UI_BOXES},
	.Min_Height  = {name = "min_height", kind = .Length, on = UI_BOXES},
	.Max_Height  = {name = "max_height", kind = .Length, on = UI_BOXES},
	.Padding     = {name = "padding", kind = .Edges, on = UI_ANY},
	.Gap         = {name = "gap", kind = .Number, on = UI_CONTAINERS, max = UI_BIG},
	.Direction   = {name = "direction", kind = .Direction, on = {.Box, .Button}},
	.Align       = {name = "align", kind = .Align, on = UI_CONTAINERS},
	.Cross       = {name = "cross", kind = .Cross, on = UI_CONTAINERS},
	.Anchor      = {name = "anchor", kind = .Anchor, on = UI_BOXES},
	.Offset      = {name = "offset", kind = .Offset, on = UI_BOXES},
	.Visible     = {name = "visible", kind = .Boolean, on = UI_BOXES},
	.Clip        = {name = "clip", kind = .Boolean, on = UI_CONTAINERS},
	.Overflow    = {name = "overflow", kind = .Overflow, on = UI_CONTAINERS},
	.Scroll_Bar  = {name = "scroll_bar", kind = .Boolean, on = UI_CONTAINERS},
	.Fill        = {name = "fill", kind = .Paint, on = UI_BOXES},
	.Radius      = {name = "radius", kind = .Corners, on = UI_BOXES},
	.Border      = {name = "border", kind = .Border, on = UI_BOXES},
	.Opacity     = {name = "opacity", kind = .Number, on = UI_ANY, max = 1},
	.Image       = {name = "image", kind = .Guid, on = UI_BOXES},
	.Tint        = {name = "tint", kind = .Color, on = UI_BOXES},
	.Slice       = {name = "slice", kind = .Edges, on = UI_BOXES},
	.Font        = {name = "font", kind = .Guid, on = UI_ANY, inherited = true},
	.Size        = {name = "size", kind = .Number, on = UI_ANY, inherited = true, min = 1, max = 1000},
	.Color       = {name = "color", kind = .Color, on = UI_ANY, inherited = true},
	.Text_Align  = {name = "text_align", kind = .Text_Align, on = UI_ANY, inherited = true},
	.Line_Height = {name = "line_height", kind = .Number, on = UI_ANY, inherited = true, min = 0.5, max = 4},
	.Wrap        = {name = "wrap", kind = .Boolean, on = UI_ANY, inherited = true},
	.Text        = {name = "text", kind = .Text, on = {.Text, .Button, .Field}},
	.Placeholder = {name = "placeholder", kind = .Text, on = {.Field}},
	.Max_Length  = {name = "max_length", kind = .Count, on = {.Field}, max = 65535},
	.Focusable   = {name = "focusable", kind = .Boolean, on = UI_BOXES},
	.Disabled    = {name = "disabled", kind = .Boolean, on = UI_BOXES},
	.Click       = {name = "click", kind = .Event, on = UI_BOXES},
	.Changed     = {name = "changed", kind = .Event, on = {.Field}},
	.Submit      = {name = "submit", kind = .Event, on = {.Field}},
	.Nav_Up      = {name = "nav_up", kind = .Id, on = UI_BOXES},
	.Nav_Down    = {name = "nav_down", kind = .Id, on = UI_BOXES},
	.Nav_Left    = {name = "nav_left", kind = .Id, on = UI_BOXES},
	.Nav_Right   = {name = "nav_right", kind = .Id, on = UI_BOXES},
	.Cancel      = {name = "cancel", kind = .Event, on = {.Ui}},
	.Focus       = {name = "focus", kind = .Id, on = {.Ui}},
	.Modal       = {name = "modal", kind = .Boolean, on = {.Ui}},
}

// ui_attr_of is the attribute of a name, such as "min_width".
ui_attr_of :: proc(name: string) -> (attr: Ui_Attr, ok: bool) {
	for info, a in UI_ATTRS {
		if info.name == name {
			return a, true
		}
	}
	return
}

// ui_element_of is the element of a name, such as "column".
ui_element_of :: proc(name: string) -> (element: Ui_Element, ok: bool) {
	for n, e in UI_ELEMENT_NAMES {
		if n == name {
			return e, true
		}
	}
	return
}

// ui_valid_id is whether a name is an element's id: lowercase letters, digits, _ and -. # and . are kept for the ids of
// a template's copies, such as row#2.label.
ui_valid_id :: proc(id: string) -> bool {
	if id == "" {
		return false
	}
	for c in id {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// ui_valid_name is whether a name is an event's or a binding's: a lowercase Luau name, so that on_<name> is one.
ui_valid_name :: proc(name: string) -> bool {
	if name == "" || name[0] >= '0' && name[0] <= '9' {
		return false
	}
	for c in name {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

@(private = "file")
ui_number :: proc(text: string) -> (value: f32, ok: bool) {
	if text == "" || text == "+" || text == "-" {
		return
	}
	value, ok = strconv.parse_f32(text)
	return value, ok && value == value && abs(value) < UI_BIG
}

@(private = "file")
ui_numbers :: proc(text: string, values: []f32) -> (count: int, ok: bool) {
	rest := text
	for word in strings.fields_iterator(&rest) {
		if count == len(values) {
			return count, false
		}
		values[count] = ui_number(word) or_return
		count += 1
	}
	return count, count > 0
}

// ui_parse_color parses #rgb, #rgba, #rrggbb or #rrggbbaa, sRGB-encoded with straight alpha, or none, which is clear.
ui_parse_color :: proc(text: string) -> (color: Ui_Color, ok: bool) {
	if text == "none" {
		return {}, true
	}
	if len(text) < 4 || text[0] != '#' {
		return
	}
	hex := text[1:]
	digit :: proc(c: u8) -> (u8, bool) {
		switch c {
		case '0' ..= '9':
			return c - '0', true
		case 'a' ..= 'f':
			return c - 'a' + 10, true
		case 'A' ..= 'F':
			return c - 'A' + 10, true
		}
		return 0, false
	}
	switch len(hex) {
	case 3, 4:
		color.a = 255
		for i in 0 ..< len(hex) {
			d := digit(hex[i]) or_return
			color[i] = d * 17
		}
	case 6, 8:
		color.a = 255
		for i in 0 ..< len(hex) / 2 {
			hi := digit(hex[i * 2]) or_return
			lo := digit(hex[i * 2 + 1]) or_return
			color[i] = hi << 4 | lo
		}
	case:
		return
	}
	return color, true
}

// ui_parse_guid parses $ and 32 hex digits.
ui_parse_guid :: proc(text: string) -> (Guid, bool) {
	if len(text) != 33 || text[0] != '$' {
		return {}, false
	}
	return guid_parse(text[1:])
}

// ui_check_bindings checks a text's braces: {name} is a binding, and {{ and }} are a brace each. It gives what is wrong,
// or "".
ui_check_bindings :: proc(text: string) -> string {
	for i := 0; i < len(text); i += 1 {
		switch text[i] {
		case '{':
			if i + 1 < len(text) && text[i + 1] == '{' {
				i += 1
				continue
			}
			end := strings.index_byte(text[i:], '}')
			if end < 0 {
				return "has a { that no } closes. Write {{ for a brace."
			}
			name := text[i + 1:][:end - 1]
			if !ui_valid_name(name) {
				return fmt.tprintf("binds {%s}, which is not a name of lowercase letters, digits and _", name)
			}
			i += end
		case '}':
			if i + 1 < len(text) && text[i + 1] == '}' {
				i += 1
			}
		}
	}
	return ""
}

@(private = "file")
ui_enum :: proc(text: string, names: []string) -> (index: int, ok: bool) {
	for n, i in names {
		if n == text {
			return i, true
		}
	}
	return
}

// ui_parse_value parses an attribute's value. It gives a message of what is wrong, without the attribute's name, if
// the text is not one that the attribute takes. Strings in the value point into text.
ui_parse_value :: proc(attr: Ui_Attr, text: string) -> (value: Ui_Value, message: string) {
	info := UI_ATTRS[attr]
	t := strings.trim_space(text)
	switch info.kind {
	case .Number, .Count:
		n, ok := ui_number(t)
		if !ok {
			return nil, fmt.tprintf("is %q, not a number", t)
		}
		if info.kind == .Count && n != f32(int(n)) {
			return nil, fmt.tprintf("is %q, not a whole number", t)
		}
		if n < info.min || n > info.max {
			return nil, fmt.tprintf("is %v, outside %v to %v", n, info.min, info.max)
		}
		return n, ""
	case .Boolean:
		switch t {
		case "true":
			return true, ""
		case "false":
			return false, ""
		}
		return nil, fmt.tprintf("is %q, not true or false", t)
	case .Text:
		if problem := ui_check_bindings(text); problem != "" {
			return nil, problem
		}
		return text, ""
	case .Event:
		if !ui_valid_name(t) {
			return nil, fmt.tprintf("is %q, not an event's name of lowercase letters, digits and _", t)
		}
		return t, ""
	case .Id:
		if !ui_valid_id(t) {
			return nil, fmt.tprintf("is %q, not an id of lowercase letters, digits, _ and -", t)
		}
		return t, ""
	case .Guid:
		guid, ok := ui_parse_guid(t)
		if !ok {
			return nil, fmt.tprintf("is %q, not an asset: $ and 32 hex digits", t)
		}
		return guid, ""
	case .Length:
		switch {
		case t == "fit":
			return Ui_Length{.Fit, 0}, ""
		case t == "fill":
			return Ui_Length{.Fill, 1}, ""
		case strings.has_prefix(t, "fill "):
			weight, ok := ui_number(strings.trim_space(t[5:]))
			if !ok || weight <= 0 {
				return nil, fmt.tprintf("is %q: a fill's weight is a number above 0", t)
			}
			return Ui_Length{.Fill, weight}, ""
		case strings.has_suffix(t, "%"):
			percent, ok := ui_number(t[:len(t) - 1])
			if !ok || percent < 0 {
				return nil, fmt.tprintf("is %q, not a percent from 0", t)
			}
			return Ui_Length{.Percent, percent}, ""
		}
		px, ok := ui_number(t)
		if !ok || px < 0 {
			return nil, fmt.tprintf("is %q, not pixels from 0, a percent, fit or fill", t)
		}
		return Ui_Length{.Px, px}, ""
	case .Edges, .Corners:
		values: [4]f32
		count, ok := ui_numbers(t, values[:])
		if !ok || values[0] < 0 || values[1] < 0 || values[2] < 0 || values[3] < 0 {
			return nil, fmt.tprintf("is %q, not one to four numbers from 0", t)
		}
		// One value is every side; two are top and bottom, then the sides (or two pairs of opposite corners); three are
		// the top, the sides and the bottom.
		switch count {
		case 1:
			values = {values[0], values[0], values[0], values[0]}
		case 2:
			values = {values[0], values[1], values[0], values[1]}
		case 3:
			values = {values[0], values[1], values[2], values[1]}
		}
		return Ui_Edges(values), ""
	case .Offset:
		values: [2]f32
		count, ok := ui_numbers(t, values[:])
		if !ok {
			return nil, fmt.tprintf("is %q, not one or two numbers", t)
		}
		if count == 1 {
			values.y = values.x
		}
		return Ui_Vec2(values), ""
	case .Color:
		color, ok := ui_parse_color(t)
		if !ok {
			return nil, fmt.tprintf("is %q, not a color: #rgb, #rgba, #rrggbb, #rrggbbaa or none", t)
		}
		return color, ""
	case .Paint:
		if strings.has_prefix(t, "linear(") && strings.has_suffix(t, ")") {
			parts := strings.split(t[len("linear("):len(t) - 1], ",", context.temp_allocator)
			if len(parts) != 3 {
				return nil, fmt.tprintf("is %q: a gradient is linear(<degrees>, <color>, <color>)", t)
			}
			angle, angle_ok := ui_number(strings.trim_space(parts[0]))
			from, from_ok := ui_parse_color(strings.trim_space(parts[1]))
			to, to_ok := ui_parse_color(strings.trim_space(parts[2]))
			if !angle_ok || !from_ok || !to_ok {
				return nil, fmt.tprintf("is %q: a gradient is linear(<degrees>, <color>, <color>)", t)
			}
			return Ui_Paint{{from, to}, angle, true}, ""
		}
		color, ok := ui_parse_color(t)
		if !ok {
			return nil, fmt.tprintf("is %q, not a color or linear(<degrees>, <color>, <color>)", t)
		}
		return Ui_Paint{colors = {color, color}}, ""
	case .Border:
		if t == "none" {
			return Ui_Border{}, ""
		}
		rest := t
		width_text, _ := strings.fields_iterator(&rest)
		width, width_ok := ui_number(width_text)
		color, color_ok := ui_parse_color(strings.trim_space(rest))
		if !width_ok || width < 0 || !color_ok {
			return nil, fmt.tprintf("is %q, not a width and a color, such as 1 #ffffff40, or none", t)
		}
		return Ui_Border{width, color}, ""
	case .Direction:
		if i, ok := ui_enum(t, {"column", "row", "stack"}); ok {
			return Ui_Direction(i), ""
		}
		return nil, fmt.tprintf("is %q, not column, row or stack", t)
	case .Align:
		if i, ok := ui_enum(t, {"start", "center", "end", "space_between"}); ok {
			return Ui_Align(i), ""
		}
		return nil, fmt.tprintf("is %q, not start, center, end or space_between", t)
	case .Cross:
		if i, ok := ui_enum(t, {"start", "center", "end", "stretch"}); ok {
			return Ui_Cross(i), ""
		}
		return nil, fmt.tprintf("is %q, not start, center, end or stretch", t)
	case .Anchor:
		names := []string{"top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom", "bottom_right", "fill"}
		if i, ok := ui_enum(t, names); ok {
			return Ui_Anchor(i), ""
		}
		return nil, fmt.tprintf("is %q, not one of %s", t, strings.join(names, ", ", context.temp_allocator))
	case .Text_Align:
		if i, ok := ui_enum(t, {"start", "center", "end"}); ok {
			return Ui_Text_Align(i), ""
		}
		return nil, fmt.tprintf("is %q, not start, center or end", t)
	case .Overflow:
		if i, ok := ui_enum(t, {"visible", "scroll"}); ok {
			return Ui_Overflow(i), ""
		}
		return nil, fmt.tprintf("is %q, not visible or scroll", t)
	}
	return nil, "is not a value"
}

// Ui_Range is a run of records in one of a blob's arrays.
Ui_Range :: struct {
	first, count: u32,
}

Ui_Node_Flag :: enum u16 {
	// The node is a template or in one, so it is not in the document until a script copies it.
	Template,
}

Ui_Node_Flags :: bit_set[Ui_Node_Flag;u16]

// Ui_Node is an element of a document, in the order of a walk that visits each element before its children. Node 0 is
// the <ui> root.
Ui_Node :: struct {
	element:     Ui_Element,
	flags:       Ui_Node_Flags,
	// The parent's index, or UI_NONE for the root.
	parent:      u32,
	// One past the last node of the element's subtree.
	subtree_end: u32,
	// The line of the source that the element is on, from 1.
	line:        u32,
	id:          Slice,
	// Ui_Prop records: the element's own attributes.
	props:       Ui_Range,
	// Indices into the blob's style refs: the styles that the element takes, in order, the style named for its element
	// first if there is one.
	styles:      Ui_Range,
}

// Ui_Style is a named set of attributes. A base style's variants are the styles that apply in each state, such as
// "button:focus", or UI_NONE.
Ui_Style :: struct {
	name:     Slice,
	props:    Ui_Range,
	variants: [Ui_State]u32,
}

// UI_NO_VARIANTS is a style's variants when it has none.
UI_NO_VARIANTS :: [Ui_State]u32 {
	.Hover    = UI_NONE,
	.Focus    = UI_NONE,
	.Press    = UI_NONE,
	.Disabled = UI_NONE,
}

// Ui_Prop is an attribute and its value's text.
Ui_Prop :: struct {
	attr:    Ui_Attr,
	padding: u16,
	value:   Slice,
}

// Ui_Blob is the start of a UI document's blob (see docs/content/kinds/ui-documents.md#the-blob).
Ui_Blob :: struct {
	header:      Blob_Header,
	nodes:       Slice,
	styles:      Slice,
	props:       Slice,
	// u32 indices of styles, which nodes' styles ranges are in.
	style_refs:  Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/ui/hud.ui".
	source_path: Slice,
}

ui_layout :: proc() -> u64 {
	return layout.hash(Ui_Blob) ~ layout.hash(Ui_Node) * 31 ~ layout.hash(Ui_Style) * 961 ~ layout.hash(Ui_Prop) * 29791
}

// ui_view checks a UI document's blob: its header, its layout, that its slices and ranges are inside it, that its
// nodes are a tree in order, and that its attributes and styles are ones that this build knows.
ui_view :: proc(data: []byte) -> (blob: ^Ui_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Ui || header.layout != ui_layout() || len(data) < size_of(Ui_Blob) {
		return
	}
	blob = (^Ui_Blob)(raw_data(data))
	inside :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(data)) && int(s.size) % size == 0 && int(s.offset) % align == 0
	}
	if !inside(data, blob.nodes, size_of(Ui_Node), align_of(Ui_Node)) ||
	   !inside(data, blob.styles, size_of(Ui_Style), align_of(Ui_Style)) ||
	   !inside(data, blob.props, size_of(Ui_Prop), align_of(Ui_Prop)) ||
	   !inside(data, blob.style_refs, size_of(u32), align_of(u32)) ||
	   !inside(data, blob.source_path, 1, 1) {
		return nil, false
	}
	nodes, styles, props, refs := ui_nodes(data, blob), ui_styles(data, blob), ui_props(data, blob), ui_style_refs(data, blob)
	in_range :: proc(r: Ui_Range, count: int) -> bool {
		return u64(r.first) + u64(r.count) <= u64(count)
	}
	for p in props {
		if !inside(data, p.value, 1, 1) || p.attr > max(Ui_Attr) {
			return nil, false
		}
	}
	for r in refs {
		if int(r) >= len(styles) {
			return nil, false
		}
	}
	for s in styles {
		if !inside(data, s.name, 1, 1) || !in_range(s.props, len(props)) {
			return nil, false
		}
		for v in s.variants {
			if v != UI_NONE && int(v) >= len(styles) {
				return nil, false
			}
		}
	}
	if len(nodes) == 0 || nodes[0].element != .Ui || nodes[0].parent != UI_NONE || int(nodes[0].subtree_end) != len(nodes) {
		return nil, false
	}
	for n, i in nodes {
		if n.element > max(Ui_Element) || !inside(data, n.id, 1, 1) || !in_range(n.props, len(props)) || !in_range(n.styles, len(refs)) {
			return nil, false
		}
		if int(n.subtree_end) <= i || int(n.subtree_end) > len(nodes) {
			return nil, false
		}
		// A child is after its parent and inside its subtree.
		if i > 0 && (int(n.parent) >= i || nodes[n.parent].subtree_end < n.subtree_end) {
			return nil, false
		}
	}
	return blob, true
}

ui_nodes :: proc "contextless" (data: []byte, blob: ^Ui_Blob) -> []Ui_Node {
	bytes := blob_bytes(data, blob.nodes)
	return ([^]Ui_Node)(raw_data(bytes))[:len(bytes) / size_of(Ui_Node)]
}

ui_styles :: proc "contextless" (data: []byte, blob: ^Ui_Blob) -> []Ui_Style {
	bytes := blob_bytes(data, blob.styles)
	return ([^]Ui_Style)(raw_data(bytes))[:len(bytes) / size_of(Ui_Style)]
}

ui_props :: proc "contextless" (data: []byte, blob: ^Ui_Blob) -> []Ui_Prop {
	bytes := blob_bytes(data, blob.props)
	return ([^]Ui_Prop)(raw_data(bytes))[:len(bytes) / size_of(Ui_Prop)]
}

ui_style_refs :: proc "contextless" (data: []byte, blob: ^Ui_Blob) -> []u32 {
	bytes := blob_bytes(data, blob.style_refs)
	return ([^]u32)(raw_data(bytes))[:len(bytes) / size_of(u32)]
}

// ui_range gives the records of a range.
ui_range :: proc "contextless" (records: []$T, r: Ui_Range) -> []T {
	return records[r.first:][:r.count]
}

// ui_find_style is the index of a style by its name, such as "button" or "button:focus".
ui_find_style :: proc(data: []byte, blob: ^Ui_Blob, name: string) -> (index: u32, ok: bool) {
	for s, i in ui_styles(data, blob) {
		if blob_string(data, s.name) == name {
			return u32(i), true
		}
	}
	return UI_NONE, false
}

// Ui_Prop_Contents is an attribute as ui_parse finds it: its value's text, and where it is in the source, for the
// cooker's problems.
Ui_Prop_Contents :: struct {
	attr:         Ui_Attr,
	value:        string,
	line, column: int,
}

Ui_Node_Contents :: struct {
	element: Ui_Element,
	flags:   Ui_Node_Flags,
	parent:  u32,
	// One past the last node of the element's subtree.
	end:     u32,
	line:    int,
	id:      string,
	props:   []Ui_Prop_Contents,
	// Indices of styles.
	styles:  []u32,
}

Ui_Style_Contents :: struct {
	name:     string,
	line:     int,
	props:    []Ui_Prop_Contents,
	variants: [Ui_State]u32,
}

Ui_Document_Contents :: struct {
	nodes:  []Ui_Node_Contents,
	styles: []Ui_Style_Contents,
}

Ui_Contents :: struct {
	guid:        Guid,
	key:         u64,
	document:    Ui_Document_Contents,
	source_path: string,
}

// ui_write builds a UI document's blob.
ui_write :: proc(contents: Ui_Contents, allocator := context.allocator) -> []byte {
	doc := contents.document
	prop_count, ref_count := 0, 0
	for n in doc.nodes {
		prop_count += len(n.props)
		ref_count += len(n.styles)
	}
	for s in doc.styles {
		prop_count += len(s.props)
	}
	buffer := make([dynamic]byte, size_of(Ui_Blob), allocator)
	nodes := reserve_bytes(&buffer, len(doc.nodes) * size_of(Ui_Node), align_of(Ui_Node))
	styles := reserve_bytes(&buffer, len(doc.styles) * size_of(Ui_Style), align_of(Ui_Style))
	props := reserve_bytes(&buffer, prop_count * size_of(Ui_Prop), align_of(Ui_Prop))
	refs := reserve_bytes(&buffer, ref_count * size_of(u32), align_of(u32))
	next_prop, next_ref := u32(0), u32(0)
	write_props :: proc(buffer: ^[dynamic]byte, props: Slice, next: ^u32, list: []Ui_Prop_Contents) -> Ui_Range {
		r := Ui_Range{next^, u32(len(list))}
		for p in list {
			record := Ui_Prop {
				attr  = p.attr,
				value = append_bytes(buffer, transmute([]byte)p.value),
			}
			mem.copy(&buffer[props.offset + next^ * size_of(Ui_Prop)], &record, size_of(record))
			next^ += 1
		}
		return r
	}
	for n, i in doc.nodes {
		record := Ui_Node {
			element     = n.element,
			flags       = n.flags,
			parent      = n.parent,
			subtree_end = n.end,
			line        = u32(n.line),
			id          = append_bytes(&buffer, transmute([]byte)n.id),
			props       = write_props(&buffer, props, &next_prop, n.props),
			styles      = {next_ref, u32(len(n.styles))},
		}
		for s in n.styles {
			index := s
			mem.copy(&buffer[refs.offset + next_ref * size_of(u32)], &index, size_of(u32))
			next_ref += 1
		}
		mem.copy(&buffer[nodes.offset + u32(i * size_of(Ui_Node))], &record, size_of(record))
	}
	for s, i in doc.styles {
		record := Ui_Style {
			name     = append_bytes(&buffer, transmute([]byte)s.name),
			props    = write_props(&buffer, props, &next_prop, s.props),
			variants = s.variants,
		}
		mem.copy(&buffer[styles.offset + u32(i * size_of(Ui_Style))], &record, size_of(record))
	}
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Ui_Blob {
		header = {magic = BLOB_MAGIC, kind = .Ui, layout = ui_layout(), key = contents.key, guid = contents.guid},
		nodes = nodes,
		styles = styles,
		props = props,
		style_refs = refs,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
