package cloud_scatter

import "core:math"

// Sun_Term is the shader's sun term's constants (cloud_sun_scattering in clouds_common.hlsli): the powder effect's
// strength, the diffusion floor, and the reflection, the light that the cloud behind a sample scatters back toward the
// sun's side, weight · (1 - e^(-thickness · od_back))² · e^(-fall · od) times the octaves' phase at an eccentricity's
// share. It builds up with the cloud behind the sample, so a thin edge keeps the octaves' light, and it makes the lit
// face of a thick cloud glow, which the octaves leave dark.
Sun_Term :: struct {
	floor:                                                                 Floor,
	powder:                                                                f64,
	reflect_weight, reflect_thickness, reflect_fall, reflect_eccentricity: f64,
}

// The constants as built: POWDER_STRENGTH, DIFFUSION_* and REFLECT_* in clouds_common.hlsli, with the reflection at
// the second octave's phase, which the shader has.
BUILT :: Sun_Term {
	floor                = {0.48, 1.25, 0.28, 0.08},
	powder               = 0.35,
	reflect_weight       = 3,
	reflect_thickness    = 0.12,
	reflect_fall         = 0.1,
	reflect_eccentricity = 0.5,
}

// sun_term is the sun term for a sun of illuminance 1, from the optical depths toward the sun and away from it, the
// cosine between the view ray and the direction toward the sun, and the sine of the sun's elevation.
sun_term :: proc(t: Sun_Term, od, od_back, mu, sun_up: f64) -> f64 {
	sun := 0.0
	a := 1.0
	for _ in 0 ..< OCTAVES {
		sun += a * cloud_phase(mu, a) * math.exp(-a * od)
		a *= ATTENUATION
	}
	front_lit := clamp(-mu * 0.5 + 0.5, 0, 1)
	sun *= math.lerp(1.0, 1 - math.exp(-2 * od), front_lit * t.powder)
	behind := 1 - math.exp(-t.reflect_thickness * od_back)
	reflect :=
		t.reflect_weight *
		behind *
		behind *
		math.exp(-t.reflect_fall * od) *
		cloud_phase(mu, t.reflect_eccentricity)
	return sun + floor_term(t.floor, od, mu, sun_up) + reflect
}

// The references that the sun term is fitted to.
References :: struct {
	slab:   ^Table,
	sphere: ^Sphere_Table,
}

// sun_term_errors is the mean squared log error over the slab's cases, where nothing is behind a sample on the slab's
// bottom, and over the sphere's, at two sun elevations, and the worst ratio of each.
sun_term_errors :: proc(
	t: Sun_Term,
	refs: ^References,
) -> (
	slab, sphere, slab_worst, sphere_worst: f64,
) {
	n := 0
	for e in 0 ..< len(ELEVATIONS) {
		to_sun := direction(ELEVATIONS[e])
		for o in 0 ..< len(DEPTHS) {
			for v in 0 ..< len(VIEWS) {
				mu := dot(direction(ELEVATIONS[e] - VIEWS[v]), to_sun)
				r := math.ln(sun_term(t, DEPTHS[o], 0, mu, to_sun.y) / refs.slab[e][o][v])
				slab += r * r
				slab_worst = max(slab_worst, abs(r))
				n += 1
			}
		}
	}
	slab /= f64(n)
	n = 0
	for r in 0 ..< len(SPHERE_RADII) {
		for a in 0 ..< len(SPHERE_ANGLES) {
			for v in 0 ..< len(SPHERE_VIEWS) {
				for k in 0 ..< len(SPHERE_DEPTHS) {
					c := sphere_case(r, a, v, k)
					mu := dot(c.d, c.to_sun)
					for up in ([2]f64{SPHERE_SUN_UP, SPHERE_SUN_UP_LOW}) {
						l := math.ln(
							sun_term(t, c.od, c.od_back, mu, up) / refs.sphere[r][a][v][k],
						)
						sphere += l * l
						sphere_worst = max(sphere_worst, abs(l))
						n += 1
					}
				}
			}
		}
	}
	sphere /= f64(n)
	return slab, sphere, math.exp(slab_worst), math.exp(sphere_worst)
}

// thin_edge_change is the most that a sun term's floor and reflection add to its octaves where the optical depths
// toward the sun and away from it are both at most 1, over the views and sun elevations every step degrees and those
// depths every 1 / samples.
thin_edge_change :: proc(t: Sun_Term, step := 1, samples := 10) -> f64 {
	worst := 0.0
	octaves_only := Sun_Term {
		powder = t.powder,
	}
	for e := 0; e <= 90; e += step {
		to_sun := direction(f64(e))
		for v := 0; v <= 180; v += step {
			mu := dot(direction(f64(e - v)), to_sun)
			for i in 1 ..= samples {
				od := f64(i) / f64(samples)
				for j in 0 ..= samples {
					od_back := f64(j) / f64(samples)
					all := sun_term(t, od, od_back, mu, to_sun.y)
					worst = max(worst, all / sun_term(octaves_only, od, 0, mu, to_sun.y) - 1)
				}
			}
		}
	}
	return worst
}

sun_term_from :: proc(p: [9]f64) -> Sun_Term {
	return {
		floor = {math.exp(p[0]), p[1], math.exp(p[2]), math.exp(p[3])},
		powder = clamp(p[4], 0, 1),
		reflect_weight = math.exp(p[5]),
		reflect_thickness = math.exp(p[6]),
		reflect_fall = math.exp(p[7]),
		reflect_eccentricity = clamp(p[8], 0, 1),
	}
}

// sun_term_fit fits the sun term to the slab's and the sphere's references, in log space, from the built constants,
// with a penalty that keeps a thin edge's change under THIN_EDGE_LIMIT.
sun_term_fit :: proc(refs: ^References) -> Sun_Term {
	objective :: proc(p: [9]f64, data: rawptr) -> f64 {
		t := sun_term_from(p)
		slab, sphere, _, _ := sun_term_errors(t, (^References)(data))
		over := max(thin_edge_change(t, 5, 5) - THIN_EDGE_LIMIT, 0)
		return slab + sphere + 100 * over * over
	}
	b := BUILT
	p := [9]f64 {
		math.ln(b.floor.weight),
		b.floor.power,
		math.ln(b.floor.rise),
		math.ln(b.floor.decay),
		b.powder,
		math.ln(b.reflect_weight),
		math.ln(b.reflect_thickness),
		math.ln(b.reflect_fall),
		b.reflect_eccentricity,
	}
	for _ in 0 ..< 4 {
		p = nelder_mead(9, objective, refs, p, [9]f64{0.2, 0.2, 0.2, 0.2, 0.1, 0.2, 0.2, 0.2, 0.1})
	}
	return sun_term_from(p)
}
