package cook

import "core:testing"

// msdf_square is a square from (0, 0) to (10, 10) in font units, counterclockwise, or clockwise when reversed.
@(private = "file")
msdf_square :: proc(reversed: bool) -> []Msdf_Command {
	corners := [4][2]f32{{0, 0}, {10, 0}, {10, 10}, {0, 10}}
	commands := make([]Msdf_Command, 5, context.temp_allocator)
	for i in 0 ..< 5 {
		corner := corners[(reversed ? 4 - i : i) % 4]
		commands[i] = {op = i == 0 ? .Move : .Line, to = corner}
	}
	return commands
}

// The field of a square, 2 pixels to a font unit with 2 pixels of border: the square covers pixels 4 to 24.
@(private = "file")
SQUARE_PARAMS :: Msdf_Params {
	width           = 28,
	height          = 28,
	scale           = 2,
	translate       = {2, 2},
	range           = 4,
	angle_threshold = MSDF_ANGLE_THRESHOLD,
}

// msdf_at is the field's pixel whose center is x, y pixels from the bottom left.
@(private = "file")
msdf_at :: proc(pixels: [][4]f32, params: Msdf_Params, x, y: int) -> [4]f32 {
	return pixels[(int(params.height) - 1 - y) * int(params.width) + x]
}

@(test)
msdf_field_is_inside_above_half_and_outside_below :: proc(t: ^testing.T) {
	for reversed in ([2]bool{false, true}) {
		pixels := make([][4]f32, 28 * 28, context.temp_allocator)
		testing.expect(t, msdf_mtsdf(msdf_square(reversed), SQUARE_PARAMS, pixels))

		// Either winding fills, as fonts disagree about which one does.
		center := msdf_at(pixels, SQUARE_PARAMS, 14, 14)
		testing.expectf(t, msdf_median(center) > 0.5 && center.a > 0.5, "reversed=%v: the center is %v", reversed, center)
		outside := msdf_at(pixels, SQUARE_PARAMS, 1, 14)
		testing.expectf(t, msdf_median(outside) < 0.5 && outside.a < 0.5, "reversed=%v: outside is %v", reversed, outside)

		// A pixel's center half a pixel inside the left edge is a quarter of the range from the outline, so its
		// distance is 0.5 + 0.5 / 4.
		edge := msdf_at(pixels, SQUARE_PARAMS, 4, 14)
		testing.expectf(t, abs(msdf_median(edge) - 0.625) < 0.01, "reversed=%v: the edge is %v", reversed, edge)
	}
}

@(test)
msdf_field_keeps_a_corner_sharp :: proc(t: ^testing.T) {
	pixels := make([][4]f32, 28 * 28, context.temp_allocator)
	testing.expect(t, msdf_mtsdf(msdf_square(false), SQUARE_PARAMS, pixels))

	// The pixel just outside the square's corner, diagonally, has its center half a pixel from each edge. The true
	// distance, sqrt(0.5) pixels, rounds the corner off; the channels' median is the distance to the nearer edge's line,
	// 0.5 pixels, as a square corner has it.
	corner := msdf_at(pixels, SQUARE_PARAMS, 24, 24)
	testing.expectf(t, abs(msdf_median(corner) - (0.5 - 0.5 / 4)) < 0.01, "the corner's median is %v", msdf_median(corner))
	testing.expectf(t, abs(corner.a - (0.5 - 0.70710678 / 4)) < 0.01, "the corner's true distance is %v", corner.a)
}

@(test)
msdf_bounds_of_an_outline_and_of_none :: proc(t: ^testing.T) {
	bounds, has_edges, ok := msdf_bounds(msdf_square(false))
	testing.expect(t, ok && has_edges)
	testing.expect_value(t, bounds, [4]f64{0, 0, 10, 10})

	_, has_edges, ok = msdf_bounds(nil)
	testing.expect(t, ok && !has_edges)

	// A line with no move before it has no contour to be in.
	_, _, ok = msdf_bounds([]Msdf_Command{{op = .Line, to = {1, 1}}})
	testing.expect(t, !ok)
}
