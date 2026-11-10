package render

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
near :: proc(a, b: [3]f32, tolerance: f32 = 1e-5) -> bool {
	return linalg.length(a - b) <= tolerance
}

@(test)
the_flat_ambient_is_the_sky_above_and_the_ground_below :: proc(t: ^testing.T) {
	sky, ground := [3]f32{0.4, 0.5, 0.9}, [3]f32{0.2, 0.1, 0.05}
	a := flat_ambient(sky, ground)
	testing.expect(t, near(ambient_at(a, {0, 1, 0}), sky))
	testing.expect(t, near(ambient_at(a, {0, -1, 0}), ground))
	testing.expect(t, near(ambient_at(a, {1, 0, 0}), (sky + ground) * 0.5))
	testing.expect(t, near(ambient_at(DEFAULT_AMBIENT, {0, 1, 0}), DEFAULT_SKY_COLOR))
	testing.expect(t, near(ambient_at(DEFAULT_AMBIENT, {0, -1, 0}), DEFAULT_GROUND_COLOR))
}

@(test)
the_fogs_sky_light_without_anisotropy_is_the_average :: proc(t: ^testing.T) {
	a := Ambient{constant = {0.4, 0.5, 0.6}, x = {0.1, 0, 0}, y = {0.2, 0.25, 0.3}, z = {0, -0.05, 0.1}}
	for d in ([][3]f32{{0, 1, 0}, {0, -1, 0}, {1, 0, 0}, linalg.normalize([3]f32{1, -2, 3})}) {
		testing.expect(t, near(ambient_scattered(a, 0, d), a.constant))
	}
}

// The share of light that scatters by an angle, per steradian, as henyey_greenstein in fog_inject.hlsli has it.
@(private = "file")
henyey_greenstein :: proc(g, cos_theta: f64) -> f64 {
	g2 := g * g
	return (1 - g2) / (4 * math.PI * math.pow(1 + g2 - 2 * g * cos_theta, 1.5))
}

// The fog's sky light is the integral, over every direction, of the sky's light from it through the phase toward the
// camera. The sky's light from a direction is the ambient's constant and its gradient times 1.5, which undoes the
// cosine's convolution.
@(test)
the_fogs_sky_light_is_the_sky_through_the_phase :: proc(t: ^testing.T) {
	a := Ambient{constant = {0.5, 0.6, 0.8}, x = {0.05, 0.02, -0.03}, y = {0.2, 0.25, 0.35}, z = {-0.04, 0.06, 0.01}}
	// At g = 0.9 the phase's lobe is about 0.1 radians wide, so the directions are 0.007 radians apart.
	N :: 1 << 18
	golden := math.PI * (3 - math.sqrt(f64(5)))
	for g in ([]f32{-0.5, 0, 0.5, 0.9}) {
		for toward in ([][3]f32{{0, -1, 0}, {0, 1, 0}, linalg.normalize([3]f32{1, -2, 3})}) {
			sum: [3]f64
			for i in 0 ..< N {
				y := 1 - (f64(i) + 0.5) * 2 / N
				r := math.sqrt(1 - y * y)
				w := [3]f64{math.cos(golden * f64(i)) * r, y, math.sin(golden * f64(i)) * r}
				from := [3]f64{f64(a.constant.r), f64(a.constant.g), f64(a.constant.b)}
				for c in 0 ..< 3 {
					from[c] += 1.5 * (f64(a.x[c]) * w.x + f64(a.y[c]) * w.y + f64(a.z[c]) * w.z)
				}
				// Light from w travels along -w, and leaves along toward.
				cos_theta := -(w.x * f64(toward.x) + w.y * f64(toward.y) + w.z * f64(toward.z))
				sum += from * henyey_greenstein(f64(g), cos_theta)
			}
			integral := sum * (4 * math.PI / N)
			expected := [3]f32{f32(integral.x), f32(integral.y), f32(integral.z)}
			got := ambient_scattered(a, g, toward)
			testing.expectf(t, near(got, expected, 1e-3), "g %v toward %v: %v, the integral %v", g, toward, got, expected)
		}
	}
	// Fog that scatters forward, above a camera under a Flat sky, takes more of the sky's light than fog below it.
	flat := flat_ambient({0.4, 0.5, 0.9}, {0.2, 0.1, 0.05})
	above, below := ambient_scattered(flat, 0.5, {0, -1, 0}), ambient_scattered(flat, 0.5, {0, 1, 0})
	testing.expectf(t, above.b > flat.constant.b && below.b < flat.constant.b, "above %v, below %v", above, below)
}

@(test)
the_air_dims_and_reddens_the_sun_toward_the_horizon :: proc(t: ^testing.T) {
	a := sky_settings(DEFAULT_ENVIRONMENT).atmosphere
	zenith := sky_transmittance(a, 0.001, {0, 1, 0})
	low := sky_transmittance(a, 0.001, sky_direction(0, 2))
	below := sky_transmittance(a, 0.001, sky_direction(0, -5))
	testing.expectf(t, zenith.r > 0.9 && zenith.b > 0.7, "zenith %v", zenith)
	testing.expectf(t, low.r < zenith.r && low.b < low.r * 0.5, "low %v", low)
	testing.expect_value(t, below, [3]f32{})
}

// The ground that the sun lights is brighter than the sky, as it is outside, so only the sky's color is checked.
@(test)
a_noon_sky_is_blue_and_a_night_sky_dark :: proc(t: ^testing.T) {
	a := sky_settings(DEFAULT_ENVIRONMENT).atmosphere
	noon := sky_ambient(a, 0.001, {{sky_direction(0, 60), 3}})
	up := ambient_at(noon, {0, 1, 0})
	testing.expectf(t, up.b > up.g && up.g > up.r && up.r > 0, "the sky from above is %v", up)
	night := sky_ambient(a, 0.001, {{sky_direction(0, -30), 3}})
	testing.expectf(t, linalg.length(ambient_at(night, {0, 1, 0})) < linalg.length(up) * 0.01, "night %v", night)
}

// The sky's light toward a low sun, where Mie's lobe is, is brighter than the sky's light away from it, so fog that
// scatters forward glows toward a sunset.
@(test)
a_sunsets_ambient_is_brighter_toward_the_sun :: proc(t: ^testing.T) {
	a := sky_settings(DEFAULT_ENVIRONMENT).atmosphere
	for el in ([]f32{4, 15, 45}) {
		toward := sky_direction(0, el)
		ambient := sky_ambient(a, 0.003, {{toward, 3}})
		along := [3]f32{toward.x, 0, toward.z}
		gradient := ambient.x * along.x + ambient.z * along.z
		testing.expectf(t, gradient.r > 0.015 * ambient.constant.r && gradient.b > 0, "elevation %v: the gradient toward the sun is %v, the constant %v", el, gradient, ambient.constant)
	}
}

@(test)
an_environment_takes_its_sun_from_the_angles :: proc(t: ^testing.T) {
	env := DEFAULT_ENVIRONMENT
	env.mode = {true, .Atmosphere}
	env.sun_azimuth = {true, 90}
	env.sun_elevation = {true, 0}
	s := sky_settings(env)
	testing.expect_value(t, s.mode, Sky_Mode.Atmosphere)
	testing.expect(t, near(s.sun_direction, {1, 0, 0}))
	testing.expect_value(t, sky_settings(DEFAULT_ENVIRONMENT).mode, Sky_Mode.Flat)
}

// A texture sky's rotation turns its ambient light about +y: the light that the texture's middle column holds, toward
// +z unturned, comes from +x after a quarter turn, as the background shows the column there.
@(test)
a_texture_skys_rotation_turns_its_ambient_light :: proc(t: ^testing.T) {
	a := Ambient{constant = {1, 1, 1}, z = {0.5, 0.5, 0.5}}
	turned := turn_ambient(a, math.PI / 2)
	testing.expect(t, near(ambient_at(turned, {1, 0, 0}), {1.5, 1.5, 1.5}))
	testing.expect(t, near(ambient_at(turned, {0, 0, 1}), {1, 1, 1}))
	testing.expect(t, near(ambient_at(turn_ambient(a, 0), {0, 0, 1}), {1.5, 1.5, 1.5}))
}

// Until its texture is resident, a texture sky's ambient light is the Flat one, and nothing draws over the background.
@(test)
a_texture_sky_without_its_texture_is_flat :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	f := Frame{renderer = r}
	settings := Sky_Settings{mode = .Texture, sky = {0.4, 0.5, 0.9}, ground = {0.2, 0.1, 0.05}, ambient_intensity = 2, texture_intensity = 1}
	ambient := begin_sky(&f, settings)
	testing.expect(t, near(ambient_at(ambient, {0, 1, 0}), {0.8, 1, 1.8}))
	testing.expect(t, f.sky_texture == nil && f.sky == nil)
}

// The texture sky's sun, which the editor aims at: only a texture sky has one, once its integral is back, when its
// brightest texels stand out, and it turns with the rotation.
@(test)
a_texture_skys_sun_is_where_its_brightest_texels_are :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	s := &r.sky.texture
	_, state := sky_texture_sun(r)
	testing.expect_value(t, state, Sky_Sun_State.No_Texture_Sky)
	r.last_sky_mode = .Texture
	_, state = sky_texture_sun(r)
	testing.expect_value(t, state, Sky_Sun_State.Not_Ready)
	s.valid, s.sun_ratio = true, 3
	s.sun, s.sun_frame = {0, 0.5, 0.866}, 0
	s.world_sun = turn_direction(s.sun, math.PI / 2)
	_, state = sky_texture_sun(r)
	testing.expect_value(t, state, Sky_Sun_State.No_Sun)
	s.sun_ratio = 1000
	direction, found := sky_texture_sun(r)
	testing.expect_value(t, found, Sky_Sun_State.Found)
	// A quarter turn takes the texture's +z to +x, as the background and the ambient light turn it.
	testing.expect(t, near(direction, {0.866, 0.5, 0}, 1e-4))
	r.scene.frame = 5
	_, state = sky_texture_sun(r)
	testing.expect_value(t, state, Sky_Sun_State.Not_Ready)
}
