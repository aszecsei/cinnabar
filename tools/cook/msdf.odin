package cook

import "core:c"

// tools/cook/msdfgen/cn_msdf.cpp with msdfgen's core, which `just msdfgen` builds. Only the cooker links it.
foreign import msdfgen "../../build/obj/msdfgen/out/cn_msdfgen.lib"

// The justfile passes the vendor/msdfgen tag, so an msdfgen update cooks every font again.
MSDFGEN_VERSION :: #config(MSDFGEN_VERSION, "unknown")

// Msdf_Op matches CnMsdfOp in cn_msdf.cpp.
Msdf_Op :: enum u32 {
	Move  = 1,
	Line  = 2,
	Quad  = 3,
	Cubic = 4,
}

// Msdf_Command matches CnMsdfCommand in cn_msdf.cpp: an outline command's end point, and the control points that its
// op takes before it, in font units with y up. A quadratic curve takes one control point, and a cubic two.
Msdf_Command :: struct {
	op:       Msdf_Op,
	to:       [2]f32,
	controls: [2][2]f32,
}

// Msdf_Params matches CnMsdfParams in cn_msdf.cpp. A font unit at p lands on the pixel (p + translate) * scale, counted
// from the field's bottom left. range is the width in pixels of the distances that the field holds: 0.5 is the outline,
// and 0 and 1 are range / 2 pixels outside and inside it. angle_threshold, in radians, is the sharpest angle between
// two edges that is still smooth, so that a corner keeps its own colors.
Msdf_Params :: struct {
	width, height:   i32,
	scale:           f64,
	translate:       [2]f64,
	range:           f64,
	angle_threshold: f64,
}

// MSDF_ANGLE_THRESHOLD is msdfgen's default, 3 radians.
MSDF_ANGLE_THRESHOLD :: 3.0

#assert(size_of(Msdf_Command) == 28)
#assert(size_of(Msdf_Params) == 48)

@(default_calling_convention = "c")
foreign msdfgen {
	// cn_msdf_bounds gives the outline's bounds in font units: left, bottom, right and top. It returns 1, 0 for an
	// outline with no edges, such as a space's, and -1 for commands that make no shape.
	cn_msdf_bounds :: proc(commands: [^]Msdf_Command, count: c.int, bounds: ^[4]f64) -> c.int ---
	// cn_msdf_mtsdf writes the outline's multi-channel distance field into red, green and blue and its true distance
	// into alpha, width * height pixels from the top row down, mapped by params.range and not clamped. It returns 0, or
	// -1 for commands that make no shape. Calls share nothing, so any number may run at once.
	cn_msdf_mtsdf :: proc(commands: [^]Msdf_Command, count: c.int, params: ^Msdf_Params, pixels: [^][4]f32) -> c.int ---
}

// msdf_bounds gives an outline's bounds in font units, as left, bottom, right and top, and whether it has any edges. ok
// is false for commands that make no shape.
msdf_bounds :: proc(commands: []Msdf_Command) -> (bounds: [4]f64, has_edges: bool, ok: bool) {
	result := cn_msdf_bounds(raw_data(commands), c.int(len(commands)), &bounds)
	return bounds, result == 1, result >= 0
}

// msdf_mtsdf fills pixels, params.width * params.height of them from the top row down, with the outline's
// multi-channel and true distance field. It returns false for commands that make no shape.
msdf_mtsdf :: proc(commands: []Msdf_Command, params: Msdf_Params, pixels: [][4]f32) -> bool {
	assert(len(pixels) == int(params.width * params.height))
	params := params
	return cn_msdf_mtsdf(raw_data(commands), c.int(len(commands)), &params, raw_data(pixels)) == 0
}

// msdf_median is the distance that a multi-channel field's red, green and blue give: their median, which is 0.5 on the
// outline and greater inside it.
msdf_median :: proc "contextless" (p: [4]f32) -> f32 {
	return max(min(p.r, p.g), min(max(p.r, p.g), p.b))
}
