package cutscene

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
SECOND :: format.CUTSCENE_TICKS_PER_SECOND

// GOLDEN_PATH is the shared test curve and its value at every tick that is a multiple of GOLDEN_STEP. The editor's
// evaluator reads the same file (see docs/cinematics/tracks.md#curves). Run the tests with the environment variable
// CINNABAR_WRITE_CURVE_GOLDEN=1 to write it again after a deliberate change to the evaluator.
@(private = "file")
GOLDEN_PATH :: "lib/engine/cutscene/testdata/curve.txt"
@(private = "file")
GOLDEN_STEP :: 250

// GOLDEN_INFINITY is each infinity block of the shared file: its pre and post modes, on the golden curve's keys from
// GOLDEN_FROM to GOLDEN_TO. Those keys leave the first on a Bezier slope and reach the last on a linear segment, and
// their values change, so linear and cycle with offset each give something other than a hold. Each mode is on each side
// once, beside another, so a side read as the other fails.
@(private = "file")
GOLDEN_INFINITY := [?][2]format.Cutscene_Infinity {
	{.Linear, .Cycle},
	{.Cycle, .Oscillate},
	{.Cycle_Offset, .Linear},
	{.Oscillate, .Cycle_Offset},
}
@(private = "file")
GOLDEN_FROM :: 3
@(private = "file")
GOLDEN_TO :: 6
// GOLDEN_INFINITY_TICKS are the infinity blocks' ticks from GOLDEN_INFINITY_START to GOLDEN_INFINITY_END in steps of
// GOLDEN_STEP, and then the ticks of golden_infinity_edges.
@(private = "file")
GOLDEN_INFINITY_START :: -60000
@(private = "file")
GOLDEN_INFINITY_END :: 180000

// golden_infinity_edges are the ticks beside the keys' ends and their repeats, where a floored division goes wrong
// first, and two far ticks, which need the i64 arithmetic.
@(private = "file")
golden_infinity_edges :: proc(keys: []format.Cutscene_Key) -> [12]i32 {
	first, last := keys[0].time, keys[len(keys) - 1].time
	span := last - first
	return {
		first - 1,
		first + 1,
		last - 1,
		last + 1,
		last + span - 1,
		last + span + 1,
		first - span - 1,
		first - span + 1,
		first - 2 * span,
		last + 2 * span,
		-2_000_000_000,
		2_000_000_000,
	}
}

@(private = "file")
INFINITY_NAMES := [format.Cutscene_Infinity]string {
	.Constant     = "constant",
	.Linear       = "linear",
	.Cycle        = "cycle",
	.Cycle_Offset = "cycle_offset",
	.Oscillate    = "oscillate",
}

@(private = "file")
key :: proc(time: i32, value: f32, interp: format.Cutscene_Interp) -> format.Cutscene_Key {
	return {time = time, value = value, interp = interp}
}

@(private = "file")
bezier :: proc(
	time: i32,
	value: f32,
	in_slope, out_slope: f32,
	in_weight: f32 = 0,
	out_weight: f32 = 0,
	weighted := false,
) -> format.Cutscene_Key {
	k := format.Cutscene_Key {
		time      = time,
		value     = value,
		interp    = .Bezier,
		in_slope  = in_slope,
		out_slope = out_slope,
	}
	if in_slope != out_slope {
		k.flags += {.Broken}
	}
	if weighted {
		k.flags += {.Weighted}
		k.in_weight, k.out_weight = in_weight, out_weight
	}
	return k
}

@(test)
a_curve_holds_before_its_first_key_and_after_its_last :: proc(t: ^testing.T) {
	keys := []format.Cutscene_Key{key(SECOND, 2, .Linear), key(2 * SECOND, 6, .Bezier)}
	testing.expect_value(t, curve_value(keys, 0, .Constant, .Constant), 2)
	testing.expect_value(t, curve_value(keys, SECOND, .Constant, .Constant), 2)
	testing.expect_value(t, curve_value(keys, 2 * SECOND, .Constant, .Constant), 6)
	testing.expect_value(t, curve_value(keys, 10 * SECOND, .Constant, .Constant), 6)
	testing.expect_value(t, curve_value(keys[:1], 5 * SECOND, .Constant, .Constant), 2)
	testing.expect_value(t, curve_value(nil, 5 * SECOND, .Constant, .Constant), 0)
}

@(test)
each_infinity_mode_carries_the_curve_past_its_keys :: proc(t: ^testing.T) {
	// From 2 at 1 s to 6 at 3 s: a span of 2 s, a change of 4 and a slope of 2 a second.
	keys := []format.Cutscene_Key{key(SECOND, 2, .Linear), key(3 * SECOND, 6, .Linear)}
	testing.expect_value(t, curve_value(keys, 0, .Linear, .Constant), 0)
	testing.expect_value(t, curve_value(keys, 4 * SECOND, .Constant, .Linear), 8)
	testing.expect_value(t, curve_value(keys, 4 * SECOND, .Constant, .Constant), 6)
	// A cycle before the first key wraps forward: 1 s before it is 1 s into the span, not 1 s before its end.
	testing.expect_value(t, curve_value(keys, 0, .Cycle, .Constant), 4)
	testing.expect_value(t, curve_value(keys, 4 * SECOND, .Constant, .Cycle), 4)
	testing.expect_value(t, curve_value(keys, 5 * SECOND, .Constant, .Cycle), 2)
	testing.expect_value(t, curve_value(keys, 0, .Cycle_Offset, .Constant), 0)
	testing.expect_value(t, curve_value(keys, 4 * SECOND, .Constant, .Cycle_Offset), 8)
	testing.expect_value(t, curve_value(keys, 5 * SECOND, .Constant, .Cycle_Offset), 10)
	testing.expect_value(t, curve_value(keys, -3 * SECOND, .Cycle_Offset, .Constant), -6)
	// Oscillate goes back from the end, then forward again.
	testing.expect_value(t, curve_value(keys, 0, .Oscillate, .Constant), 4)
	testing.expect_value(t, curve_value(keys, 4 * SECOND, .Constant, .Oscillate), 4)
	testing.expect_value(t, curve_value(keys, 5 * SECOND, .Constant, .Oscillate), 2)
	testing.expect_value(t, curve_value(keys, 5 * SECOND + SECOND / 2, .Constant, .Oscillate), 3)
	// Each side reads its own mode.
	testing.expect_value(t, curve_value(keys, 0, .Constant, .Linear), 2)
	testing.expect_value(t, curve_value(keys, 4 * SECOND, .Linear, .Constant), 6)
}

@(test)
a_curve_whose_keys_span_no_time_holds_in_every_mode :: proc(t: ^testing.T) {
	keys := []format.Cutscene_Key{key(SECOND, 2, .Linear)}
	for mode in format.Cutscene_Infinity {
		testing.expect_value(t, curve_value(keys, 0, mode, mode), 2)
		testing.expect_value(t, curve_value(keys, 9 * SECOND, mode, mode), 2)
		testing.expect_value(t, curve_step(keys, 9 * SECOND, mode, mode), 2)
	}
}

@(test)
a_stepped_curve_repeats_and_holds_its_linear_side :: proc(t: ^testing.T) {
	keys := []format.Cutscene_Key {
		key(0, 1, .Constant),
		key(SECOND, 3, .Constant),
		key(2 * SECOND, 5, .Constant),
	}
	testing.expect_value(t, curve_step(keys, 3 * SECOND, .Constant, .Linear), 5)
	testing.expect_value(t, curve_step(keys, -SECOND, .Linear, .Constant), 1)
	testing.expect_value(t, curve_step(keys, 2 * SECOND + SECOND / 2, .Constant, .Cycle), 1)
	testing.expect_value(t, curve_step(keys, 2 * SECOND + SECOND / 2, .Constant, .Cycle_Offset), 5)
	testing.expect_value(t, curve_step(keys, 2 * SECOND + SECOND / 2, .Constant, .Oscillate), 3)
	testing.expect_value(t, curve_step(keys, -SECOND / 2, .Cycle, .Constant), 3)
}

@(test)
constant_and_linear_keys_step_and_ramp :: proc(t: ^testing.T) {
	keys := []format.Cutscene_Key {
		key(0, 1, .Constant),
		key(SECOND, 3, .Linear),
		key(3 * SECOND, 7, .Constant),
	}
	testing.expect_value(t, curve_value(keys, SECOND / 2, .Constant, .Constant), 1)
	testing.expect_value(t, curve_value(keys, SECOND - 1, .Constant, .Constant), 1)
	testing.expect_value(t, curve_value(keys, SECOND, .Constant, .Constant), 3)
	testing.expect_value(t, curve_value(keys, 2 * SECOND, .Constant, .Constant), 5)
	testing.expect_value(t, curve_value(keys, 3 * SECOND, .Constant, .Constant), 7)
	testing.expect_value(t, curve_step(keys, 2 * SECOND, .Constant, .Constant), 3)
	testing.expect_value(t, curve_step(keys, 3 * SECOND - 1, .Constant, .Constant), 3)
	testing.expect_value(t, curve_step(keys, 3 * SECOND, .Constant, .Constant), 7)
	testing.expect_value(t, curve_step(keys, -1, .Constant, .Constant), 1)
}

@(test)
a_bezier_segment_follows_its_tangents :: proc(t: ^testing.T) {
	// From 0 with a slope of 2 a second to 2 with a slope of 2 a second over one second: the line v = 2t.
	line := []format.Cutscene_Key{bezier(0, 0, 2, 2), bezier(SECOND, 2, 2, 2)}
	for tick := i32(0); tick <= SECOND; tick += SECOND / 8 {
		want := 2 * f32(tick) / SECOND
		testing.expectf(
			t,
			abs(curve_value(line, tick, .Constant, .Constant) - want) < 1e-6,
			"at %d: %v, not %v",
			tick,
			curve_value(line, tick, .Constant, .Constant),
			want,
		)
	}
	// Flat tangents ease from one value to the other: the middle is halfway, and the first quarter is below a line.
	eased := []format.Cutscene_Key{bezier(0, 0, 0, 0), bezier(SECOND, 1, 0, 0)}
	testing.expect(t, abs(curve_value(eased, SECOND / 2, .Constant, .Constant) - 0.5) < 1e-6)
	testing.expect(t, curve_value(eased, SECOND / 4, .Constant, .Constant) < 0.25)
	// The slope is in value per second, so the same keys over two seconds have half the effect of their tangents.
	steep := []format.Cutscene_Key{bezier(0, 0, 4, 4), bezier(SECOND, 0, 4, 4)}
	slow := []format.Cutscene_Key{bezier(0, 0, 4, 4), bezier(2 * SECOND, 0, 4, 4)}
	testing.expect(t, curve_value(steep, SECOND / 4, .Constant, .Constant) > 0)
	testing.expect(
		t,
		abs(
			curve_value(slow, SECOND / 2, .Constant, .Constant) -
			2 * curve_value(steep, SECOND / 4, .Constant, .Constant),
		) <
		1e-5,
		"a segment twice as long rises twice as far with the same slopes",
	)
}

@(test)
broken_tangents_leave_a_key_at_another_slope :: proc(t: ^testing.T) {
	// The middle key comes in rising and leaves falling, so the curve peaks there with a corner.
	broken := []format.Cutscene_Key {
		bezier(0, 0, 0, 0),
		bezier(SECOND, 1, 3, -3),
		bezier(2 * SECOND, 0, 0, 0),
	}
	unified := []format.Cutscene_Key {
		bezier(0, 0, 0, 0),
		bezier(SECOND, 1, 3, 3),
		bezier(2 * SECOND, 0, 0, 0),
	}
	testing.expect_value(t, broken[1].flags, format.Cutscene_Key_Flags{.Broken})
	testing.expect_value(t, unified[1].flags, format.Cutscene_Key_Flags{})
	before := curve_value(broken, SECOND - SECOND / 10, .Constant, .Constant)
	after := curve_value(broken, SECOND + SECOND / 10, .Constant, .Constant)
	testing.expect(t, before < 1 && after < 1, "the corner is a peak")
	testing.expect(t, abs(before - after) < 1e-5, "with mirrored slopes, the two sides mirror")
	testing.expect(
		t,
		curve_value(unified, SECOND + SECOND / 10, .Constant, .Constant) > 1,
		"a unified slope carries the curve on past the key",
	)
	testing.expect_value(t, curve_value(broken, SECOND, .Constant, .Constant), 1)
}

@(test)
weights_of_a_third_are_the_hermite_curve :: proc(t: ^testing.T) {
	third := f32(format.CUTSCENE_TANGENT_WEIGHT)
	plain := []format.Cutscene_Key{bezier(0, 0, 1, 1), bezier(SECOND, 2, -1, -1)}
	weighted := []format.Cutscene_Key {
		bezier(0, 0, 1, 1, third, third, true),
		bezier(SECOND, 2, -1, -1, third, third, true),
	}
	for tick := i32(0); tick <= SECOND; tick += SECOND / 16 {
		a, b :=
			curve_value(plain, tick, .Constant, .Constant),
			curve_value(weighted, tick, .Constant, .Constant)
		testing.expectf(t, abs(a - b) < 1e-5, "at %d: %v and %v", tick, a, b)
	}
	// A heavier out handle holds the start's slope for longer, so early on the curve is closer to its tangent's line.
	heavy := []format.Cutscene_Key {
		bezier(0, 0, 0, 0, 0, 0.9, true),
		bezier(SECOND, 1, 0, 0, third, third, true),
	}
	light := []format.Cutscene_Key {
		bezier(0, 0, 0, 0, 0, 0.1, true),
		bezier(SECOND, 1, 0, 0, third, third, true),
	}
	testing.expect(
		t,
		curve_value(heavy, SECOND / 4, .Constant, .Constant) <
		curve_value(light, SECOND / 4, .Constant, .Constant),
	)
	testing.expect_value(t, curve_value(heavy, 0, .Constant, .Constant), 0)
	testing.expect_value(t, curve_value(heavy, SECOND, .Constant, .Constant), 1)
}

@(test)
auto_keys_do_not_overshoot :: proc(t: ^testing.T) {
	// Two keys of one value between two of another: an auto curve stays inside [0, 1].
	plateau := []format.Cutscene_Key {
		key(0, 0, .Auto),
		key(SECOND, 1, .Auto),
		key(2 * SECOND, 1, .Auto),
		key(3 * SECOND, 0, .Auto),
	}
	for tick := i32(0); tick <= 3 * SECOND; tick += 100 {
		v := curve_value(plateau, tick, .Constant, .Constant)
		testing.expectf(t, v >= 0 && v <= 1, "at %d: %v", tick, v)
		if tick >= SECOND && tick <= 2 * SECOND {
			testing.expectf(t, v == 1, "between the two keys of 1, at %d: %v", tick, v)
		}
	}
	// A rise that slows: each key's slope is limited, so the curve never passes the next key's value.
	rise := []format.Cutscene_Key {
		key(0, 0, .Auto),
		key(SECOND / 10, 10, .Auto),
		key(SECOND, 10.5, .Auto),
		key(2 * SECOND, 11, .Auto),
	}
	last := f32(0)
	for tick := i32(0); tick <= 2 * SECOND; tick += 50 {
		v := curve_value(rise, tick, .Constant, .Constant)
		testing.expectf(t, v >= last && v <= 11, "at %d: %v after %v", tick, v, last)
		last = v
	}
	// The first and the last key are flat, and a middle key on a slope is not.
	testing.expect_value(t, curve_auto_slope(rise, 0), 0)
	testing.expect_value(t, curve_auto_slope(rise, 3), 0)
	testing.expect(t, curve_auto_slope(rise, 2) > 0)
}

@(test)
a_stale_hint_changes_no_value :: proc(t: ^testing.T) {
	keys := []format.Cutscene_Key {
		key(0, 0, .Auto),
		key(SECOND, 3, .Linear),
		key(2 * SECOND, -1, .Auto),
		key(3 * SECOND, 2, .Constant),
		key(4 * SECOND, 5, .Auto),
	}
	for hint_start in -2 ..< 8 {
		for tick := i32(-SECOND); tick <= 5 * SECOND; tick += 777 {
			hint := hint_start
			testing.expectf(
				t,
				curve_value(keys, tick, .Constant, .Constant, &hint) ==
				curve_value(keys, tick, .Constant, .Constant),
				"at %d with the hint %d",
				tick,
				hint_start,
			)
			hint = hint_start
			testing.expect(
				t,
				curve_step(keys, tick, .Constant, .Constant, &hint) ==
				curve_step(keys, tick, .Constant, .Constant),
			)
		}
	}
	// Playback: the hint follows the time forward, one segment at a time.
	hint := 0
	for tick := i32(0); tick <= 4 * SECOND; tick += 1000 {
		testing.expect(
			t,
			curve_value(keys, tick, .Constant, .Constant, &hint) ==
			curve_value(keys, tick, .Constant, .Constant),
		)
	}
	testing.expect_value(t, hint, 3)
}

// golden_curve is the shared test curve: every interpolation, broken and unified tangents, weights, and auto keys at a
// plateau.
@(private = "file")
golden_curve :: proc() -> []format.Cutscene_Key {
	keys := []format.Cutscene_Key {
		key(0, 0, .Auto),
		key(15000, 1.5, .Auto),
		bezier(30000, 2, 0.5, -1.25),
		bezier(45000, 0.25, 2, 2, 0.75, 0.125, true),
		key(60000, 1, .Linear),
		key(72000, -0.5, .Constant),
		key(84000, 3, .Auto),
		key(96000, 3, .Auto),
		bezier(108000, 0, 0, 0, 0.5, 0.5, true),
		key(120000, 0, .Linear),
	}
	return slice.clone(keys, context.temp_allocator)
}

@(test)
the_curve_gives_the_shared_values :: proc(t: ^testing.T) {
	keys := golden_curve()
	if os.get_env("CINNABAR_WRITE_CURVE_GOLDEN", context.temp_allocator) == "1" {
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintln(
			&b,
			"# The shared test curve and its values (see docs/cinematics/tracks.md#curves). lib/engine/cutscene/curve_test.odin",
		)
		fmt.sbprintln(
			&b,
			"# writes it. key: time, value, interpolation, flags (- for none), in slope, in weight, out slope, out weight.",
		)
		fmt.sbprintln(&b, "# at: a tick and the value there, as the bits of an f32 in hex.")
		fmt.sbprintln(
			&b,
			"# infinity: the pre and post modes, and the keys from the first index to before the second, of the at lines after it.",
		)
		INTERPS := [format.Cutscene_Interp]string {
			.Constant = "constant",
			.Linear   = "linear",
			.Bezier   = "bezier",
			.Auto     = "auto",
		}
		for k in keys {
			flags := "-"
			switch k.flags {
			case {.Broken}:
				flags = "broken"
			case {.Weighted}:
				flags = "weighted"
			case {.Broken, .Weighted}:
				flags = "broken,weighted"
			}
			fmt.sbprintf(&b, "key %d %v %s %s", k.time, k.value, INTERPS[k.interp], flags)
			fmt.sbprintfln(&b, " %v %v %v %v", k.in_slope, k.in_weight, k.out_slope, k.out_weight)
		}
		for tick := i32(-GOLDEN_STEP); tick <= 120000 + GOLDEN_STEP; tick += GOLDEN_STEP {
			fmt.sbprintfln(
				&b,
				"at %d %08x",
				tick,
				transmute(u32)curve_value(keys, tick, .Constant, .Constant),
			)
		}
		part := keys[GOLDEN_FROM:GOLDEN_TO]
		for modes in GOLDEN_INFINITY {
			fmt.sbprintfln(
				&b,
				"infinity %s %s %d %d",
				INFINITY_NAMES[modes[0]],
				INFINITY_NAMES[modes[1]],
				GOLDEN_FROM,
				GOLDEN_TO,
			)
			for tick := i32(GOLDEN_INFINITY_START);
			    tick <= GOLDEN_INFINITY_END;
			    tick += GOLDEN_STEP {
				fmt.sbprintfln(
					&b,
					"at %d %08x",
					tick,
					transmute(u32)curve_value(part, tick, modes[0], modes[1]),
				)
			}
			for tick in golden_infinity_edges(part) {
				fmt.sbprintfln(
					&b,
					"at %d %08x",
					tick,
					transmute(u32)curve_value(part, tick, modes[0], modes[1]),
				)
			}
		}
		testing.expect(
			t,
			os.write_entire_file(GOLDEN_PATH, transmute([]byte)strings.to_string(b)) == nil,
		)
	}
	data, read_err := os.read_entire_file(GOLDEN_PATH, context.temp_allocator)
	read := read_err == nil
	testing.expect(t, read, "the shared curve's values are in " + GOLDEN_PATH)
	if !read {
		return
	}
	count := 0
	block_counts: [len(GOLDEN_INFINITY)]int
	block := -1
	curve := keys
	pre, post := format.Cutscene_Infinity.Constant, format.Cutscene_Infinity.Constant
	text := string(data)
	key_index := 0
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 0 || fields[0] == "#" || strings.has_prefix(fields[0], "#") {
			continue
		}
		switch fields[0] {
		case "key":
			// The file's curve is the test's curve.
			testing.expect(t, key_index < len(keys))
			if key_index < len(keys) {
				time, _ := strconv.parse_int(fields[1])
				value, _ := strconv.parse_f32(fields[2])
				testing.expect_value(t, i32(time), keys[key_index].time)
				testing.expect_value(t, value, keys[key_index].value)
			}
			key_index += 1
		case "infinity":
			// The blocks are GOLDEN_INFINITY's, in order.
			block += 1
			testing.expect(t, block < len(GOLDEN_INFINITY))
			if block >= len(GOLDEN_INFINITY) {
				return
			}
			testing.expect_value(t, fields[1], INFINITY_NAMES[GOLDEN_INFINITY[block][0]])
			testing.expect_value(t, fields[2], INFINITY_NAMES[GOLDEN_INFINITY[block][1]])
			testing.expect_value(t, fields[3], fmt.tprint(GOLDEN_FROM))
			testing.expect_value(t, fields[4], fmt.tprint(GOLDEN_TO))
			curve = keys[GOLDEN_FROM:GOLDEN_TO]
			pre, post = GOLDEN_INFINITY[block][0], GOLDEN_INFINITY[block][1]
		case "at":
			tick, _ := strconv.parse_int(fields[1])
			bits, _ := strconv.parse_u64_of_base(fields[2], 16)
			got := curve_value(curve, i32(tick), pre, post)
			want := transmute(f32)u32(bits)
			testing.expectf(
				t,
				transmute(u32)got == transmute(u32)want,
				"at %d: %v, not %v",
				tick,
				got,
				want,
			)
			if block < 0 {
				count += 1
			} else {
				block_counts[block] += 1
			}
		}
	}
	testing.expect_value(t, key_index, len(keys))
	testing.expect_value(t, count, 120000 / GOLDEN_STEP + 3)
	testing.expect_value(t, block + 1, len(GOLDEN_INFINITY))
	for n in block_counts {
		testing.expect_value(
			t,
			n,
			(GOLDEN_INFINITY_END - GOLDEN_INFINITY_START) / GOLDEN_STEP +
			1 +
			len(golden_infinity_edges(keys)),
		)
	}
	testing.expect(t, !math.is_nan(curve_value(keys, 50000, .Constant, .Constant)))
}
