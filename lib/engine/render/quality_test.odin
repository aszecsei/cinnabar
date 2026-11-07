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
	testing.expect_value(t, settings.gi.technique, Gi_Technique.Split_Cascades)
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

// Low takes the reflection probes, Medium the screen-space reflections, and High and Ultra the traced reflections where
// the device has ray queries, and the screen-space reflections where it does not, at their levels.
@(test)
low_takes_the_probes_medium_the_screen_and_high_the_traced_reflections :: proc(t: ^testing.T) {
	for caps in ([]Caps{{}, {ray_query = true}}) {
		for preset in Quality_Preset.Low ..= Quality_Preset.Ultra {
			q := preset_quality(preset, caps)
			technique := Reflection_Technique.Screen
			switch {
			case preset == .Low:
				technique = .Probes
			case preset >= .High && caps.ray_query:
				technique = .Ray_Traced
			}
			testing.expect_value(t, q.reflections, Reflection_Quality{technique, Quality_Level(u8(preset))})
			testing.expect_value(t, clamp_quality(q, caps).reflections, q.reflections)
			testing.expect_value(t, quality_preset(q, caps), preset)
			settings: Frame_Settings
			apply_quality(&settings, q)
			testing.expect(t, !settings.reflections.off)
			testing.expect_value(t, settings.reflections.level, q.reflections.level)
			testing.expect_value(t, settings.reflections.technique, technique)
		}
	}
	testing.expect_value(t, Quality{}.reflections.technique, Reflection_Technique.Off)
	settings: Frame_Settings
	apply_quality(&settings, Quality{})
	testing.expect(t, settings.reflections.off)
	// Both run at any level, on any device.
	for technique in ([]Reflection_Technique{.Probes, .Screen}) {
		q := preset_quality(.Ultra, {})
		q.reflections.technique = technique
		testing.expect_value(t, clamp_quality(q, {}).reflections, Reflection_Quality{technique, .Ultra})
	}
	// The traced reflections run at any level with ray queries, and are the screen-space reflections without.
	for level in Quality_Level {
		q := preset_quality(.Ultra, {})
		q.reflections = {.Ray_Traced, level}
		testing.expect_value(t, clamp_quality(q, {ray_query = true}).reflections, q.reflections)
		testing.expect_value(t, clamp_quality(q, {}).reflections, Reflection_Quality{.Screen, level})
	}
}

// The screen-space reflections' levels go from half resolution and one short ray to full resolution and two long ones,
// and take rougher surfaces at each.
@(test)
the_screen_reflections_levels_grow :: proc(t: ^testing.T) {
	for level in Quality_Level {
		p := REFLECTION_PARAMS[.Screen][level]
		testing.expect_value(t, p.stride, level <= .Medium ? [2]u32{2, 2} : [2]u32{1, 1})
		testing.expect(t, p.rays >= 1 && p.rays <= 2 && p.steps > 0 && p.cutoff > 0 && p.cutoff <= 1)
		if level > .Low {
			before := REFLECTION_PARAMS[.Screen][Quality_Level(u8(level) - 1)]
			testing.expectf(t, p.steps > before.steps && p.cutoff > before.cutoff, "%v takes no more than %v", level, Quality_Level(u8(level) - 1))
		}
	}
}

// The traced reflections' levels trace more pixels' rays, further, and take rougher surfaces at each.
@(test)
the_traced_reflections_levels_grow :: proc(t: ^testing.T) {
	strides := [Quality_Level][2]u32 {
		.Low    = {2, 2},
		.Medium = {2, 2},
		.High   = {2, 1},
		.Ultra  = {1, 1},
	}
	for level in Quality_Level {
		p := REFLECTION_PARAMS[.Ray_Traced][level]
		testing.expect_value(t, p.stride, strides[level])
		testing.expect(t, p.rays == 1 && p.cutoff > 0 && p.cutoff <= 1 && p.distance > 0)
		if level > .Low {
			before := REFLECTION_PARAMS[.Ray_Traced][Quality_Level(u8(level) - 1)]
			testing.expectf(t, p.distance > before.distance && p.cutoff > before.cutoff, "%v takes no more than %v", level, Quality_Level(u8(level) - 1))
		}
	}
}

// A frame whose every pixel's ray would not fit one hit shading batch traces one pixel of a larger block.
@(test)
the_traced_reflections_stride_fits_a_batch :: proc(t: ^testing.T) {
	testing.expect_value(t, reflection_stride({2560, 1440}, {1, 1}), [2]u32{1, 1})
	testing.expect_value(t, reflection_stride({3840, 2160}, {1, 1}), [2]u32{2, 1})
	testing.expect_value(t, reflection_stride({3840, 2160}, {2, 1}), [2]u32{2, 1})
	testing.expect_value(t, reflection_stride({7680, 4320}, {1, 1}), [2]u32{4, 2})
	testing.expect_value(t, reflection_stride({15360, 8640}, {1, 1}), [2]u32{8, 4})
	for size in ([][2]u32{{1, 1}, {7680, 4320}, {65535, 65535}}) {
		s := reflection_stride(size, {1, 1})
		trace := (size + s - 1) / s
		testing.expect(t, trace.x * trace.y <= MAX_HIT_RAYS)
	}
}

@(test)
the_virtual_shadow_map_takes_every_level_but_low :: proc(t: ^testing.T) {
	testing.expect(t, !preset_quality(.Low, {}).shadows.virtual, "the cascades stay for Low")
	for preset in Quality_Preset.Medium ..= Quality_Preset.Ultra {
		q := preset_quality(preset, {})
		testing.expect(t, q.shadows.virtual)
		testing.expect_value(t, quality_preset(q, {}), preset)
		// With the device's traced shadows, the option stays, and the traced shadows take the light first.
		testing.expect(t, preset_quality(preset, {ray_query = true}).shadows.virtual)
	}
	// Low has no virtual shadow map to turn on.
	custom := preset_quality(.Low, {})
	custom.shadows.virtual = true
	testing.expect(t, !clamp_quality(custom, {}).shadows.virtual)
	// The zero quality is the cheapest frame.
	testing.expect(t, !Quality{}.shadows.virtual)
	settings: Frame_Settings
	apply_quality(&settings, preset_quality(.High, {}))
	testing.expect(t, settings.shadows.virtual)
}

@(test)
quality_keeps_to_what_the_device_can_do :: proc(t: ^testing.T) {
	q := preset_quality(.Ultra, {ray_query = true})
	testing.expect(t, q.shadows.ray_traced)
	testing.expect(t, !clamp_quality(q, {}).shadows.ray_traced, "without Ray_Query, the shadows are maps")
	// Without Ray_Query, the world probes are the screen-space cascades alone.
	testing.expect_value(t, q.gi.technique, Gi_Technique.Split_Cascades)
	testing.expect_value(t, clamp_quality(q, {}).gi.technique, Gi_Technique.Screen_Cascades)
	testing.expect_value(t, clamp_quality(q, {}).reflections.technique, Reflection_Technique.Screen)
	testing.expect_value(t, clamp_quality(q, {ray_query = true}), q)
	// The voxel cones need no ray queries, and no preset chooses them.
	voxels := q
	voxels.gi.technique = .Voxel_Cones
	testing.expect_value(t, clamp_quality(voxels, {}).gi.technique, Gi_Technique.Voxel_Cones)
	testing.expect_value(t, clamp_quality(voxels, {ray_query = true}).gi.technique, Gi_Technique.Voxel_Cones)
	for preset in Quality_Preset {
		testing.expect(t, preset_quality(preset, {}).gi.technique != .Voxel_Cones)
		testing.expect(t, preset_quality(preset, {ray_query = true}).gi.technique != .Voxel_Cones)
	}

	// A settings file or a script may give any number.
	bad := q
	bad.shadows.level = Quality_Level(200)
	bad.ao.technique = Ao_Technique(200)
	bad.gi.technique = Gi_Technique(200)
	bad.reflections = {Reflection_Technique(200), Quality_Level(200)}
	bad.aa = Aa_Technique(200)
	bad.render_scale = 0.1
	clamped := clamp_quality(bad, {})
	testing.expect_value(t, clamped.render_scale, MIN_RENDER_SCALE)
	// 0 is full resolution, as is anything that is not a number.
	bad.render_scale = 0
	testing.expect_value(t, clamp_quality(bad, {}).render_scale, 1)
	nan := f32(0)
	bad.render_scale = nan / nan
	testing.expect_value(t, clamp_quality(bad, {}).render_scale, 1)
	// The level of detail's error is a number of pixels within its range, and 1 without one.
	bad.lod_error = 100
	testing.expect_value(t, clamp_quality(bad, {}).lod_error, MAX_LOD_ERROR)
	bad.lod_error = nan / nan
	testing.expect_value(t, clamp_quality(bad, {}).lod_error, 1)
	testing.expect_value(t, preset_quality(.Ultra, {}).lod_error, LOD_ERRORS[.Ultra])
	testing.expect_value(t, clamped.shadows.level, Quality_Level.High)
	testing.expect_value(t, clamped.ao.technique, Ao_Technique.Off)
	testing.expect_value(t, clamped.gi.technique, Gi_Technique.Off)
	testing.expect_value(t, clamped.reflections, Reflection_Quality{.Off, .High})
	testing.expect_value(t, clamped.aa, Aa_Technique.Off)

	// An upscaler that the device does not run gives temporal AA, which upscales too.
	q.aa = .Fsr
	testing.expect_value(t, clamp_quality(q, {}).aa, Aa_Technique.Taa)
	testing.expect_value(t, clamp_quality(q, {upscalers = {.Fsr}}).aa, Aa_Technique.Fsr)
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
	// Traced shadows, the world probes and the traced reflections from High up, where the device has them.
	testing.expect(t, !default_quality({ray_query = true, video_memory = 3 << 30}).shadows.ray_traced)
	testing.expect(t, default_quality({ray_query = true}).shadows.ray_traced)
	testing.expect_value(t, default_quality({ray_query = true, video_memory = 3 << 30}).gi.technique, Gi_Technique.Screen_Cascades)
	testing.expect_value(t, default_quality({ray_query = true}).gi.technique, Gi_Technique.Split_Cascades)
	testing.expect_value(t, default_quality({}).gi.technique, Gi_Technique.Screen_Cascades)
	testing.expect_value(t, default_quality({ray_query = true}).reflections.technique, Reflection_Technique.Ray_Traced)
	testing.expect_value(t, default_quality({}).reflections.technique, Reflection_Technique.Screen)
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

@(test)
the_render_size_is_the_frames_at_the_render_scale :: proc(t: ^testing.T) {
	testing.expect_value(t, render_size({1280, 720}, 1), [2]u32{1280, 720})
	testing.expect_value(t, render_size({1280, 720}, 0.5), [2]u32{640, 360})
	testing.expect_value(t, render_size({1280, 720}, 0.67), [2]u32{858, 482})
	testing.expect_value(t, render_size({1, 1}, 0.5), [2]u32{1, 1})
}
