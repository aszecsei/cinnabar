// tools/refdiff compares a screenshot of the engine with a path traced reference of the same view (see
// docs/rendering/reference-scenes.md): both go back to scene-linear radiance, and it reports how bright each is, by
// channel and over a grid of regions, in stops of the capture against the reference.
//
//   refdiff <reference.png> <capture.png>... [--reference-exposure <x>] [--capture-exposure <x>] [--out <prefix>]
//           [--probe <x>,<y>]...
//
// With several captures, it compares their mean. The reference is an 8- or 16-bit PNG of Blender's Standard view:
// sRGB-encoded scene-linear light times its exposure (2 by default, one stop). A capture is an 8-bit PNG of the engine's
// output with its tone mapping off, which rolls off to white as h / (1 + h) before it encodes sRGB, so h = c / (1 - c)
// undoes it, over its exposure (2 by default).
// --out writes <prefix>.ratio.png, each pixel's stops as heat from blue (darker than the reference) through black to
// red (brighter), full at REPORT_STOPS, and <prefix>.side.png, the reference and the capture side by side at one
// exposure and one curve. --probe prints a pixel's radiance in both.
package refdiff

import "core:fmt"
import "core:image"
import "core:image/png"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "cinnabar:core/capture"

_ :: png

// The ratio map is full blue or red at this many stops.
REPORT_STOPS :: 2
// The regions' grid: columns and rows.
GRID :: [2]int{8, 4}
// A pixel darker than this, in linear light of both images, has no ratio: its stops would be noise.
DARK_FLOOR :: 1e-4
// The luminance weights of Rec. 709, which the engine's and Blender's sRGB primaries share.
LUMA :: [3]f32{0.2126, 0.7152, 0.0722}

// Linear is an image's scene-linear radiance, three floats a pixel.
Linear :: struct {
	size:   [2]int,
	pixels: [][3]f32,
}

srgb_decode :: proc(c: f32) -> f32 {
	v := clamp(c, 0, 1)
	return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
}

// decode_reference is a reference pixel's radiance: its sRGB-encoded code, of a channel of depth bits, over its exposure.
decode_reference :: proc(code: u32, depth: int, exposure: f32) -> f32 {
	full := f32((u32(1) << uint(depth)) - 1)
	return srgb_decode(f32(code) / full) / exposure
}

// decode_capture is a capture pixel's radiance: its 8-bit sRGB code, its roll-off undone, over its exposure. The
// roll-off reaches 1 only at infinity, so a code of 255 is the most that it can tell, 254.5 / 255 of the way.
decode_capture :: proc(code: u8, exposure: f32) -> f32 {
	c := min(srgb_decode(f32(code) / 255), 254.5 / 255)
	return c / (1 - c) / exposure
}

luma :: proc(c: [3]f32) -> f32 {
	return c.r * LUMA.r + c.g * LUMA.g + c.b * LUMA.b
}

// stops is how many stops brighter a is than b, or 0 where both are darker than DARK_FLOOR. It is false then.
stops :: proc(a, b: f32) -> (f32, bool) {
	if a < DARK_FLOOR && b < DARK_FLOOR {
		return 0, false
	}
	return math.log2(max(a, DARK_FLOOR) / max(b, DARK_FLOOR)), true
}

// add_mean adds an image's share of the mean of count images to sum.
add_mean :: proc(sum: ^Linear, img: Linear, count: int) {
	for c, i in img.pixels {
		sum.pixels[i] += c / f32(count)
	}
}

// Region is a cell of the grid: its mean radiance in each image.
Region :: struct {
	reference: [3]f32,
	capture:   [3]f32,
}

// Report is the comparison: each image's mean radiance, the regions, and each pixel's stops where it has them.
Report :: struct {
	reference: [3]f32,
	capture:   [3]f32,
	regions:   [GRID.y][GRID.x]Region,
	pixels:    []f32,
	counted:   []bool,
}

compare :: proc(reference, capture: Linear, allocator := context.allocator) -> (r: Report) {
	n := len(reference.pixels)
	r.pixels = make([]f32, n, allocator)
	r.counted = make([]bool, n, allocator)
	counts: [GRID.y][GRID.x]int
	w, h := reference.size.x, reference.size.y
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := y * w + x
			a, b := reference.pixels[i], capture.pixels[i]
			r.reference += a / f32(n)
			r.capture += b / f32(n)
			cell := [2]int{x * GRID.x / w, y * GRID.y / h}
			r.regions[cell.y][cell.x].reference += a
			r.regions[cell.y][cell.x].capture += b
			counts[cell.y][cell.x] += 1
			r.pixels[i], r.counted[i] = stops(luma(b), luma(a))
		}
	}
	for y in 0 ..< GRID.y {
		for x in 0 ..< GRID.x {
			if counts[y][x] > 0 {
				r.regions[y][x].reference /= f32(counts[y][x])
				r.regions[y][x].capture /= f32(counts[y][x])
			}
		}
	}
	return
}

// Quantiles are of the pixels' absolute stops.
Quantiles :: struct {
	p50, p90, p99: f32,
	count:         int,
}

quantiles :: proc(r: Report, allocator := context.temp_allocator) -> (q: Quantiles) {
	values := make([dynamic]f32, 0, len(r.pixels), allocator)
	for v, i in r.pixels {
		if r.counted[i] {
			append(&values, abs(v))
		}
	}
	q.count = len(values)
	if q.count == 0 {
		return
	}
	slice.sort(values[:])
	at :: proc(v: []f32, p: f32) -> f32 {
		return v[min(int(p * f32(len(v))), len(v) - 1)]
	}
	return {at(values[:], 0.5), at(values[:], 0.9), at(values[:], 0.99), q.count}
}

// diverging is a pixel's stops as heat: blue where the capture is darker, red where it is brighter, black where they
// agree, full at REPORT_STOPS; grey where it has no ratio.
diverging :: proc(v: f32, counted: bool) -> [3]u8 {
	if !counted {
		return {48, 48, 48}
	}
	t := u8(clamp(abs(v) / REPORT_STOPS, 0, 1) * 255 + 0.5)
	return v < 0 ? {0, t / 3, t} : {t, t / 3, 0}
}

load_linear :: proc(path: string, is_reference: bool, exposure: f32) -> (img: Linear, ok: bool) {
	src, err := image.load_from_file(path, {.alpha_drop_if_present}, context.allocator)
	if err != nil ||
	   src.channels != 3 ||
	   (!is_reference && src.depth != 8) ||
	   (src.depth != 8 && src.depth != 16) {
		fmt.eprintfln("refdiff: %s is not an RGB PNG of the depth that it needs: %v", path, err)
		return
	}
	defer image.destroy(src)
	img.size = {src.width, src.height}
	img.pixels = make([][3]f32, src.width * src.height)
	buf := src.pixels.buf[:]
	for i in 0 ..< len(img.pixels) {
		for c in 0 ..< 3 {
			k := i * 3 + c
			if src.depth == 16 {
				// core:image keeps 16-bit samples in the machine's order.
				code := u32((cast([^]u16)raw_data(buf))[k])
				img.pixels[i][c] = decode_reference(code, 16, exposure)
			} else if is_reference {
				img.pixels[i][c] = decode_reference(u32(buf[k]), 8, exposure)
			} else {
				img.pixels[i][c] = decode_capture(buf[k], exposure)
			}
		}
	}
	return img, true
}

write_png :: proc(path: string, size: [2]int, pixels: []byte) -> bool {
	encoded, ok := capture.encode_png(
		{size = {u32(size.x), u32(size.y)}, pixels = pixels},
		context.temp_allocator,
	)
	return ok && os.write_entire_file(path, encoded) == nil
}

// show is a pixel as both halves of the side by side show it: the reference's exposure, then h / (1 + h) and sRGB, as
// the engine's output does without tone mapping.
show :: proc(c: [3]f32, exposure: f32) -> [3]u8 {
	out: [3]u8
	for v, k in c {
		h := v * exposure
		out[k] = capture.srgb_encode(h / (1 + h))
	}
	return out
}

num :: proc(v: f32) -> string {
	return fmt.tprintf("%.5f", v)
}

print_report :: proc(r: Report) {
	ratio :: proc(a, b: f32) -> string {
		s, ok := stops(a, b)
		return ok ? fmt.tprintf("%+.2f", s) : "    -"
	}
	fmt.printfln("mean radiance      %10s %10s %10s %10s", "r", "g", "b", "luma")
	fmt.printfln(
		"  reference        %10s %10s %10s %10s",
		num(r.reference.r),
		num(r.reference.g),
		num(r.reference.b),
		num(luma(r.reference)),
	)
	fmt.printfln(
		"  capture          %10s %10s %10s %10s",
		num(r.capture.r),
		num(r.capture.g),
		num(r.capture.b),
		num(luma(r.capture)),
	)
	fmt.printfln(
		"  stops            %10s %10s %10s %10s",
		ratio(r.capture.r, r.reference.r),
		ratio(r.capture.g, r.reference.g),
		ratio(r.capture.b, r.reference.b),
		ratio(luma(r.capture), luma(r.reference)),
	)
	q := quantiles(r)
	fmt.printfln(
		"pixels' |stops|: p50 %.2f, p90 %.2f, p99 %.2f, over %d pixels brighter than %v",
		q.p50,
		q.p90,
		q.p99,
		q.count,
		DARK_FLOOR,
	)
	fmt.printfln(
		"regions' luma, stops of the capture against the reference (%dx%d, top row first):",
		GRID.x,
		GRID.y,
	)
	for row in r.regions {
		fmt.print(" ")
		for cell in row {
			fmt.printf(" %6s", ratio(luma(cell.capture), luma(cell.reference)))
		}
		fmt.println()
	}
	fmt.println("regions' reference luma:")
	for row in r.regions {
		fmt.print(" ")
		for cell in row {
			fmt.printf(" %.4f", luma(cell.reference))
		}
		fmt.println()
	}
}

usage :: proc() {
	fmt.eprintln(
		"usage: refdiff <reference.png> <capture.png>... [--reference-exposure <x>] [--capture-exposure <x>] [--out <prefix>] [--probe <x>,<y>]...",
	)
	os.exit(2)
}

main :: proc() {
	paths: [dynamic]string
	probes: [dynamic][2]int
	out: string
	reference_exposure, capture_exposure: f32 = 2, 2
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		flag := args[i]
		if strings.has_prefix(flag, "--") {
			if i + 1 >= len(args) {
				usage()
			}
			value := args[i + 1]
			i += 1
			switch flag {
			case "--out":
				out = value
			case "--probe":
				parts := strings.split(value, ",", context.temp_allocator)
				x, x_ok := strconv.parse_int(parts[0])
				y, y_ok := strconv.parse_int(parts[len(parts) - 1])
				if len(parts) != 2 || !x_ok || !y_ok {
					usage()
				}
				append(&probes, [2]int{x, y})
			case "--reference-exposure", "--capture-exposure":
				x, ok := strconv.parse_f32(value)
				if !ok || x <= 0 {
					usage()
				}
				if flag == "--reference-exposure" {
					reference_exposure = x
				} else {
					capture_exposure = x
				}
			case:
				usage()
			}
			continue
		}
		append(&paths, flag)
	}
	if len(paths) < 2 {
		usage()
	}
	reference, a_ok := load_linear(paths[0], true, reference_exposure)
	if !a_ok {
		os.exit(1)
	}
	// The captures' mean, so the GI's noise between frames does not count as error.
	capture_img := Linear{reference.size, make([][3]f32, len(reference.pixels))}
	for path in paths[1:] {
		one, ok := load_linear(path, false, capture_exposure)
		if !ok {
			os.exit(1)
		}
		if one.size != reference.size {
			fmt.eprintfln(
				"refdiff: the reference is %dx%d and %s %dx%d",
				reference.size.x,
				reference.size.y,
				path,
				one.size.x,
				one.size.y,
			)
			os.exit(1)
		}
		add_mean(&capture_img, one, len(paths) - 1)
		delete(one.pixels)
	}
	report := compare(reference, capture_img)
	fmt.printfln(
		"the mean of %d captures against %s, %dx%d",
		len(paths) - 1,
		paths[0],
		reference.size.x,
		reference.size.y,
	)
	print_report(report)
	for p in probes {
		if p.x < 0 || p.y < 0 || p.x >= reference.size.x || p.y >= reference.size.y {
			fmt.eprintfln("refdiff: the probe %v is outside the image", p)
			os.exit(1)
		}
		i := p.y * reference.size.x + p.x
		a, b := reference.pixels[i], capture_img.pixels[i]
		fmt.printfln(
			"pixel %d,%d: reference %.5f %.5f %.5f, capture %.5f %.5f %.5f",
			p.x,
			p.y,
			a.r,
			a.g,
			a.b,
			b.r,
			b.g,
			b.b,
		)
	}
	if out == "" {
		return
	}
	size := reference.size
	heat := make([]byte, size.x * size.y * 3, context.temp_allocator)
	for v, i in report.pixels {
		c := diverging(v, report.counted[i])
		copy(heat[i * 3:], c[:])
	}
	side := make([]byte, size.x * 2 * size.y * 3, context.temp_allocator)
	for y in 0 ..< size.y {
		for x in 0 ..< size.x {
			i := y * size.x + x
			a := show(reference.pixels[i], reference_exposure)
			b := show(capture_img.pixels[i], reference_exposure)
			copy(side[(y * size.x * 2 + x) * 3:], a[:])
			copy(side[(y * size.x * 2 + size.x + x) * 3:], b[:])
		}
	}
	ratio_path := fmt.tprintf("%s.ratio.png", out)
	side_path := fmt.tprintf("%s.side.png", out)
	if !write_png(ratio_path, size, heat) || !write_png(side_path, {size.x * 2, size.y}, side) {
		fmt.eprintfln("refdiff: cannot write %s or %s", ratio_path, side_path)
		os.exit(1)
	}
	fmt.println(ratio_path)
	fmt.println(side_path)
}
