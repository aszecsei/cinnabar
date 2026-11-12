package random

import "core:testing"

// The first values of seed 42, from the reference algorithm, so a change to the generator shows.
@(test)
a_seed_gives_the_reference_sequence :: proc(t: ^testing.T) {
	g: State
	seed(&g, 42)
	for want in ([]u64{0x15780b2e0c2ec716, 0x6104d9866d113a7e, 0xae17533239e499a1, 0xecb8ad4703b360a1}) {
		testing.expect_value(t, next(&g), want)
	}
}

@(test)
floats_and_integers_stay_in_their_ranges :: proc(t: ^testing.T) {
	g: State
	seed(&g, 7)
	for _ in 0 ..< 10000 {
		a, b, n := float64(&g), float32(&g), below(&g, 3)
		testing.expect(t, a >= 0 && a < 1 && b >= 0 && b < 1 && n < 3)
	}
}
