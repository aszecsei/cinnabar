package ui

import "core:math"
import "core:testing"


@(private = "file")
BACK :: "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"
@(private = "file")
FRONT :: "d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4"

@(test)
the_batch_draws_documents_by_order_and_each_tree_parents_first :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	// The front document is shown first but has the higher order, so it draws last.
	show(t, f, FRONT, `ui 1
<ui><box id="front" width="10" height="10" fill="#ff000080" opacity="0.5"/></ui>`, order = 2)
	show(t, f, BACK, `ui 1
<ui>
	<box id="panel" width="100" height="50" fill="linear(90, #000, #fff)" radius="4 4 0 0" border="2 #00ff00">
		<box id="inner" width="10" height="10" fill="#0000ff"/>
		<box id="clear" width="10" height="10"/>
		<box id="hidden" width="10" height="10" fill="#fff" visible="false"/>
	</box>
</ui>`, order = 1)
	step(f)
	b := build_batch(&f.ui, 0, context.temp_allocator)
	testing.expect_value(t, len(b.instances), 3)
	if len(b.instances) != 3 {
		return
	}
	panel, inner, front := b.instances[0], b.instances[1], b.instances[2]
	testing.expect_value(t, panel.rect, [4]f32{0, 0, 100, 50})
	testing.expect_value(t, panel.kind, INSTANCE_RECT | INSTANCE_GRADIENT)
	testing.expect_value(t, panel.radii, [4]f32{4, 4, 0, 0})
	testing.expect_value(t, panel.width, 2)
	testing.expect_value(t, panel.border, 0xff00ff00)
	testing.expect_value(t, panel.fill, 0xff000000)
	testing.expect_value(t, panel.fill_end, 0xffffffff)
	// 90 degrees runs top to bottom over the panel's height.
	testing.expect(t, abs(panel.gradient.x) < 1e-6 && abs(panel.gradient.y - 1.0 / 50) < 1e-6)
	testing.expect_value(t, inner.fill, 0xffff0000)
	// Opacity multiplies the color's own alpha: 0x80 by a half.
	testing.expect_value(t, front.fill, 0x400000ff)
}

@(test)
a_gradient_reaches_from_corner_to_corner_along_its_angle :: proc(t: ^testing.T) {
	rect := [4]f32{10, 20, 110, 70}
	g := gradient_of(rect, 0)
	testing.expect_value(t, g, [2]f32{0.01, 0})
	g = gradient_of(rect, 45)
	// A corner's t is 0.5 plus its offset from the middle along the gradient.
	at := proc(g: [2]f32, p: [2]f32) -> f32 {
		return 0.5 + (p.x - 60) * g.x + (p.y - 45) * g.y
	}
	testing.expect(t, abs(at(g, {10, 20})) < 1e-5)
	testing.expect(t, abs(at(g, {110, 70}) - 1) < 1e-5)
	testing.expect(t, math.is_nan(gradient_of({0, 0, 0, 0}, 30).x) == false)
}

@(test)
a_nine_slice_keeps_its_corners_and_stretches_the_rest :: proc(t: ^testing.T) {
	cells := nine_slice({0, 0, 200, 100}, {8, 4, 8, 4}, 2, {32, 32})
	testing.expect_value(t, cells[0].rect, [4]f32{0, 0, 8, 16})
	testing.expect_value(t, cells[0].uv, [4]f32{0, 0, 0.125, 0.25})
	testing.expect_value(t, cells[4].rect, [4]f32{8, 16, 192, 84})
	testing.expect_value(t, cells[4].uv, [4]f32{0.125, 0.25, 0.875, 0.75})
	testing.expect_value(t, cells[8].rect, [4]f32{192, 84, 200, 100})
	testing.expect_value(t, cells[8].uv, [4]f32{0.875, 0.75, 1, 1})
}

@(test)
instances_outside_their_clip_are_left_out :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	show(t, f, BACK, `ui 1
<ui><row width="20" height="10" clip="true" cross="stretch"><box width="20" fill="#fff"/><box id="out" width="20" fill="#fff"/></row></ui>`)
	step(f)
	b := build_batch(&f.ui, 0, context.temp_allocator)
	testing.expect_value(t, len(b.instances), 1)
}
