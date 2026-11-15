// tools/cloud_scatter measures the clouds' sun term against two Monte Carlo references, a slab and a sphere (see
// docs/rendering/clouds.md#multiple-scattering): it prints the references, each model's error against them, and the
// sun term's constants fitted to them. Run `just cloud-scatter` after a change to the clouds' phase or sun term. When
// the fit moves, copy its constants into POWDER_STRENGTH, DIFFUSION_* and REFLECT_* in clouds_common.hlsli and
// clouds.odin and into BUILT (sun_term.odin), and the two references into the tables in clouds_test.odin.
//
// The slab (this file) is a uniform slab of cloud lit from above by a sun of illuminance 1, with no sky and no ground. A
// sample is on the slab's bottom, so the slab is a cloud whose optical depth toward the sun is the sample's: the samples
// that the camera sees with a large optical depth are near a cloud's bottom or its far side, not deep inside it. The
// reference is the sun's light that reaches the sample, scattered toward the viewer: ∫ phase · L, the shader's sun term,
// which the march then multiplies by the albedo and by its share of the light. A path starts at the sample in the view
// ray's direction and scatters through the slab. At each vertex it adds the sun's light that reaches the vertex
// straight through the slab, scattered into the path's direction.
package cloud_scatter

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:sync"
import "core:thread"

Vec3 :: [3]f64

// A medium: its single-scattering albedo and the eccentricities of its phase's two lobes, which take half the light
// each.
Medium :: struct {
	albedo:  f64,
	forward: f64,
	back:    f64,
}

// The clouds' medium: cloud_phase in clouds_common.hlsli, and the albedo of water droplets in visible light, which
// absorb less than a thousandth of the light at each scattering. The march's own albedo (albedo in clouds_march.hlsl,
// 0.95 and 0.8 in rain) darkens the result once, as it darkens the ambient light; inside the cloud, the light that
// scatters many times keeps the medium's.
CLOUDS :: Medium{0.999, 0.8, -0.3}

// The cases: the sun's elevation in degrees, the sample's optical depth toward the sun, and the view's angle from the
// sun in degrees. The view turns from the sun downward in the sun's vertical plane. So at noon, 0 looks up through the
// cloud at the sun, 90 looks along the horizon, and 180 looks straight down onto the cloud.
@(rodata)
ELEVATIONS := [4]f64{90, 45, 20, 5}
@(rodata)
DEPTHS := [4]f64{1, 5, 15, 30}
@(rodata)
VIEWS := [5]f64{0, 45, 90, 135, 180}
// The paths for each case.
PATHS :: 200_000

Table :: [4][4][5]f64

// A slab so deep that its bottom does not matter, for the tests.
DEEP_SLAB :: 1000.0

hg :: proc(mu, g: f64) -> f64 {
	g2 := g * g
	return (1 - g2) / (4 * math.PI * math.pow(max(1 + g2 - 2 * g * mu, 1e-4), 1.5))
}

phase :: proc(m: Medium, mu: f64) -> f64 {
	return 0.5 * hg(mu, m.back) + 0.5 * hg(mu, m.forward)
}

// sample_hg is the cosine of a direction from Henyey and Greenstein's phase at g, by the inverse of its distribution.
sample_hg :: proc(g, u: f64) -> f64 {
	if abs(g) < 1e-4 {
		return 1 - 2 * u
	}
	s := (1 - g * g) / (1 - g + 2 * g * u)
	return clamp((1 + g * g - s * s) / (2 * g), -1, 1)
}

dot :: proc(a, b: Vec3) -> f64 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

// turn is d turned by an angle whose cosine is cos_t, at an azimuth phi around d.
turn :: proc(d: Vec3, cos_t, phi: f64) -> Vec3 {
	sin_t := math.sqrt(max(0, 1 - cos_t * cos_t))
	a := abs(d.x) > 0.9 ? Vec3{0, 1, 0} : Vec3{1, 0, 0}
	t := a - d * dot(a, d)
	t /= math.sqrt(dot(t, t))
	b := Vec3{d.y * t.z - d.z * t.y, d.z * t.x - d.x * t.z, d.x * t.y - d.y * t.x}
	return d * cos_t + (t * math.cos(phi) + b * math.sin(phi)) * sin_t
}

// direction is the unit vector at an elevation in degrees, in the xy plane.
direction :: proc(elevation: f64) -> Vec3 {
	e := elevation * math.PI / 180
	return {math.cos(e), math.sin(e), 0}
}

// The weight window: a path's weight stays about e^(-rate · its rise from the sample), at diffusion's rate of fall-off
// in the medium, sqrt(3 (1 - albedo) (1 - albedo · g)) with g the phase's mean cosine, and at least MIN_WINDOW. So the
// paths split as they climb toward the lit top, where a deep sample's light comes from, and the deep samples are not
// all noise.
MIN_WINDOW :: 0.05
MAX_SPLIT :: 64

window :: proc(m: Medium) -> f64 {
	g := (m.forward + m.back) / 2
	return max(math.sqrt(3 * (1 - m.albedo) * (1 - m.albedo * g)), MIN_WINDOW)
}

Particle :: struct {
	depth:  f64,
	d:      Vec3,
	weight: f64,
}

// reference is ∫ phase · L / E at a vertical optical depth into a slab of a thickness, along the view ray d (away from
// the eye), with to_sun toward the sun, from a number of paths with a seed. It is unbiased: absorption ends a path with
// one less the albedo's chance, and the weight window splits and ends paths with weights that keep the expected sum.
reference :: proc(m: Medium, depth, slab: f64, d, to_sun: Vec3, paths: int, seed: u64) -> f64 {
	state := rand.create(seed)
	gen := rand.default_random_generator(&state)
	stack := make([dynamic]Particle, 0, 256, context.temp_allocator)
	rate := window(m)
	sum := 0.0
	for _ in 0 ..< paths {
		append(&stack, Particle{depth, d, 1})
		for len(stack) > 0 {
			p := pop(&stack)
			for {
				sum += p.weight * phase(m, dot(p.d, to_sun)) * math.exp(-p.depth / to_sun.y)
				if rand.float64(gen) >= m.albedo {
					break
				}
				g := rand.float64(gen) < 0.5 ? m.back : m.forward
				p.d = turn(p.d, sample_hg(g, rand.float64(gen)), 2 * math.PI * rand.float64(gen))
				p.depth += p.d.y * math.ln(1 - rand.float64(gen))
				if p.depth < 0 || p.depth > slab {
					break
				}
				target := math.exp(-rate * (depth - p.depth))
				ratio := p.weight / target
				if ratio > 2 {
					n := min(int(ratio), MAX_SPLIT)
					p.weight /= f64(n)
					for _ in 1 ..< n {
						append(&stack, p)
					}
				} else if ratio < 0.5 {
					if rand.float64(gen) >= ratio {
						break
					}
					p.weight = target
				}
			}
		}
	}
	return sum / f64(paths)
}

// reference_case is the reference at a case of the grid, on the slab's bottom, with a seed of its own.
reference_case :: proc(e, o, v: int, paths: int) -> f64 {
	to_sun := direction(ELEVATIONS[e])
	depth := DEPTHS[o] * to_sun.y
	d := direction(ELEVATIONS[e] - VIEWS[v])
	seed := u64((e * len(DEPTHS) + o) * len(VIEWS) + v) * 7919 + 1
	return reference(CLOUDS, depth, depth, d, to_sun, paths, seed)
}

reference_table :: proc() -> (table: Table) {
	Work :: struct {
		table: ^Table,
		next:  int,
	}
	work := Work{&table, 0}
	worker :: proc(data: rawptr) {
		work := (^Work)(data)
		cases := len(ELEVATIONS) * len(DEPTHS) * len(VIEWS)
		for {
			i := sync.atomic_add(&work.next, 1)
			if i >= cases {
				return
			}
			v := i % len(VIEWS)
			o := i / len(VIEWS) % len(DEPTHS)
			e := i / (len(VIEWS) * len(DEPTHS))
			work.table[e][o][v] = reference_case(e, o, v, PATHS)
			free_all(context.temp_allocator)
		}
	}
	threads := make(
		[]^thread.Thread,
		max(os.get_processor_core_count(), 1),
		context.temp_allocator,
	)
	for &t in threads {
		t = thread.create_and_start_with_data(&work, worker)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
	return
}

// The models of the sun term, for a sun of illuminance 1. od is the optical depth toward the sun, mu the cosine
// between the view ray and the direction toward the sun, and sun_up the sine of the sun's elevation.

Model :: enum {
	Octaves,
	Power,
	Table,
	Built,
}

@(rodata)
MODEL_NAMES := [Model]string {
	.Octaves = "The octaves with the whole powder effect, before",
	.Power   = "The octaves and w / (1 + k·od)",
	.Table   = "A table of od and mu at its best, the mean over the sun's elevations",
	.Built   = "As built, with nothing behind a sample on the slab's bottom",
}

// The octaves (SCATTER_OCTAVES, SCATTER_ATTENUATION in clouds_common.hlsli): each takes this share of the light, the
// extinction and the phase's eccentricity of the one before. octaves is the term before the floor, with the whole
// powder effect.
OCTAVES :: 3
ATTENUATION :: 0.5

cloud_phase :: proc(mu, k: f64) -> f64 {
	return phase({forward = CLOUDS.forward * k, back = CLOUDS.back * k}, mu)
}

octaves :: proc(od, mu: f64) -> f64 {
	sun := 0.0
	a := 1.0
	for _ in 0 ..< OCTAVES {
		sun += a * cloud_phase(mu, a) * math.exp(-a * od)
		a *= ATTENUATION
	}
	front_lit := clamp(-mu * 0.5 + 0.5, 0, 1)
	powder := math.lerp(1.0, 1 - math.exp(-2 * od), front_lit)
	return sun * powder
}

// Floor is the diffusion floor's constants (DIFFUSION_* in clouds_common.hlsli). The floor is
// weight · sun_up^power · (1 - e^(-rise · od))² · e^(-decay · od · sun_up) · the last octave's phase. In a slab, the
// light that has scattered many times comes in through the top, which the sun lights at sun_up. It falls off with the
// vertical depth, od · sun_up, as it leaks out of the slab and the cloud absorbs it, and it builds up over the first
// optical depths, so a thin edge keeps the octaves' light. The phase is the last octave's, which the shader has.
Floor :: struct {
	weight, power, rise, decay: f64,
}

floor_term :: proc(f: Floor, od, mu, sun_up: f64) -> f64 {
	up := max(sun_up, 0)
	buildup := 1 - math.exp(-f.rise * od)
	last := math.pow(ATTENUATION, OCTAVES - 1)
	return(
		f.weight *
		math.pow(up, f.power) *
		buildup *
		buildup *
		math.exp(-f.decay * od * up) *
		cloud_phase(mu, last) \
	)
}

// Power is a floor that falls off as a power of od, not by its exponential: weight / (1 + k · od), the same in every
// direction.
Power :: struct {
	weight, k: f64,
}

Fits :: struct {
	power: Power,
	table: [4][5]f64,
}

model :: proc(m: Model, fits: ^Fits, e, o, v: int) -> f64 {
	to_sun := direction(ELEVATIONS[e])
	mu := dot(direction(ELEVATIONS[e] - VIEWS[v]), to_sun)
	od := DEPTHS[o]
	switch m {
	case .Octaves:
		return octaves(od, mu)
	case .Power:
		return octaves(od, mu) + fits.power.weight / (1 + fits.power.k * od) / (4 * math.PI)
	case .Table:
		return fits.table[o][v]
	case .Built:
		return sun_term(BUILT, od, 0, mu, to_sun.y)
	}
	return 0
}

// log_error is the mean of the squared log of each case's ratio to the reference.
log_error :: proc(m: Model, fits: ^Fits, ref: ^Table) -> f64 {
	sum := 0.0
	for e in 0 ..< len(ELEVATIONS) {
		for o in 0 ..< len(DEPTHS) {
			for v in 0 ..< len(VIEWS) {
				r := math.ln(model(m, fits, e, o, v) / ref[e][o][v])
				sum += r * r
			}
		}
	}
	return sum / f64(len(ELEVATIONS) * len(DEPTHS) * len(VIEWS))
}

FIT_ITERATIONS :: 4000
FIT_TOLERANCE :: 1e-10

// nelder_mead minimizes an objective over N parameters from a first guess, with a first simplex of steps.
nelder_mead :: proc(
	$N: int,
	objective: proc(p: [N]f64, data: rawptr) -> f64,
	data: rawptr,
	first, steps: [N]f64,
) -> [N]f64 {
	s: [N + 1][N]f64
	f: [N + 1]f64
	s[0] = first
	for i in 1 ..= N {
		s[i] = first
		s[i][i - 1] += steps[i - 1]
	}
	for i in 0 ..= N {
		f[i] = objective(s[i], data)
	}
	for _ in 0 ..< FIT_ITERATIONS {
		lo, hi := 0, 0
		for i in 1 ..= N {
			if f[i] < f[lo] {
				lo = i
			}
			if f[i] > f[hi] {
				hi = i
			}
		}
		nh := lo
		for i in 0 ..= N {
			if i != hi && f[i] > f[nh] {
				nh = i
			}
		}
		if abs(f[hi] - f[lo]) <= FIT_TOLERANCE * (abs(f[lo]) + FIT_TOLERANCE) {
			break
		}
		centroid: [N]f64
		for i in 0 ..= N {
			if i != hi {
				centroid += s[i]
			}
		}
		centroid /= f64(N)
		r := centroid + (centroid - s[hi])
		fr := objective(r, data)
		if fr < f[nh] {
			if fr < f[lo] {
				x := centroid + 2 * (centroid - s[hi])
				if fx := objective(x, data); fx < fr {
					s[hi], f[hi] = x, fx
					continue
				}
			}
			s[hi], f[hi] = r, fr
			continue
		}
		c := centroid - 0.5 * (centroid - s[hi])
		if fc := objective(c, data); fc < f[hi] {
			s[hi], f[hi] = c, fc
			continue
		}
		for k in 0 ..= N {
			if k != lo {
				s[k] = s[lo] + 0.5 * (s[k] - s[lo])
				f[k] = objective(s[k], data)
			}
		}
	}
	best := 0
	for i in 1 ..= N {
		if f[i] < f[best] {
			best = i
		}
	}
	return s[best]
}

Fit_Data :: struct {
	fits: ^Fits,
	ref:  ^Table,
}

// fit fits the power floor to the reference on the slab's bottom, in log space, from several restarts, and puts the
// mean over the sun's elevations in the table: the options that #438 weighed against the diffusion floor.
fit :: proc(ref: ^Table) -> (fits: Fits) {
	data := Fit_Data{&fits, ref}
	power_objective :: proc(p: [2]f64, data: rawptr) -> f64 {
		d := (^Fit_Data)(data)
		d.fits.power = {math.exp(p[0]), math.exp(p[1])}
		return log_error(.Power, d.fits, d.ref)
	}
	q := [2]f64{math.ln(f64(0.1)), math.ln(f64(0.1))}
	for _ in 0 ..< 5 {
		q = nelder_mead(2, power_objective, &data, q, [2]f64{0.3, 0.3})
	}
	fits.power = {math.exp(q[0]), math.exp(q[1])}

	// The best that a table of od and mu does: the geometric mean over the sun's elevations, which share their mu.
	for o in 0 ..< len(DEPTHS) {
		for v in 0 ..< len(VIEWS) {
			sum := 0.0
			for e in 0 ..< len(ELEVATIONS) {
				sum += math.ln(ref[e][o][v])
			}
			fits.table[o][v] = math.exp(sum / f64(len(ELEVATIONS)))
		}
	}
	return
}

// The most that the floor and the reflection may add to a thin edge's light, which the fit keeps them under, with a
// margin for the sweep that the fit takes, which is coarser than the report's.
THIN_EDGE_LIMIT :: 0.09

print_header :: proc(last: string) {
	fmt.printf("\n| Sun | od |")
	for view in VIEWS {
		fmt.printf(" %.0f° |", view)
	}
	fmt.printf("%s\n|---|---|", last)
	for _ in VIEWS {
		fmt.printf("---|")
	}
	fmt.println(last == "" ? "" : "---|")
}

print_ratios :: proc(title: string, m: Model, fits: ^Fits, ref: ^Table) {
	fmt.printfln("\n%s: the model over the reference", title)
	print_header(" Worst |")
	for e in 0 ..< len(ELEVATIONS) {
		for o in 0 ..< len(DEPTHS) {
			fmt.printf("| %.0f° | %.0f |", ELEVATIONS[e], DEPTHS[o])
			worst := 1.0
			for v in 0 ..< len(VIEWS) {
				r := model(m, fits, e, o, v) / ref[e][o][v]
				fmt.printf(" %.2f |", r)
				worst = max(worst, r, 1 / r)
			}
			fmt.printfln(" %.1f× |", worst)
		}
	}
	fmt.printfln("\nThe RMS of the log error is %.3f.", math.sqrt(log_error(m, fits, ref)))
}

main :: proc() {
	table := reference_table()
	sphere := sphere_table(0)
	again := sphere_table(1_000_003)
	fits := fit(&table)
	refs := References{&table, &sphere}
	fitted := sun_term_fit(&refs)

	fmt.println("The reference: ∫ phase · L / E on the slab's bottom")
	print_header("")
	for e in 0 ..< len(ELEVATIONS) {
		for o in 0 ..< len(DEPTHS) {
			fmt.printf("| %.0f° | %.0f |", ELEVATIONS[e], DEPTHS[o])
			for v in 0 ..< len(VIEWS) {
				fmt.printf(" %.2e |", table[e][o][v])
			}
			fmt.println()
		}
	}
	for m in Model {
		print_ratios(MODEL_NAMES[m], m, &fits, &table)
	}
	fmt.printfln("The power floor: weight %.4f, k %.4f.", fits.power.weight, fits.power.k)

	fmt.println("\nThe sphere: as built over the reference, with a sun 45° up")
	print_sphere(BUILT, &sphere, &again)

	slab, ball, slab_worst, ball_worst := sun_term_errors(BUILT, &refs)
	fmt.printfln(
		"\nAs built: the RMS of the log error is %.3f on the slab and %.3f on the sphere, at worst %.1fx and %.1fx.",
		math.sqrt(slab),
		math.sqrt(ball),
		slab_worst,
		ball_worst,
	)
	fmt.printfln(
		"Where od and od_back are at most 1, the floor and the reflection add at most %.1f%% to the octaves.",
		100 * thin_edge_change(BUILT),
	)
	slab, ball, _, _ = sun_term_errors(fitted, &refs)
	fmt.printfln("\nThe fit: %v", fitted)
	fmt.printfln(
		"The RMS of its log error is %.3f on the slab and %.3f on the sphere.",
		math.sqrt(slab),
		math.sqrt(ball),
	)

	fmt.println(
		"\nThe slab's reference for clouds_test.odin, by the sun's elevation, od and the view:",
	)
	for e in 0 ..< len(ELEVATIONS) {
		fmt.println("\t{")
		for o in 0 ..< len(DEPTHS) {
			fmt.printf("\t\t{{")
			for v in 0 ..< len(VIEWS) {
				fmt.printf("%s%.3e", v == 0 ? "" : ", ", table[e][o][v])
			}
			fmt.println("},")
		}
		fmt.println("\t},")
	}
	print_sphere_test(&sphere)
}
