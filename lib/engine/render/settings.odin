package render

import "cinnabar:engine/ecs"
import "cinnabar:engine/volume"

// The render settings (see docs/rendering/frame.md#settings) are settings components on volumes (see docs/world/volumes.md#volumes):
// the frame takes each from the volumes at the camera. Each field is a volume.Value. A setting that no volume
// overrides has its default, from the DEFAULT_ structs below, which register_settings_components registers, so a
// component added in the editor starts from them too.

ANTI_ALIASING_ID :: ecs.Component_Id(43)
EXPOSURE_ID :: ecs.Component_Id(44)
TONE_MAPPING_ID :: ecs.Component_Id(45)
BLOOM_ID :: ecs.Component_Id(46)
AMBIENT_OCCLUSION_ID :: ecs.Component_Id(47)
GLOBAL_ILLUMINATION_ID :: ecs.Component_Id(48)
ENVIRONMENT_ID :: ecs.Component_Id(49)
SHADOWS_ID :: ecs.Component_Id(50)

// Anti_Aliasing is the anti-aliasing, of the technique that the quality chooses (see
// docs/rendering/anti-aliasing.md#anti-aliasing): off turns it off.
Anti_Aliasing :: struct {
	off: volume.Value(bool),
}

// Exposure is how bright the scene shows: adapted to the scene's average luminance, or manual.
Exposure :: struct {
	mode:             volume.Value(Exposure_Mode),
	// With Manual, the scale of the scene's colors.
	exposure:         volume.Value(f32) `editor:"range=0,10"`,
	// Stops added to the exposure, in either mode.
	compensation:     volume.Value(f32) `editor:"range=-5,5"`,
	// With Auto, the range of the scene's average luminance, as log2, that the exposure adapts to.
	range:            volume.Value([2]f32),
	// With Auto, how fast the exposure adapts.
	adaptation_speed: volume.Value(f32) `editor:"range=0,10"`,
}

// Tone_Mapping is the curve from the scene's HDR colors to the display's, and the color grading that the lookup table
// bakes with it.
Tone_Mapping :: struct {
	tone_mapper: volume.Value(Tone_Mapper),
	// In stops around middle grey.
	contrast:    volume.Value(f32) `editor:"range=0,3"`,
	// 0 is grey.
	saturation:  volume.Value(f32) `editor:"range=0,2"`,
	// Multiplies the scene.
	tint:        volume.Value([3]f32) `editor:"color"`,
	// For HDR output, in nits: the brightness of SDR's white, which the UI has, and the brightest color. 0 gives the
	// display's. Paper white is at most the peak.
	paper_white: volume.Value(f32) `editor:"range=0,1000"`,
	peak:        volume.Value(f32) `editor:"range=0,10000"`,
}

Bloom :: struct {
	off:       volume.Value(bool),
	// Bloom's share of the final color.
	intensity: volume.Value(f32) `editor:"range=0,0.5"`,
}

// Ambient_Occlusion is the ambient occlusion (see docs/rendering/ambient-occlusion.md#ambient-occlusion).
Ambient_Occlusion :: struct {
	off:    volume.Value(bool),
	// In meters.
	radius: volume.Value(f32) `editor:"range=0,5"`,
	power:  volume.Value(f32) `editor:"range=0,5"`,
}

// Global_Illumination is the global illumination (see docs/rendering/global-illumination.md#global-illumination). Without it, the indirect
// light is the Environment's ambient light.
Global_Illumination :: struct {
	off: volume.Value(bool),
}

// Environment is what is around the world (see docs/rendering/sky.md#sky): the background where nothing draws, and the
// light from everything else until global illumination, its ambient light. With Flat, the background is a color, which
// is not pre-exposed, and the ambient light is the sky's color from above and the ground's from below. With Atmosphere,
// both are the sky's: the atmosphere scatters the sun's and the moon's light, and the night has stars.
Environment :: struct {
	mode:              volume.Value(Sky_Mode),
	background:        volume.Value([3]f32) `editor:"color"`,
	sky:               volume.Value([3]f32) `editor:"color"`,
	ground:            volume.Value([3]f32) `editor:"color"`,
	// Multiplies the ambient light, in either mode.
	ambient_intensity: volume.Value(f32) `editor:"range=0,4"`,
	// The directional light that is the sun, whose direction and light the sky takes and whose light the atmosphere
	// tints (see docs/rendering/sky.md#the-sun). Without one, the sky's sun is at the angles below and lights nothing
	// else.
	sun:               volume.Value(ecs.Entity),
	// In degrees: the azimuth from +z toward +x, and the elevation above the horizon.
	sun_azimuth:       volume.Value(f32) `editor:"range=0,360"`,
	sun_elevation:     volume.Value(f32) `editor:"range=-90,90"`,
	sun_illuminance:   volume.Value(f32) `editor:"range=0,100"`,
	// The sun disc's angular diameter, in degrees.
	sun_disc_size:     volume.Value(f32) `editor:"range=0,5"`,
	atmosphere:        Atmosphere,
	night:             Night,
}

// Sky_Mode is what an Environment draws around the world.
Sky_Mode :: enum u8 {
	Flat,
	Atmosphere,
}

// Atmosphere is the planet's air (see docs/rendering/sky.md#the-atmosphere), after Hillaire's model: molecules that
// scatter blue more than red (Rayleigh), aerosols that scatter all colors forward and absorb some (Mie), and ozone that
// absorbs. Coefficients are per megameter, and heights in kilometers, as the literature has them; the defaults are
// Earth's.
Atmosphere :: struct {
	rayleigh_scattering: volume.Value([3]f32),
	// The height over which the density falls by e.
	rayleigh_height:     volume.Value(f32) `editor:"range=0.1,30"`,
	mie_scattering:      volume.Value(f32) `editor:"range=0,100"`,
	mie_absorption:      volume.Value(f32) `editor:"range=0,100"`,
	mie_anisotropy:      volume.Value(f32) `editor:"range=0,0.99"`,
	mie_height:          volume.Value(f32) `editor:"range=0.1,10"`,
	ozone_absorption:    volume.Value([3]f32),
	ground_albedo:       volume.Value([3]f32) `editor:"color"`,
	planet_radius:       volume.Value(f32) `editor:"range=1,10000"`,
	// From the ground to the top of the atmosphere.
	atmosphere_height:   volume.Value(f32) `editor:"range=1,200"`,
	// The world's y of 0 above the ground, to which the camera's y adds.
	altitude:            volume.Value(f32) `editor:"range=0,50"`,
}

// Night is what an Atmosphere has besides the sun (see docs/rendering/sky.md#night). The moon is a disc that the sun
// lights, so its phase follows the angle between them, and it lights the sky; stars are points in every direction. An
// illuminance or intensity of 0 leaves either out.
Night :: struct {
	// In degrees, as the sun's.
	moon_azimuth:     volume.Value(f32) `editor:"range=0,360"`,
	moon_elevation:   volume.Value(f32) `editor:"range=-90,90"`,
	// When full.
	moon_illuminance: volume.Value(f32) `editor:"range=0,1"`,
	moon_disc_size:   volume.Value(f32) `editor:"range=0,10"`,
	moon_color:       volume.Value([3]f32) `editor:"color"`,
	star_intensity:   volume.Value(f32) `editor:"range=0,10"`,
	// The share of directions with a star, about.
	star_density:     volume.Value(f32) `editor:"range=0,1"`,
}

// Shadows are the directional lights' cascades: how far they reach, and how their depths split, between even (toward
// 0) and exponential (1), which gives the near ones more texels.
Shadows :: struct {
	// In meters from the camera.
	distance:     volume.Value(f32) `editor:"range=1,1000"`,
	split_lambda: volume.Value(f32) `editor:"range=0,1"`,
}

// Fog fills the world with volumetric fog (see docs/rendering/fog.md#volumetric-fog). Its density is the share of light
// that a meter of fog takes away, at and below its base height, and falls off above it. A density of 0 is no fog.
Fog :: struct {
	density:        volume.Value(f32) `editor:"range=0,1"`,
	// The share of the light that the fog takes away that it scatters rather than absorbs, per channel.
	albedo:         volume.Value([3]f32) `editor:"color"`,
	// The world's height in meters, its y, below which the density is whole.
	base_height:    volume.Value(f32) `editor:"range=-100,100"`,
	// How fast the density falls with height above the base, per meter. 0 keeps it the same everywhere.
	height_falloff: volume.Value(f32) `editor:"range=0,10"`,
	// Where the fog scatters light: above 0 forward, so it glows around a light that the camera looks toward, and below
	// 0 back toward the light.
	anisotropy:     volume.Value(f32) `editor:"range=-0.9,0.9"`,
}

// The settings' defaults, which volumes blend from.
DEFAULT_EXPOSURE :: Exposure {
	exposure = {value = 1},
	range = {value = DEFAULT_EXPOSURE_RANGE},
	adaptation_speed = {value = DEFAULT_ADAPTATION_SPEED},
}
DEFAULT_TONE_MAPPING :: Tone_Mapping {
	contrast = {value = 1},
	saturation = {value = 1},
	tint = {value = {1, 1, 1}},
}
DEFAULT_BLOOM :: Bloom {
	intensity = {value = DEFAULT_BLOOM_INTENSITY},
}
DEFAULT_AMBIENT_OCCLUSION :: Ambient_Occlusion {
	radius = {value = DEFAULT_AO_RADIUS},
	power = {value = DEFAULT_AO_POWER},
}
DEFAULT_ENVIRONMENT :: Environment {
	sky = {value = DEFAULT_SKY_COLOR},
	ground = {value = DEFAULT_GROUND_COLOR},
	ambient_intensity = {value = 1},
	sun_elevation = {value = 45},
	sun_illuminance = {value = 3},
	sun_disc_size = {value = DEFAULT_SUN_DISC},
	atmosphere = {
		rayleigh_scattering = {value = {5.802, 13.558, 33.1}},
		rayleigh_height = {value = 8},
		mie_scattering = {value = 3.996},
		mie_absorption = {value = 4.4},
		mie_anisotropy = {value = 0.8},
		mie_height = {value = 1.2},
		ozone_absorption = {value = {0.65, 1.881, 0.085}},
		ground_albedo = {value = {0.3, 0.3, 0.3}},
		planet_radius = {value = 6360},
		atmosphere_height = {value = 100},
	},
	night = {
		moon_azimuth = {value = 180},
		moon_elevation = {value = 30},
		moon_disc_size = {value = DEFAULT_MOON_DISC},
		moon_color = {value = {1, 1, 1}},
		star_density = {value = 0.3},
	},
}
DEFAULT_FOG :: Fog {
	albedo = {value = {1, 1, 1}},
}
DEFAULT_SHADOWS :: Shadows {
	distance = {value = SHADOW_DISTANCE},
	split_lambda = {value = SHADOW_SPLIT_LAMBDA},
}

// Shadow_Settings are a frame's cascades, from the Shadows settings, and its shadows' quality. A distance of 0 gives
// SHADOW_DISTANCE.
Shadow_Settings :: struct {
	distance:     f32,
	split_lambda: f32,
	// The shadow maps' SHADOW_PARAMS, and whether the first lights trace their shadows where the device can.
	level:        Quality_Level,
	ray_traced:   bool,
}

// Fog_Settings are a frame's fog, from the Fog settings. A density of 0 is no fog.
Fog_Settings :: struct {
	density:        f32,
	albedo:         [3]f32,
	base_height:    f32,
	height_falloff: f32,
	anisotropy:     f32,
	// The volume's FOG_LEVEL_SLICES.
	level:          Quality_Level,
}

// Frame_Settings are a frame's settings, which resolve_settings takes from the volumes at the camera. A game can
// resolve them, change them and give them to the frame in Frame_Desc.settings. draw_frame then gives them the frame's
// quality (see apply_quality).
Frame_Settings :: struct {
	post:              Post_Settings,
	ambient_occlusion: Ao_Settings,
	gi:                Gi_Settings,
	fog:               Fog_Settings,
	shadows:           Shadow_Settings,
	// What is around the world: the background and the ambient light.
	sky:               Sky_Settings,
	// The game's post effects' settings, by their index in Renderer.effects (see register_post_effect).
	effects:           []Effect_Settings,
}

register_settings_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Anti_Aliasing, ANTI_ALIASING_ID)
	ecs.register_component(r, Exposure, EXPOSURE_ID, DEFAULT_EXPOSURE)
	ecs.register_component(r, Tone_Mapping, TONE_MAPPING_ID, DEFAULT_TONE_MAPPING)
	ecs.register_component(r, Bloom, BLOOM_ID, DEFAULT_BLOOM)
	ecs.register_component(r, Ambient_Occlusion, AMBIENT_OCCLUSION_ID, DEFAULT_AMBIENT_OCCLUSION)
	ecs.register_component(r, Global_Illumination, GLOBAL_ILLUMINATION_ID)
	ecs.register_component(r, Environment, ENVIRONMENT_ID, DEFAULT_ENVIRONMENT)
	ecs.register_component(r, Fog, FOG_ID, DEFAULT_FOG)
	ecs.register_component(r, Shadows, SHADOWS_ID, DEFAULT_SHADOWS)
}

// resolve_settings takes the frame's settings from the volumes at a position, usually the camera's, leaving out the
// hidden entities, as Frame_Desc.hidden gives them.
resolve_settings :: proc(r: ^Renderer, w: ^ecs.World, position: ecs.World_Position, hidden: []u32 = nil) -> Frame_Settings {
	inf := volume.gather(&r.volumes, w, position, hidden)
	aa, _ := volume.blend(w, &inf, Anti_Aliasing)
	exposure, _ := volume.blend(w, &inf, Exposure)
	tone, _ := volume.blend(w, &inf, Tone_Mapping)
	bloom, _ := volume.blend(w, &inf, Bloom)
	ao, _ := volume.blend(w, &inf, Ambient_Occlusion)
	gi, _ := volume.blend(w, &inf, Global_Illumination)
	env, _ := volume.blend(w, &inf, Environment)
	fog, _ := volume.blend(w, &inf, Fog)
	shadows, _ := volume.blend(w, &inf, Shadows)
	return {
		post = {
			no_aa = aa.off.value,
			no_bloom = bloom.off.value,
			bloom_intensity = bloom.intensity.value,
			exposure_mode = exposure.mode.value,
			exposure = exposure.exposure.value,
			exposure_compensation = exposure.compensation.value,
			exposure_range = exposure.range.value,
			adaptation_speed = exposure.adaptation_speed.value,
			tone_mapper = tone.tone_mapper.value,
			contrast = tone.contrast.value,
			saturation = tone.saturation.value,
			tint = tone.tint.value,
			paper_white = tone.paper_white.value,
			peak = tone.peak.value,
		},
		ambient_occlusion = {off = ao.off.value, radius = ao.radius.value, power = ao.power.value},
		gi = {off = gi.off.value},
		fog = {
			density = fog.density.value,
			albedo = fog.albedo.value,
			base_height = fog.base_height.value,
			height_falloff = fog.height_falloff.value,
			anisotropy = fog.anisotropy.value,
		},
		shadows = {distance = shadows.distance.value, split_lambda = shadows.split_lambda.value},
		sky = sky_settings(env),
		effects = resolve_effects(r, w, &inf),
	}
}
