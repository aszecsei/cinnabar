package render

import "core:testing"

@(test)
quality_only_turns_features_off :: proc(t: ^testing.T) {
	q := preset_quality(.Ultra, {ray_query = true})
	settings: Frame_Settings
	apply_quality(&settings, q)
	testing.expect(t, !settings.ambient_occlusion.off && !settings.gi.off && !settings.post.no_aa)
	testing.expect_value(t, settings.shadows.level, Quality_Level.Ultra)
	testing.expect(t, settings.shadows.ray_traced)
	testing.expect_value(t, settings.fog.level, Quality_Level.Ultra)
	q.aa = .Smaa
	apply_quality(&settings, q)
	testing.expect_value(t, settings.post.aa, Aa_Technique.Smaa)

	// A volume that turned a feature off keeps it off at every quality.
	settings = {}
	settings.ambient_occlusion.off, settings.gi.off, settings.post.no_aa = true, true, true
	apply_quality(&settings, q)
	testing.expect(t, settings.ambient_occlusion.off && settings.gi.off && settings.post.no_aa)

	// The quality turns them off too.
	q.ao.technique, q.gi.technique, q.aa = .Off, .Off, .Off
	settings = {}
	apply_quality(&settings, q)
	testing.expect(t, settings.ambient_occlusion.off && settings.gi.off && settings.post.no_aa)
}

@(test)
quality_keeps_to_what_the_device_can_do :: proc(t: ^testing.T) {
	q := preset_quality(.Ultra, {ray_query = true})
	testing.expect(t, q.shadows.ray_traced)
	testing.expect(t, !clamp_quality(q, {}).shadows.ray_traced, "without Ray_Query, the shadows are maps")
	testing.expect_value(t, clamp_quality(q, {ray_query = true}), q)

	// A settings file or a script may give any number.
	bad := q
	bad.shadows.level = Quality_Level(200)
	bad.ao.technique = Ao_Technique(200)
	bad.aa = Aa_Technique(200)
	clamped := clamp_quality(bad, {})
	testing.expect_value(t, clamped.shadows.level, Quality_Level.High)
	testing.expect_value(t, clamped.ao.technique, Ao_Technique.Off)
	testing.expect_value(t, clamped.aa, Aa_Technique.Off)
}

@(test)
the_default_quality_follows_the_video_memory :: proc(t: ^testing.T) {
	gigabytes :: proc(n: u64) -> Caps {
		return {video_memory = n << 30}
	}
	testing.expect_value(t, quality_preset(default_quality(gigabytes(2)), gigabytes(2)), Quality_Preset.Low)
	testing.expect_value(t, quality_preset(default_quality(gigabytes(4)), gigabytes(4)), Quality_Preset.Medium)
	testing.expect_value(t, quality_preset(default_quality(gigabytes(8)), gigabytes(8)), Quality_Preset.High)
	testing.expect_value(t, quality_preset(default_quality(gigabytes(16)), gigabytes(16)), Quality_Preset.Ultra)
	// Unknown memory, as on an adapter that shares the CPU's, is High.
	testing.expect_value(t, quality_preset(default_quality({}), {}), Quality_Preset.High)
	// Traced shadows from High up, where the device has them.
	testing.expect(t, !default_quality({ray_query = true, video_memory = 3 << 30}).shadows.ray_traced)
	testing.expect(t, default_quality({ray_query = true}).shadows.ray_traced)
}

@(test)
a_quality_that_differs_from_every_preset_is_custom :: proc(t: ^testing.T) {
	caps := Caps{ray_query = true}
	for preset in Quality_Preset.Low ..= Quality_Preset.Ultra {
		testing.expect_value(t, quality_preset(preset_quality(preset, caps), caps), preset)
	}
	q := preset_quality(.High, caps)
	q.ao.level = .Low
	testing.expect_value(t, quality_preset(q, caps), Quality_Preset.Custom)
}
