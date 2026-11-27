package render

import "core:log"
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


// guide_mirror_sphere_pdf is gi_guide.hlsli's guide_sphere_pdf: the chance of a leaf is the leaf over the root.
guide_mirror_sphere_pdf :: proc(m: ^Guide_Mirror, d: [3]f64) -> f64 {
	leaf := leaf_of(d)
	return(
		m.nodes[64 + leaf.y * GUIDE_SIDE + leaf.x] /
		m.nodes[148] /
		(4.0 / GUIDE_LEAVES) /
		jacobian(d) \
	)
}

// guide_mirror_sphere_warp is gi_guide.hlsli's guide_sphere_warp: a point of the unit square warped down the quadtree,
// the column by u.x, then the row by u.y, each rescaled, and the rest of u the point in the leaf.
guide_mirror_sphere_warp :: proc(m: ^Guide_Mirror, point: [2]f64) -> [3]f64 {
	u := point
	xy: [2]int
	for k in 1 ..= 3 {
		side := 1 << uint(k)
		at := level_offset(k)
		b := xy * 2
		n00 := m.nodes[at + b.y * side + b.x]
		n10 := m.nodes[at + b.y * side + b.x + 1]
		n01 := m.nodes[at + (b.y + 1) * side + b.x]
		n11 := m.nodes[at + (b.y + 1) * side + b.x + 1]
		left, right := n00 + n01, n10 + n11
		x := u.x * (left + right)
		col := x < left ? 0 : 1
		u.x = col == 0 ? x / left : (x - left) / right
		top, bottom := col == 0 ? n00 : n10, col == 0 ? n01 : n11
		y := u.y * (top + bottom)
		row := y < top ? 0 : 1
		u.y = row == 0 ? y / top : (y - top) / bottom
		u = {clamp(u.x, 0, 0.99999), clamp(u.y, 0, 0.99999)}
		xy = b + {col, row}
	}
	return unfold(([2]f64{f64(xy.x), f64(xy.y)} + u) / GUIDE_SIDE * 2 - 1)
}

@(private = "file")
PROBE_TEXELS :: GI_PROBE_INTERIOR * GI_PROBE_INTERIOR
@(private = "file")
PROBE_TEST_RAYS :: 64
@(private = "file")
PROBE_TEST_UPDATES :: 20000

// Probe_Test_Light is the light around the probe: a window of 12 degrees, 80 times as bright as its sky.
@(private = "file")
Probe_Test_Light :: struct {
	window:   [3]f64,
	cos_half: f64,
	sky:      f64,
	bright:   f64,
}

@(private = "file")
test_light :: proc(l: Probe_Test_Light, d: [3]f64) -> f64 {
	return linalg.dot(d, l.window) >= l.cos_half ? l.bright : l.sky
}

// Probe_Test_Lobe is a tile's texels and, for one of the update's lobes, the light's integral over each and the lobe's.
@(private = "file")
Probe_Test_Lobe :: struct {
	texels:    [PROBE_TEXELS][3]f64,
	sharpness: f64,
	exact:     [PROBE_TEXELS]f64,
	total:     [PROBE_TEXELS]f64,
}

// Probe_Test_Result is a run of updates for each texel: the weighed sums' means and squares, and the means that the
// update keeps, with their squared errors against the light.
@(private = "file")
Probe_Test_Result :: struct {
	sum, square:  [PROBE_TEXELS]f64,
	mean, error2: [PROBE_TEXELS]f64,
}

// random_rotation is a rotation uniform over the rotations (Shoemake), as probe_rotation draws from the Halton sequence.
@(private = "file")
random_rotation :: proc(gen: rand.Generator) -> matrix[3, 3]f64 {
	u1, u2, u3 := rand.float64(gen), rand.float64(gen), rand.float64(gen)
	a, b := math.sqrt(1 - u1), math.sqrt(u1)
	q := quaternion(
		x = a * math.sin(math.TAU * u2),
		y = a * math.cos(math.TAU * u2),
		z = b * math.sin(math.TAU * u3),
		w = b * math.cos(math.TAU * u3),
	)
	return linalg.matrix3_from_quaternion(q)
}

// probe_test_run mirrors gi_probe_update.hlsl's blend of a lobe over many updates. The first rays are a Fibonacci set
// of their count at a random rotation, and the rest, guided of them, the R2 sequence at a random shift, warped down the
// guide (probe_ray). Each ray's weight is the maximum heuristic's (probe_ray_weight), and each mean is over the lobe's
// weight in the Fibonacci rays alone.
@(private = "file")
probe_test_run :: proc(
	guide: ^Guide_Mirror,
	guided: int,
	lobe: ^Probe_Test_Lobe,
	l: Probe_Test_Light,
	gen: rand.Generator,
) -> (
	res: Probe_Test_Result,
) {
	fibonacci := PROBE_TEST_RAYS - guided
	directions: [PROBE_TEST_RAYS][3]f64
	weights: [PROBE_TEST_RAYS]f64
	share := f64(PROBE_TEST_RAYS) / f64(fibonacci)
	for _ in 0 ..< PROBE_TEST_UPDATES {
		rotation := random_rotation(gen)
		offset := [2]f64{rand.float64(gen), rand.float64(gen)}
		for i in 0 ..< PROBE_TEST_RAYS {
			if i < fibonacci {
				z := 1 - (2 * f64(i) + 1) / f64(fibonacci)
				s := math.sqrt(max(1 - z * z, 0))
				phi := f64(i) * 2.39996323
				directions[i] = rotation * [3]f64{s * math.cos(phi), s * math.sin(phi), z}
			} else {
				point := offset + f64(i - fibonacci) * [2]f64{0.75487766, 0.56984029}
				directions[i] = guide_mirror_sphere_warp(guide, point - linalg.floor(point))
			}
			weights[i] = 1
			if guided > 0 {
				f := f64(fibonacci) / (4 * math.PI)
				g := f64(guided) * guide_mirror_sphere_pdf(guide, directions[i])
				if i < fibonacci {
					weights[i] = f >= g ? share : 0
				} else {
					weights[i] = g > f ? PROBE_TEST_RAYS / (4 * math.PI * g) : 0
				}
			}
		}
		for x, k in lobe.texels {
			sum, total: f64
			for d, i in directions {
				c := math.pow(max(linalg.dot(d, x), 0), lobe.sharpness)
				sum += test_light(l, d) * c * weights[i]
				if i < fibonacci {
					total += c * share
				}
			}
			// The weighed sum over a uniform ray's density is the integral's estimate.
			integral := sum * 4 * math.PI / PROBE_TEST_RAYS
			res.sum[k] += integral / PROBE_TEST_UPDATES
			res.square[k] += integral * integral / PROBE_TEST_UPDATES
			mean := total > 0 ? sum / total : 0
			res.mean[k] += mean / PROBE_TEST_UPDATES
			e := mean - lobe.exact[k] / lobe.total[k]
			res.error2[k] += e * e / PROBE_TEST_UPDATES
		}
	}
	return
}

// The world probes' update with half of its rays from the guide, as gi_probe_update.hlsl blends them. The weighed sum
// over each texel's lobe, the cosine's and the radiance's, is the light's integral without bias, with a guide learned
// from the light and with one that points away from it. The means that the update keeps, over the lobe's weight in the
// Fibonacci rays, are as near the light as the Fibonacci set's own, and with the learned guide each update's error is
// smaller. The update blends about 33 updates, which divides its noise but not its bias, so the bias is what must not
// grow.
@(test)
the_probes_guided_update_is_unbiased :: proc(t: ^testing.T) {
	r := rand.create(23)
	gen := rand.default_random_generator(&r)
	l := Probe_Test_Light {
		window   = linalg.normalize([3]f64{0.6, 0.3, 0.74}),
		cos_half = math.cos(math.to_radians(f64(12))),
		sky      = 0.5,
		bright   = 40,
	}

	// The texels of a probe's tile, and each one's lobes integrated over a fine grid.
	lobes := new([2]Probe_Test_Lobe)
	defer free(lobes)
	lobes[0].sharpness, lobes[1].sharpness = 1, 8
	for i in 0 ..< PROBE_TEXELS {
		x := unfold(
			{
				(f64(i % GI_PROBE_INTERIOR) + 0.5) / GI_PROBE_INTERIOR * 2 - 1,
				(f64(i / GI_PROBE_INTERIOR) + 0.5) / GI_PROBE_INTERIOR * 2 - 1,
			},
		)
		lobes[0].texels[i], lobes[1].texels[i] = x, x
	}
	rows :: 300
	for i in 0 ..< rows {
		theta := (f64(i) + 0.5) / rows * math.PI
		for j in 0 ..< 2 * rows {
			phi := (f64(j) + 0.5) / (2 * rows) * 2 * math.PI
			d := [3]f64 {
				math.sin(theta) * math.cos(phi),
				math.sin(theta) * math.sin(phi),
				math.cos(theta),
			}
			area := math.sin(theta) * (math.PI / rows) * (math.PI / rows)
			light := test_light(l, d)
			for &lobe in lobes {
				for x, k in lobe.texels {
					c := math.pow(max(linalg.dot(d, x), 0), lobe.sharpness)
					lobe.exact[k] += light * c * area
					lobe.total[k] += c * area
				}
			}
		}
	}

	// A guide learned from the light, each leaf the light through it integrated over it, with the build's floor, and
	// one that points away from it.
	learned, wrong: [GUIDE_LEAVES]f64
	for i in 0 ..< GUIDE_LEAVES {
		cell := [2]f64{f64(i % GUIDE_SIDE), f64(i / GUIDE_SIDE)}
		center := unfold((cell + 0.5) / GUIDE_SIDE * 2 - 1)
		wrong[i] =
			(linalg.dot(center, -l.window) > 0.7 ? 100.0 : 1.0) *
			4.0 /
			GUIDE_LEAVES *
			jacobian(center)
		SUB :: 16
		for y in 0 ..< SUB {
			for x in 0 ..< SUB {
				d := unfold((cell + ([2]f64{f64(x), f64(y)} + 0.5) / SUB) / GUIDE_SIDE * 2 - 1)
				learned[i] += test_light(l, d) * jacobian(d) * 4.0 / (GUIDE_LEAVES * SUB * SUB)
			}
		}
	}
	for leaves in ([]^[GUIDE_LEAVES]f64{&learned, &wrong}) {
		total: f64
		for v in leaves {
			total += v
		}
		for &v in leaves {
			v += GUIDE_FLOOR * total / GUIDE_LEAVES
		}
	}
	guides := []Guide_Mirror{guide_mirror_build(learned), guide_mirror_build(wrong)}

	for &lobe in lobes {
		plain := probe_test_run(&guides[0], 0, &lobe, l, gen)
		for &guide, g in guides {
			res := probe_test_run(&guide, PROBE_TEST_RAYS / 2, &lobe, l, gen)
			error_plain, error_guided, bias_plain, bias_guided: f64
			for k in 0 ..< PROBE_TEXELS {
				// The weighed sum, within four standard errors of the light's integral.
				se := math.sqrt(
					max(res.square[k] - res.sum[k] * res.sum[k], 0) / PROBE_TEST_UPDATES,
				)
				testing.expectf(
					t,
					abs(res.sum[k] - lobe.exact[k]) < 4 * se + 2e-3 * lobe.exact[k],
					"guide %d, lobe %v, texel %d: %v, not %v, with a standard error of %v",
					g,
					lobe.sharpness,
					k,
					res.sum[k],
					lobe.exact[k],
					se,
				)
				truth := lobe.exact[k] / lobe.total[k]
				bias_plain = max(bias_plain, abs(plain.mean[k] - truth) / truth)
				bias_guided = max(bias_guided, abs(res.mean[k] - truth) / truth)
				error_plain += math.sqrt(plain.error2[k]) / truth / PROBE_TEXELS
				error_guided += math.sqrt(res.error2[k]) / truth / PROBE_TEXELS
			}
			log.infof(
				"guide %d, lobe %v: error per update %.3f -> %.3f, largest bias %.4f -> %.4f",
				g,
				lobe.sharpness,
				error_plain,
				error_guided,
				bias_plain,
				bias_guided,
			)
			testing.expectf(
				t,
				bias_guided < max(2 * bias_plain, 0.01),
				"guide %d, lobe %v: the means' bias %v against the Fibonacci set's %v",
				g,
				lobe.sharpness,
				bias_guided,
				bias_plain,
			)
			if g == 0 {
				testing.expectf(
					t,
					error_guided < error_plain,
					"lobe %v: a learned guide's error %v, not below the Fibonacci set's %v",
					lobe.sharpness,
					error_guided,
					error_plain,
				)
			}
		}
	}
}
