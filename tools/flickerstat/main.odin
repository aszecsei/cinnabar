// tools/flickerstat measures how much a still view changes over time (see docs/editor/capture.md#flicker): from a
// directory of screenshots of one view from one camera, taken with editorctl, it reports how far each pixel strays from
// its mean, and each pixel's largest step between two screenshots. Steady noise has a spread near its largest step; a
// pop has a large step and a small spread. The values are the PNGs' 8-bit codes, which is what a display shows.
//
//   flickerstat <directory> [--out <prefix>]
//
// --out writes <prefix>.spread.png and <prefix>.step.png, as heat from black to white.
package flickerstat

import "core:encoding/json"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "cinnabar:core/capture"

_ :: png

// A step at least this large, in 8-bit codes, counts as a pop. The screenshots' dither and TAA's ripple stay below it.
POP_CODES :: 8
// The heat maps are white at these many codes.
SPREAD_FULL :: 16
STEP_FULL :: 64
// The report lists this many of the largest steps.
LISTED_STEPS :: 5

// Step is what changed between one screenshot and the next.
Step :: struct {
	from, to: i64,
	// The mean change, in codes, and the share of the pixels that popped, with their bounds.
	mean:     f32,
	popped:   f32,
	low:      [2]int,
	high:     [2]int,
}

// Stats accumulates the screenshots of one view, by Welford's running mean and variance for each pixel.
Stats :: struct {
	size:     [2]int,
	count:    int,
	frame:    i64,
	mean:     []f32,
	m2:       []f32,
	largest:  []f32,
	previous: []f32,
	steps:    [dynamic]Step,
}

Quantiles :: struct {
	p50, p95, p99, p999, most: f32,
}

// add takes one screenshot's values. A size other than the first's is an error, since a resize resets every history.
add :: proc(s: ^Stats, values: []f32, size: [2]int, frame: i64) -> bool {
	if s.count == 0 {
		s.size = size
		n := size.x * size.y
		s.mean = make([]f32, n)
		s.m2 = make([]f32, n)
		s.largest = make([]f32, n)
		s.previous = make([]f32, n)
	} else if s.size != size {
		return false
	}
	s.count += 1
	if s.count > 1 {
		step := Step{from = s.frame, to = frame, low = size}
		total: f64
		pops := 0
		for v, i in values {
			change := abs(v - s.previous[i])
			total += f64(change)
			s.largest[i] = max(s.largest[i], change)
			if change >= POP_CODES {
				pops += 1
				at := [2]int{i % size.x, i / size.x}
				step.low = {min(step.low.x, at.x), min(step.low.y, at.y)}
				step.high = {max(step.high.x, at.x), max(step.high.y, at.y)}
			}
		}
		step.mean = f32(total / f64(len(values)))
		step.popped = f32(pops) / f32(len(values))
		append(&s.steps, step)
	}
	for v, i in values {
		delta := v - s.mean[i]
		s.mean[i] += delta / f32(s.count)
		s.m2[i] += delta * (v - s.mean[i])
	}
	copy(s.previous, values)
	s.frame = frame
	return true
}

// spread is each pixel's standard deviation over the screenshots.
spread :: proc(s: ^Stats, allocator := context.allocator) -> []f32 {
	out := make([]f32, len(s.m2), allocator)
	for m, i in s.m2 {
		out[i] = math.sqrt(max(m, 0) / f32(max(s.count - 1, 1)))
	}
	return out
}

// quantiles sorts a copy of the values.
quantiles :: proc(values: []f32) -> (q: Quantiles) {
	if len(values) == 0 {
		return
	}
	sorted := slice.clone(values, context.temp_allocator)
	slice.sort(sorted)
	at :: proc(sorted: []f32, share: f32) -> f32 {
		return sorted[min(int(share * f32(len(sorted))), len(sorted) - 1)]
	}
	return {at(sorted, 0.5), at(sorted, 0.95), at(sorted, 0.99), at(sorted, 0.999), sorted[len(sorted) - 1]}
}

// luma is an RGB8 image's Rec. 709 luma in 8-bit codes, on the encoded values.
luma :: proc(pixels: []byte, allocator := context.allocator) -> []f32 {
	out := make([]f32, len(pixels) / 3, allocator)
	for &v, i in out {
		v = 0.2126 * f32(pixels[i * 3]) + 0.7152 * f32(pixels[i * 3 + 1]) + 0.0722 * f32(pixels[i * 3 + 2])
	}
	return out
}

// heat maps 0..1 from black through red and yellow to white.
heat :: proc(v: f32) -> [3]u8 {
	t := clamp(v, 0, 1) * 3
	return {u8(clamp(t, 0, 1) * 255), u8(clamp(t - 1, 0, 1) * 255), u8(clamp(t - 2, 0, 1) * 255)}
}

// screenshots lists a directory's PNGs in order. Their names start with their times, or number them.
screenshots :: proc(directory: string, allocator := context.allocator) -> (paths: []string, ok: bool) {
	infos, err := os.read_all_directory_by_path(directory, context.temp_allocator)
	if err != nil {
		return
	}
	found := make([dynamic]string, allocator)
	for info in infos {
		if strings.has_suffix(info.name, ".png") && !strings.has_suffix(info.name, ".spread.png") && !strings.has_suffix(info.name, ".step.png") {
			append(&found, strings.clone(info.fullpath, allocator))
		}
	}
	slice.sort(found[:])
	return found[:], true
}

// frame_of is the host's frame number from a screenshot's sidecar, or else the screenshot's place.
frame_of :: proc(png_path: string, place: int) -> i64 {
	Image_Entry :: struct {
		frame: i64 `json:"frame"`,
	}
	Sidecar :: struct {
		images: []Image_Entry `json:"images"`,
	}
	stem := png_path[:len(png_path) - len(filepath.ext(png_path))]
	data, err := os.read_entire_file(fmt.tprintf("%s.json", stem), context.temp_allocator)
	sidecar: Sidecar
	if err != nil || json.unmarshal(data, &sidecar, allocator = context.temp_allocator) != nil || len(sidecar.images) == 0 {
		return i64(place)
	}
	return sidecar.images[0].frame
}

write_heat :: proc(path: string, values: []f32, size: [2]int, full: f32) -> bool {
	pixels := make([]byte, len(values) * 3, context.temp_allocator)
	for v, i in values {
		color := heat(v / full)
		copy(pixels[i * 3:], color[:])
	}
	encoded, ok := capture.encode_png({size = {u32(size.x), u32(size.y)}, pixels = pixels}, context.temp_allocator)
	return ok && os.write_entire_file(path, encoded) == nil
}

print_report :: proc(s: ^Stats, spreads: []f32) {
	a := quantiles(spreads)
	b := quantiles(s.largest)
	fmt.printfln("%d screenshots of %dx%d", s.count, s.size.x, s.size.y)
	row :: proc(name: string, q: Quantiles) {
		fmt.printf("%-6s", name)
		for v in ([]f32{q.p50, q.p95, q.p99, q.p999, q.most}) {
			fmt.printf(" %7s", fmt.tprintf("%.2f", v))
		}
		fmt.println()
	}
	fmt.printfln("%-6s %7s %7s %7s %7s %7s  (8-bit codes)", "", "p50", "p95", "p99", "p99.9", "max")
	row("spread", a)
	row("step", b)
	means := make([]f32, len(s.steps), context.temp_allocator)
	for step, i in s.steps {
		means[i] = step.mean
	}
	m := quantiles(means)
	fmt.printfln("mean change between screenshots: median %.3f, largest %.3f", m.p50, m.most)
	slice.sort_by(s.steps[:], proc(x, y: Step) -> bool {
		return x.popped > y.popped
	})
	fmt.printfln("largest pops (a change of %d codes or more):", POP_CODES)
	for step, i in s.steps {
		if i == LISTED_STEPS || step.popped <= 0 {
			break
		}
		fmt.printfln(
			"  frames %d-%d: %.3f%% of pixels, x %d-%d, y %d-%d, mean change %.3f",
			step.from,
			step.to,
			step.popped * 100,
			step.low.x,
			step.high.x,
			step.low.y,
			step.high.y,
			step.mean,
		)
	}
}

main :: proc() {
	directory, out: string
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--out" && i + 1 < len(args):
			out = args[i + 1]
			i += 1
		case directory == "" && !strings.has_prefix(args[i], "--"):
			directory = args[i]
		case:
			fmt.eprintln("usage: flickerstat <directory> [--out <prefix>]")
			os.exit(2)
		}
	}
	if directory == "" {
		fmt.eprintln("usage: flickerstat <directory> [--out <prefix>]")
		os.exit(2)
	}
	paths, listed := screenshots(directory)
	if !listed || len(paths) < 2 {
		fmt.eprintfln("flickerstat: %s needs at least two PNGs", directory)
		os.exit(1)
	}
	stats: Stats
	for path, i in paths {
		img, err := image.load_from_file(path, {.alpha_drop_if_present}, context.temp_allocator)
		if err != nil || img.channels != 3 || img.depth != 8 {
			fmt.eprintfln("flickerstat: %s is not an 8-bit RGB PNG: %v", path, err)
			os.exit(1)
		}
		size := [2]int{img.width, img.height}
		if !add(&stats, luma(img.pixels.buf[:], context.temp_allocator), size, frame_of(path, i)) {
			fmt.eprintfln("flickerstat: %s is %dx%d, not %dx%d like the others", path, size.x, size.y, stats.size.x, stats.size.y)
			os.exit(1)
		}
		free_all(context.temp_allocator)
	}
	spreads := spread(&stats)
	print_report(&stats, spreads)
	if out != "" {
		a := fmt.tprintf("%s.spread.png", out)
		b := fmt.tprintf("%s.step.png", out)
		if !write_heat(a, spreads, stats.size, SPREAD_FULL) || !write_heat(b, stats.largest, stats.size, STEP_FULL) {
			fmt.eprintfln("flickerstat: cannot write %s or %s", a, b)
			os.exit(1)
		}
		fmt.println(a)
		fmt.println(b)
	}
}
