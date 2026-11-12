// Package random is the engine's generator: xoshiro256** (Blackman and Vigna 2018), seeded by splitmix64. It is plain
// data with a fixed algorithm, so one seed gives one sequence on every platform and compiler, and a code reload keeps
// a State that the host's memory holds. Scripts' Random draws from the world's State (see docs/scripting/api.md#random),
// and native code passes its own, as nav.random_point takes one (see docs/ai/navigation.md#queries).
package random

import "core:math/bits"

State :: struct {
	s: [4]u64,
}

// seed starts the sequence of a seed.
seed :: proc "contextless" (g: ^State, seed: u64) {
	x := seed
	for &word in g.s {
		word = splitmix64(&x)
	}
}

// splitmix64 is the next value of splitmix64's sequence from x, which it advances.
splitmix64 :: proc "contextless" (x: ^u64) -> u64 {
	x^ += 0x9E3779B97F4A7C15
	z := x^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

next :: proc "contextless" (g: ^State) -> u64 {
	s := &g.s
	result := bits.rotate_left64(s[1] * 5, 7) * 9
	t := s[1] << 17
	s[2] ~= s[0]
	s[3] ~= s[1]
	s[1] ~= s[2]
	s[0] ~= s[3]
	s[2] ~= t
	s[3] = bits.rotate_left64(s[3], 45)
	return result
}

// float64 is a number in [0, 1), from the top 53 bits.
float64 :: proc "contextless" (g: ^State) -> f64 {
	return f64(next(g) >> 11) * (1.0 / (1 << 53))
}

// float32 is a number in [0, 1), from the top 24 bits.
float32 :: proc "contextless" (g: ^State) -> f32 {
	return f32(next(g) >> 40) * (1.0 / (1 << 24))
}

// below is an integer in [0, n), without bias (Lemire 2019). n is not 0.
below :: proc "contextless" (g: ^State, n: u64) -> u64 {
	m := u128(next(g)) * u128(n)
	if u64(m) < n {
		threshold := (0 - n) % n
		for u64(m) < threshold {
			m = u128(next(g)) * u128(n)
		}
	}
	return u64(m >> 64)
}
