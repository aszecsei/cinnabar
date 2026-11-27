package render

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:testing"

// A CPU mirror of the ray guide's walk in gi_restir_guide.hlsli: a cell's quadtree from its leaves, the walk's sample
// and the pdf of a direction, and the mixture with cosine-weighted directions.

Guide_Mirror :: struct {
	// The root at 148, 2 x 2 at 144, 4 x 4 at 128 and the leaves at 64, as in a cell's floats.
	nodes: [GUIDE_STRIDE]f64,
}

@(private = "file")
level_offset :: proc(k: int) -> int {
	switch k {
	case 0:
		return 148
	case 1:
		return 144
	case 2:
		return 128
	}
	return 64
}

@(private = "file")
unfold :: proc(p: [2]f64) -> [3]f64 {
	n := [3]f64{p.x, p.y, 1 - abs(p.x) - abs(p.y)}
	if n.z < 0 {
		sx := n.x >= 0 ? 1.0 : -1.0
		sy := n.y >= 0 ? 1.0 : -1.0
		n.x, n.y = (1 - abs(n.y)) * sx, (1 - abs(n.x)) * sy
	}
	return linalg.normalize(n)
}

@(private = "file")
fold :: proc(d: [3]f64) -> [2]f64 {
	n := d / (abs(d.x) + abs(d.y) + abs(d.z))
	p := [2]f64{n.x, n.y}
	if n.z < 0 {
		sx := p.x >= 0 ? 1.0 : -1.0
		sy := p.y >= 0 ? 1.0 : -1.0
		p = {(1 - abs(p.y)) * sx, (1 - abs(p.x)) * sy}
	}
	return p
}

@(private = "file")
leaf_of :: proc(d: [3]f64) -> [2]int {
	uv := fold(d) * 0.5 + 0.5
	return {
		min(int(uv.x * GUIDE_SIDE), GUIDE_SIDE - 1),
		min(int(uv.y * GUIDE_SIDE), GUIDE_SIDE - 1),
	}
}

@(private = "file")
jacobian :: proc(d: [3]f64) -> f64 {
	l1 := abs(d.x) + abs(d.y) + abs(d.z)
	return l1 * l1 * l1
}

// guide_mirror_build is a cell's quadtree over its leaves, as the build pass sums them.
guide_mirror_build :: proc(leaves: [GUIDE_LEAVES]f64) -> (m: Guide_Mirror) {
	for v, i in leaves {
		m.nodes[64 + i] = v
	}
	for k := 3; k > 0; k -= 1 {
		side, child := 1 << uint(k - 1), 1 << uint(k)
		for y in 0 ..< side {
			for x in 0 ..< side {
				sum: f64
				for c in 0 ..< 4 {
					sum += m.nodes[level_offset(k) + (2 * y + c / 2) * child + 2 * x + c % 2]
				}
				m.nodes[level_offset(k - 1) + y * side + x] = sum
			}
		}
	}
	return
}

@(private = "file")
node_weight :: proc(m: ^Guide_Mirror, k: int, xy: [2]int, n: [3]f64) -> f64 {
	side := f64(int(1) << uint(k))
	light := m.nodes[level_offset(k) + xy.y * int(side) + xy.x]
	lo := [2]f64{f64(xy.x), f64(xy.y)} / side * 2 - 1
	hi := [2]f64{f64(xy.x + 1), f64(xy.y + 1)} / side * 2 - 1
	c := linalg.dot(n, unfold((lo + hi) * 0.5))
	for corner in ([][2]f64{lo, hi, {lo.x, hi.y}, {hi.x, lo.y}}) {
		c = max(c, linalg.dot(n, unfold(corner)))
	}
	return light * (clamp(c, 0, 1) + 0.02)
}

guide_mirror_pdf :: proc(m: ^Guide_Mirror, n, d: [3]f64) -> f64 {
	leaf := leaf_of(d)
	chance := 1.0
	for k in 1 ..= 3 {
		parent := [2]int{leaf.x >> uint(4 - k), leaf.y >> uint(4 - k)}
		mine := [2]int{leaf.x >> uint(3 - k), leaf.y >> uint(3 - k)}
		total, chosen: f64
		for i in 0 ..< 4 {
			c := parent * 2 + {i & 1, i >> 1}
			w := node_weight(m, k, c, n)
			total += w
			if c == mine {
				chosen = w
			}
		}
		if total <= 0 {
			return 0
		}
		chance *= chosen / total
	}
	return chance / (4.0 / GUIDE_LEAVES) / jacobian(d)
}

guide_mirror_sample :: proc(m: ^Guide_Mirror, n: [3]f64, gen: rand.Generator) -> [3]f64 {
	xy: [2]int
	for k in 1 ..= 3 {
		w: [4]f64
		total: f64
		for i in 0 ..< 4 {
			w[i] = node_weight(m, k, xy * 2 + {i & 1, i >> 1}, n)
			total += w[i]
		}
		r := rand.float64(gen) * total
		pick := 3
		for j in 0 ..< 3 {
			if r < w[j] {
				pick = j
				break
			}
			r -= w[j]
		}
		xy = xy * 2 + {pick & 1, pick >> 1}
	}
	u := [2]f64{rand.float64(gen), rand.float64(gen)}
	return unfold(([2]f64{f64(xy.x), f64(xy.y)} + u) / GUIDE_SIDE * 2 - 1)
}

@(private = "file")
cosine_direction :: proc(n: [3]f64, gen: rand.Generator) -> [3]f64 {
	s := n.z >= 0 ? 1.0 : -1.0
	a := -1 / (s + n.z)
	b := n.x * n.y * a
	t := [3]f64{1 + s * n.x * n.x * a, s * b, -s * n.x}
	bt := [3]f64{b, s + n.y * n.y * a, -n.y}
	u1, u2 := rand.float64(gen), rand.float64(gen)
	r := math.sqrt(u1)
	phi := 2 * math.PI * u2
	return linalg.normalize(
		t * (r * math.cos(phi)) + bt * (r * math.sin(phi)) + n * math.sqrt(1 - u1),
	)
}

// The guide's pdf is a density over the sphere, with the octahedron's solid angle per area in it, and the mixture of
// the guide and cosine-weighted directions, weighed by its pdf, estimates the light at a surface without bias at every
// share of the guide, with a guide that matches the light and with one that does not: only the noise changes.
@(test)
the_guided_estimate_is_unbiased :: proc(t: ^testing.T) {
	r := rand.create(11)
	gen := rand.default_random_generator(&r)
	// The light is a bright window, a cap of 12 degrees, in a dim sky.
	window := linalg.normalize([3]f64{0.6, 0.3, 0.74})
	half := math.to_radians(f64(12))
	sky, bright := 0.5, 40.0
	light :: proc(d, window: [3]f64, half, sky, bright: f64) -> f64 {
		return linalg.dot(d, window) >= math.cos(half) ? bright : sky
	}
	n := linalg.normalize([3]f64{0.1, -0.2, 0.97})
	// The cap is above the horizon, so its cosine-weighted integral is its axis's cosine times pi sin^2.
	exact :=
		sky * math.PI +
		(bright - sky) * linalg.dot(n, window) * math.PI * math.pow(math.sin(half), 2)

	// A guide learned from the light, each leaf the light through it with a floor, and one that points elsewhere.
	learned, wrong: [GUIDE_LEAVES]f64
	for i in 0 ..< GUIDE_LEAVES {
		center := unfold(
			{
				(f64(i % GUIDE_SIDE) + 0.5) / GUIDE_SIDE * 2 - 1,
				(f64(i / GUIDE_SIDE) + 0.5) / GUIDE_SIDE * 2 - 1,
			},
		)
		solid := 4.0 / GUIDE_LEAVES * jacobian(center)
		learned[i] = light(center, window, half, sky, bright) * solid
		wrong[i] = (linalg.dot(center, -window) > 0.7 ? 100.0 : 1.0) * solid
	}
	floor :: proc(leaves: ^[GUIDE_LEAVES]f64) {
		total: f64
		for v in leaves {
			total += v
		}
		for &v in leaves {
			v += GUIDE_FLOOR * total / GUIDE_LEAVES
		}
	}
	floor(&learned)
	floor(&wrong)
	guides := []Guide_Mirror{guide_mirror_build(learned), guide_mirror_build(wrong)}

	for &guide, g in guides {
		// The pdf over a grid of latitude and longitude, which knows nothing of the octahedron, sums to 1.
		rows :: 600
		integral: f64
		for i in 0 ..< rows {
			theta := (f64(i) + 0.5) / rows * math.PI
			for j in 0 ..< 2 * rows {
				phi := (f64(j) + 0.5) / (2 * rows) * 2 * math.PI
				d := [3]f64 {
					math.sin(theta) * math.cos(phi),
					math.sin(theta) * math.sin(phi),
					math.cos(theta),
				}
				integral +=
					guide_mirror_pdf(&guide, n, d) *
					math.sin(theta) *
					(math.PI / rows) *
					(math.PI / rows)
			}
		}
		testing.expectf(
			t,
			abs(integral - 1) < 0.003,
			"guide %d: the pdf integrates to %v",
			g,
			integral,
		)

		runs :: 200000
		for mix in ([]f64{0, 0.5, 1}) {
			mean, square: f64
			for _ in 0 ..< runs {
				d :=
					rand.float64(gen) < mix ? guide_mirror_sample(&guide, n, gen) : cosine_direction(n, gen)
				cosine := max(linalg.dot(n, d), 0)
				pdf := (1 - mix) * cosine / math.PI + mix * guide_mirror_pdf(&guide, n, d)
				if cosine > 0 && pdf > 0 {
					v := light(d, window, half, sky, bright) * cosine / pdf
					mean += v / runs
					square += v * v / runs
				}
			}
			// Within four standard errors of the run, whose noise the guide changes.
			error := math.sqrt(max(square - mean * mean, 0) / runs)
			testing.expectf(
				t,
				abs(mean - exact) < 4 * error + 1e-3 * exact,
				"guide %d, mix %v: %v, not %v, with a standard error of %v",
				g,
				mix,
				mean,
				exact,
				error,
			)
		}
	}
}
