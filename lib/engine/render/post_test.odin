package render

import "core:math"
import "core:testing"

// Bloom halves the scene while the shorter side is at least 4 pixels, up to 8 levels, and the smallest levels, under 16
// pixels on their shorter side, are upsampled with Catmull-Rom (see docs/rendering/post-processing.md#bloom).
@(test)
bloom_goes_down_while_the_shorter_side_is_four_pixels :: proc(t: ^testing.T) {
	levels, sizes := bloom_chain({1920, 1080})
	testing.expect_value(t, levels, 8)
	testing.expect_value(t, sizes[0], [2]u32{960, 540})
	testing.expect_value(t, sizes[5], [2]u32{30, 16})
	testing.expect_value(t, sizes[7], [2]u32{7, 4})
	testing.expect_value(t, bloom_up_mode(sizes[5]), BLOOM_UP)
	testing.expect_value(t, bloom_up_mode(sizes[6]), BLOOM_UP_BICUBIC)
	testing.expect_value(t, bloom_up_mode(sizes[7]), BLOOM_UP_BICUBIC)

	levels, sizes = bloom_chain({2560, 1440})
	testing.expect_value(t, levels, 8)
	testing.expect_value(t, sizes[7], [2]u32{10, 5})

	// A small view stops before the shorter side is under 4 pixels.
	levels, sizes = bloom_chain({64, 36})
	testing.expect_value(t, levels, 3)
	testing.expect_value(t, sizes[2], [2]u32{8, 4})

	// The first level is there at any size.
	levels, sizes = bloom_chain({1, 1})
	testing.expect_value(t, levels, 1)
	testing.expect_value(t, sizes[0], [2]u32{1, 1})
}

// Adapt_Input and adapt_exposure match Push and cs_main in exposure_adapt.hlsl: the next exposure from the histogram's
// bins and the current exposure.
@(private = "file")
Adapt_Input :: struct {
	bins:         [HISTOGRAM_BINS]u32,
	current:      f32,
	manual:       bool,
	reset:        bool,
	limits:       [2]f32,
	compensation: f32,
	scale:        f32,
	adapt:        f32,
}

@(private = "file")
adapt_exposure :: proc(in_: Adapt_Input) -> f32 {
	MIDDLE_GREY :: 0.18
	MIN_EXPOSURE :: 5.421010862427522e-20 // 2^-64
	MAX_EXPOSURE :: 1.8446744073709552e19 // 2^64
	current := in_.current
	valid := !math.is_nan(current) && !math.is_inf(current) && current > 0
	if !valid {
		current = 1
	}
	target := in_.scale * exp2(in_.compensation)
	if !in_.manual {
		total: f32
		for count in in_.bins {
			total += f32(count)
		}
		low, high := total * 0.1, total * 0.9
		seen, sum, weight: f32
		for count, b in in_.bins {
			taken := clamp(seen + f32(count), low, high) - clamp(seen, low, high)
			sum += taken * bin_log(b)
			weight += taken
			seen += f32(count)
		}
		target =
			weight > 0 ? MIDDLE_GREY / exp2(clamp(sum / weight, in_.limits[0], in_.limits[1])) * exp2(in_.compensation) : current
	}
	next := target
	if !(in_.reset || in_.manual || !valid) {
		next = exp2(math.lerp(math.log2(current), math.log2(target), in_.adapt))
	}
	return clamp(next, MIN_EXPOSURE, MAX_EXPOSURE)
}

// bin_log matches exposure_adapt.hlsl's: the log2 luminance at a bin's middle.
@(private = "file")
bin_log :: proc(bin: int) -> f32 {
	range :: f32(HISTOGRAM_MAX_LOG - HISTOGRAM_MIN_LOG)
	return(
		bin == 0 ? HISTOGRAM_MIN_LOG : HISTOGRAM_MIN_LOG + (f32(bin) - 0.5) / (HISTOGRAM_BINS - 2) * range \
	)
}

// The bin that log2 luminance l falls in, as exposure_histogram.hlsl counts it.
@(private = "file")
bin_of :: proc(l: f32) -> int {
	return(
		int(
			(l - HISTOGRAM_MIN_LOG) /
			(HISTOGRAM_MAX_LOG - HISTOGRAM_MIN_LOG) *
			(HISTOGRAM_BINS - 2),
		) +
		1 \
	)
}

// With nothing in the histogram, as while the sky compiles in an empty world, the exposure stays where it is: the
// compensation is in it already, and does not compound each frame (#444).
@(test)
an_empty_histogram_holds_the_exposure :: proc(t: ^testing.T) {
	in_ := Adapt_Input {
		current      = 1,
		reset        = true,
		limits       = DEFAULT_EXPOSURE_RANGE,
		compensation = 4,
		scale        = 1,
		adapt        = 0.1,
	}
	in_.current = adapt_exposure(in_)
	testing.expect_value(t, in_.current, 1)
	in_.reset = false
	for _ in 0 ..< 100 {
		in_.current = adapt_exposure(in_)
	}
	testing.expect_value(t, in_.current, 1)

	// From an adapted exposure, an empty histogram keeps it, compensation and all.
	in_.current = 3
	testing.expect_value(t, adapt_exposure(in_), 3)
}

// The compensation applies once to the histogram's target.
@(test)
the_compensation_applies_once :: proc(t: ^testing.T) {
	in_ := Adapt_Input {
		current      = 1,
		reset        = true,
		limits       = DEFAULT_EXPOSURE_RANGE,
		compensation = 4,
		scale        = 1,
		adapt        = 0.1,
	}
	b := bin_of(-2)
	in_.bins[b] = 1000
	target := 0.18 / exp2(bin_log(b)) * 16
	testing.expect(t, abs(adapt_exposure(in_) / target - 1) < 1e-5)

	// Adapting to the same scene does not go past it.
	in_.reset = false
	in_.current = target
	for _ in 0 ..< 100 {
		in_.current = adapt_exposure(in_)
	}
	testing.expect(t, abs(in_.current / target - 1) < 1e-4)
}

// An exposure that is not finite and positive goes to the target at once, so the view comes back (#444).
@(test)
an_exposure_out_of_range_comes_back :: proc(t: ^testing.T) {
	for current in ([]f32{math.inf_f32(1), math.inf_f32(-1), math.nan_f32(), 0, -1}) {
		in_ := Adapt_Input {
			current      = current,
			limits       = DEFAULT_EXPOSURE_RANGE,
			compensation = 4,
			scale        = 1,
			adapt        = 0.1,
		}
		testing.expect_value(t, adapt_exposure(in_), 1)

		b := bin_of(0)
		in_.bins[b] = 1000
		target := 0.18 / exp2(bin_log(b)) * 16
		testing.expect(t, abs(adapt_exposure(in_) / target - 1) < 1e-5)
	}

	// No compensation stores an infinite or zero exposure.
	for compensation in ([]f32{1000, -1000}) {
		in_ := Adapt_Input {
			current      = 1,
			manual       = true,
			compensation = compensation,
			scale        = 1,
		}
		next := adapt_exposure(in_)
		testing.expect(t, next > 0 && !math.is_inf(next))
	}
}

@(private = "file")
exp2 :: proc(x: f32) -> f32 {
	return math.pow(2, x)
}
