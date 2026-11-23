package cutscene

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:time"

import "cinnabar:core"
import boundary "cinnabar:core/audio"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/audio"
import "cinnabar:engine/ecs"

// These run on a fake backend whose voices move through their sounds as its clock moves, at their pitch, so a test can
// check where a voice is against where the cutscene's time puts it. The backend is a global, so the tests take turns.
@(private = "file")
lock: sync.Mutex

@(private = "file")
SECOND :: format.CUTSCENE_TICKS_PER_SECOND

// The cutscene's ticks in a world tick at 60 Hz, and the audio's frames in a frame of 1/60 s.
@(private = "file")
TICK :: SECOND / 60
@(private = "file")
FRAME :: boundary.SAMPLE_RATE / 60

@(private = "file")
SOUNDS_GUID :: format.Guid {
	0  = 0x75,
	15 = 1,
}

// A sound of 8 s, and another.
@(private = "file")
LINE :: format.Guid {
	0  = 0x75,
	15 = 2,
}
@(private = "file")
MUSIC :: format.Guid {
	0  = 0x75,
	15 = 3,
}
@(private = "file")
SOUND_SECONDS :: 8

@(private = "file")
Fake_Voice :: struct {
	sound:   boundary.Sound,
	// The frame of the sound at a time on the clock, and the rate from there.
	frame:   f64,
	at:      u64,
	params:  boundary.Voice_Params,
	flags:   boundary.Voice_Flags,
	// Where it started in its sound, and when on the clock.
	start:   u64,
	started: u64,
	length:  u64,
	playing: bool,
	// The fade that stopped it.
	fade:    f32,
}

@(private = "file")
Fake_Seek :: struct {
	voice: int,
	frame: u64,
	clock: u64,
}

@(private = "file")
Fake :: struct {
	clock:  u64,
	sounds: [dynamic]u64,
	voices: [dynamic]Fake_Voice,
	seeks:  [dynamic]Fake_Seek,
}

@(private = "file")
fake: Fake

@(private = "file")
fake_index :: proc "contextless" (voice: boundary.Voice) -> (int, bool) {
	i := int(voice.index) - 1
	return i, voice.generation == 1 && i >= 0 && i < len(fake.voices)
}

// fake_place is where a voice is at the clock: its frame at its anchor, moved at its pitch since.
@(private = "file")
fake_place :: proc "contextless" (v: Fake_Voice, clock: u64) -> f64 {
	if clock <= v.at {
		return v.frame
	}
	return v.frame + f64(clock - v.at) * f64(v.params.pitch)
}

@(private = "file")
fake_table :: proc() -> boundary.Audio_API {
	api: boundary.Audio_API
	api.info = proc "c" () -> boundary.Backend_Info {
		return {features = {.Seek, .Buses}}
	}
	api.update = proc "c" () {
	}
	api.sound_create = proc "c" (desc: ^boundary.Sound_Desc) -> boundary.Sound {
		context = runtime.default_context()
		append(&fake.sounds, desc.frames)
		return {u32(len(fake.sounds)), 1}
	}
	api.sound_destroy = proc "c" (sound: boundary.Sound) {
	}
	api.voice_play = proc "c" (desc: ^boundary.Voice_Desc) -> boundary.Voice {
		context = runtime.default_context()
		at := desc.clock if desc.clock != 0 else fake.clock
		voice := Fake_Voice {
			sound   = desc.sound,
			frame   = f64(desc.start),
			at      = at,
			params  = desc.params,
			flags   = desc.flags,
			start   = desc.start,
			started = at,
			length  = desc.length,
			playing = true,
		}
		append(&fake.voices, voice)
		return {u32(len(fake.voices)), 1}
	}
	api.voice_set = proc "c" (voice: boundary.Voice, params: ^boundary.Voice_Params) {
		if i, ok := fake_index(voice); ok {
			v := &fake.voices[i]
			v.frame = fake_place(v^, fake.clock)
			v.at = max(v.at, fake.clock)
			v.params = params^
		}
	}
	api.voice_stop = proc "c" (voice: boundary.Voice, fade: f32) {
		if i, ok := fake_index(voice); ok {
			fake.voices[i].playing = false
			fake.voices[i].fade = fade
		}
	}
	api.voice_playing = proc "c" (voice: boundary.Voice) -> b32 {
		i, ok := fake_index(voice)
		return b32(ok && fake.voices[i].playing)
	}
	api.voice_seek = proc "c" (voice: boundary.Voice, frame: u64, clock: u64) {
		context = runtime.default_context()
		if i, ok := fake_index(voice); ok {
			append(&fake.seeks, Fake_Seek{i, frame, clock})
			fake.voices[i].frame = f64(frame)
			fake.voices[i].at = clock if clock != 0 else fake.clock
		}
	}
	api.voice_position = proc "c" (voice: boundary.Voice, out: ^boundary.Voice_Position) -> b32 {
		i, ok := fake_index(voice)
		if !ok || !fake.voices[i].playing {
			return false
		}
		out^ = {fake_place(fake.voices[i], fake.clock), fake.clock}
		return true
	}
	api.bus_create = proc "c" (name: cstring, parent: boundary.Bus) -> boundary.Bus {
		return {}
	}
	api.bus_set_gain = proc "c" (bus: boundary.Bus, gain: f32) {
	}
	api.bus_set_effect = proc "c" (bus: boundary.Bus, slot: u32, effect: ^boundary.Effect) {
	}
	api.bus_set_duck = proc "c" (bus: boundary.Bus, target: boundary.Bus, duck: ^boundary.Duck) {
	}
	api.set_paused = proc "c" (paused: b32) {
	}
	api.clock = proc "c" () -> u64 {
		return fake.clock
	}
	api.stats = proc "c" (out: ^boundary.Stats) {
		out^ = {}
	}
	api.reset = proc "c" () -> i32 {
		return 0
	}
	api.shutdown = proc "c" () {
	}
	return api
}

@(private = "file")
Sound_Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	assets:    asset.Assets,
	audio:     audio.State,
	cutscenes: State,
	cache:     string,
	// The entities that the cutscene's bindings 1, 2, ... name, by override.
	entities:  [dynamic]ecs.Entity,
}

@(private = "file")
sound_setup :: proc(t: ^testing.T) -> ^Sound_Fixture {
	sync.lock(&lock)
	fake = {
		clock = 48000,
	}
	f := new(Sound_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		},
		jobs_wait = proc(counter: ^jobs.Counter) {},
		audio = fake_table(),
		file_read = core.file_read,
		file_read_range = core.file_read_range,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {return 0},
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
	audio.register_components(&f.world.registry)
	cache, err := os.make_directory_temp("", "cutscene_audio_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	audio.init(&f.audio, &f.platform, &f.assets)
	init(&f.cutscenes, &f.world, &f.assets, sounds = &f.audio)
	register(&f.cutscenes, &f.world)
	f.entities = make([dynamic]ecs.Entity)
	samples := make([]i16, SOUND_SECONDS * boundary.SAMPLE_RATE, context.temp_allocator)
	for guid in ([?]format.Guid{LINE, MUSIC}) {
		buffer: [32]u8
		blob := format.audio_write(
			{
				guid = guid,
				frames = u64(len(samples)),
				channels = 1,
				data = slice.to_bytes(samples),
				source_path = "game/audio/test.wav",
			},
			context.temp_allocator,
		)
		testing.expect(
			t,
			os.write_entire_file(
				fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(guid, &buffer)),
				blob,
			) ==
			nil,
		)
	}
	return f
}

@(private = "file")
sound_teardown :: proc(f: ^Sound_Fixture) {
	destroy(&f.cutscenes, &f.world)
	audio.destroy(&f.audio)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	os.remove_all(f.cache)
	delete(f.cache)
	virtual.arena_destroy(&f.frame)
	delete(f.entities)
	free(f)
	delete(fake.sounds)
	delete(fake.voices)
	delete(fake.seeks)
	fake = {}
	sync.unlock(&lock)
}

// sound_section is an audio section of a sound from a time to a time, in ticks, from an offset in it.
@(private = "file")
sound_section :: proc(
	id: u32,
	start, end: i32,
	sound := LINE,
	offset: i32 = 0,
	flags: format.Cutscene_Section_Flags = {},
	channels: []format.Cutscene_Channel_Contents = nil,
) -> format.Cutscene_Section_Contents {
	return {
		id = id,
		start = start,
		end = end,
		weight = 1,
		asset = sound,
		offset = offset,
		speed = 1,
		flags = flags,
		min_distance = 1,
		max_distance = 50,
		channels = channels,
	}
}

@(private = "file")
sound_track :: proc(
	id: u32,
	sections: ..format.Cutscene_Section_Contents,
	time_scale: format.Cutscene_Audio_Scale = .Follow,
	binding: u32 = format.CUTSCENE_NONE,
) -> format.Cutscene_Track_Contents {
	copied := make([]format.Cutscene_Section_Contents, len(sections), context.temp_allocator)
	copy(copied, sections)
	return {
		id = id,
		kind = .Audio,
		name = "Sound",
		binding = binding,
		gain = 1,
		time_scale = time_scale,
		sections = copied,
	}
}

@(private = "file")
sounds_blob :: proc(
	f: ^Sound_Fixture,
	tracks: []format.Cutscene_Track_Contents,
	length: i32,
	skip_fade: i32 = 0,
	range_end: i32 = 0,
	skip_ranges: []format.Cutscene_Skip_Range = nil,
) -> []byte {
	bindings := make([]format.Cutscene_Binding_Contents, len(f.entities), context.temp_allocator)
	for &b, i in bindings {
		b = {
			id       = u32(i + 1),
			kind     = .Possessed,
			name     = "A",
			parent   = format.CUTSCENE_NONE,
			asset    = SCENE_GUID_AUDIO,
			entity   = u64(i + 1),
			rotation = {0, 0, 0, 1},
			scale    = {1, 1, 1},
		}
	}
	return format.cutscene_write(
		{
			guid = SOUNDS_GUID,
			key = 1,
			length = length,
			rate = 30,
			range_end = range_end if range_end > 0 else length,
			bindings = bindings,
			tracks = tracks,
			skip_fade = skip_fade,
			skip = .Ranges if len(skip_ranges) > 0 else .Anywhere,
			skip_ranges = skip_ranges,
			source_path = "game/cutscenes/sounds.cutscene",
		},
		context.temp_allocator,
	)
}

@(private = "file")
SCENE_GUID_AUDIO :: format.Guid {
	0  = 0x75,
	15 = 9,
}

@(private = "file")
play_sounds :: proc(t: ^testing.T, f: ^Sound_Fixture, blob: []byte) -> Player_Handle {
	testing.expect(t, asset.set_live(&f.assets, SOUNDS_GUID, blob))
	overrides := make([]Binding_Override, len(f.entities), context.temp_allocator)
	for e, i in f.entities {
		overrides[i] = {Binding_Id(i + 1), e}
	}
	h, ok := play(&f.cutscenes, &f.world, {cutscene = SOUNDS_GUID, overrides = overrides})
	testing.expect(t, ok)
	update(&f.cutscenes, {world = &f.world})
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Playing)
	return h
}

// sound_frame runs a frame as the frame code does: ticks of the world, the Late stage, the players' update and the
// audio's, and then moves the audio's clock by a frame of real time. A frame at a time scale of 0.5 takes two frames of
// real time for each tick.
@(private = "file")
sound_frame :: proc(f: ^Sound_Fixture, ticks := 1, real: u64 = FRAME, dt := time.Second / 60) {
	clock := &f.world.clock
	for _ in 0 ..< ticks {
		it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
		for ecs.next_tick(&it) {
			ecs.run_tick_systems(&it, f)
			ecs.update_transforms(&f.world)
		}
	}
	ecs.run_stage(&f.world, .Late, ecs.tick_length(&f.world), f)
	update(&f.cutscenes, {world = &f.world, dt = dt})
	audio.update(&f.audio, &f.world, nil, true, dt)
	free_all(f.platform.frame_allocator)
	fake.clock += real
}

// voice_of is the fake voice that plays a sound, the last started, and false when none is playing.
@(private = "file")
voice_of :: proc(sound: format.Guid) -> (index: int, v: Fake_Voice, ok: bool) {
	want := u32(1 if sound == LINE else 2)
	#reverse for voice, i in fake.voices {
		if voice.playing && voice.sound.index == want {
			return i, voice, true
		}
	}
	return
}

// shown is the time in ticks that the frame shows, which a playing cutscene's sounds keep to.
@(private = "file")
shown :: proc(f: ^Sound_Fixture, h: Player_Handle) -> f64 {
	t, _ := player_time(&f.cutscenes, h)
	return f64(t) - f64(1 - f.world.clock.alpha) * TICK
}

// Playback that starts in the middle of a section starts its sound at the section's offset plus the time since its
// start, and then keeps it there.
@(test)
a_section_started_in_its_middle_plays_from_its_offset :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	tracks := [?]format.Cutscene_Track_Contents {
		sound_track(1, sound_section(1, 0, 4 * SECOND, offset = SECOND / 2)),
	}
	h := play_sounds(t, f, sounds_blob(f, tracks[:], 4 * SECOND))
	testing.expect_value(t, set_time(&f.cutscenes, &f.world, h, 2 * SECOND), Command_Result.Done)
	sound_frame(f)
	_, v, playing := voice_of(LINE)
	testing.expect(t, playing)
	expected := (0.5 + (shown(f, h) - 0) / SECOND) * boundary.SAMPLE_RATE
	testing.expectf(
		t,
		abs(v.frame - expected) < 1,
		"starts at frame %v, not %v",
		v.frame,
		expected,
	)
	testing.expect_value(t, v.at, fake.clock - FRAME)
	for _ in 0 ..< 30 {
		sound_frame(f)
	}
	_, v, playing = voice_of(LINE)
	testing.expect(t, playing)
	testing.expect_value(t, len(fake.seeks), 0)
	place := fake_place(v, fake.clock - FRAME)
	expected = (0.5 + shown(f, h) / SECOND) * boundary.SAMPLE_RATE
	testing.expectf(
		t,
		abs(place - expected) < AUDIO_DRIFT * boundary.SAMPLE_RATE,
		"at frame %v, not %v",
		place,
		expected,
	)
}

// At a time scale of 0.5, a section that follows the scale plays at half its pitch and keeps to the cutscene's time; a
// free one plays at its own rate, drifts ahead, and is not sought. When the scale is 1 again, the free section's next
// check brings it back within the limit.
@(test)
a_free_section_drifts_under_a_time_scale_and_resyncs_at_its_next_check :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	tracks := [?]format.Cutscene_Track_Contents {
		sound_track(1, sound_section(1, 0, 6 * SECOND, sound = LINE)),
		sound_track(2, sound_section(2, 0, 6 * SECOND, sound = MUSIC), time_scale = .Free),
	}
	h := play_sounds(t, f, sounds_blob(f, tracks[:], 6 * SECOND))
	set_rate(&f.cutscenes, 0.5)
	for _ in 0 ..< 60 {
		sound_frame(f, real = 2 * FRAME)
	}
	_, follow, _ := voice_of(LINE)
	music_index, free, _ := voice_of(MUSIC)
	testing.expect_value(t, follow.params.pitch, 0.5)
	testing.expect_value(t, free.params.pitch, 1)
	testing.expect_value(t, len(fake.seeks), 0)
	now := fake.clock - 2 * FRAME
	expected := shown(f, h) / SECOND * boundary.SAMPLE_RATE
	limit := AUDIO_DRIFT * boundary.SAMPLE_RATE
	testing.expectf(
		t,
		abs(fake_place(follow, now) - expected) < limit,
		"follow at %v",
		fake_place(follow, now),
	)
	testing.expectf(
		t,
		fake_place(free, now) - expected > limit,
		"free at %v",
		fake_place(free, now),
	)

	set_rate(&f.cutscenes, 1)
	sound_frame(f)
	testing.expect_value(t, len(fake.seeks), 1)
	testing.expect_value(t, fake.seeks[0].voice, music_index)
	_, free, _ = voice_of(MUSIC)
	at := fake.seeks[0].clock
	expected = shown(f, h) / SECOND * boundary.SAMPLE_RATE + f64(at - (fake.clock - FRAME))
	testing.expectf(
		t,
		abs(fake_place(free, at) - expected) < limit,
		"free at %v, not %v",
		fake_place(free, at),
		expected,
	)
}

// A seek backwards across two sections stops the later section's voice and starts the earlier one's at the new time;
// a seek inside a section that plays seeks its voice.
@(test)
a_seek_backwards_across_two_sections_plays_the_section_under_it :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	tracks := [?]format.Cutscene_Track_Contents {
		sound_track(
			1,
			sound_section(1, 0, 2 * SECOND, sound = LINE),
			sound_section(2, 2 * SECOND, 4 * SECOND, sound = MUSIC, offset = SECOND),
		),
	}
	h := play_sounds(t, f, sounds_blob(f, tracks[:], 4 * SECOND))
	set_time(&f.cutscenes, &f.world, h, 3 * SECOND)
	sound_frame(f)
	_, _, music := voice_of(MUSIC)
	_, _, line := voice_of(LINE)
	testing.expect(t, music && !line)

	set_time(&f.cutscenes, &f.world, h, SECOND / 2)
	sound_frame(f)
	_, _, music = voice_of(MUSIC)
	index, v, playing := voice_of(LINE)
	testing.expect(t, playing && !music)
	expected := shown(f, h) / SECOND * boundary.SAMPLE_RATE
	testing.expectf(t, abs(v.frame - expected) < 1, "line at %v, not %v", v.frame, expected)

	set_time(&f.cutscenes, &f.world, h, SECOND + SECOND / 2)
	sound_frame(f)
	testing.expect_value(t, len(fake.seeks), 1)
	seek := fake.seeks[0]
	testing.expect_value(t, seek.voice, index)
	expected = shown(f, h) / SECOND * boundary.SAMPLE_RATE + f64(seek.clock - (fake.clock - FRAME))
	testing.expectf(
		t,
		abs(f64(seek.frame) - expected) < 1,
		"sought to %v, not %v",
		seek.frame,
		expected,
	)
}

// A pitch curve, a weighted Bezier among its keys: playback sets the voice's pitch each frame, and the voice lands where
// a seek to the same time would start it, with no drift check that seeks.
@(test)
a_seek_lands_where_playback_reaches_under_a_pitch_curve :: proc(t: ^testing.T) {
	pitch := []format.Cutscene_Key {
		{time = 0, value = 1, interp = .Linear},
		{
			time = SECOND,
			value = 1.5,
			interp = .Bezier,
			flags = {.Weighted, .Broken},
			in_slope = 0,
			out_slope = 1,
			in_weight = 0.3,
			out_weight = 0.6,
		},
		{time = 2 * SECOND, value = 0.75, interp = .Auto},
		{time = 3 * SECOND, value = 1.25, interp = .Auto},
	}
	channels := []format.Cutscene_Channel_Contents{{name = "pitch", keys = pitch}}
	tracks := [?]format.Cutscene_Track_Contents {
		sound_track(1, sound_section(1, 0, 4 * SECOND, offset = SECOND / 4, channels = channels)),
	}
	// Playback to 2.6 s, which is in the middle of a segment.
	f := sound_setup(t)
	h := play_sounds(t, f, sounds_blob(f, tracks[:], 4 * SECOND))
	for _ in 0 ..< 156 {
		sound_frame(f)
	}
	_, v, playing := voice_of(LINE)
	testing.expect(t, playing)
	testing.expect_value(t, len(fake.seeks), 0)
	at := shown(f, h)
	played := fake_place(v, fake.clock - FRAME)
	sound_teardown(f)

	f = sound_setup(t)
	defer sound_teardown(f)
	h = play_sounds(t, f, sounds_blob(f, tracks[:], 4 * SECOND))
	// The seek's frame runs a tick, so it shows the time that playback showed.
	set_time(&f.cutscenes, &f.world, h, i32(at))
	sound_frame(f)
	_, v, playing = voice_of(LINE)
	testing.expect(t, playing)
	testing.expectf(t, abs(shown(f, h) - at) <= 1, "the seek shows %v, not %v", shown(f, h), at)
	testing.expectf(
		t,
		abs(v.frame - played) < 0.002 * boundary.SAMPLE_RATE,
		"a seek starts at frame %v, and playback reached %v",
		v.frame,
		played,
	)
}

// A skip fades out a section's voice over the skip's fade, and lets a section that plays through it go: it plays on past
// the cutscene's end, and stops at its section's end on the audio's clock, after its ease out.
@(test)
a_skip_fades_a_section_out_and_one_that_plays_through_it_plays_on :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	music := sound_section(2, 0, 5 * SECOND, sound = MUSIC, flags = {.Plays_Through_Skip})
	music.ease_out = SECOND
	tracks := [?]format.Cutscene_Track_Contents {
		sound_track(1, sound_section(1, 0, 4 * SECOND, sound = LINE)),
		sound_track(2, music),
	}
	h := play_sounds(
		t,
		f,
		sounds_blob(f, tracks[:], 6 * SECOND, skip_fade = SECOND / 2, range_end = 4 * SECOND),
	)
	for _ in 0 ..< 60 {
		sound_frame(f)
	}
	line_index, _, _ := voice_of(LINE)
	music_index, _, _ := voice_of(MUSIC)
	at, _ := player_time(&f.cutscenes, h)
	testing.expect_value(t, skip(&f.cutscenes, &f.world, h), Command_Result.Done)
	sound_frame(f, ticks = 0)
	line := fake.voices[line_index]
	testing.expect(t, !line.playing)
	testing.expectf(t, abs(line.fade - 0.5) < 0.02, "the line fades over %v s", line.fade)
	testing.expect(t, fake.voices[music_index].playing)

	// The fade out runs, and the skip ends the cutscene: the music plays on, and no section starts again.
	voices := len(fake.voices)
	for _ in 0 ..< 40 {
		sound_frame(f, ticks = 0)
	}
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	testing.expect_value(t, len(fake.voices), voices)
	testing.expect(t, fake.voices[music_index].playing)
	// It stops at the section's end less its ease out, 5 s - 1 s - the time of the skip, after the skip began.
	stop_at := f64(5 * SECOND - SECOND - at) / SECOND
	fake.clock += u64(stop_at * boundary.SAMPLE_RATE) - 41 * FRAME
	audio.update(&f.audio, &f.world, nil, true, 0)
	testing.expect(t, !fake.voices[music_index].playing)
	testing.expectf(
		t,
		abs(fake.voices[music_index].fade - 1) < 1e-6,
		"the music fades over %v s",
		fake.voices[music_index].fade,
	)
}

// A pause stops the voices, and play goes on from where they should be.
@(test)
a_pause_stops_the_voices_and_resume_plays_them_from_their_place :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	tracks := [?]format.Cutscene_Track_Contents{sound_track(1, sound_section(1, 0, 4 * SECOND))}
	h := play_sounds(t, f, sounds_blob(f, tracks[:], 4 * SECOND))
	for _ in 0 ..< 30 {
		sound_frame(f)
	}
	testing.expect_value(t, pause(&f.cutscenes, &f.world, h), Command_Result.Done)
	sound_frame(f)
	_, _, playing := voice_of(LINE)
	testing.expect(t, !playing)
	testing.expect_value(t, resume(&f.cutscenes, &f.world, h), Command_Result.Done)
	sound_frame(f)
	_, v, resumed := voice_of(LINE)
	testing.expect(t, resumed)
	expected := shown(f, h) / SECOND * boundary.SAMPLE_RATE
	testing.expectf(t, abs(v.frame - expected) < 1, "resumes at %v, not %v", v.frame, expected)
	testing.expect_value(t, stop(&f.cutscenes, &f.world, h), Command_Result.Done)
	sound_frame(f)
	_, _, playing = voice_of(LINE)
	testing.expect(t, !playing)
}

// A track with a binding plays at the binding's pose, with the section's distances.
@(test)
a_section_of_a_bound_track_plays_at_its_binding :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	ear := ecs.spawn(&f.world)
	ecs.add(&f.world, ear, ecs.TRANSFORM_IDENTITY)
	ecs.add(&f.world, ear, audio.Audio_Listener{})
	guard := ecs.spawn(&f.world)
	pose := ecs.TRANSFORM_IDENTITY
	pose.position = ecs.position_from_meters({0, 0, 5})
	ecs.add(&f.world, guard, pose)
	append(&f.entities, guard)
	section := sound_section(1, 0, 4 * SECOND)
	section.min_distance, section.max_distance = 2, 30
	tracks := [?]format.Cutscene_Track_Contents{sound_track(1, section, binding = 0)}
	play_sounds(t, f, sounds_blob(f, tracks[:], 4 * SECOND))
	sound_frame(f)
	sound_frame(f)
	_, v, playing := voice_of(LINE)
	testing.expect(t, playing)
	testing.expect(t, bool(v.params.spatial))
	testing.expectf(t, abs(v.params.position.z - 5) < 1e-3, "at %v", v.params.position)
	testing.expect_value(t, v.params.min_distance, 2)
	testing.expect_value(t, v.params.max_distance, 30)
}

// An evaluation that scrubs plays a grain of each section under the time after a seek, and no voice of its own; seeks
// closer together than SCRUB_INTERVAL play one.
@(test)
a_scrub_plays_a_grain_of_each_section_under_the_playhead :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	tracks := [?]format.Cutscene_Track_Contents {
		sound_track(1, sound_section(1, 0, 4 * SECOND, sound = LINE)),
		sound_track(2, sound_section(2, SECOND, 4 * SECOND, sound = MUSIC)),
	}
	data := sounds_blob(f, tracks[:], 4 * SECOND)
	aligned := make([]byte, len(data) + 16, context.temp_allocator)
	start := int(-uintptr(raw_data(aligned)) & 15)
	copy(aligned[start:], data)
	data = aligned[start:][:len(data)]
	blob, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	e: Evaluation
	init_evaluation(&e, &f.world, {}, data, blob)
	defer destroy_evaluation(&e, &f.world)
	set_audition(&e, &f.world, .Scrub)
	seek(&f.cutscenes, &e, &f.world, data, blob, 2 * SECOND)
	evaluate(&f.cutscenes, &e, &f.world, data, blob, .Late)
	testing.expect_value(t, len(fake.voices), 2)
	for v in fake.voices {
		testing.expect_value(t, v.flags, boundary.Voice_Flags{.Unpaused})
		testing.expect_value(t, v.length, u64(audio.SCRUB_GRAIN * boundary.SAMPLE_RATE))
	}
	testing.expect_value(t, fake.voices[0].frame, 2 * boundary.SAMPLE_RATE)
	testing.expect_value(t, fake.voices[1].frame, boundary.SAMPLE_RATE)
	// Too soon: no grain.
	fake.clock += SCRUB_INTERVAL / 2
	seek(&f.cutscenes, &e, &f.world, data, blob, SECOND / 2)
	evaluate(&f.cutscenes, &e, &f.world, data, blob, .Late)
	testing.expect_value(t, len(fake.voices), 2)
	// Later, a grain of the one section under it.
	fake.clock += SCRUB_INTERVAL
	seek(&f.cutscenes, &e, &f.world, data, blob, SECOND / 2)
	evaluate(&f.cutscenes, &e, &f.world, data, blob, .Late)
	testing.expect_value(t, len(fake.voices), 3)
	// Without a seek, nothing.
	fake.clock += SCRUB_INTERVAL
	evaluate(&f.cutscenes, &e, &f.world, data, blob, .Late)
	testing.expect_value(t, len(fake.voices), 3)
	free_all(f.platform.frame_allocator)
}

// A gain's linear infinity can go below 0 where no key is; the section plays it at 0, not at a negative gain.
@(test)
a_gain_that_its_infinity_takes_below_zero_plays_silent :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	gain := []format.Cutscene_Key {
		{time = 0, value = 1, interp = .Linear},
		{time = SECOND, value = 0.5, interp = .Linear},
	}
	channels := []format.Cutscene_Channel_Contents {
		{name = "gain", post_infinity = .Linear, keys = gain},
	}
	tracks := [?]format.Cutscene_Track_Contents {
		sound_track(1, sound_section(1, 0, 4 * SECOND, channels = channels)),
	}
	data := sounds_blob(f, tracks[:], 4 * SECOND)
	aligned := make([]byte, len(data) + 16, context.temp_allocator)
	start := int(-uintptr(raw_data(aligned)) & 15)
	copy(aligned[start:], data)
	data = aligned[start:][:len(data)]
	blob, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	e: Evaluation
	init_evaluation(&e, &f.world, {}, data, blob)
	defer destroy_evaluation(&e, &f.world)
	set_audition(&e, &f.world, .Scrub)
	// At 2 s the line goes on to 0, and at 3 s to -0.5, which plays as 0.
	seek(&f.cutscenes, &e, &f.world, data, blob, 2 * SECOND)
	evaluate(&f.cutscenes, &e, &f.world, data, blob, .Late)
	fake.clock += 2 * SCRUB_INTERVAL
	seek(&f.cutscenes, &e, &f.world, data, blob, 3 * SECOND)
	evaluate(&f.cutscenes, &e, &f.world, data, blob, .Late)
	testing.expect_value(t, len(fake.voices), 2)
	testing.expect_value(t, fake.voices[0].params.gain, 0)
	testing.expect_value(t, fake.voices[1].params.gain, 0)
	fake.clock += 2 * SCRUB_INTERVAL
	seek(&f.cutscenes, &e, &f.world, data, blob, SECOND / 2)
	evaluate(&f.cutscenes, &e, &f.world, data, blob, .Late)
	testing.expect_value(t, len(fake.voices), 3)
	testing.expect_value(t, fake.voices[2].params.gain, 0.75)
	free_all(f.platform.frame_allocator)
}

// The editor's preview plays an evaluation of no player under the Preview audition, moved by advance on each frame's
// real time (see docs/editor/cutscene-editor.md#the-games-side). Over 60 s of 1/60 s frames, its voices stay within a
// frame of the picture, across eight sections in a row.
@(test)
a_previews_sounds_keep_within_a_frame_of_its_time_over_a_minute :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	SECTION :: SECOND * 15 / 2
	sections: [8]format.Cutscene_Section_Contents
	for &s, i in sections {
		s = sound_section(
			u32(i + 1),
			i32(i) * SECTION,
			i32(i + 1) * SECTION,
			sound = LINE if i % 2 == 0 else MUSIC,
		)
	}
	tracks := [?]format.Cutscene_Track_Contents{sound_track(1, ..sections[:])}
	data := sounds_blob(f, tracks[:], 8 * SECTION)
	aligned := make([]byte, len(data) + 16, context.temp_allocator)
	start := int(-uintptr(raw_data(aligned)) & 15)
	copy(aligned[start:], data)
	data = aligned[start:][:len(data)]
	blob, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	e: Evaluation
	init_evaluation(&e, &f.world, {}, data, blob)
	defer destroy_evaluation(&e, &f.world)
	set_audition(&e, &f.world, .Preview)
	worst := 0.0
	for k in 0 ..< 60 * 60 {
		if k > 0 {
			advance(&e, blob, time.Second / 60)
		}
		evaluate(&f.cutscenes, &e, &f.world, data, blob, .Fixed)
		evaluate(&f.cutscenes, &e, &f.world, data, blob, .Late)
		audio.update(&f.audio, &f.world, nil, true, time.Second / 60)
		free_all(f.platform.frame_allocator)
		// Away from a section's start, whose voice waits for its start on the audio's clock.
		into := e.time % SECTION
		if into > SECOND / 10 && into < SECTION - SECOND / 10 {
			_, v, playing := voice_of(LINE if (e.time / SECTION) % 2 == 0 else MUSIC)
			testing.expectf(t, playing, "no voice at %v", e.time)
			expected := f64(into) / SECOND * boundary.SAMPLE_RATE
			worst = max(worst, abs(fake_place(v, fake.clock) - expected))
		}
		fake.clock += FRAME
	}
	// 3599 frames of 1/60 s, which time.Duration rounds down by a third of a nanosecond each.
	testing.expectf(t, abs(e.time - 3599 * TICK) <= 1, "the time is %v", e.time)
	testing.expectf(t, worst < FRAME, "a voice was %v frames of audio from the picture", worst)
}

// The integral of a curve matches a fine sum of its values, through constant, linear, Bezier, automatic and weighted
// segments, and past both ends.
@(test)
a_curves_integral_is_the_sum_of_its_values :: proc(t: ^testing.T) {
	keys := []format.Cutscene_Key {
		{time = 6000, value = 1, interp = .Constant},
		{time = 12000, value = 2, interp = .Linear},
		{time = 30000, value = 0.5, interp = .Auto},
		{time = 42000, value = 3, interp = .Bezier, in_slope = 1, out_slope = 1},
		{
			time = 60000,
			value = 1,
			interp = .Bezier,
			flags = {.Weighted, .Broken},
			in_slope = -2,
			out_slope = 0.5,
			in_weight = 0.2,
			out_weight = 0.7,
		},
		{time = 90000, value = 2, interp = .Bezier, flags = {.Weighted}, in_weight = 0.4},
	}
	for end in ([?]f64{3000, 9000, 20000.5, 41999, 51234.25, 75000, 100000}) {
		sum := 0.0
		STEPS :: 200000
		for i in 0 ..< STEPS {
			at := (f64(i) + 0.5) * end / STEPS
			sum += f64(curve_value(keys, i32(at), .Constant, .Constant)) * end / STEPS / SECOND
		}
		got := curve_integral(keys, end)
		testing.expectf(t, abs(got - sum) < 2e-4, "to %v: %v, and the sum %v", end, got, sum)
	}
}

// After a skip to the end of a skip range, a section under the time that does not play through the skip starts again at
// its place when play goes on.
@(test)
a_section_under_a_skip_ranges_end_plays_on_from_there :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	tracks := [?]format.Cutscene_Track_Contents{sound_track(1, sound_section(1, 0, 4 * SECOND))}
	ranges := [?]format.Cutscene_Skip_Range{{0, 2 * SECOND}}
	h := play_sounds(t, f, sounds_blob(f, tracks[:], 4 * SECOND, skip_ranges = ranges[:]))
	for _ in 0 ..< 30 {
		sound_frame(f)
	}
	first, _, _ := voice_of(LINE)
	testing.expect_value(t, skip(&f.cutscenes, &f.world, h), Command_Result.Done)
	sound_frame(f, ticks = 0)
	testing.expect(t, !fake.voices[first].playing)
	sound_frame(f)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Playing)
	sound_frame(f)
	index, v, playing := voice_of(LINE)
	testing.expect(t, playing && index != first)
	expected := shown(f, h) / SECOND * boundary.SAMPLE_RATE
	testing.expectf(t, abs(v.frame - expected) < 1, "plays on from %v, not %v", v.frame, expected)
}

// sound_step runs a frame that moves the world by a step, which can be less than a tick, as at a frame rate above the
// tick rate, and the audio's clock by the same real time.
@(private = "file")
sound_step :: proc(f: ^Sound_Fixture, step: time.Duration) {
	it := ecs.begin_ticks(&f.world, step)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, f)
		ecs.update_transforms(&f.world)
	}
	ecs.run_stage(&f.world, .Late, step, f)
	update(&f.cutscenes, {world = &f.world, dt = step})
	audio.update(&f.audio, &f.world, nil, true, step)
	free_all(f.platform.frame_allocator)
	fake.clock += u64(time.duration_seconds(step) * boundary.SAMPLE_RATE)
}

// At three frames to a tick, the sounds keep to the frames that presentation shows between ticks, with no seek. A
// section starts its voice ahead, on the audio's clock, at the exact start of its sound, so nothing of its attack is cut,
// at the cutscene's start and later.
@(test)
sounds_start_on_their_frame_and_keep_to_frames_between_ticks :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	tracks := [?]format.Cutscene_Track_Contents {
		sound_track(1, sound_section(1, 0, 4 * SECOND, sound = LINE)),
		sound_track(2, sound_section(2, SECOND, 4 * SECOND, sound = MUSIC)),
	}
	h := play_sounds(t, f, sounds_blob(f, tracks[:], 4 * SECOND))
	// 200 frames a second: more than three to a tick at 60 Hz, and 240 frames of audio each, so the audio's clock is exact.
	STEP :: time.Second / 200
	for _ in 0 ..< 400 {
		sound_step(f, STEP)
	}
	testing.expect_value(t, len(fake.seeks), 0)
	_, line, line_playing := voice_of(LINE)
	_, music, music_playing := voice_of(MUSIC)
	testing.expect(t, line_playing && music_playing)
	testing.expect_value(t, line.start, 0)
	testing.expect_value(t, music.start, 0)
	// The music started 1 s after the line, on the audio's clock.
	testing.expectf(
		t,
		abs(f64(music.started) - f64(line.started) - boundary.SAMPLE_RATE) < 2,
		"the music started %v frames after the line",
		i64(music.started) - i64(line.started),
	)
	// Each frame places the voices where the frame's time puts them.
	now := fake.clock - u64(boundary.SAMPLE_RATE / 200)
	expected := shown(f, h) / SECOND * boundary.SAMPLE_RATE
	limit := AUDIO_DRIFT * boundary.SAMPLE_RATE
	testing.expectf(
		t,
		abs(fake_place(line, now) - expected) < limit,
		"the line at %v, not %v",
		fake_place(line, now),
		expected,
	)
	testing.expectf(
		t,
		abs(fake_place(music, now) - (expected - boundary.SAMPLE_RATE)) < limit,
		"the music at %v, not %v",
		fake_place(music, now),
		expected - boundary.SAMPLE_RATE,
	)
}

// When a cutscene plays to its end, a section that plays through a skip and runs past the end plays on, and stops at its
// end on the audio's clock after its ease out; a section that does not stops. A stop before the end lets none play on.
@(test)
a_section_that_runs_past_the_end_plays_on_only_when_marked :: proc(t: ^testing.T) {
	f := sound_setup(t)
	defer sound_teardown(f)
	music := sound_section(2, 0, 5 * SECOND, sound = MUSIC, flags = {.Plays_Through_Skip})
	music.ease_out = SECOND / 2
	tracks := [?]format.Cutscene_Track_Contents {
		sound_track(1, sound_section(1, 0, 5 * SECOND, sound = LINE)),
		sound_track(2, music),
	}
	blob := sounds_blob(f, tracks[:], 6 * SECOND, range_end = 4 * SECOND)
	h := play_sounds(t, f, blob)
	sound_frame(f)
	line_index, _, _ := voice_of(LINE)
	music_index, _, _ := voice_of(MUSIC)
	for status(&f.cutscenes, h) == .Playing {
		sound_frame(f)
	}
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	testing.expect(t, !fake.voices[line_index].playing)
	testing.expect(t, fake.voices[music_index].playing)
	// It stops at 5 s less its ease out of 0.5 s, over 0.5 s: 0.5 s after the end.
	fake.clock += boundary.SAMPLE_RATE / 2 - 2 * FRAME
	audio.update(&f.audio, &f.world, nil, true, 0)
	testing.expect(t, fake.voices[music_index].playing)
	fake.clock += 2 * FRAME
	audio.update(&f.audio, &f.world, nil, true, 0)
	testing.expect(t, !fake.voices[music_index].playing)
	testing.expectf(
		t,
		abs(fake.voices[music_index].fade - 0.5) < 1e-6,
		"fades over %v",
		fake.voices[music_index].fade,
	)

	// A stop before the end stops both.
	h = play_sounds(t, f, blob)
	for _ in 0 ..< 30 {
		sound_frame(f)
	}
	line_index, _, _ = voice_of(LINE)
	music_index, _, _ = voice_of(MUSIC)
	testing.expect_value(t, stop(&f.cutscenes, &f.world, h), Command_Result.Done)
	sound_frame(f)
	testing.expect(t, !fake.voices[line_index].playing)
	testing.expect(t, !fake.voices[music_index].playing)
}
