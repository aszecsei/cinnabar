package stbn

import "core:math"
import "core:slice"
import "core:testing"

TEST_SIZE :: 16
TEST_SLICES :: 8
TEST_ROUNDS :: 24

// The low frequencies' share of the power of each slice's x values, over space, and of each pixel's, over time: white
// noise has its power spread evenly, and blue noise little at the low end.
low_power :: proc(n: ^Noise) -> (space, time: f64) {
	area := n.size * n.size
	for t in 0 ..< n.slices {
		mean: f64
		for i in 0 ..< area {
			mean += f64(n.values[t * area + i].x)
		}
		mean /= f64(area)
		for ky in -2 ..= 2 {
			for kx in -2 ..= 2 {
				if kx == 0 && ky == 0 {
					continue
				}
				re, im: f64
				for y in 0 ..< n.size {
					for x in 0 ..< n.size {
						a := -2 * math.PI * f64(kx * x + ky * y) / f64(n.size)
						v := f64(n.values[t * area + y * n.size + x].x) - mean
						re += v * math.cos(a)
						im += v * math.sin(a)
					}
				}
				space += re * re + im * im
			}
		}
	}
	for i in 0 ..< area {
		mean: f64
		for t in 0 ..< n.slices {
			mean += f64(n.values[t * area + i].x)
		}
		mean /= f64(n.slices)
		re, im: f64
		for t in 0 ..< n.slices {
			a := -2 * math.PI * f64(t) / f64(n.slices)
			v := f64(n.values[t * area + i].x) - mean
			re += v * math.cos(a)
			im += v * math.sin(a)
		}
		time += re * re + im * im
	}
	return
}

@(test)
the_noise_is_blue_over_space_and_time :: proc(t: ^testing.T) {
	n := noise_make(TEST_SIZE, TEST_SLICES, SEED)
	defer noise_destroy(&n)
	first := energy(&n)
	white_space, white_time := low_power(&n)
	optimize(&n, TEST_ROUNDS, SEED)
	last := energy(&n)
	blue_space, blue_time := low_power(&n)
	// Most of the energy is the pairs' floor, which no order removes, so it falls by a few percent: the spectra show
	// what it bought.
	testing.expectf(t, last < first, "the energy went from %f to %f", first, last)
	testing.expectf(t, blue_space < white_space * 0.5, "the low spatial frequencies went from %f to %f", white_space, blue_space)
	testing.expectf(t, blue_time < white_time * 0.5, "the low temporal frequency went from %f to %f", white_time, blue_time)
}

@(test)
each_slice_keeps_every_stratified_value_once :: proc(t: ^testing.T) {
	n := noise_make(TEST_SIZE, TEST_SLICES, SEED)
	defer noise_destroy(&n)
	optimize(&n, 4, SEED)
	area := n.size * n.size
	cells := make([]int, area)
	defer delete(cells)
	for s in 0 ..< n.slices {
		for v, i in n.values[s * area:][:area] {
			x, y := int(v.x * f32(n.size)), int(v.y * f32(n.size))
			cells[i] = y * n.size + x
		}
		slice.sort(cells)
		for c, i in cells {
			if c != i {
				testing.expectf(t, false, "slice %d: cell %d is %d", s, i, c)
				return
			}
		}
	}
}

@(test)
the_same_seed_gives_the_same_bytes :: proc(t: ^testing.T) {
	a := noise_make(TEST_SIZE, TEST_SLICES, SEED)
	defer noise_destroy(&a)
	b := noise_make(TEST_SIZE, TEST_SLICES, SEED)
	defer noise_destroy(&b)
	// Different thread counts, so the slices finish in different orders.
	optimize(&a, 4, SEED, threads = 1)
	optimize(&b, 4, SEED, threads = 2)
	pa, pb := pixels(&a), pixels(&b)
	defer delete(pa)
	defer delete(pb)
	testing.expect(t, slice.equal(pa, pb), "the same seed gave different textures")
	c := noise_make(TEST_SIZE, TEST_SLICES, SEED + 1)
	defer noise_destroy(&c)
	testing.expect(t, !slice.equal(a.values, c.values), "another seed gave the same starting order")
}
