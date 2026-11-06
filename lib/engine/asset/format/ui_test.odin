package asset_format

import "core:slice"
import "core:strings"
import "core:testing"

// Documents with their problems marked: `<!-- problem -->` on each line that reports an error, and `<!-- warning -->`
// on each that reports a warning, and on no other.
@(private = "file")
UI_CORPUS := #load_directory("testdata/ui")

@(test)
ui_documents_report_their_problems_at_their_lines :: proc(t: ^testing.T) {
	testing.expect(t, len(UI_CORPUS) >= 5)
	for file in UI_CORPUS {
		text := string(file.data)
		errors, warnings := make([dynamic]int, context.temp_allocator), make([dynamic]int, context.temp_allocator)
		for line, i in strings.split_lines(text, context.temp_allocator) {
			if strings.contains(line, "<!-- problem -->") {
				append(&errors, i + 1)
			}
			if strings.contains(line, "<!-- warning -->") {
				append(&warnings, i + 1)
			}
		}
		_, problems, ok := ui_parse(text)
		found_errors, found_warnings := make([dynamic]int, context.temp_allocator), make([dynamic]int, context.temp_allocator)
		for p in problems {
			list := p.error ? &found_errors : &found_warnings
			if !slice.contains(list[:], p.line) {
				append(list, p.line)
			}
		}
		slice.sort(found_errors[:])
		slice.sort(found_warnings[:])
		testing.expectf(t, slice.equal(found_errors[:], errors[:]), "%s: errors at %v, expected at %v: %v", file.name, found_errors, errors, problems)
		testing.expectf(t, slice.equal(found_warnings[:], warnings[:]), "%s: warnings at %v, expected at %v: %v", file.name, found_warnings, warnings, problems)
		testing.expectf(t, ok == (len(errors) == 0), "%s: ok is %v", file.name, ok)
	}
}

@(private = "file")
ui_node_by_id :: proc(doc: Ui_Document_Contents, id: string) -> (Ui_Node_Contents, int) {
	for n, i in doc.nodes {
		if n.id == id {
			return n, i
		}
	}
	return {}, -1
}

@(private = "file")
ui_prop :: proc(n: Ui_Node_Contents, attr: Ui_Attr) -> string {
	for p in n.props {
		if p.attr == attr {
			return p.value
		}
	}
	return ""
}

@(test)
ui_menu_parses_into_nodes_styles_and_templates :: proc(t: ^testing.T) {
	text := string(#load("testdata/ui/menu.ui"))
	doc, problems, ok := ui_parse(text)
	testing.expectf(t, ok && len(problems) == 0, "%v", problems)
	root := doc.nodes[0]
	testing.expect_value(t, root.element, Ui_Element.Ui)
	testing.expect_value(t, root.parent, UI_NONE)
	testing.expect_value(t, int(root.end), len(doc.nodes))
	testing.expect_value(t, ui_prop(root, .Cancel), "resume")
	testing.expect_value(t, ui_prop(root, .Font), "$00112233445566778899aabbccddeeff")

	// The button's style is its kind's, and its variants hang off it.
	button, b := find_style(doc, "button")
	testing.expect(t, b >= 0)
	_, focus := find_style(doc, "button:focus")
	_, hover := find_style(doc, "button:hover")
	testing.expect_value(t, button.variants[.Focus], u32(focus))
	testing.expect_value(t, button.variants[.Hover], u32(hover))
	testing.expect_value(t, len(doc.styles), 7)

	// A button's text is a <text> of its own, after it.
	resume, r := ui_node_by_id(doc, "resume")
	testing.expect_value(t, resume.element, Ui_Element.Button)
	testing.expectf(t, slice.equal(resume.styles, []u32{u32(b)}), "resume's styles are %v", resume.styles)
	label := doc.nodes[r + 1]
	testing.expect_value(t, label.element, Ui_Element.Text)
	testing.expect_value(t, int(label.parent), r)
	testing.expect_value(t, ui_prop(label, .Text), "Resume")
	testing.expect_value(t, int(resume.end), r + 2)

	// The kind's style comes first, then the list, without the kind's again.
	quit, _ := ui_node_by_id(doc, "quit")
	_, panel := find_style(doc, "panel")
	testing.expectf(t, slice.equal(quit.styles, []u32{u32(b), u32(panel)}), "quit's styles are %v", quit.styles)

	// Entities decode, whitespace collapses, and {{ stays in the text for the runtime to unescape.
	for n in doc.nodes {
		if v := ui_prop(n, .Text); strings.has_prefix(v, "Paused") {
			testing.expect_value(t, v, "Paused & waiting …")
		}
	}
	testing.expect_value(t, ui_prop(doc.nodes[ui_node_by_id_index(doc, "quit") + 1], .Text), "Quit {{not a binding}}")

	// A template and its subtree are flagged, and its ids are its own.
	slot, s := ui_node_by_id(doc, "slot")
	testing.expect_value(t, slot.element, Ui_Element.Template)
	testing.expect(t, .Template in slot.flags)
	for n in doc.nodes[s:slot.end] {
		testing.expect(t, .Template in n.flags)
	}
	testing.expect_value(t, int(slot.end), len(doc.nodes))
	testing.expect_value(t, doc.nodes[s + 1].id, "slot")
}

@(private = "file")
ui_node_by_id_index :: proc(doc: Ui_Document_Contents, id: string) -> int {
	_, i := ui_node_by_id(doc, id)
	return i
}

@(private = "file")
find_style :: proc(doc: Ui_Document_Contents, name: string) -> (Ui_Style_Contents, int) {
	for s, i in doc.styles {
		if s.name == name {
			return s, i
		}
	}
	return {}, -1
}

@(test)
ui_blob_round_trips_a_document :: proc(t: ^testing.T) {
	doc, _, ok := ui_parse(string(#load("testdata/ui/menu.ui")))
	testing.expect(t, ok)
	data := aligned(ui_write({guid = {0 = 7}, key = 9, document = doc, source_path = "game/ui/menu.ui"}, context.temp_allocator))
	blob, view_ok := ui_view(data)
	testing.expect(t, view_ok)
	if !view_ok {
		return
	}
	nodes, props, refs := ui_nodes(data, blob), ui_props(data, blob), ui_style_refs(data, blob)
	testing.expect_value(t, len(nodes), len(doc.nodes))
	testing.expect_value(t, len(ui_styles(data, blob)), len(doc.styles))
	for n, i in nodes {
		c := doc.nodes[i]
		testing.expect_value(t, n.element, c.element)
		testing.expect_value(t, n.parent, c.parent)
		testing.expect_value(t, n.subtree_end, c.end)
		testing.expect_value(t, blob_string(data, n.id), c.id)
		testing.expect_value(t, int(n.props.count), len(c.props))
		for p, j in ui_range(props, n.props) {
			testing.expect_value(t, p.attr, c.props[j].attr)
			testing.expect_value(t, blob_string(data, p.value), c.props[j].value)
		}
		testing.expect(t, slice.equal(ui_range(refs, n.styles), c.styles))
	}
	focus, found := ui_find_style(data, blob, "button:focus")
	testing.expect(t, found)
	button, _ := ui_find_style(data, blob, "button")
	testing.expect_value(t, ui_styles(data, blob)[button].variants[.Focus], focus)
	testing.expect_value(t, blob_string(data, blob.source_path), "game/ui/menu.ui")

	// A node whose parent is after it is not a tree.
	ui_nodes(data, blob)[3].parent = 5
	_, view_ok = ui_view(data)
	testing.expect(t, !view_ok)
}

@(test)
ui_values_parse_as_their_attributes_take_them :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, attr: Ui_Attr, text: string, want: Ui_Value, loc := #caller_location) {
		v, message := ui_parse_value(attr, text)
		testing.expectf(t, message == "", "%v %q: %s", attr, text, message, loc = loc)
		testing.expectf(t, v == want, "%v %q is %v, not %v", attr, text, v, want, loc = loc)
	}
	check(t, .Width, "120", Ui_Length{.Px, 120})
	check(t, .Width, " 50% ", Ui_Length{.Percent, 50})
	check(t, .Width, "fit", Ui_Length{.Fit, 0})
	check(t, .Width, "fill", Ui_Length{.Fill, 1})
	check(t, .Width, "fill 2.5", Ui_Length{.Fill, 2.5})
	check(t, .Padding, "4", Ui_Edges{4, 4, 4, 4})
	check(t, .Padding, "4 8", Ui_Edges{4, 8, 4, 8})
	check(t, .Padding, "1 2 3", Ui_Edges{1, 2, 3, 2})
	check(t, .Radius, "1 2 3 4", Ui_Edges{1, 2, 3, 4})
	check(t, .Offset, "3", Ui_Vec2{3, 3})
	check(t, .Offset, "-3 4", Ui_Vec2{-3, 4})
	check(t, .Color, "#f80", Ui_Color{255, 136, 0, 255})
	check(t, .Color, "#f808", Ui_Color{255, 136, 0, 136})
	check(t, .Color, "#12345678", Ui_Color{0x12, 0x34, 0x56, 0x78})
	check(t, .Color, "none", Ui_Color{})
	check(t, .Fill, "#102030", Ui_Paint{colors = {{16, 32, 48, 255}, {16, 32, 48, 255}}})
	check(t, .Fill, "linear(45, #000, #fff)", Ui_Paint{{{0, 0, 0, 255}, {255, 255, 255, 255}}, 45, true})
	check(t, .Border, "1.5 #fff8", Ui_Border{1.5, {255, 255, 255, 136}})
	check(t, .Opacity, "0.25", f32(0.25))
	check(t, .Visible, "false", false)
	check(t, .Anchor, "bottom_right", Ui_Anchor.Bottom_Right)
	check(t, .Align, "space_between", Ui_Align.Space_Between)
	check(t, .Click, "start_game", "start_game")
	check(t, .Text, "  keeps its spaces {x} {{ ", "  keeps its spaces {x} {{ ")
	check(t, .Font, "$00112233445566778899aabbccddeeff", Guid{0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff})

	bad := []struct {
		attr: Ui_Attr,
		text: string,
	}{{.Width, "-1"}, {.Width, "1e9"}, {.Width, "nan"}, {.Opacity, "2"}, {.Max_Length, "-1"}, {.Color, "#ggg"}, {.Click, "9lives"}, {.Text, "{"}, {.Text, "{a b}"}}
	for b in bad {
		_, message := ui_parse_value(b.attr, b.text)
		testing.expectf(t, message != "", "%v %q parses", b.attr, b.text)
	}
}

@(test)
ui_documents_need_their_header :: proc(t: ^testing.T) {
	for text in ([]string{"", "<ui/>", "ui\n<ui/>", "ui 2\n<ui/>", "\n\nui 1\n"}) {
		_, problems, ok := ui_parse(text)
		testing.expectf(t, !ok && len(problems) > 0, "%q parses", text)
	}
	doc, _, ok := ui_parse("\nui 1\n<ui/>\n")
	testing.expect(t, ok)
	testing.expect_value(t, len(doc.nodes), 1)
}
