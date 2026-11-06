package ui

import "core:fmt"
import "core:testing"

import "cinnabar:engine/ecs"

@(private = "file")
DOC :: "7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e"

@(private = "file")
node_of :: proc(t: ^testing.T, f: ^Fixture, e: ecs.Entity, id: string, loc := #caller_location) -> ^Node {
	d := document_of(&f.ui, e)
	n, found := find_node(d, id)
	testing.expectf(t, found, "no element %s", id, loc = loc)
	return &d.nodes[n]
}

@(private = "file")
text_document :: proc(body: string) -> string {
	return fmt.tprintf("ui 1\n<ui font=$%s size=\"100\">\n%s\n</ui>\n", TEST_FONT, body)
}

@(test)
text_is_kerned_and_takes_ligatures :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, text_document(`<text id="av">AV</text><text id="a">A</text><text id="v">V</text><text id="office">office</text>`))
	step(f)
	av, a, v := node_of(t, f, e, "av"), node_of(t, f, e, "a"), node_of(t, f, e, "v")
	testing.expect(t, av.text.ok && a.text.ok && v.text.ok)
	// Fira Sans kerns A before V by 14 units of 1000, at 100 pixels to the em.
	testing.expectf(t, abs(a.text.width + v.text.width - av.text.width - 1.4) < 0.01, "AV is %v wide, A and V %v and %v", av.text.width, a.text.width, v.text.width)
	// fi is one glyph.
	office := node_of(t, f, e, "office")
	testing.expect_value(t, office.text.glyphs.count, 5)
	testing.expect_value(t, office.text.length, 6)
	// A text's box fits its line: its width, and its line's height from the font's metrics.
	testing.expect_value(t, av.rect[2] - av.rect[0], f32(int(av.text.width + 0.5)))
	testing.expectf(t, abs(av.text.line - 120) < 0.01, "a line is %v", av.text.line)
}

@(test)
text_wraps_at_its_box_after_spaces_and_breaks_at_line_breaks :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, text_document(`<text id="w" width="400">one two three four five</text><text id="nowrap" width="100" wrap="false">one two three</text><text id="hard">a</text>`))
	step(f)
	d := document_of(&f.ui, e)
	w := node_of(t, f, e, "w")
	testing.expectf(t, w.text.lines.count >= 3, "%d lines", w.text.lines.count)
	for line, i in d.lines[w.text.lines.first:][:w.text.lines.count] {
		testing.expectf(t, line.width <= 400, "line %d is %v wide", i, line.width)
		first := d.glyphs[line.glyphs.first]
		testing.expect(t, .Space not_in first.flags)
		testing.expect_value(t, first.x, 0)
	}
	// Three lines of 120 pixels, which the box's height fits.
	testing.expect_value(t, w.rect[3] - w.rect[1], f32(w.text.lines.count) * 120)
	testing.expect_value(t, node_of(t, f, e, "nowrap").text.lines.count, 1)
	testing.expect_value(t, set_attribute(&f.ui, d, "hard", "text", "a\nb\n"), "")
	step(f)
	testing.expect_value(t, node_of(t, f, e, "hard").text.lines.count, 3)
}

@(test)
a_caret_goes_to_the_edges_of_clusters :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, text_document(`<field id="f" width="2000">office</field>`))
	step(f)
	d := document_of(&f.ui, e)
	field := node_of(t, f, e, "f")
	text := field.text
	glyphs := d.glyphs[text.glyphs.first:][:text.glyphs.count]
	// o, f, fi, c, e: the caret at the i, inside the ligature, goes to its end, where c starts.
	testing.expect_value(t, caret_x(d, text, 0), 0)
	testing.expect_value(t, caret_x(d, text, 2), glyphs[2].x)
	testing.expect_value(t, caret_x(d, text, 3), glyphs[3].x)
	testing.expect_value(t, caret_x(d, text, 6), glyphs[4].x + glyphs[4].advance)
	for g in glyphs {
		testing.expect_value(t, caret_at(d, text, g.x + 0.1), g.cluster)
	}
	testing.expect_value(t, caret_at(d, text, 1e5), 6)
}

@(test)
bindings_fill_text_and_braces_escape :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, text_document(`<text id="score">Score: {score} {{x}} {missing}!</text><button id="b">{score} points</button>`))
	step(f)
	d := document_of(&f.ui, e)
	text, ok := text_of(&f.ui, d, "score")
	testing.expect(t, ok)
	testing.expect_value(t, text, "Score:  {x} !")
	set_binding(&f.ui, d, "score", "42")
	text, _ = text_of(&f.ui, d, "score")
	testing.expect_value(t, text, "Score: 42 {x} !")
	text, _ = text_of(&f.ui, d, "b")
	testing.expect_value(t, text, "42 points")
	step(f)
	testing.expect_value(t, node_of(t, f, e, "score").text.length, u32(len("Score: 42 {x} !")))
}

@(test)
a_code_reload_places_fonts_again_with_the_same_glyphs :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, text_document(`<text id="t">Ligatures fit</text>`))
	step(f)
	before := node_of(t, f, e, "t").text
	on_reload(&f.ui, &f.platform)
	testing.expect(t, !f.ui.fonts[0].placed)
	step(f)
	after := node_of(t, f, e, "t").text
	testing.expect(t, f.ui.fonts[0].placed)
	testing.expect_value(t, after.width, before.width)
	testing.expect_value(t, after.glyphs.count, before.glyphs.count)
}

@(test)
text_without_a_font_draws_nothing_and_takes_no_room :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := show(t, f, DOC, "ui 1\n<ui><text id=\"t\">No font</text></ui>")
	step(f)
	n := node_of(t, f, e, "t")
	testing.expect(t, !n.text.ok)
	testing.expect_value(t, n.rect, [4]f32{0, 0, 0, 0})
}
