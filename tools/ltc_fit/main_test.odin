package ltc_fit

import "core:math"
import "core:testing"

@(test)
rough_lobe_at_normal_incidence_fits :: proc(t: ^testing.T) {
	l := Ltc {
		m00 = 1,
		m11 = 1,
	}
	fit := fit_texel(&l, SIZE - 1, 0)
	testing.expectf(t, fit.error < 0.05, "the roughest lobe puts %.3f of its light in the wrong place", fit.error)
	// GGX at alpha 1 is uniform, so with Lit's visibility its magnitude is 1 - ln 2.
	testing.expectf(t, abs(fit.magnitude - (1 - math.ln(f64(2)))) < 0.01, "magnitude %f", fit.magnitude)
	// At normal incidence, the lobe is isotropic.
	testing.expect_value(t, fit.m[0, 0], fit.m[1, 1])
	testing.expect_value(t, fit.m[0, 2], 0)
}

@(test)
smooth_lobes_reflect_most_of_the_light :: proc(t: ^testing.T) {
	for y in ([]int{0, 20, 40}) {
		v, alpha := texel_view(4, y)
		magnitude, fresnel, direction := average_terms(v, alpha)
		testing.expectf(t, magnitude > 0.9 && magnitude <= 1.01, "y %d: magnitude %f", y, magnitude)
		testing.expect(t, fresnel >= 0 && fresnel < magnitude)
		// A smooth lobe's average direction is the view's reflection.
		testing.expectf(t, abs(direction.x + v.x) < 0.05 && abs(direction.z - v.z) < 0.05, "y %d: direction %v for view %v", y, direction, v)
	}
}

@(test)
sphere_form_factor_clips_at_the_horizon :: proc(t: ^testing.T) {
	// A cap well above the horizon is unclipped: its form factor is its vector's z, length * z.
	testing.expect(t, abs(sphere_form_factor(1, 0.1) - 1) < 1e-6)
	testing.expect(t, abs(sphere_form_factor(0.8, 0.1) - 0.8) < 1e-6)
	// One well below gives nothing, and one at the horizon gives part of itself.
	testing.expect_value(t, sphere_form_factor(-0.8, 0.1), 0)
	half := sphere_form_factor(0, 0.5)
	testing.expectf(t, half > 0 && half < 1, "a cap across the horizon keeps %f", half)
	// A point, of no size, is a cosine.
	testing.expect_value(t, sphere_form_factor(0.5, 0), 0.5)
}

@(test)
pack_stores_the_normalized_inverse :: proc(t: ^testing.T) {
	fits := make([]Fit, SIZE * SIZE)
	defer delete(fits)
	for &fit in fits {
		fit.m = Mat3{0.5, 0, 0.25, 0, 0.5, 0, 0, 0, 1}
		fit.magnitude, fit.fresnel = 0.75, 0.125
	}
	data := pack(fits)
	defer delete(data)
	testing.expect_value(t, len(data), SIZE * SIZE * 8)
	// The inverse is [[2, 0, -0.5], [0, 2, 0], [0, 0, 1]], over its middle element.
	testing.expect_value(t, data[0], 1)
	testing.expect_value(t, data[1], -0.25)
	testing.expect_value(t, data[2], 0)
	testing.expect_value(t, data[3], 0.5)
	second := data[SIZE * SIZE * 4:]
	testing.expect_value(t, second[0], 0.75)
	testing.expect_value(t, second[1], 0.125)
	// The sphere table's first texel is a point at the nadir.
	testing.expect_value(t, second[3], 0)
}
