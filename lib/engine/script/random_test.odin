package script

import "core:testing"

// Five values of the sequence of each seed that the script gives.
@(private = "file")
SEQUENCES :: `
for _, seed in { 42, 42, 7 } do
	Random.seed(seed)
	for _ = 1, 5 do
		Test.report(Random.value())
	end
end
`

@(test)
the_same_seed_gives_the_same_sequence :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=sequences", SEQUENCES)
	testing.expect(t, ok)
	if !testing.expect_value(t, len(f.reports), 15) {
		return
	}
	testing.expect(t, f.reports[0] != f.reports[1], "a seed gives one number again and again")
	differ := false
	for i in 0 ..< 5 {
		testing.expect_value(t, f.reports[5 + i], f.reports[i])
		differ ||= f.reports[10 + i] != f.reports[i]
	}
	testing.expect(t, differ, "seeds 42 and 7 give the same sequence")
}

@(test)
two_worlds_with_one_seed_agree :: proc(t: ^testing.T) {
	a := setup(t, register_first_build)
	defer teardown(a)
	b := setup(t, register_first_build)
	defer teardown(b)
	DRAWS :: "for _ = 1, 4 do Test.report(Random.integer(1, 1000000)) end"
	for f in ([]^Fixture{a, b}) {
		context.user_ptr = f
		seed_random(&f.runtime, 1234)
		_, ok := spawn_source(&f.runtime, "=draws", DRAWS)
		testing.expect(t, ok)
	}
	testing.expect_value(t, len(a.reports), 4)
	testing.expect_value(t, len(b.reports), 4)
	for i in 0 ..< min(len(a.reports), len(b.reports)) {
		testing.expect_value(t, b.reports[i], a.reports[i])
	}
}

@(test)
the_generator_survives_a_code_reload :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=whole", "Random.seed(9) for _ = 1, 4 do Test.report(Random.value()) end")
	testing.expect(t, ok)
	_, ok = spawn_source(&f.runtime, "=before", "Random.seed(9) for _ = 1, 2 do Test.report(Random.value()) end")
	testing.expect(t, ok)
	reload(&f.runtime, &f.platform, register_second_build)
	_, ok = spawn_source(&f.runtime, "=after", "for _ = 1, 2 do Test.report(Random.value()) end")
	testing.expect(t, ok)
	if testing.expect_value(t, len(f.reports), 8) {
		for i in 0 ..< 4 {
			testing.expect_value(t, f.reports[4 + i], f.reports[i])
		}
	}
}

@(test)
restart_random_repeats_the_world_seed :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	// init seeds from the clock, below 2^53, and scripts get that seed exactly.
	seed := f.runtime.random_seed
	testing.expect(t, seed < 1 << 53)
	_, ok := spawn_source(&f.runtime, "=seed", "Test.report(Random.get_seed())")
	testing.expect(t, ok)
	DRAWS :: "for _ = 1, 3 do Test.report(Random.value()) end"
	_, ok = spawn_source(&f.runtime, "=first", DRAWS)
	testing.expect(t, ok)
	restart_random(&f.runtime)
	_, ok = spawn_source(&f.runtime, "=again", DRAWS)
	testing.expect(t, ok)
	_, ok = spawn_source(&f.runtime, "=negative", "Random.seed(-5) Test.report(Random.get_seed())")
	testing.expect(t, ok)
	if testing.expect_value(t, len(f.reports), 8) {
		testing.expect_value(t, f.reports[0], f64(seed))
		for i in 0 ..< 3 {
			testing.expect_value(t, f.reports[4 + i], f.reports[1 + i])
		}
		testing.expect_value(t, f.reports[7], -5)
	}
}

// Each check reports 1 when it holds over many draws.
@(private = "file")
RANGES :: `
Random.seed(3)
local ok_value, ok_range, ok_sphere, ok_surface, ok_circle, ok_rotation = true, true, true, true, true, true
local faces = {}
for _ = 1, 2000 do
	local v = Random.value()
	ok_value = ok_value and v >= 0 and v < 1
	local r = Random.range(-2, 3)
	ok_range = ok_range and r >= -2 and r < 3
	local face = Random.integer(1, 6)
	faces[face] = (faces[face] or 0) + 1
	ok_sphere = ok_sphere and vector.magnitude(Random.inside_unit_sphere()) <= 1 + 1e-6
	ok_surface = ok_surface and math.abs(vector.magnitude(Random.on_unit_sphere()) - 1) < 1e-5
	local c = Random.inside_unit_circle()
	ok_circle = ok_circle and c.z == 0 and vector.magnitude(c) <= 1 + 1e-6
	local q = Random.rotation()
	ok_rotation = ok_rotation and math.abs(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w - 1) < 1e-5
end
local ok_faces = true
for face, count in faces do
	ok_faces = ok_faces and face >= 1 and face <= 6 and face == math.floor(face)
end
for face = 1, 6 do
	ok_faces = ok_faces and faces[face] ~= nil
end
Test.report(Random.integer(4, 4))
for _, ok in { ok_value, ok_range, ok_faces, ok_sphere, ok_surface, ok_circle, ok_rotation } do
	Test.report(ok and 1 or 0)
end
`

@(test)
random_values_stay_in_their_ranges :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=ranges", RANGES)
	testing.expect(t, ok)
	expected := []f64{4, 1, 1, 1, 1, 1, 1, 1}
	if testing.expect_value(t, len(f.reports), len(expected)) {
		for v, i in expected {
			testing.expectf(t, f.reports[i] == v, "report %d is %v, not %v", i, f.reports[i], v)
		}
	}
}

@(test)
random_refuses_bad_arguments :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	context.logger = capture_errors(f)
	_, ok := spawn_source(&f.runtime, "=reversed", "Random.integer(5, 1)")
	testing.expect(t, !ok)
	expect_error(t, f, "max is less than min")
	_, ok = spawn_source(&f.runtime, "=fraction", "Random.integer(1.5, 3)")
	testing.expect(t, !ok)
	expect_error(t, f, "min must be an integer")
	_, ok = spawn_source(&f.runtime, "=seed", "Random.seed(0.5)")
	testing.expect(t, !ok)
	expect_error(t, f, "the seed must be an integer")
}
