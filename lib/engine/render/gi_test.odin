package render

import "core:math"
import "core:math/linalg"
import "core:testing"

// octahedral_point and direction_weight match gi_common.hlsli.
@(private = "file")
octahedral_point :: proc(p: [2]f64) -> [3]f64 {
	n := [3]f64{p.x, p.y, 1 - abs(p.x) - abs(p.y)}
	if n.z < 0 {
		n.x = (1 - abs(p.y)) * (p.x >= 0 ? 1 : -1)
		n.y = (1 - abs(p.x)) * (p.y >= 0 ? 1 : -1)
	}
	return n
}

@(private = "file")
texel_point :: proc(texel: [2]int, directions: int, within: [2]f64) -> [3]f64 {
	return octahedral_point(([2]f64{f64(texel.x), f64(texel.y)} + within) / f64(directions) * 2 - 1)
}

@(private = "file")
cosine_weight :: proc(texel: [2]int, directions: int, normal: [3]f64) -> f64 {
	return max(linalg.dot(linalg.normalize(texel_point(texel, directions, 0.5)), normal), 0)
}

@(private = "file")
solid_angle_weight :: proc(texel: [2]int, directions: int, normal: [3]f64) -> f64 {
	p := texel_point(texel, directions, 0.5)
	l2 := linalg.dot(p, p)
	return max(linalg.dot(p, normal), 0) / (l2 * l2)
}

@(private = "file")
direction_weight :: proc(texel: [2]int, directions: int, normal: [3]f64) -> f64 {
	return directions < 6 ? cosine_weight(texel, directions, normal) : solid_angle_weight(texel, directions, normal)
}

// fibonacci is a point of a spherical Fibonacci set of count points.
@(private = "file")
fibonacci :: proc(i, count: int) -> [3]f64 {
	z := 1 - (2 * f64(i) + 1) / f64(count)
	r := math.sqrt(max(1 - z * z, 0))
	phi := f64(i) * 2.39996322972865332
	return {r * math.cos(phi), r * math.sin(phi), z}
}

@(private = "file")
Light_Shape :: enum {
	// Light from every direction on one side of a plane, as a sky above a horizon.
	Hemisphere,
	// Light that falls off smoothly away from a direction.
	Lobe,
}

@(private = "file")
light_from :: proc(shape: Light_Shape, toward, d: [3]f64) -> f64 {
	switch shape {
	case .Hemisphere:
		return linalg.dot(d, toward) > 0 ? 1 : 0
	case .Lobe:
		return math.exp(3 * (linalg.dot(d, toward) - 1))
	}
	return 0
}

// FINE is the side of the grid that the exact mean integrates over: the octahedron's square, where a cell's solid angle
// is its area over |p|^3.
@(private = "file")
FINE :: 160
// TEXEL_SAMPLES is the side of the grid that gives each texel its light: the mean over the texel's square, as the
// cascades' rays jitter evenly within it.
@(private = "file")
TEXEL_SAMPLES :: 12

@(private = "file")
exact_mean :: proc(shape: Light_Shape, toward, normal: [3]f64) -> f64 {
	sum, total: f64
	for i in 0 ..< FINE {
		for j in 0 ..< FINE {
			p := octahedral_point({(f64(i) + 0.5) / FINE * 2 - 1, (f64(j) + 0.5) / FINE * 2 - 1})
			l := linalg.length(p)
			d := p / l
			c := max(linalg.dot(d, normal), 0) / (l * l * l)
			sum += light_from(shape, toward, d) * c
			total += c
		}
	}
	return sum / total
}

@(private = "file")
Weighting :: enum {
	Chosen,
	Cosine,
	Solid_Angle,
}

// gather_errors is each weighting's root mean square error in the cosine-weighted mean of a light over many normals and
// light directions, as a share of the light that faces it head on.
@(private = "file")
gather_errors :: proc(directions: int, shape: Light_Shape) -> (errors: [Weighting]f64) {
	LIGHTS :: 11
	NORMALS :: 13
	texels := make([]f64, directions * directions, context.temp_allocator)
	squares: [Weighting]f64
	for li in 0 ..< LIGHTS {
		toward := fibonacci(li, LIGHTS)
		for &mean, t in texels {
			texel := [2]int{t % directions, t / directions}
			mean = 0
			for s in 0 ..< TEXEL_SAMPLES * TEXEL_SAMPLES {
				within := [2]f64{(f64(s % TEXEL_SAMPLES) + 0.5) / TEXEL_SAMPLES, (f64(s / TEXEL_SAMPLES) + 0.5) / TEXEL_SAMPLES}
				mean += light_from(shape, toward, linalg.normalize(texel_point(texel, directions, within)))
			}
			mean /= TEXEL_SAMPLES * TEXEL_SAMPLES
		}
		peak := exact_mean(shape, toward, toward)
		for ni in 0 ..< NORMALS {
			// The normals' set is turned from the lights', so that none lines up with a light.
			n := linalg.normalize(fibonacci(ni, NORMALS) + {0.11, -0.07, 0.05})
			exact := exact_mean(shape, toward, n)
			for weighting in Weighting {
				sum, total: f64
				for mean, t in texels {
					texel := [2]int{t % directions, t / directions}
					w: f64
					switch weighting {
					case .Chosen:
						w = direction_weight(texel, directions, n)
					case .Cosine:
						w = cosine_weight(texel, directions, n)
					case .Solid_Angle:
						w = solid_angle_weight(texel, directions, n)
					}
					sum += mean * w
					total += w
				}
				e := (sum / total - exact) / peak
				squares[weighting] += e * e
			}
		}
	}
	for weighting in Weighting {
		errors[weighting] = math.sqrt(squares[weighting] / (LIGHTS * NORMALS))
	}
	return
}

@(test)
the_solid_angle_counts_in_the_gather_from_6_directions :: proc(t: ^testing.T) {
	for shape in Light_Shape {
		// With 4 directions the cosine alone is the nearer of the two, so the gather keeps it.
		e4 := gather_errors(4, shape)
		testing.expectf(t, e4[.Cosine] <= e4[.Solid_Angle], "%v at 4: cosine %.4f, solid angle %.4f", shape, e4[.Cosine], e4[.Solid_Angle])
		testing.expectf(t, e4[.Chosen] < 0.045, "%v at 4: %.4f", shape, e4[.Chosen])
		// From 6, the solid angle is.
		for directions in ([]int{6, 8}) {
			e := gather_errors(directions, shape)
			testing.expectf(t, e[.Solid_Angle] < e[.Cosine], "%v at %d: cosine %.4f, solid angle %.4f", shape, directions, e[.Cosine], e[.Solid_Angle])
			testing.expectf(t, e[.Chosen] == e[.Solid_Angle], "%v at %d", shape, directions)
			if directions == 8 {
				testing.expectf(t, e[.Chosen] < 0.015, "%v at 8: %.4f", shape, e[.Chosen])
			}
		}
	}
	free_all(context.temp_allocator)
}

@(test)
the_cascades_fit_the_texture_at_every_level :: proc(t: ^testing.T) {
	for level in Quality_Level {
		for size in ([][2]u32{{1280, 720}, {1920, 1080}, {2560, 1440}, {3840, 2160}}) {
			params := gi_fit(size, GI_PARAMS[level])
			testing.expectf(t, params.cascades == GI_PARAMS[level].cascades, "%v at %v keeps %d cascades", level, size, params.cascades)
			region := gi_region(size, params)
			testing.expect(t, region.x <= GI_MAX_TEXTURE_SIZE && region.y * params.cascades <= GI_MAX_TEXTURE_SIZE)
		}
	}

	// Ultra's 8 directions at spacing 8 take no more texels than 4 directions at spacing 4 with a cascade more, and
	// reach as far: the interval grows with the directions.
	size := [2]u32{3840, 2160}
	ultra := GI_PARAMS[.Ultra]
	before := Gi_Params{cascades = 6, spacing = 4, directions = 4}
	texels :: proc(size: [2]u32, p: Gi_Params) -> u32 {
		region := gi_region(size, p)
		return region.x * region.y * p.cascades
	}
	testing.expect(t, texels(size, ultra) <= texels(size, before))
	reach :: proc(p: Gi_Params) -> f32 {
		base := GI_INTERVAL_SCALE * f32(p.directions) / 4 * f32(p.spacing)
		return base * f32((u32(1) << (2 * p.cascades)) - 1) / 3
	}
	testing.expect(t, abs(reach(ultra) - reach(before)) <= 0.01 * reach(before))

	// A view too large for every cascade keeps the nearer ones.
	params := gi_fit({7680, 4320}, ultra)
	testing.expect(t, params.cascades < ultra.cascades && params.cascades >= 1)
	region := gi_region({7680, 4320}, params)
	testing.expect(t, region.y * params.cascades <= GI_MAX_TEXTURE_SIZE)
}
