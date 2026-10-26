// tools/ltc_fit fits the lookup tables that the area lights shade with (see docs/rendering/lighting-and-shadows.md#area-lights): for each
// roughness and view angle, the linearly transformed cosine that best matches the Lit shading model's GGX specular, with
// its magnitude and Fresnel term, and the horizon-clipped sphere's form factor. Run `just ltc-fit` after a change to
// Lit's specular, and commit the table it writes.
//
// The fit is Heitz, Dupuy, Hill and Neubelt's, "Real-Time Polygonal-Light Shading with Linearly Transformed Cosines"
// (2016), with the parameterization of their 2017 code: a table is SIZE × SIZE, x the perceptual roughness and y
// sqrt(1 - cos θ) of the view, both sampled at i / (SIZE - 1).
package ltc_fit

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:sync"
import "core:thread"

// Matches LTC_SIZE in lib/engine/render/lights.odin and ltc.hlsli.
SIZE :: 64
// Matches the clamp in shade_direct in lib/engine/content/shading/lit.hlsli.
MIN_ALPHA :: 2e-3
// The samples on each side of the grid that integrate a texel's error and its averages.
SAMPLES :: 32
// The Nelder-Mead search: its first simplex's size, its tolerance and its iterations.
FIT_DELTA :: 0.05
FIT_TOLERANCE :: 1e-5
FIT_ITERATIONS :: 300

Vec3 :: [3]f64
Mat3 :: matrix[3, 3]f64

// Ltc is a linearly transformed cosine: the clamped cosine over the hemisphere, transformed by m, which is a frame
// times [[m00, 0, m02], [0, m11, 0], [0, 0, 1]], and scaled by magnitude. The frame's z is in the xz plane, base + tilt
// radians from +z toward +x: base is the specular's average direction, and the fit chooses the tilt.
Ltc :: struct {
	m00, m11, m02: f64,
	base, tilt:    f64,
	m, inverse:    Mat3,
	determinant:   f64,
	magnitude:     f64,
}

// Fit is one texel's result.
Fit :: struct {
	m:         Mat3,
	magnitude: f64,
	fresnel:   f64,
	// The share of the light in the wrong place (see relative_error).
	error:     f64,
}

ltc_update :: proc(l: ^Ltc) {
	s, c := math.sincos(l.base + l.tilt)
	// The columns are x = (c, 0, -s), y and z = (s, 0, c).
	basis := Mat3{c, 0, s, 0, 1, 0, -s, 0, c}
	l.m = basis * Mat3{l.m00, 0, l.m02, 0, l.m11, 0, 0, 0, 1}
	l.inverse = linalg.inverse(l.m)
	l.determinant = abs(linalg.determinant(l.m))
}

// ltc_eval is the distribution's value in a direction: the cosine at the direction it came from, times the Jacobian.
ltc_eval :: proc(l: ^Ltc, d: Vec3) -> f64 {
	original := linalg.normalize(l.inverse * d)
	transformed := l.m * original
	length := linalg.length(transformed)
	jacobian := l.determinant / (length * length * length)
	return l.magnitude * max(original.z, 0) / math.PI / jacobian
}

ltc_sample :: proc(l: ^Ltc, u1, u2: f64) -> Vec3 {
	theta := math.acos(math.sqrt(u1))
	phi := 2 * math.PI * u2
	return linalg.normalize(l.m * Vec3{math.sin(theta) * math.cos(phi), math.sin(theta) * math.sin(phi), math.cos(theta)})
}

// brdf_eval is Lit's specular without Fresnel, times the cosine, as shade_direct computes it, and the probability of
// sampling l with brdf_sample. v and l are in the frame where the normal is +z.
brdf_eval :: proc(v, l: Vec3, alpha: f64) -> (value, pdf: f64) {
	if v.z <= 0 {
		return 0, 0
	}
	h := linalg.normalize(v + l)
	a2 := alpha * alpha
	denominator := h.z * h.z * (a2 - 1) + 1
	distribution := a2 / (math.PI * denominator * denominator)
	pdf = abs(distribution * h.z / (4 * linalg.dot(v, h)))
	if l.z <= 0 {
		return 0, pdf
	}
	k := alpha * 0.5
	nv := max(v.z, 1e-4)
	visibility := 0.25 / ((nv * (1 - k) + k) * (l.z * (1 - k) + k))
	return distribution * visibility * l.z, pdf
}

// brdf_sample reflects v about a normal sampled from GGX's distribution of normals.
brdf_sample :: proc(v: Vec3, alpha, u1, u2: f64) -> Vec3 {
	phi := 2 * math.PI * u1
	r := alpha * math.sqrt(u2 / (1 - u2))
	n := linalg.normalize(Vec3{r * math.cos(phi), r * math.sin(phi), 1})
	return -v + 2 * n * linalg.dot(n, v)
}

// average_terms integrates the specular's magnitude, its Fresnel term (the share that Schlick's (1 - v·h)^5 weights),
// and its average direction, which is in the xz plane.
average_terms :: proc(v: Vec3, alpha: f64) -> (magnitude, fresnel: f64, direction: Vec3) {
	for j in 0 ..< SAMPLES {
		for i in 0 ..< SAMPLES {
			u1 := (f64(i) + 0.5) / SAMPLES
			u2 := (f64(j) + 0.5) / SAMPLES
			l := brdf_sample(v, alpha, u1, u2)
			value, pdf := brdf_eval(v, l, alpha)
			if pdf <= 0 {
				continue
			}
			weight := value / pdf
			h := linalg.normalize(v + l)
			magnitude += weight
			fresnel += weight * math.pow(1 - max(linalg.dot(v, h), 0), 5)
			direction += weight * l
		}
	}
	magnitude /= SAMPLES * SAMPLES
	fresnel /= SAMPLES * SAMPLES
	direction.y = 0
	direction = linalg.normalize(direction)
	return
}

// fit_error is the L3 error between the specular and the distribution, sampling both with multiple importance.
fit_error :: proc(l: ^Ltc, v: Vec3, alpha: f64) -> f64 {
	error: f64
	add :: proc(error: ^f64, l: ^Ltc, v, d: Vec3, alpha: f64) {
		value, pdf_brdf := brdf_eval(v, d, alpha)
		value_ltc := ltc_eval(l, d)
		pdf_ltc := value_ltc / l.magnitude
		e := abs(value - value_ltc)
		if pdf_ltc + pdf_brdf > 0 {
			error^ += e * e * e / (pdf_ltc + pdf_brdf)
		}
	}
	for j in 0 ..< SAMPLES {
		for i in 0 ..< SAMPLES {
			u1 := (f64(i) + 0.5) / SAMPLES
			u2 := (f64(j) + 0.5) / SAMPLES
			add(&error, l, v, ltc_sample(l, u1, u2), alpha)
			add(&error, l, v, brdf_sample(v, alpha, u1, u2), alpha)
		}
	}
	return error / (SAMPLES * SAMPLES)
}

// relative_error is the L1 difference between the specular and the distribution over the specular's magnitude: the
// share of the light that the fit puts in the wrong place, which the tool reports.
relative_error :: proc(l: ^Ltc, v: Vec3, alpha: f64) -> f64 {
	error: f64
	add :: proc(error: ^f64, l: ^Ltc, v, d: Vec3, alpha: f64) {
		value, pdf_brdf := brdf_eval(v, d, alpha)
		value_ltc := ltc_eval(l, d)
		pdf_ltc := value_ltc / l.magnitude
		if pdf_ltc + pdf_brdf > 0 {
			error^ += abs(value - value_ltc) / (pdf_ltc + pdf_brdf)
		}
	}
	for j in 0 ..< SAMPLES {
		for i in 0 ..< SAMPLES {
			u1 := (f64(i) + 0.5) / SAMPLES
			u2 := (f64(j) + 0.5) / SAMPLES
			add(&error, l, v, ltc_sample(l, u1, u2), alpha)
			add(&error, l, v, brdf_sample(v, alpha, u1, u2), alpha)
		}
	}
	return error / (SAMPLES * SAMPLES) / l.magnitude
}

// Fit_Params is which of the distribution's parameters, (m00, m11, m02, tilt), a search varies.
Fit_Params :: enum {
	// At normal incidence: m11 = m00, m02 = 0 and no tilt.
	Isotropic,
	// m00, m11 and m02, about the specular's average direction.
	Untilted,
	// All four.
	Tilted,
}

// set_params puts a search's parameters into the distribution.
set_params :: proc(l: ^Ltc, p: [4]f64, params: Fit_Params) {
	m00 := max(p[0], 1e-7)
	l.m00 = m00
	l.m11 = params == .Isotropic ? m00 : max(p[1], 1e-7)
	l.m02 = params == .Isotropic ? 0 : p[2]
	l.tilt = params == .Tilted ? p[3] : 0
	ltc_update(l)
}

// nelder_mead minimizes the error over the distribution's parameters from a first guess, with a first simplex of steps,
// and leaves the best in l.
nelder_mead :: proc(l: ^Ltc, v: Vec3, alpha: f64, params: Fit_Params, steps: [4]f64) -> f64 {
	objective :: proc(l: ^Ltc, p: [4]f64, v: Vec3, alpha: f64, params: Fit_Params) -> f64 {
		set_params(l, p, params)
		return fit_error(l, v, alpha)
	}
	n := params == .Isotropic ? 1 : params == .Untilted ? 3 : 4
	s: [5][4]f64
	f: [5]f64
	s[0] = {l.m00, l.m11, l.m02, l.tilt}
	for i in 1 ..= n {
		s[i] = s[0]
		s[i][i - 1] += steps[i - 1]
	}
	for i in 0 ..= n {
		f[i] = objective(l, s[i], v, alpha, params)
	}
	lowest :: proc(f: []f64) -> int {
		lo := 0
		for i in 1 ..< len(f) {
			if f[i] < f[lo] {
				lo = i
			}
		}
		return lo
	}
	for _ in 0 ..< FIT_ITERATIONS {
		// The lowest, the highest and the next highest.
		lo := lowest(f[:n + 1])
		hi := 0
		for i in 1 ..= n {
			if f[i] > f[hi] {
				hi = i
			}
		}
		nh := lo
		for i in 0 ..= n {
			if i != hi && f[i] > f[nh] {
				nh = i
			}
		}
		a, b := abs(f[lo]), abs(f[hi])
		if 2 * abs(a - b) < (a + b) * FIT_TOLERANCE {
			break
		}
		centroid: [4]f64
		for i in 0 ..= n {
			if i != hi {
				centroid += s[i]
			}
		}
		centroid /= f64(n)
		r := centroid + (centroid - s[hi])
		fr := objective(l, r, v, alpha, params)
		if fr < f[nh] {
			if fr < f[lo] {
				e := centroid + 2 * (centroid - s[hi])
				if fe := objective(l, e, v, alpha, params); fe < fr {
					s[hi], f[hi] = e, fe
					continue
				}
			}
			s[hi], f[hi] = r, fr
			continue
		}
		c := centroid - 0.5 * (centroid - s[hi])
		if fc := objective(l, c, v, alpha, params); fc < f[hi] {
			s[hi], f[hi] = c, fc
			continue
		}
		for k in 0 ..= n {
			if k != lo {
				s[k] = s[lo] + 0.5 * (s[k] - s[lo])
				f[k] = objective(l, s[k], v, alpha, params)
			}
		}
	}
	lo := lowest(f[:n + 1])
	set_params(l, s[lo], params)
	return f[lo]
}

// texel_view is the view direction and alpha of a texel: x is the roughness, y is sqrt(1 - cos θ).
texel_view :: proc(x, y: int) -> (v: Vec3, alpha: f64) {
	u := f64(y) / (SIZE - 1)
	theta := min(1.57, math.acos(1 - u * u))
	roughness := f64(x) / (SIZE - 1)
	return {math.sin(theta), 0, math.cos(theta)}, max(roughness * roughness, MIN_ALPHA)
}

// fit_texel fits one texel from a first guess in l: at normal incidence, an isotropic lobe about +z. Otherwise a lobe
// about the specular's average direction, then the same lobe tilted, which fits better away from normal incidence.
// The tilt's first step is a share of the lobe's width, so a narrow lobe does not step off the specular and lose it.
fit_texel :: proc(l: ^Ltc, x, y: int) -> Fit {
	v, alpha := texel_view(x, y)
	magnitude, fresnel, direction := average_terms(v, alpha)
	l.magnitude = magnitude
	isotropic := y == 0
	l.base = isotropic ? 0 : math.atan2(direction.x, direction.z)
	l.tilt = 0
	if isotropic {
		nelder_mead(l, v, alpha, .Isotropic, FIT_DELTA)
	} else {
		untilted_error := nelder_mead(l, v, alpha, .Untilted, FIT_DELTA)
		untilted := l^
		if nelder_mead(l, v, alpha, .Tilted, {FIT_DELTA, FIT_DELTA, FIT_DELTA, 0.25 * min(l.m00, l.m11)}) > untilted_error {
			l^ = untilted
		}
	}
	error := relative_error(l, v, alpha)
	m := l.m
	// Only the xz plane couples; y stays apart.
	m[0, 1], m[1, 0], m[1, 2], m[2, 1] = 0, 0, 0, 0
	return {m = m, magnitude = magnitude, fresnel = fresnel, error = error}
}

// fit_all fits every texel. The normal-incidence column fits from rough to smooth, each from the last; then each
// roughness's row fits from normal incidence to grazing, each from the last, the rows in parallel.
fit_all :: proc(fits: []Fit) {
	first: [SIZE]Ltc
	l := Ltc {
		m00 = 1,
		m11 = 1,
	}
	for x := SIZE - 1; x >= 0; x -= 1 {
		fits[x] = fit_texel(&l, x, 0)
		first[x] = l
	}

	Work :: struct {
		fits:  []Fit,
		first: ^[SIZE]Ltc,
		next:  int,
	}
	work := Work{fits, &first, 0}
	worker :: proc(data: rawptr) {
		work := (^Work)(data)
		for {
			x := sync.atomic_add(&work.next, 1)
			if x >= SIZE {
				return
			}
			l := work.first[x]
			for y in 1 ..< SIZE {
				work.fits[y * SIZE + x] = fit_texel(&l, x, y)
			}
		}
	}
	threads := make([]^thread.Thread, max(os.get_processor_core_count(), 1), context.temp_allocator)
	for &t in threads {
		t = thread.create_and_start_with_data(&work, worker)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
}

// sphere_form_factor is the form factor of a spherical cap with an unclipped form factor of length, whose center is at
// cos elevation z, as the part above the horizon gives it, over length: the shader multiplies it back. It is
// Heitz's analytic integral of the cap's clipped cosine (from the 2017 code's ihemi).
sphere_form_factor :: proc(z, length: f64) -> f64 {
	sigma := math.asin(math.sqrt(clamp(length, 0, 1)))
	if sigma <= 0 {
		return max(z, 0)
	}
	omega := math.acos(clamp(z, -1, 1))
	return clipped_cap(omega, sigma) / (math.PI * length)
}

// clipped_cap is the projected solid angle of the cap of half angle s at angle w from the normal, above the horizon.
@(private = "file")
clipped_cap :: proc(w, s: f64) -> f64 {
	sin2s := math.sin(s) * math.sin(s)
	if w <= math.PI / 2 - s {
		return math.PI * math.cos(w) * sin2s
	}
	if w >= math.PI / 2 + s {
		return 0
	}
	g := math.asin(clamp(math.cos(s) / math.sin(w), -1, 1))
	cos_g := math.cos(g)
	big_g := -2 * math.sin(w) * math.cos(s) * cos_g + math.PI / 2 - g + math.sin(g) * cos_g
	big_h := math.cos(w) * (cos_g * math.sqrt(max(sin2s - cos_g * cos_g, 0)) + sin2s * math.asin(clamp(cos_g / math.sin(s), -1, 1)))
	if w < math.PI / 2 {
		return math.PI * math.cos(w) * sin2s + big_g - big_h
	}
	return big_g + big_h
}

// pack writes the tables as the renderer reads them: the inverse matrices, normalized so their [1][1] is 1, as (m00,
// m02, m20, m22) by row and column, then (magnitude, fresnel, 0, sphere).
pack :: proc(fits: []Fit) -> []f32 {
	data := make([]f32, SIZE * SIZE * 8)
	second := data[SIZE * SIZE * 4:]
	for fit, i in fits {
		inverse := linalg.inverse(fit.m)
		scale := 1 / inverse[1, 1]
		data[i * 4 + 0] = f32(inverse[0, 0] * scale)
		data[i * 4 + 1] = f32(inverse[0, 2] * scale)
		data[i * 4 + 2] = f32(inverse[2, 0] * scale)
		data[i * 4 + 3] = f32(inverse[2, 2] * scale)
		x, y := i % SIZE, i / SIZE
		second[i * 4 + 0] = f32(fit.magnitude)
		second[i * 4 + 1] = f32(fit.fresnel)
		second[i * 4 + 3] = f32(sphere_form_factor(f64(x) / (SIZE - 1) * 2 - 1, f64(y) / (SIZE - 1)))
	}
	return data
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: ltc_fit <output>")
		os.exit(2)
	}
	fits := make([]Fit, SIZE * SIZE)
	fit_all(fits)
	worst, total: f64
	for fit in fits {
		worst = max(worst, fit.error)
		total += fit.error
	}
	fmt.printfln("fitted %dx%d: the share of light in the wrong place is %.3f at most, %.3f on average", SIZE, SIZE, worst, total / (SIZE * SIZE))
	// A sample of the grid, by roughness across and by view angle down.
	for y := 0; y < SIZE; y += 9 {
		fmt.printf("  y %2d:", y)
		for x := 0; x < SIZE; x += 9 {
			fmt.printf(" %.3f", fits[y * SIZE + x].error)
		}
		fmt.println()
	}
	data := pack(fits)
	if err := os.write_entire_file(os.args[1], ([^]byte)(raw_data(data))[:len(data) * size_of(f32)]); err != nil {
		fmt.eprintfln("ltc_fit: cannot write %s: %v", os.args[1], err)
		os.exit(1)
	}
}
