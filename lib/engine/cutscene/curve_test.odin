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
	testing.expect_value(t, curve_value(keys, 0), 2)
	testing.expect_value(t, curve_value(keys, SECOND), 2)
	testing.expect_value(t, curve_value(keys, 2 * SECOND), 6)
	testing.expect_value(t, curve_value(keys, 10 * SECOND), 6)
	testing.expect_value(t, curve_value(keys[:1], 5 * SECOND), 2)
	testing.expect_value(t, curve_value(nil, 5 * SECOND), 0)
}

@(test)
constant_and_linear_keys_step_and_ramp :: proc(t: ^testing.T) {
	keys := []format.Cutscene_Key {
		key(0, 1, .Constant),
		key(SECOND, 3, .Linear),
		key(3 * SECOND, 7, .Constant),
	}
	testing.expect_value(t, curve_value(keys, SECOND / 2), 1)
	testing.expect_value(t, curve_value(keys, SECOND - 1), 1)
	testing.expect_value(t, curve_value(keys, SECOND), 3)
	testing.expect_value(t, curve_value(keys, 2 * SECOND), 5)
	testing.expect_value(t, curve_value(keys, 3 * SECOND), 7)
	testing.expect_value(t, curve_step(keys, 2 * SECOND), 3)
	testing.expect_value(t, curve_step(keys, 3 * SECOND - 1), 3)
	testing.expect_value(t, curve_step(keys, 3 * SECOND), 7)
	testing.expect_value(t, curve_step(keys, -1), 1)
}

@(test)
a_bezier_segment_follows_its_tangents :: proc(t: ^testing.T) {
	// From 0 with a slope of 2 a second to 2 with a slope of 2 a second over one second: the line v = 2t.
	line := []format.Cutscene_Key{bezier(0, 0, 2, 2), bezier(SECOND, 2, 2, 2)}
	for tick := i32(0); tick <= SECOND; tick += SECOND / 8 {
		want := 2 * f32(tick) / SECOND
		testing.expectf(
			t,
			abs(curve_value(line, tick) - want) < 1e-6,
			"at %d: %v, not %v",
			tick,
			curve_value(line, tick),
			want,
		)
	}
	// Flat tangents ease from one value to the other: the middle is halfway, and the first quarter is below a line.
	eased := []format.Cutscene_Key{bezier(0, 0, 0, 0), bezier(SECOND, 1, 0, 0)}
	testing.expect(t, abs(curve_value(eased, SECOND / 2) - 0.5) < 1e-6)
	testing.expect(t, curve_value(eased, SECOND / 4) < 0.25)
	// The slope is in value per second, so the same keys over two seconds have half the effect of their tangents.
	steep := []format.Cutscene_Key{bezier(0, 0, 4, 4), bezier(SECOND, 0, 4, 4)}
	slow := []format.Cutscene_Key{bezier(0, 0, 4, 4), bezier(2 * SECOND, 0, 4, 4)}
	testing.expect(t, curve_value(steep, SECOND / 4) > 0)
	testing.expect(
		t,
		abs(curve_value(slow, SECOND / 2) - 2 * curve_value(steep, SECOND / 4)) < 1e-5,
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
	before := curve_value(broken, SECOND - SECOND / 10)
	after := curve_value(broken, SECOND + SECOND / 10)
	testing.expect(t, before < 1 && after < 1, "the corner is a peak")
	testing.expect(t, abs(before - after) < 1e-5, "with mirrored slopes, the two sides mirror")
	testing.expect(
		t,
		curve_value(unified, SECOND + SECOND / 10) > 1,
		"a unified slope carries the curve on past the key",
	)
	testing.expect_value(t, curve_value(broken, SECOND), 1)
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
		a, b := curve_value(plain, tick), curve_value(weighted, tick)
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
	testing.expect(t, curve_value(heavy, SECOND / 4) < curve_value(light, SECOND / 4))
	testing.expect_value(t, curve_value(heavy, 0), 0)
	testing.expect_value(t, curve_value(heavy, SECOND), 1)
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
		v := curve_value(plateau, tick)
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
		v := curve_value(rise, tick)
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
				curve_value(keys, tick, &hint) == curve_value(keys, tick),
				"at %d with the hint %d",
				tick,
				hint_start,
			)
			hint = hint_start
			testing.expect(t, curve_step(keys, tick, &hint) == curve_step(keys, tick))
		}
	}
	// Playback: the hint follows the time forward, one segment at a time.
	hint := 0
	for tick := i32(0); tick <= 4 * SECOND; tick += 1000 {
		testing.expect(t, curve_value(keys, tick, &hint) == curve_value(keys, tick))
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
			fmt.sbprintfln(&b, "at %d %08x", tick, transmute(u32)curve_value(keys, tick))
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
		case "at":
			tick, _ := strconv.parse_int(fields[1])
			bits, _ := strconv.parse_u64_of_base(fields[2], 16)
			got := curve_value(keys, i32(tick))
			want := transmute(f32)u32(bits)
			testing.expectf(
				t,
				transmute(u32)got == transmute(u32)want,
				"at %d: %v, not %v",
				tick,
				got,
				want,
			)
			count += 1
		}
	}
	testing.expect_value(t, key_index, len(keys))
	testing.expect_value(t, count, 120000 / GOLDEN_STEP + 3)
	testing.expect(t, !math.is_nan(curve_value(keys, 50000)))
}
