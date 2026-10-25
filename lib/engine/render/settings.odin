package render

import "cinnabar:engine/ecs"
import "cinnabar:engine/volume"

// The render settings (see docs/rendering.md#settings) are settings components on volumes (see docs/world.md#volumes):
// the frame takes each from the volumes at the camera. Each field is a volume.Value, and 0 in a value means its
// default, as elsewhere. A setting that no volume overrides has its default.

ANTI_ALIASING_ID :: ecs.Component_Id(43)
EXPOSURE_ID :: ecs.Component_Id(44)
TONE_MAPPING_ID :: ecs.Component_Id(45)
BLOOM_ID :: ecs.Component_Id(46)
AMBIENT_OCCLUSION_ID :: ecs.Component_Id(47)
GLOBAL_ILLUMINATION_ID :: ecs.Component_Id(48)
ENVIRONMENT_ID :: ecs.Component_Id(49)

// Anti_Aliasing is the temporal AA (see docs/rendering.md#post-processing).
Anti_Aliasing :: struct {
	off: volume.Value(bool),
}

// Exposure is how bright the scene shows: adapted to the scene's average luminance, or manual.
Exposure :: struct {
	mode:             volume.Value(Exposure_Mode),
	// With Manual, the scale of the scene's colors. 0 means 1.
	exposure:         volume.Value(f32) `editor:"range=0,10"`,
	// Stops added to the exposure, in either mode.
	compensation:     volume.Value(f32) `editor:"range=-5,5"`,
	// With Auto, the range of the scene's average luminance, as log2, that the exposure adapts to. Zero gives
	// DEFAULT_EXPOSURE_RANGE.
	range:            volume.Value([2]f32),
	// With Auto, how fast the exposure adapts. 0 gives DEFAULT_ADAPTATION_SPEED.
	adaptation_speed: volume.Value(f32) `editor:"range=0,10"`,
}

// Tone_Mapping is the curve from the scene's HDR colors to the display's, and the color grading that the lookup table
// bakes with it.
Tone_Mapping :: struct {
	tone_mapper: volume.Value(Tone_Mapper),
	// In stops around middle grey. 0 means 1.
	contrast:    volume.Value(f32) `editor:"range=0,3"`,
	// 0 means 1.
	saturation:  volume.Value(f32) `editor:"range=0,2"`,
	// Multiplies the scene. Zero means white.
	tint:        volume.Value([3]f32) `editor:"color"`,
	// For HDR output, in nits: the brightness of SDR's white, which the UI has, and the brightest color. 0 gives the
	// display's. Paper white is at most the peak.
	paper_white: volume.Value(f32) `editor:"range=0,1000"`,
	peak:        volume.Value(f32) `editor:"range=0,10000"`,
}

Bloom :: struct {
	off:       volume.Value(bool),
	// Bloom's share of the final color. 0 gives DEFAULT_BLOOM_INTENSITY.
	intensity: volume.Value(f32) `editor:"range=0,0.5"`,
}

// Ambient_Occlusion is the ambient occlusion (see docs/rendering.md#ambient-occlusion).
Ambient_Occlusion :: struct {
	off:    volume.Value(bool),
	// In meters. 0 gives DEFAULT_AO_RADIUS.
	radius: volume.Value(f32) `editor:"range=0,5"`,
	// 0 gives DEFAULT_AO_POWER.
	power:  volume.Value(f32) `editor:"range=0,5"`,
}

// Global_Illumination is the global illumination (see docs/rendering.md#global-illumination). Without it, the indirect
// light is the Environment's ambient light.
Global_Illumination :: struct {
	off: volume.Value(bool),
}

// Environment is what is around the world: the background where nothing draws, which is not pre-exposed, and the light
// from everything else until global illumination, the sky's from above and the ground's from below. Zero gives black
// for the background, and DEFAULT_AMBIENT.
Environment :: struct {
	background: volume.Value([3]f32) `editor:"color"`,
	sky:        volume.Value([3]f32) `editor:"color"`,
	ground:     volume.Value([3]f32) `editor:"color"`,
}

// Fog fills the world with volumetric fog (see docs/rendering.md#volumetric-fog). Its density is the share of light
// that a meter of fog takes away, at and below its base height, and falls off above it. A density of 0 is no fog.
Fog :: struct {
	density:        volume.Value(f32) `editor:"range=0,1"`,
	// The share of the light that the fog takes away that it scatters rather than absorbs, per channel. 0 means white.
	albedo:         volume.Value([3]f32) `editor:"color"`,
	// The world's height in meters, its y, below which the density is whole.
	base_height:    volume.Value(f32) `editor:"range=-100,100"`,
	// How fast the density falls with height above the base, per meter. 0 keeps it the same everywhere.
	height_falloff: volume.Value(f32) `editor:"range=0,10"`,
	// Where the fog scatters light: above 0 forward, so it glows around a light that the camera looks toward, and below
	// 0 back toward the light.
	anisotropy:     volume.Value(f32) `editor:"range=-0.9,0.9"`,
}

// The settings with their defaults resolved, which volumes blend from.
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
	sky = {value = DEFAULT_AMBIENT.sky},
	ground = {value = DEFAULT_AMBIENT.ground},
}
DEFAULT_FOG :: Fog {
	albedo = {value = {1, 1, 1}},
}

// Fog_Settings are a frame's fog, from the Fog settings. A density of 0 is no fog.
Fog_Settings :: struct {
	density:        f32,
	albedo:         [3]f32,
	base_height:    f32,
	height_falloff: f32,
	anisotropy:     f32,
}

// Frame_Settings are a frame's settings, which resolve_settings takes from the volumes at the camera. A game can
// resolve them, change them and give them to the frame in Frame_Desc.settings.
Frame_Settings :: struct {
	post:              Post_Settings,
	ambient_occlusion: Ao_Settings,
	gi:                Gi_Settings,
	fog:               Fog_Settings,
	// The world pass clears the scene to this, which is not pre-exposed.
	background:        [3]f32,
	ambient:           Ambient,
}

register_settings_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Anti_Aliasing, ANTI_ALIASING_ID)
	ecs.register_component(r, Exposure, EXPOSURE_ID)
	ecs.register_component(r, Tone_Mapping, TONE_MAPPING_ID)
	ecs.register_component(r, Bloom, BLOOM_ID)
	ecs.register_component(r, Ambient_Occlusion, AMBIENT_OCCLUSION_ID)
	ecs.register_component(r, Global_Illumination, GLOBAL_ILLUMINATION_ID)
	ecs.register_component(r, Environment, ENVIRONMENT_ID)
	ecs.register_component(r, Fog, FOG_ID)
}

// resolve_settings takes the frame's settings from the volumes at a position, usually the camera's, leaving out the
// hidden entities, as Frame_Desc.hidden gives them.
resolve_settings :: proc(r: ^Renderer, w: ^ecs.World, position: ecs.World_Position, hidden: []u32 = nil) -> Frame_Settings {
	inf := volume.gather(&r.volumes, w, position, hidden)
	aa, _ := volume.blend(w, &inf, Anti_Aliasing, Anti_Aliasing{})
	exposure, _ := volume.blend(w, &inf, Exposure, DEFAULT_EXPOSURE)
	tone, _ := volume.blend(w, &inf, Tone_Mapping, DEFAULT_TONE_MAPPING)
	bloom, _ := volume.blend(w, &inf, Bloom, DEFAULT_BLOOM)
	ao, _ := volume.blend(w, &inf, Ambient_Occlusion, DEFAULT_AMBIENT_OCCLUSION)
	gi, _ := volume.blend(w, &inf, Global_Illumination, Global_Illumination{})
	env, _ := volume.blend(w, &inf, Environment, DEFAULT_ENVIRONMENT)
	fog, _ := volume.blend(w, &inf, Fog, DEFAULT_FOG)
	return {
		post = {
			no_temporal_aa = aa.off.value,
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
		background = env.background.value,
		ambient = {sky = env.sky.value, ground = env.ground.value},
	}
}
