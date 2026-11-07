// tools/stbn makes the spatiotemporal blue noise that the screen-space reflections sample their rays with (see
// docs/rendering/lighting-and-shadows.md#screen-space-reflections): SLICES textures of SIZE × SIZE uniform 2D values,
// each slice blue noise over space and each pixel's sequence of values blue noise over time. Run `just stbn` and commit
// the texture that it writes.
//
// The method is Wolfe, Morrical, Akenine-Möller and Ramamoorthi's, "Spatiotemporal Blue Noise Masks" (EGSR 2022), for
// vector values: each slice starts with the same stratified set of values in a random order, and swaps of two of a
// slice's values that lower the energy are kept. The energy is Georgiev and Fajardo's, "Blue-noise Dithered Sampling"
// (SIGGRAPH 2016 Talks), summed separately over space and time, half each: over the pairs of texels in one slice,
// exp(-|Δx|²/σs²) · exp(-|Δv|²/σv²), and over the pairs of slices at one pixel, exp(-|Δt|²/σt²) · exp(-|Δv|²/σv²).
// Multiplying the terms over a space-time window instead gives the pairs that share a pixel little of the energy: at
// 16x16x8 and 24 rounds it left 41% of white noise's low-frequency power over space and 73% over time, and this energy
// leaves 4% and 18%.
//
//   stbn <output.png> [--size N] [--slices N] [--swaps N] [--seed N]
//
// The PNG is the slices one above the other, slice 0 at the top, the values in red and green, which the cooker reads
// as an array with layout = array_strip.
package stbn

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"

import "cinnabar:core/capture"

SIZE :: 128
SLICES :: 32
// The swaps that each texel starts, over as many rounds.
SWAPS :: 256
SEED :: 0x5354424e
// The energy's widths: the space and time terms' are the paper's, and the values' is Georgiev and Fajardo's.
SIGMA_SPACE :: 1.9
SIGMA_TIME :: 1.9
SIGMA_VALUE :: 1.0
// The time term's share of the energy.
TIME_SHARE :: 0.5
// The window's radius in texels and in slices. Its corners, whose weight is below WEIGHT_CUTOFF, are left out.
RADIUS :: 3
WEIGHT_CUTOFF :: 1e-3
// A texel swaps with one at most this far away in its slice.
SWAP_RADIUS :: 8
// Slices this far apart share no window, so their swaps run at once: the window reaches RADIUS slices each way.
PHASES :: RADIUS + 1

Noise :: struct {
	size, slices: int,
	// Slice by slice, row by row.
	values:       [][2]f32,
	window:       []Offset,
}

// Offset is a neighbor in the window, and its weight.
Offset :: struct {
	x, y, t: int,
	weight:  f32,
}

// Rng is PCG32 (O'Neill 2014), so that the same seed gives the same texture on every platform and compiler.
Rng :: struct {
	state, increment: u64,
}

rng_make :: proc(seed: u64, stream: u64) -> Rng {
	r := Rng{0, stream << 1 | 1}
	rng_next(&r)
	r.state += seed
	rng_next(&r)
	return r
}

rng_next :: proc(r: ^Rng) -> u32 {
	old := r.state
	r.state = old * 6364136223846793005 + r.increment
	shifted := u32(((old >> 18) ~ old) >> 27)
	rotation := u32(old >> 59)
	return shifted >> rotation | shifted << ((32 - rotation) & 31)
}

// rng_below is a value in [0, n), without modulo bias.
rng_below :: proc(r: ^Rng, n: int) -> int {
	bound := u32(n)
	threshold := (~bound + 1) % bound
	for {
		v := rng_next(r)
		if v >= threshold {
			return int(v % bound)
		}
	}
}

noise_make :: proc(size, slices: int, seed: u64, allocator := context.allocator) -> Noise {
	n := Noise {
		size   = size,
		slices = slices,
		values = make([][2]f32, size * size * slices, allocator),
	}
	window := make([dynamic]Offset, allocator)
	for y in -RADIUS ..= RADIUS {
		for x in -RADIUS ..= RADIUS {
			w := math.exp(-f32(x * x + y * y) / (SIGMA_SPACE * SIGMA_SPACE))
			if (x != 0 || y != 0) && w >= WEIGHT_CUTOFF {
				append(&window, Offset{x, y, 0, (1 - TIME_SHARE) * w})
			}
		}
	}
	for t in -RADIUS ..= RADIUS {
		if t != 0 {
			append(&window, Offset{0, 0, t, TIME_SHARE * math.exp(-f32(t * t) / (SIGMA_TIME * SIGMA_TIME))})
		}
	}
	n.window = window[:]
	// Each slice holds every cell center of a size × size grid once: the values are stratified, so each slice's are
	// uniform however they are ordered.
	area := size * size
	for t in 0 ..< slices {
		r := rng_make(seed, u64(t))
		slice := n.values[t * area:][:area]
		for &v, i in slice {
			v = {(f32(i % size) + 0.5) / f32(size), (f32(i / size) + 0.5) / f32(size)}
		}
		for i := area - 1; i > 0; i -= 1 {
			j := rng_below(&r, i + 1)
			slice[i], slice[j] = slice[j], slice[i]
		}
	}
	return n
}

noise_destroy :: proc(n: ^Noise) {
	delete(n.values)
	delete(n.window)
}

wrap :: #force_inline proc(v, n: int) -> int {
	return ((v % n) + n) % n
}

index :: #force_inline proc(n: ^Noise, x, y, t: int) -> int {
	return (wrap(t, n.slices) * n.size + wrap(y, n.size)) * n.size + wrap(x, n.size)
}

// kernel is the values' term of the energy.
kernel :: #force_inline proc(a, b: [2]f32) -> f32 {
	d := a - b
	return math.exp(-(d.x * d.x + d.y * d.y) / (SIGMA_VALUE * SIGMA_VALUE))
}

// energy_at is the energy between the texel at (x, y, t) with value v and its window, leaving out the texel at skip,
// whose term with this one a swap does not change.
energy_at :: proc(n: ^Noise, x, y, t: int, v: [2]f32, skip: int) -> (e: f32) {
	for o in n.window {
		i := index(n, x + o.x, y + o.y, t + o.t)
		if i != skip {
			e += o.weight * kernel(v, n.values[i])
		}
	}
	return
}

// energy is the whole texture's, each pair counted once.
energy :: proc(n: ^Noise) -> (e: f64) {
	for t in 0 ..< n.slices {
		for y in 0 ..< n.size {
			for x in 0 ..< n.size {
				e += f64(energy_at(n, x, y, t, n.values[index(n, x, y, t)], -1))
			}
		}
	}
	return e / 2
}

// optimize_slice tries a swap from each of slice t's texels, in a random order, with one at most SWAP_RADIUS away,
// and keeps those that lower the energy. It returns how many it kept.
optimize_slice :: proc(n: ^Noise, t: int, r: ^Rng) -> (kept: int) {
	area := n.size * n.size
	reach := min(SWAP_RADIUS, n.size / 2)
	for _ in 0 ..< area {
		a := rng_below(r, area)
		ax, ay := a % n.size, a / n.size
		bx := wrap(ax + rng_below(r, 2 * reach + 1) - reach, n.size)
		by := wrap(ay + rng_below(r, 2 * reach + 1) - reach, n.size)
		ia, ib := index(n, ax, ay, t), index(n, bx, by, t)
		if ia == ib {
			continue
		}
		va, vb := n.values[ia], n.values[ib]
		before := energy_at(n, ax, ay, t, va, ib) + energy_at(n, bx, by, t, vb, ia)
		after := energy_at(n, ax, ay, t, vb, ib) + energy_at(n, bx, by, t, va, ia)
		if after < before {
			n.values[ia], n.values[ib] = vb, va
			kept += 1
		}
	}
	return
}

// optimize runs the rounds. In each, every slice optimizes once, PHASES groups in turn: the slices of a group are
// PHASES apart, so none reads a value that another writes, and each draws from its own generator, so the texture is
// the same whatever the threads' timing.
optimize :: proc(n: ^Noise, rounds: int, seed: u64, threads := 0) {
	assert(n.slices % PHASES == 0 && n.slices >= 2 * PHASES, "the slices must be a multiple of PHASES, twice at least")
	Work :: struct {
		noise: ^Noise,
		seed:  u64,
		round: int,
		phase: int,
		next:  int,
		kept:  int,
	}
	work := Work {
		noise = n,
		seed  = seed,
	}
	worker :: proc(data: rawptr) {
		work := (^Work)(data)
		groups := work.noise.slices / PHASES
		for {
			k := sync.atomic_add(&work.next, 1)
			if k >= groups {
				return
			}
			t := k * PHASES + work.phase
			// Streams below slices are the starting orders'.
			r := rng_make(work.seed, u64((1 + work.round) * work.noise.slices + t))
			kept := optimize_slice(work.noise, t, &r)
			sync.atomic_add(&work.kept, kept)
		}
	}
	count := threads > 0 ? threads : max(os.get_processor_core_count(), 1)
	count = min(count, n.slices / PHASES)
	pool := make([]^thread.Thread, count, context.temp_allocator)
	for round in 0 ..< rounds {
		work.round, work.kept = round, 0
		for phase in 0 ..< PHASES {
			work.phase, work.next = phase, 0
			for &t in pool {
				t = thread.create_and_start_with_data(&work, worker)
			}
			for t in pool {
				thread.join(t)
				thread.destroy(t)
			}
		}
		if rounds >= 8 && (round + 1) % (rounds / 8) == 0 {
			fmt.printfln("  round %d of %d: kept %d swaps", round + 1, rounds, work.kept)
		}
	}
}

// pixels is the texture as RGB8, the slices one above the other: each value at its cell's code, so a size of 128
// gives the odd codes, centered in their cells.
pixels :: proc(n: ^Noise, allocator := context.allocator) -> []byte {
	out := make([]byte, len(n.values) * 3, allocator)
	for v, i in n.values {
		out[i * 3 + 0] = u8(min(v.x * 256, 255))
		out[i * 3 + 1] = u8(min(v.y * 256, 255))
	}
	return out
}

main :: proc() {
	output := ""
	size, slices, swaps, seed := SIZE, SLICES, SWAPS, u64(SEED)
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		number := 0
		if arg == "--size" || arg == "--slices" || arg == "--swaps" || arg == "--seed" {
			ok := false
			if i + 1 < len(os.args) {
				number, ok = strconv.parse_int(os.args[i + 1])
			}
			if !ok || number <= 0 {
				fmt.eprintfln("stbn: %s takes a positive number", arg)
				os.exit(2)
			}
			i += 1
		}
		switch arg {
		case "--size":
			size = number
		case "--slices":
			slices = number
		case "--swaps":
			swaps = number
		case "--seed":
			seed = u64(number)
		case:
			if output != "" {
				fmt.eprintln("usage: stbn <output.png> [--size N] [--slices N] [--swaps N] [--seed N]")
				os.exit(2)
			}
			output = arg
		}
	}
	if output == "" || slices % PHASES != 0 || slices < 2 * PHASES || size < 2 * RADIUS + 1 {
		fmt.eprintfln("usage: stbn <output.png> [--size N] [--slices N] [--swaps N] [--seed N]; the slices a multiple of %d, %d at least, and the size %d at least", PHASES, 2 * PHASES, 2 * RADIUS + 1)
		os.exit(2)
	}
	start := time.tick_now()
	n := noise_make(size, slices, seed)
	defer noise_destroy(&n)
	first := energy(&n)
	optimize(&n, swaps, seed)
	last := energy(&n)
	fmt.printfln("stbn: %dx%dx%d, %d swaps a texel, energy %.0f to %.0f, in %.1f s", size, size, slices, swaps, first, last, time.duration_seconds(time.tick_since(start)))
	encoded, ok := capture.encode_png({size = {u32(size), u32(size * slices)}, pixels = pixels(&n)}, context.temp_allocator)
	if !ok {
		fmt.eprintln("stbn: cannot encode the PNG")
		os.exit(1)
	}
	if err := os.write_entire_file(output, encoded); err != nil {
		fmt.eprintfln("stbn: cannot write %s: %v", output, err)
		os.exit(1)
	}
}
