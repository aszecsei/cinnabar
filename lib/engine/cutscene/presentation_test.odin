package cutscene

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"
import "cinnabar:engine/ui"

@(private = "file")
SHOW_GUID :: format.Guid {
	0  = 0x75,
	15 = 1,
}

@(private = "file")
SECOND :: format.CUTSCENE_TICKS_PER_SECOND

@(private = "file")
FRAME :: time.Second / 60

// The overlay's document, which the tests show with its blob as the cook writes it. Its text needs no font: the tests
// read what the overlay sets, not what draws.
@(private = "file")
OVERLAY_TEXT :: #load("../content/ui/cutscene_overlay.ui", string)

// The window that the overlay lays out in: 16:9, narrower than the letterbox's 2.39.
@(private = "file")
WINDOW :: [2]f32{1920, 1080}

@(private = "file")
Present_Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	assets:    asset.Assets,
	ui:        ui.State,
	cutscenes: State,
	dir:       string,
}

@(private = "file")
present_setup :: proc(t: ^testing.T) -> ^Present_Fixture {
	f := new(Present_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = context.allocator,
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		file_size = core.file_size,
		time_seconds = proc() -> f64 {return 0},
		jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		},
		jobs_wait = proc(counter: ^jobs.Counter) {},
		level_generation = proc() -> u64 {return 0},
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	render.register_components(&f.world.registry)
	ui.register_components(&f.world.registry)
	temp, err := os.make_directory_temp("", "cutscene_presentation_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	ui.init(&f.ui, &f.platform, &f.assets)
	document, problems, parsed := format.ui_parse(OVERLAY_TEXT)
	testing.expectf(t, parsed, "the overlay's document: %v", problems)
	guid, _ := format.meta_guid(OVERLAY_DOCUMENT_META)
	blob := format.ui_write({guid = guid, key = 1, document = document}, context.temp_allocator)
	testing.expect(t, asset.set_live(&f.assets, guid, blob))
	init(&f.cutscenes, &f.world, &f.assets, interface = &f.ui)
	register(&f.cutscenes, &f.world)
	return f
}

@(private = "file")
present_teardown :: proc(f: ^Present_Fixture) {
	destroy(&f.cutscenes, &f.world)
	ui.destroy(&f.ui)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	os.remove_all(f.dir)
	delete(f.dir)
	free(f)
}

// frame runs a frame as game_update and render_frame do: the players' update and the UI's documents, the ticks of a
// 60th of a second of the world's time at a scale (none at 0, as while the game is paused), the Late stage, and the
// overlay.
@(private = "file")
frame :: proc(f: ^Present_Fixture, scale: f64 = 1) {
	update(&f.cutscenes, {world = &f.world, dt = FRAME})
	ui.sync(&f.ui, &f.world)
	if scale > 0 {
		it := ecs.begin_ticks(&f.world, time.Duration(f64(FRAME) * scale))
		for ecs.next_tick(&it) {
			ecs.run_tick_systems(&it, f)
			ecs.update_transforms(&f.world)
		}
	}
	ecs.run_stage(&f.world, .Late, ecs.tick_length(&f.world), f)
	present(&f.cutscenes, &f.world, WINDOW)
	end_frame(&f.cutscenes)
	free_all(f.platform.frame_allocator)
}

@(private = "file")
frames :: proc(f: ^Present_Fixture, n: int, scale: f64 = 1) {
	for _ in 0 ..< n {
		frame(f, scale)
	}
}

// overlay is the overlay's document.
@(private = "file")
overlay :: proc(f: ^Present_Fixture) -> ^ui.Document {
	opened, open := f.cutscenes.overlay.opened.?
	if !open {
		return nil
	}
	return ui.owned_document(&f.ui, opened.index)
}

// shown is whether the overlay's document shows.
@(private = "file")
shown :: proc(f: ^Present_Fixture) -> bool {
	d := overlay(f)
	return d != nil && d.visible
}

// set_on is what the overlay set on an element's attribute, as a type.
@(private = "file")
set_on :: proc(f: ^Present_Fixture, id: string, attr: format.Ui_Attr, $T: typeid) -> T {
	d := overlay(f)
	if d == nil {
		return {}
	}
	value, _ := ui.override_of(d, id, attr)
	return value.(T) or_else {}
}

@(private = "file")
opacity :: proc(f: ^Present_Fixture) -> f32 {
	return set_on(f, "fade", .Opacity, f32)
}

@(private = "file")
fade_color :: proc(f: ^Present_Fixture) -> format.Ui_Color {
	return set_on(f, "fade", .Fill, format.Ui_Paint).colors[0]
}

@(private = "file")
bar :: proc(f: ^Present_Fixture, id: string, attr: format.Ui_Attr) -> f32 {
	return set_on(f, id, attr, format.Ui_Length).value
}

@(private = "file")
text :: proc(f: ^Present_Fixture, id: string) -> string {
	d := overlay(f)
	if d == nil {
		return ""
	}
	value, _ := ui.text_of(&f.ui, d, id)
	return value
}

@(private = "file")
near :: proc(t: ^testing.T, got, want: f32, what: string, tolerance: f32 = 0.002, loc := #caller_location) {
	testing.expectf(t, abs(got - want) <= tolerance, "%s: %v, not %v", what, got, want, loc = loc)
}

@(private = "file")
linear_keys :: proc(from, to: f32, duration: i32) -> []format.Cutscene_Key {
	keys := make([]format.Cutscene_Key, 2, context.temp_allocator)
	keys[0] = {
		time   = 0,
		value  = from,
		interp = .Linear,
	}
	keys[1] = {
		time   = duration,
		value  = to,
		interp = .Linear,
	}
	return keys
}

@(private = "file")
channel_of :: proc(name: string, keys: []format.Cutscene_Key) -> []format.Cutscene_Channel_Contents {
	channels := make([]format.Cutscene_Channel_Contents, 1, context.temp_allocator)
	channels[0] = {
		name = name,
		keys = keys,
	}
	return channels
}

@(private = "file")
subtitle :: proc(
	id: u32,
	start, end: i32,
	line: string,
	speaker := "",
) -> format.Cutscene_Section_Contents {
	return {
		id = id,
		start = start,
		end = end,
		weight = 1,
		presentation = {kind = .Subtitle, speaker = speaker, text = line},
	}
}

// Show is what a test's cutscene varies: what its presentation track keeps when finished, its fades, its skip's fade
// and color, and whether its bars follow the camera.
@(private = "file")
Show :: struct {
	finish:     format.Cutscene_Finish,
	fades:      []format.Cutscene_Section_Contents,
	skip_fade:  i32,
	skip_color: [3]u8,
	follow:     bool,
}

// write_show writes a 4 s cutscene with a presentation track: its fades, bars at 2.39 whose amount rises from 0 to 1
// over the first second, and four subtitles, A from 1 s, B from 1.5 s (Fox's), C from 2 s and D from 2.5 s, to 3 s.
@(private = "file")
write_show :: proc(t: ^testing.T, f: ^Present_Fixture, c: Show) {
	sections := make([dynamic]format.Cutscene_Section_Contents, context.temp_allocator)
	append(&sections, ..c.fades)
	append(
		&sections,
		format.Cutscene_Section_Contents {
			id = 10,
			start = 0,
			end = 4 * SECOND,
			weight = 1,
			presentation = {kind = .Letterbox},
			channels = channel_of(format.CUTSCENE_LETTERBOX_AMOUNT, linear_keys(0, 1, SECOND)),
		},
		subtitle(11, SECOND, 3 * SECOND, "A"),
		subtitle(12, 3 * SECOND / 2, 3 * SECOND, "B", "Fox"),
		subtitle(13, 2 * SECOND, 3 * SECOND, "C"),
		subtitle(14, 5 * SECOND / 2, 3 * SECOND, "D"),
	)
	tracks := make([]format.Cutscene_Track_Contents, 1, context.temp_allocator)
	tracks[0] = {
		id       = 1,
		kind     = .Presentation,
		name     = "Presentation",
		binding  = format.CUTSCENE_NONE,
		finish   = c.finish,
		flags    = {.Follow_Camera} if c.follow else {},
		sections = sections[:],
	}
	blob := format.cutscene_write(
		{
			guid = SHOW_GUID,
			key = 1,
			length = 4 * SECOND,
			rate = 30,
			range_end = 4 * SECOND,
			tracks = tracks,
			source_path = "game/cutscenes/show.cutscene",
			skip_fade = c.skip_fade,
			skip_color = c.skip_color,
		},
		context.temp_allocator,
	)
	testing.expect(t, asset.set_live(&f.assets, SHOW_GUID, blob))
}

// fade_in is a black fade from opaque to clear over the first second.
@(private = "file")
fade_in :: proc() -> []format.Cutscene_Section_Contents {
	sections := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
	sections[0] = {
		id       = 1,
		start    = 0,
		end      = SECOND,
		weight   = 1,
		channels = channel_of(format.CUTSCENE_FADE_OPACITY, linear_keys(1, 0, SECOND)),
	}
	return sections
}

// fade_out is a fade to a color over the last second.
@(private = "file")
fade_out :: proc(color: [3]u8 = {}) -> []format.Cutscene_Section_Contents {
	sections := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
	sections[0] = {
		id           = 2,
		start        = 3 * SECOND,
		end          = 4 * SECOND,
		weight       = 1,
		presentation = {kind = .Fade, color = color},
		channels     = channel_of(format.CUTSCENE_FADE_OPACITY, linear_keys(0, 1, SECOND)),
	}
	return sections
}

// start plays the test's cutscene, and runs the frame that loads it and its first.
@(private = "file")
start :: proc(t: ^testing.T, f: ^Present_Fixture) -> Player_Handle {
	h, ok := play(&f.cutscenes, &f.world, {cutscene = SHOW_GUID})
	testing.expect(t, ok)
	frame(f)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Playing)
	return h
}

// look pauses a player at a time and shows the frame there.
@(private = "file")
look :: proc(f: ^Present_Fixture, h: Player_Handle, at: i32) {
	pause(&f.cutscenes, &f.world, h)
	set_time(&f.cutscenes, &f.world, h, at)
	frame(f, 0)
}

@(test)
fades_bars_and_subtitles_show_at_each_time :: proc(t: ^testing.T) {
	f := present_setup(t)
	defer present_teardown(f)
	write_show(t, f, {fades = fade_in()})
	testing.expect(t, !shown(f), "the overlay hides with no cutscene")
	h := start(t, f)
	testing.expect(t, shown(f))

	// Half way through the fade in, and the bars half way in: the bars crop 16:9 to 2.39 by half.
	look(f, h, SECOND / 2)
	near(t, opacity(f), 0.5, "the fade")
	testing.expect_value(t, fade_color(f), format.Ui_Color{0, 0, 0, 255})
	full := (1 - (WINDOW.x / WINDOW.y) / 2.39) / 2 * 100
	near(t, bar(f, "bar_top", .Height), full / 2, "the top bar")
	near(t, bar(f, "bar_bottom", .Height), full / 2, "the bottom bar")
	near(t, bar(f, "bar_left", .Width), 0, "a side bar")
	testing.expect(t, !set_on(f, "subtitle_1", .Visible, bool), "no subtitle yet")

	// The fade is over, the bars are in, and four lines cover the time: the newest three show, the newest at the bottom.
	look(f, h, 11 * SECOND / 4)
	near(t, opacity(f), 0, "the fade")
	near(t, bar(f, "bar_top", .Height), full, "the top bar")
	for id in ([?]string{"subtitle_1", "subtitle_2", "subtitle_3"}) {
		testing.expect(t, set_on(f, id, .Visible, bool), id)
	}
	testing.expect_value(t, text(f, "line_1"), "B")
	testing.expect_value(t, text(f, "speaker_1"), "Fox")
	testing.expect(t, set_on(f, "speaker_1", .Visible, bool), "a speaker shows")
	testing.expect_value(t, text(f, "line_2"), "C")
	testing.expect(t, !set_on(f, "speaker_2", .Visible, bool), "a line without a speaker hides it")
	testing.expect_value(t, text(f, "line_3"), "D")
	near(t, set_on(f, "line_1", .Size, f32), 30, "the line's own size")
	near(t, set_on(f, "subtitle_back_1", .Opacity, f32), 0.5, "the back's opacity")

	// A seek backwards shows the line under the new time, and only it.
	look(f, h, 5 * SECOND / 4)
	testing.expect_value(t, text(f, "line_1"), "A")
	testing.expect(t, set_on(f, "subtitle_1", .Visible, bool))
	testing.expect(t, !set_on(f, "subtitle_2", .Visible, bool))

	// The player's settings scale the text and the backs.
	set_subtitles(&f.cutscenes, {enabled = true, size = 1.5, background = 0.25})
	frame(f, 0)
	near(t, set_on(f, "line_1", .Size, f32), 45, "the scaled size")
	near(t, set_on(f, "speaker_1", .Size, f32), 33, "the scaled speaker")
	near(t, set_on(f, "subtitle_back_1", .Opacity, f32), 0.25, "the back's opacity")

	// After the cutscene, the overlay hides.
	stop(&f.cutscenes, &f.world, h)
	frame(f)
	testing.expect(t, !shown(f))
}

@(test)
with_subtitles_off_fades_and_bars_still_show :: proc(t: ^testing.T) {
	f := present_setup(t)
	defer present_teardown(f)
	write_show(t, f, {fades = fade_in()})
	set_subtitles(&f.cutscenes, {enabled = false, size = 1, background = 0.5})
	h := start(t, f)
	look(f, h, SECOND / 2)
	near(t, opacity(f), 0.5, "the fade")
	look(f, h, 11 * SECOND / 4)
	testing.expect(t, bar(f, "bar_top", .Height) > 0, "the bars show")
	for id in ([?]string{"subtitle_1", "subtitle_2", "subtitle_3"}) {
		testing.expect(t, !set_on(f, id, .Visible, bool), id)
	}
}

@(test)
a_fade_holds_in_a_pause_and_moves_with_the_time_scale :: proc(t: ^testing.T) {
	f := present_setup(t)
	defer present_teardown(f)
	write_show(t, f, {fades = fade_in()})
	h := start(t, f)
	frames(f, 29)
	// 30 frames of a 60th of a second: the fade is half way, give or take the frame between ticks.
	half := opacity(f)
	near(t, half, 0.5, "after half a second", 0.04)

	// The game pauses: no tick runs, and the fade holds where the cutscene is.
	frames(f, 30, 0)
	near(t, opacity(f), half, "while paused", 0.0001)
	// A player that is paused holds it too, though the world runs.
	pause(&f.cutscenes, &f.world, h)
	frames(f, 30)
	near(t, opacity(f), half, "while the player is paused", 0.0001)
	resume(&f.cutscenes, &f.world, h)

	// At half speed, a quarter of a second of the cutscene's time passes in half a second.
	frames(f, 30, 0.5)
	near(t, opacity(f), half - 0.25, "at half speed", 0.04)
}

@(test)
a_skip_fades_to_its_color_gives_the_world_back_and_fades_back :: proc(t: ^testing.T) {
	f := present_setup(t)
	defer present_teardown(f)
	// The skip fades for half a second, to red.
	write_show(t, f, {fades = fade_in(), skip_fade = SECOND / 2, skip_color = {255, 0, 0}})
	h := start(t, f)
	look(f, h, 11 * SECOND / 4)
	resume(&f.cutscenes, &f.world, h)
	frame(f)
	testing.expect(t, set_on(f, "subtitle_1", .Visible, bool))
	testing.expect_value(t, skip(&f.cutscenes, &f.world, h), Command_Result.Done)
	frames(f, 15)
	// A quarter of a second in, the red covers half the frame, and the subtitles hide.
	near(t, opacity(f), 0.5, "the skip's fade", 0.04)
	testing.expect_value(t, fade_color(f), format.Ui_Color{255, 0, 0, 255})
	testing.expect(t, !set_on(f, "subtitle_1", .Visible, bool), "subtitles hide in a skip")
	testing.expect(t, bar(f, "bar_top", .Height) > 0, "the bars stay")
	// Thirty frames of a 60th of a second fall a little short of the half second, so the jump is in the 31st.
	frames(f, 16)
	// The world is given back behind the red, which then fades back over gameplay, without bars.
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	testing.expect(t, shown(f))
	near(t, opacity(f), 1, "opaque as the world comes back", 0.04)
	near(t, bar(f, "bar_top", .Height), 0, "no bars over gameplay")
	frames(f, 15)
	near(t, opacity(f), 0.5, "half way back", 0.04)
	frames(f, 16)
	testing.expect(t, !shown(f), "the fade back is over")
}

@(test)
a_stop_in_a_skip_fades_back_from_where_the_skip_was :: proc(t: ^testing.T) {
	f := present_setup(t)
	defer present_teardown(f)
	write_show(t, f, {skip_fade = SECOND / 2})
	h := start(t, f)
	frames(f, 60)
	skip(&f.cutscenes, &f.world, h)
	frames(f, 15)
	stop(&f.cutscenes, &f.world, h)
	frame(f)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	near(t, opacity(f), 0.5, "from where the skip was", 0.05)
	frames(f, 31)
	testing.expect(t, !shown(f))
}

@(test)
a_kept_fade_outlives_its_cutscene_and_a_new_level_until_it_is_released :: proc(t: ^testing.T) {
	f := present_setup(t)
	defer present_teardown(f)
	write_show(t, f, {finish = .Keep, fades = fade_out({0, 0, 64})})
	h := start(t, f)
	frames(f, 260)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	testing.expect(t, shown(f), "the kept fade covers the frame")
	near(t, opacity(f), 1, "the kept fade")
	testing.expect_value(t, fade_color(f), format.Ui_Color{0, 0, 64, 255})
	// The game loads a level behind it.
	reset(&f.cutscenes, &f.world)
	frames(f, 10)
	testing.expect(t, shown(f), "a new level keeps it")
	release_fade(&f.cutscenes, time.Second / 2)
	frames(f, 15)
	near(t, opacity(f), 0.5, "half way back", 0.04)
	frames(f, 16)
	testing.expect(t, !shown(f))
}

@(test)
a_restored_fade_clears_and_a_kept_one_wins_over_a_skips_fade_back :: proc(t: ^testing.T) {
	f := present_setup(t)
	defer present_teardown(f)
	write_show(t, f, {fades = fade_out()})
	h := start(t, f)
	frames(f, 260)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	testing.expect(t, !shown(f), "a fade set to restore clears")

	// A skip to the end of a cutscene whose last fade keeps: the fade stays, and does not fade back.
	write_show(t, f, {finish = .Keep, fades = fade_out(), skip_fade = SECOND / 4})
	h = start(t, f)
	skip(&f.cutscenes, &f.world, h)
	frames(f, 20)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	frames(f, 30)
	testing.expect(t, shown(f), "the kept fade stays")
	near(t, opacity(f), 1, "the kept fade")
	_, kept := f.cutscenes.overlay.held.(Overlay_Kept)
	testing.expect(t, kept)
}

@(test)
bars_follow_the_camera_that_shows_and_stale_rows_are_not_read :: proc(t: ^testing.T) {
	f := present_setup(t)
	defer present_teardown(f)
	write_show(t, f, {follow = true})
	h := start(t, f)
	look(f, h, 11 * SECOND / 4)
	e, _ := player_evaluation(&f.cutscenes, h)
	// While gameplay shows, the bars take the sections' aspect.
	near(t, presentation_values(&f.cutscenes, &f.world, e).aspect, 2.39, "the sections' aspect")
	// A shot of a camera with a 4:3 sensor.
	camera := ecs.spawn(&f.world)
	lens := render.DEFAULT_CINEMATIC_CAMERA
	lens.sensor_width, lens.sensor_height = 24, 18
	ecs.add(&f.world, camera, lens)
	e.cut.shown = Cut_Shot {
		entity = camera,
	}
	v := presentation_values(&f.cutscenes, &f.world, e)
	near(t, v.aspect, 4.0 / 3, "the camera's aspect")
	present(&f.cutscenes, &f.world, WINDOW)
	side := (1 - (4.0 / 3) / (WINDOW.x / WINDOW.y)) / 2 * 100
	near(t, bar(f, "bar_left", .Width), side, "a narrower shot has side bars")
	near(t, bar(f, "bar_top", .Height), 0, "and no top bar")
	e.cut.shown = nil
	testing.expect_value(t, v.line_count, 3)
	// The blobs changed since the Late phase: the lines are not read until the next.
	e.presented.key += 1
	testing.expect_value(t, presentation_values(&f.cutscenes, &f.world, e).line_count, 0)
	frame(f, 0)
	testing.expect_value(t, presentation_values(&f.cutscenes, &f.world, e).line_count, 3)
}
