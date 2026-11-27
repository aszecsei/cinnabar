package refdiff

import "core:math"
import "core:testing"

import "cinnabar:core/capture"

// A capture of radiance h, through the engine's output without tone mapping, decodes back to h, within a code's step.
@(test)
a_capture_decodes_to_its_radiance :: proc(t: ^testing.T) {
	for h in ([]f32{0, 0.001, 0.01, 0.1, 0.5, 1, 3}) {
		exposed := h * 2
		code := capture.srgb_encode(exposed / (1 + exposed))
		back := decode_capture(code, 2)
		testing.expectf(t, abs(back - h) <= 0.02 * h + 2e-4, "%v decodes to %v", h, back)
	}
}

@(test)
a_reference_decodes_to_its_radiance :: proc(t: ^testing.T) {
	for h in ([]f32{0, 0.001, 0.01, 0.1, 0.45}) {
		v := h * 2
		encoded := v * 12.92 if v <= 0.0031308 else 1.055 * math.pow(v, 1 / 2.4) - 0.055
		code := u32(encoded * 65535 + 0.5)
		back := decode_reference(code, 16, 2)
		testing.expectf(t, abs(back - h) <= 1e-3 * h + 1e-6, "%v decodes to %v", h, back)
	}
}

// A capture twice as bright as its reference is one stop brighter everywhere, and a dark pixel has no ratio.
@(test)
a_capture_twice_as_bright_is_a_stop_brighter :: proc(t: ^testing.T) {
	size := [2]int{16, 8}
	a := Linear{size, make([][3]f32, size.x * size.y)}
	b := Linear{size, make([][3]f32, size.x * size.y)}
	defer delete(a.pixels)
	defer delete(b.pixels)
	for i in 0 ..< len(a.pixels) {
		a.pixels[i] = {0.1, 0.2, f32(i) * 0.001 + 0.01}
		b.pixels[i] = a.pixels[i] * 2
	}
	a.pixels[0], b.pixels[0] = 0, 0
	r := compare(a, b)
	defer delete(r.pixels)
	defer delete(r.counted)
	testing.expect(t, !r.counted[0])
	for v, i in r.pixels[1:] {
		testing.expectf(t, abs(v - 1) < 1e-4, "pixel %d: %v stops", i + 1, v)
	}
	for row in r.regions {
		for cell in row {
			s, ok := stops(luma(cell.capture), luma(cell.reference))
			testing.expect(t, ok && abs(s - 1) < 1e-4)
		}
	}
	q := quantiles(r)
	testing.expect_value(t, q.count, len(r.pixels) - 1)
}
