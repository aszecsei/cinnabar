package cloud_scatter

import "core:math"
import "core:math/rand"
import "core:testing"

// Sampling a Henyey-Greenstein lobe gives its eccentricity as the mean cosine.
@(test)
the_phase_samples_have_the_lobes_mean_cosine :: proc(t: ^testing.T) {
	state := rand.create(1)
	gen := rand.default_random_generator(&state)
	for g in ([]f64{0.8, -0.3, 0}) {
		sum := 0.0
		n := 50_000
		for _ in 0 ..< n {
			sum += sample_hg(g, rand.float64(gen))
		}
		testing.expectf(
			t,
			abs(sum / f64(n) - g) < 0.01,
			"g %v: the mean cosine is %v",
			g,
			sum / f64(n),
		)
	}
}

// Deep in a slab that scatters the same in every direction, the light falls off at transport theory's exact rate k,
// where albedo / (2 k) · ln((1 + k) / (1 - k)) = 1. The reference, weight window and all, follows it.
@(test)
the_reference_falls_off_at_the_exact_rate_in_depth :: proc(t: ^testing.T) {
	albedo := 0.95
	lo, hi := 1e-6, 1 - 1e-9
	for _ in 0 ..< 100 {
		k := (lo + hi) / 2
		if albedo / (2 * k) * math.ln((1 + k) / (1 - k)) > 1 {
			hi = k
		} else {
			lo = k
		}
	}
	k := (lo + hi) / 2
	m := Medium{albedo, 0, 0}
	up := Vec3{0, 1, 0}
	near := reference(m, 8, DEEP_SLAB, up, up, 20_000, 1)
	far := reference(m, 12, DEEP_SLAB, up, up, 20_000, 2)
	rate := math.ln(near / far) / 4
	testing.expectf(t, abs(rate - k) < 0.02, "the light falls off at %v, exactly at %v", rate, k)
}

// The floor as built adds at most 10% to the octaves at an optical depth of 1 or less, so a thin edge keeps its light.
@(test)
the_floor_leaves_thin_edges :: proc(t: ^testing.T) {
	change := thin_edge_change(BUILT)
	testing.expectf(t, change <= 0.1, "the floor adds %v to a thin edge", change)
}
