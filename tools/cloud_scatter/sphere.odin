package cloud_scatter

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:sync"
import "core:thread"

// The sphere: a uniform cloud of an optical radius around the origin, lit by the sun from to_sun, without a sky or a
// ground. A sample is on its surface, at an angle from the point that faces the sun, and the view looks into the
// cloud, as the camera's ray does where it enters one. Unlike a slab, a sphere loses light through its sides, so its
// far side is darker, and its lit face sends back the light that its body scatters.

@(rodata)
SPHERE_RADII := [3]f64{3, 10, 30}
// The sample's angle from the point that faces the sun, in degrees: 90 is the edge between light and shadow.
@(rodata)
SPHERE_ANGLES := [5]f64{0, 45, 90, 135, 180}
// The view's tilt from looking straight into the surface, in degrees, in the plane of the sun and the surface's
// normal: a positive tilt heads the ray toward the shadow side, a negative one toward the lit side.
@(rodata)
SPHERE_VIEWS := [3]f64{0, 60, -60}
// How far inside the surface the sample is, in optical depths along the normal: the camera's march gathers most of
// its light over the first few.
@(rodata)
SPHERE_DEPTHS := [3]f64{0, 1, 3}
SPHERE_PATHS :: 100_000
// A sphere has no up, so the sun term's floor, which takes the sun's elevation, is compared at these two: the fit
// takes both, and the report and the test take the first.
SPHERE_SUN_UP :: 0.7071
SPHERE_SUN_UP_LOW :: 0.1736

Sphere_Table :: [3][5][3][3]f64

// chord_exit is the optical distance from a point inside a sphere of a radius to its surface along d.
chord_exit :: proc(p, d: Vec3, radius: f64) -> f64 {
	b := dot(p, d)
	c := dot(p, p) - radius * radius
	return max(-b + math.sqrt(max(b * b - c, 0)), 0)
}

Sphere_Particle :: struct {
	p, d:   Vec3,
	weight: f64,
}

// reference_sphere is ∫ phase · L / E at a point of a sphere of a radius, along the view ray d (away from the eye), with
// to_sun toward the sun, from a number of paths with a seed. A path's vertex takes the sun's light that reaches it
// along the chord toward the sun, and a path ends when it leaves the sphere or the cloud absorbs it. The weight window
// keeps a path's weight about e^(-rate · how much nearer the sun its chord is than the sample's), so the paths split
// as they near the lit side, where a shaded sample's light comes from.
reference_sphere :: proc(
	m: Medium,
	radius: f64,
	x, d, to_sun: Vec3,
	paths: int,
	seed: u64,
) -> f64 {
	state := rand.create(seed)
	gen := rand.default_random_generator(&state)
	stack := make([dynamic]Sphere_Particle, 0, 256, context.temp_allocator)
	rate := window(m)
	start := chord_exit(x, to_sun, radius)
	sum := 0.0
	for _ in 0 ..< paths {
		append(&stack, Sphere_Particle{x, d, 1})
		for len(stack) > 0 {
			q := pop(&stack)
			for {
				chord := chord_exit(q.p, to_sun, radius)
				sum += q.weight * phase(m, dot(q.d, to_sun)) * math.exp(-chord)
				if rand.float64(gen) >= m.albedo {
					break
				}
				g := rand.float64(gen) < 0.5 ? m.back : m.forward
				q.d = turn(q.d, sample_hg(g, rand.float64(gen)), 2 * math.PI * rand.float64(gen))
				q.p -= q.d * math.ln(1 - rand.float64(gen))
				if dot(q.p, q.p) > radius * radius {
					break
				}
				target := math.exp(-rate * (start - chord_exit(q.p, to_sun, radius)))
				ratio := q.weight / target
				if ratio > 2 {
					n := min(int(ratio), MAX_SPLIT)
					q.weight /= f64(n)
					for _ in 1 ..< n {
						append(&stack, q)
					}
				} else if ratio < 0.5 {
					if rand.float64(gen) >= ratio {
						break
					}
					q.weight = target
				}
			}
		}
	}
	return sum / f64(paths)
}

// Sphere_Case is a case's geometry: the sample, its view, the sun, and the optical depths from the sample toward the
// sun and away from it.
Sphere_Case :: struct {
	x, d, to_sun: Vec3,
	od, od_back:  f64,
	radius:       f64,
}

sphere_case :: proc(r, a, v, k: int) -> (c: Sphere_Case) {
	radius := SPHERE_RADII[r]
	theta := SPHERE_ANGLES[a] * math.PI / 180
	tilt := SPHERE_VIEWS[v] * math.PI / 180
	c.to_sun = {0, 0, 1}
	side := Vec3{1, 0, 0}
	n := c.to_sun * math.cos(theta) + side * math.sin(theta)
	// The tangent toward the shadow side.
	t := -c.to_sun * math.sin(theta) + side * math.cos(theta)
	c.x = n * (radius - SPHERE_DEPTHS[k])
	c.d = -n * math.cos(tilt) + t * math.sin(tilt)
	c.od = chord_exit(c.x, c.to_sun, radius)
	c.od_back = chord_exit(c.x, -c.to_sun, radius)
	c.radius = radius
	return
}

sphere_table :: proc(seed_offset: u64) -> (table: Sphere_Table) {
	Work :: struct {
		table:  ^Sphere_Table,
		offset: u64,
		next:   int,
	}
	work := Work{&table, seed_offset, 0}
	worker :: proc(data: rawptr) {
		work := (^Work)(data)
		cases := len(SPHERE_RADII) * len(SPHERE_ANGLES) * len(SPHERE_VIEWS) * len(SPHERE_DEPTHS)
		for {
			i := sync.atomic_add(&work.next, 1)
			if i >= cases {
				return
			}
			k := i % len(SPHERE_DEPTHS)
			v := i / len(SPHERE_DEPTHS) % len(SPHERE_VIEWS)
			a := i / (len(SPHERE_DEPTHS) * len(SPHERE_VIEWS)) % len(SPHERE_ANGLES)
			r := i / (len(SPHERE_DEPTHS) * len(SPHERE_VIEWS) * len(SPHERE_ANGLES))
			c := sphere_case(r, a, v, k)
			seed := u64(i) * 104729 + 17 + work.offset
			work.table[r][a][v][k] = reference_sphere(
				CLOUDS,
				c.radius,
				c.x,
				c.d,
				c.to_sun,
				SPHERE_PATHS,
				seed,
			)
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

// print_sphere prints a sun term over the sphere's reference at a sun 45° above the horizon, by radius, depth inside
// the surface, angle from the point that faces the sun, and view, and how far a second seed's reference strays.
print_sphere :: proc(t: Sun_Term, sphere, again: ^Sphere_Table) {
	worst := 0.0
	for r in 0 ..< len(SPHERE_RADII) {
		for k in 0 ..< len(SPHERE_DEPTHS) {
			fmt.printf("radius %2.0f, depth %.0f:", SPHERE_RADII[r], SPHERE_DEPTHS[k])
			for a in 0 ..< len(SPHERE_ANGLES) {
				fmt.printf("  %3.0f°", SPHERE_ANGLES[a])
				for v in 0 ..< len(SPHERE_VIEWS) {
					c := sphere_case(r, a, v, k)
					mu := dot(c.d, c.to_sun)
					fmt.printf(
						" %.2f",
						sun_term(t, c.od, c.od_back, mu, SPHERE_SUN_UP) / sphere[r][a][v][k],
					)
					worst = max(worst, abs(math.ln(again[r][a][v][k] / sphere[r][a][v][k])))
				}
			}
			fmt.println()
		}
	}
	fmt.printfln(
		"(views %v° at each angle; a second seed's reference strays by at most %.1f%%)",
		SPHERE_VIEWS,
		100 * (math.exp(worst) - 1),
	)
}

// print_sphere_test prints the sphere's cases for clouds_test.odin, looking straight into the surface, at optical radii
// 10 and 30, 0 and 1 inside the surface, by angle from the point that faces the sun: each case's od, od_back, mu and
// reference, and the built term's ratio, for the tolerance.
print_sphere_test :: proc(sphere: ^Sphere_Table) {
	fmt.println(
		"\nThe sphere's cases for clouds_test.odin: od, od_back, mu, the reference, and the built term's ratio",
	)
	for r in 1 ..< len(SPHERE_RADII) {
		for k in 0 ..< 2 {
			for a in 0 ..< len(SPHERE_ANGLES) {
				c := sphere_case(r, a, 0, k)
				mu := dot(c.d, c.to_sun)
				ref := sphere[r][a][0][k]
				fmt.printfln(
					"\t{{%.3f, %.3f, %.3f, %.3e}}, // %.2f",
					c.od,
					c.od_back,
					mu,
					ref,
					sun_term(BUILT, c.od, c.od_back, mu, SPHERE_SUN_UP) / ref,
				)
			}
		}
	}
}
