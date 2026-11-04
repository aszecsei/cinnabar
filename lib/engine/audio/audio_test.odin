package audio

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:time"

import "cinnabar:core"
import boundary "cinnabar:core/audio"
import "cinnabar:core/audio/adpcm"
import audio_host "cinnabar:core/audio/host"
import audio_null "cinnabar:core/audio/null"
import "cinnabar:core/jobs"
import "cinnabar:core/luau"
import physics_host "cinnabar:core/physics/host"
import physics_boundary "cinnabar:core/physics"
import physics_jolt "cinnabar:core/physics/jolt"
import script_host "cinnabar:core/script"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"
import "cinnabar:engine/script"

// These run on the null backend, whose table records what the game side asks of it, with Jolt for the occlusion rays. The
// backends and the scheduler are singletons, and the test runner runs tests on several threads.
@(private = "file")
lock: sync.Mutex

// What the backend was asked, for the running test.
@(private = "file")
Record :: struct {
	null:         ^boundary.Audio_API,
	sounds:       [dynamic]boundary.Sound_Desc,
	paths:        [dynamic]string,
	plays:        [dynamic]boundary.Voice_Desc,
	stops:        int,
	last:         boundary.Voice_Params,
	sets:         int,
	paused:       bool,
	// Voices that have ended, as the null backend's never do.
	ended:        bool,
	bus_gains:    [dynamic]f32,
}

@(private = "file")
record: Record

@(private = "file")
recording_table :: proc(null: ^boundary.Audio_API) -> boundary.Audio_API {
	record.null = null
	api := null^
	api.sound_create = proc "c" (desc: ^boundary.Sound_Desc) -> boundary.Sound {
		context = runtime.default_context()
		append(&record.sounds, desc^)
		append(&record.paths, fmt.aprintf("%s", desc.path) if desc.path != nil else "")
		return record.null.sound_create(desc)
	}
	api.voice_play = proc "c" (desc: ^boundary.Voice_Desc) -> boundary.Voice {
		context = runtime.default_context()
		append(&record.plays, desc^)
		record.last = desc.params
		return record.null.voice_play(desc)
	}
	api.voice_set = proc "c" (voice: boundary.Voice, params: ^boundary.Voice_Params) {
		record.last = params^
		record.sets += 1
		record.null.voice_set(voice, params)
	}
	api.voice_stop = proc "c" (voice: boundary.Voice, fade: f32) {
		record.stops += 1
		record.null.voice_stop(voice, fade)
	}
	api.voice_playing = proc "c" (voice: boundary.Voice) -> b32 {
		return !record.ended && record.null.voice_playing(voice)
	}
	api.set_paused = proc "c" (paused: b32) {
		record.paused = bool(paused)
	}
	api.bus_set_gain = proc "c" (bus: boundary.Bus, gain: f32) {
		context = runtime.default_context()
		append(&record.bus_gains, gain)
		record.null.bus_set_gain(bus, gain)
	}
	return api
}

@(private = "file")
Fixture :: struct {
	frame:        virtual.Arena,
	platform:     core.Platform_API,
	physics_host: physics_boundary.Host,
	audio_host:   boundary.Host,
	world:        ecs.World,
	physics:      physics.State,
	assets:       asset.Assets,
	audio:        State,
	cache:        string,
	scripts:      bool,
	runtime:      script.Runtime,
	reports:      [dynamic]f64,
}

@(private = "file")
fake_write :: proc "c" (frames: [^]boundary.Device_Frame, count: i32) -> i32 {
	return count
}

@(private = "file")
fake_status :: proc "c" (out: ^boundary.Device_Status) {
	out^ = {}
}

@(private = "file")
SOUND :: format.Guid{0 = 0xa0, 15 = 0x01}
@(private = "file")
OTHER :: format.Guid{0 = 0xa0, 15 = 0x02}
@(private = "file")
LONG :: format.Guid{0 = 0xa0, 15 = 0x03}

// A step that a test passes, long enough that the occlusion arrives in one update.
@(private = "file")
STEP :: 1 * time.Second

@(private = "file")
setup :: proc(t: ^testing.T, scripts := false) -> ^Fixture {
	sync.lock(&lock)
	testing.expect(t, jobs.init())
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.physics_host = physics_host.table()
	api := physics_jolt.load(&f.physics_host)
	physics_host.bind(api)
	f.audio_host = audio_host.table(fake_write, fake_status)
	audio_api := recording_table(audio_null.load(&f.audio_host))
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		jobs_run = jobs.run,
		jobs_wait = jobs.wait,
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
		physics = api^,
		audio = audio_api,
		file_read = core.file_read,
		file_read_range = core.file_read_range,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {return 0},
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	physics.register_components(&f.world.registry)
	register_components(&f.world.registry)
	cache, err := os.make_directory_temp("", "audio_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	testing.expect(t, physics.init(&f.physics, &f.platform, assets = &f.assets))
	physics.register(&f.physics, &f.world)
	init(&f.audio, &f.platform, &f.assets)
	if scripts {
		f.scripts = true
		f.reports = make([dynamic]f64)
		script.register_components(&f.world.registry)
		context.user_ptr = f
		testing.expect(t, script.init(&f.runtime, &f.platform, &f.world, nil, register_test_scripts))
	}
	return f
}

@(private = "file")
register_test_scripts :: proc(r: ^script.Runtime) {
	f := (^Fixture)(context.user_ptr)
	register_scripts(r, &f.audio)
	script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
		f := (^Fixture)(context.user_ptr)
		append(&f.reports, luau.L_checknumber(L, 1))
		return 0
	})
	script.define(r, "Test.sound", proc(L: ^luau.State) -> c.int {
		script.push_asset(script.runtime_of(L), L, SOUND)
		return 1
	})
}

@(private = "file")
teardown :: proc(t: ^testing.T, f: ^Fixture) {
	if f.scripts {
		script.destroy(&f.runtime)
		delete(f.reports)
	}
	destroy(&f.audio)
	f.platform.audio.reset()
	physics.destroy(&f.physics)
	testing.expect_value(t, f.platform.physics.world_destroy_all(), 0)
	asset.destroy(&f.assets)
	os.remove_all(f.cache)
	delete(f.cache)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
	for path in record.paths {
		delete(path, runtime.default_allocator())
	}
	delete(record.sounds)
	delete(record.paths)
	delete(record.plays)
	delete(record.bus_gains)
	record = {}
	testing.expect(t, jobs.drain_frame())
	jobs.shutdown()
	sync.unlock(&lock)
}

// frame runs a frame's update, and frees the frame's memory as the host does.
@(private = "file")
frame :: proc(f: ^Fixture, run := true) {
	physics.sync(&f.physics, &f.world)
	update(&f.audio, &f.world, &f.physics, run, STEP)
	free_all(f.platform.frame_allocator)
}

@(private = "file")
write_sound :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, samples: []i16, channels: u32 = 1, stream := false) {
	buffer: [32]u8
	blob := format.audio_write({guid = guid, frames = u64(len(samples)) / u64(channels), channels = channels, stream = stream, data = slice.to_bytes(samples), source_path = "game/audio/test.wav"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(guid, &buffer)), blob) == nil)
}

@(private = "file")
SAMPLES := [?]i16{100, 200, 300, 400}

@(private = "file")
spawn_at :: proc(f: ^Fixture, meters: [3]f64, rotation: quaternion128 = 1) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	pose := ecs.TRANSFORM_IDENTITY
	pose.position = ecs.position_from_meters(meters)
	pose.rotation = rotation
	ecs.add(&f.world, e, pose)
	return e
}

@(private = "file")
listener :: proc(f: ^Fixture, meters: [3]f64 = {}, rotation: quaternion128 = 1) -> ecs.Entity {
	e := spawn_at(f, meters, rotation)
	ecs.add(&f.world, e, Audio_Listener{})
	return e
}

@(private = "file")
source :: proc(f: ^Fixture, meters: [3]f64, sound := SOUND, loop := true) -> ecs.Entity {
	e := spawn_at(f, meters)
	s := DEFAULT_AUDIO_SOURCE
	s.sound = sound
	s.loop = loop
	ecs.add(&f.world, e, s)
	return e
}

@(private = "file")
close_to :: proc(a, b: [3]f32, tolerance: f32 = 0.001) -> bool {
	return linalg.length(a - b) <= tolerance
}

// A source plays at its position in the listener's axes: nearer the listener than its world position says, and turned
// with it. Far from the origin, as the sample is, the numbers stay exact.
@(test)
a_source_plays_in_the_listeners_axes :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	write_sound(t, f, SOUND, SAMPLES[:])
	FAR :: 1.5e11
	// A quarter turn about Y: the listener's right is the world's -Z, so a source at -Z is on its right.
	turn := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 1, 0})
	listener(f, {FAR, 0, 0}, turn)
	source(f, {FAR, 0, -3})
	frame(f)
	testing.expect_value(t, len(record.plays), 1)
	testing.expect(t, bool(record.last.spatial))
	testing.expectf(t, close_to(record.last.position, {3, 0, 0}), "position %v", record.last.position)
}

// A source that moves in ticks is heard between them, as it is drawn.
@(test)
a_source_follows_the_presented_pose :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	write_sound(t, f, SOUND, SAMPLES[:])
	listener(f)
	e := source(f, {0, 0, 0})
	frame(f)
	pose := ecs.TRANSFORM_IDENTITY
	pose.position = ecs.position_from_meters({10, 0, 0})
	ecs.add(&f.world, e, ecs.Previous_Transform(pose))
	pose.position = ecs.position_from_meters({20, 0, 0})
	ecs.get_write(&f.world, e, ecs.Transform)^ = pose
	f.world.clock.alpha = 0.25
	update(&f.audio, &f.world, nil, true, STEP)
	free_all(f.platform.frame_allocator)
	testing.expectf(t, close_to(record.last.position, {12.5, 0, 0}), "position %v", record.last.position)
	testing.expect_value(t, len(record.plays), 1)
}

// A source that goes away takes its voice with it: despawned, disabled, or with no component.
@(test)
a_voice_stops_with_its_source :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	write_sound(t, f, SOUND, SAMPLES[:])
	listener(f)
	despawned := source(f, {1, 0, 0})
	disabled := source(f, {2, 0, 0})
	removed := source(f, {3, 0, 0})
	frame(f)
	testing.expect_value(t, len(record.plays), 3)
	testing.expect_value(t, record.stops, 0)
	ecs.despawn(&f.world, despawned)
	frame(f)
	testing.expect_value(t, record.stops, 1)
	ecs.set_active(&f.world, disabled, false)
	frame(f)
	testing.expect_value(t, record.stops, 2)
	ecs.remove(&f.world, removed, Audio_Source)
	frame(f)
	testing.expect_value(t, record.stops, 3)
}

// Clearing playing stops it, a sound that is not looping clears playing when it ends, and setting it plays it again.
@(test)
playing_starts_and_stops_a_voice :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	write_sound(t, f, SOUND, SAMPLES[:])
	listener(f)
	e := source(f, {1, 0, 0}, loop = false)
	frame(f)
	testing.expect_value(t, len(record.plays), 1)
	record.ended = true
	frame(f)
	testing.expect(t, !ecs.get(&f.world, e, Audio_Source).playing)
	testing.expect_value(t, len(record.plays), 1)
	record.ended = false
	ecs.get_write(&f.world, e, Audio_Source).playing = true
	frame(f)
	testing.expect_value(t, len(record.plays), 2)
	ecs.get_write(&f.world, e, Audio_Source).playing = false
	frame(f)
	testing.expect_value(t, record.stops, 1)
	testing.expect_value(t, len(record.plays), 2)
}

// While the world does not run, voices hold and none starts. Then it goes on.
@(test)
a_world_that_does_not_run_holds_its_voices :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	write_sound(t, f, SOUND, SAMPLES[:])
	listener(f)
	source(f, {1, 0, 0})
	frame(f, run = false)
	testing.expect(t, record.paused)
	testing.expect_value(t, len(record.plays), 0)
	frame(f)
	testing.expect(t, !record.paused)
	testing.expect_value(t, len(record.plays), 1)
	frame(f, run = false)
	testing.expect(t, record.paused)
	testing.expect_value(t, record.stops, 0)
	frame(f)
	testing.expect_value(t, len(record.plays), 1)
}

// A wall between the source and the listener occludes it, by a ray against the physics world. The source's own collider
// does not, and moving the wall away clears it.
@(test)
a_wall_occludes_a_source :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	write_sound(t, f, SOUND, SAMPLES[:])
	listener(f)
	e := source(f, {0, 0, 10})
	ecs.add(&f.world, e, physics.DEFAULT_COLLIDER)
	frame(f)
	frame(f)
	testing.expect_value(t, record.last.occlusion, 0)

	wall := spawn_at(f, {0, 0, 5})
	c := physics.DEFAULT_COLLIDER
	c.size = {10, 10, 1}
	ecs.add(&f.world, wall, c)
	frame(f)
	frame(f)
	testing.expect_value(t, record.last.occlusion, 1)

	// A step shorter than the smoothing takes only part of the way.
	ecs.get_write(&f.world, wall, ecs.Transform).position = ecs.position_from_meters({0, 100, 5})
	physics.sync(&f.physics, &f.world)
	update(&f.audio, &f.world, &f.physics, true, 50 * time.Millisecond)
	free_all(f.platform.frame_allocator)
	update(&f.audio, &f.world, &f.physics, true, 50 * time.Millisecond)
	free_all(f.platform.frame_allocator)
	testing.expect(t, record.last.occlusion > 0 && record.last.occlusion < 1)
	frame(f)
	frame(f)
	testing.expect_value(t, record.last.occlusion, 0)
}

// A voice that starts behind a wall starts muffled, with no fade from clear. One that does not ask to be occluded is not.
@(test)
a_voice_starts_with_its_occlusion :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	write_sound(t, f, SOUND, SAMPLES[:])
	listener(f)
	wall := spawn_at(f, {0, 0, 5})
	c := physics.DEFAULT_COLLIDER
	c.size = {10, 10, 1}
	ecs.add(&f.world, wall, c)
	physics.sync(&f.physics, &f.world)
	source(f, {0, 0, 10})
	frame(f)
	testing.expect_value(t, record.plays[0].params.occlusion, 1)

	open := source(f, {1, 0, 10})
	ecs.get_write(&f.world, open, Audio_Source).occluded = false
	frame(f)
	testing.expect_value(t, record.plays[1].params.occlusion, 0)
	frame(f)
	testing.expect_value(t, record.last.occlusion, 0)
}

// Without physics nothing occludes, and without a listener a spatial source plays centred.
@(test)
no_physics_and_no_listener :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	context.logger = log.nil_logger()
	write_sound(t, f, SOUND, SAMPLES[:])
	source(f, {0, 0, 10})
	update(&f.audio, &f.world, nil, true, STEP)
	free_all(f.platform.frame_allocator)
	testing.expect(t, !bool(record.last.spatial))
	testing.expect_value(t, record.last.position, [3]f32{})
	testing.expect_value(t, record.last.occlusion, 0)
	testing.expect(t, f.audio.warned_listener)
}

// A short sound's samples go to the backend, and a long one's blob is only named, with where its samples start. Neither
// stays in the asset system.
@(test)
a_sound_loads_or_streams :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	write_sound(t, f, SOUND, SAMPLES[:])
	long := [?]i16{1, 2, 3, 4, 5, 6}
	write_sound(t, f, LONG, long[:], channels = 2, stream = true)
	listener(f)
	source(f, {1, 0, 0}, SOUND)
	frame(f)
	source(f, {2, 0, 0}, LONG)
	frame(f)
	testing.expect_value(t, len(record.sounds), 2)
	memory, stream := record.sounds[0], record.sounds[1]
	testing.expect_value(t, memory.frames, 4)
	testing.expect_value(t, memory.channels, 1)
	testing.expect(t, memory.path == nil)
	testing.expect_value(t, stream.frames, 3)
	testing.expect_value(t, stream.channels, 2)
	testing.expect(t, stream.samples == nil)
	testing.expect(t, stream.offset >= size_of(format.Audio_Blob))
	buffer: [32]u8
	testing.expect_value(t, record.paths[1], fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(LONG, &buffer)))
	testing.expect_value(t, f.assets.used, 0)
}

@(private = "file")
write_adpcm_sound :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, samples: []i16, stream: bool) {
	buffer: [32]u8
	data := adpcm.encode(samples, 1, context.temp_allocator)
	blob := format.audio_write({guid = guid, frames = u64(len(samples)), channels = 1, stream = stream, format = .ADPCM, data = data, source_path = "game/audio/test.wav"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(guid, &buffer)), blob) == nil)
}

// A compressed sound that streams goes to a backend that can read it with its format and where its data is, and a backend
// that cannot gets it decoded, as PCM. So does a compressed sound that does not stream, on any backend.
@(test)
a_compressed_sound_streams_or_decodes :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	samples := [?]i16{100, 110, 120, 130, 140, 150, 160, 170}
	write_adpcm_sound(t, f, SOUND, samples[:], stream = false)
	write_adpcm_sound(t, f, LONG, samples[:], stream = true)
	write_adpcm_sound(t, f, OTHER, samples[:], stream = true)
	listener(f)

	source(f, {1, 0, 0}, SOUND)
	frame(f)
	source(f, {2, 0, 0}, LONG)
	frame(f)
	f.audio.features -= {.Stream_ADPCM}
	source(f, {3, 0, 0}, OTHER)
	frame(f)

	testing.expect_value(t, len(record.sounds), 3)
	memory, streamed, fallback := record.sounds[0], record.sounds[1], record.sounds[2]
	testing.expect(t, memory.path == nil)
	testing.expect_value(t, memory.frames, 8)
	testing.expect_value(t, memory.format, boundary.Sound_Format.PCM)
	testing.expect(t, streamed.samples == nil)
	testing.expect_value(t, streamed.format, boundary.Sound_Format.ADPCM)
	testing.expect_value(t, streamed.frames, 8)
	testing.expect_value(t, streamed.size, adpcm.data_bytes(8, 1))
	testing.expect(t, streamed.offset >= size_of(format.Audio_Blob))
	testing.expect(t, fallback.path == nil)
	testing.expect_value(t, fallback.format, boundary.Sound_Format.PCM)
	testing.expect_value(t, fallback.frames, 8)
	testing.expect_value(t, f.assets.used, 0)
}

// A blob that the cooker writes again makes a new sound, and its source starts again from it.
@(test)
a_changed_blob_restarts_its_sources :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	write_sound(t, f, SOUND, SAMPLES[:])
	listener(f)
	source(f, {1, 0, 0})
	frame(f)
	frame(f)
	testing.expect_value(t, len(record.sounds), 1)
	testing.expect_value(t, len(record.plays), 1)

	time.sleep(20 * time.Millisecond)
	more := [?]i16{1, 2, 3, 4, 5, 6, 7, 8}
	write_sound(t, f, SOUND, more[:])
	frame(f)
	frame(f)
	testing.expect_value(t, len(record.sounds), 2)
	testing.expect_value(t, record.sounds[1].frames, 8)
	testing.expect_value(t, record.stops, 1)
	testing.expect_value(t, len(record.plays), 2)
}

// A sound with no blob does not play and logs once, and plays when it is cooked.
@(test)
a_missing_blob_waits_to_be_cooked :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	context.logger = log.nil_logger()
	listener(f)
	source(f, {1, 0, 0})
	frame(f)
	frame(f)
	testing.expect_value(t, len(record.sounds), 0)
	testing.expect_value(t, len(record.plays), 0)
	write_sound(t, f, SOUND, SAMPLES[:])
	frame(f)
	frame(f)
	testing.expect_value(t, len(record.plays), 1)
}

// A code reload takes the new Platform_API, and the voice goes on with the same handle.
@(test)
a_code_reload_keeps_the_voice :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	write_sound(t, f, SOUND, SAMPLES[:])
	listener(f)
	source(f, {1, 0, 0})
	frame(f)
	sets := record.sets
	reload(&f.audio, &f.platform)
	frame(f)
	testing.expect_value(t, len(record.plays), 1)
	testing.expect_value(t, record.stops, 0)
	testing.expect(t, record.sets > sets)
}

// A behaviour plays a sound through Audio: at a position, heard from the listener, and to its end.
@(test)
a_script_plays_a_sound :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(t, f)
	context.user_ptr = f
	write_sound(t, f, SOUND, SAMPLES[:])
	listener(f, {0, 0, 0})
	_, ok := script.spawn_source(&f.runtime, "=play", `
Audio.play(Test.sound(), WorldPosition.from_meters(4, 0, 0), 0.5)
Audio.play(Test.sound())
`)
	testing.expect(t, ok)
	frame(f)
	testing.expect_value(t, len(record.plays), 2)
	a, b := record.plays[0].params, record.plays[1].params
	testing.expect(t, bool(a.spatial))
	testing.expect_value(t, a.gain, 0.5)
	testing.expectf(t, close_to(a.position, {4, 0, 0}), "position %v", a.position)
	testing.expect_value(t, record.plays[0].loop, false)
	testing.expect(t, !bool(b.spatial))
	testing.expect_value(t, b.gain, 1)
	testing.expect_value(t, f.audio.one_shot_count, 2)

	// It moves as the listener does, until it ends.
	frame(f)
	testing.expect_value(t, len(record.plays), 2)
	record.ended = true
	frame(f)
	testing.expect_value(t, f.audio.one_shot_count, 0)
}

// What is not a sound or a bus raises an error in the script, and a bus that the project names works by name.
@(test)
a_script_is_told_what_it_got_wrong :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(t, f)
	context.user_ptr = f
	names: Bus_Names
	testing.expect(t, add_bus_name(&names, "Sfx"))
	set_buses(&f.audio, names)
	_, ok := script.spawn_source(&f.runtime, "=checks", `
Test.report(pcall(Audio.play, 3) and 1 or 0)
Test.report(pcall(Audio.play, Test.sound(), nil, 1, "Nope") and 1 or 0)
Test.report(pcall(Audio.set_bus_gain, "Nope", 1) and 1 or 0)
Test.report(pcall(Audio.play, Test.sound(), nil, 1, "Sfx") and 1 or 0)
Test.report(pcall(Audio.set_bus_gain, "Sfx", 0.25) and 1 or 0)
Test.report(pcall(Audio.set_bus_gain, "Master", 0.5) and 1 or 0)
`)
	testing.expect(t, ok)
	testing.expectf(t, len(f.reports) == 6 && f.reports[0] == 0 && f.reports[1] == 0 && f.reports[2] == 0 && f.reports[3] == 1 && f.reports[4] == 1 && f.reports[5] == 1, "reports %v", f.reports[:])
	testing.expect_value(t, len(record.bus_gains), 2)
	testing.expect_value(t, f.audio.one_shots[0].bus, 1)
}

// A project's buses are made once, and keep their handles across a change of what it names.
@(test)
buses_come_from_names :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	context.logger = log.nil_logger()
	names: Bus_Names
	testing.expect(t, add_bus_name(&names, "Music"))
	testing.expect(t, add_bus_name(&names, "Sfx"))
	testing.expect(t, !add_bus_name(&names, "Sfx"))
	testing.expect(t, !add_bus_name(&names, MASTER_NAME))
	testing.expect(t, !add_bus_name(&names, ""))
	set_buses(&f.audio, names)
	music := f.audio.buses[0]
	testing.expect(t, music != {})
	index, ok := bus_index(&f.audio, "Sfx")
	testing.expect(t, ok)
	testing.expect_value(t, index, 2)
	_, ok = bus_index(&f.audio, "Nope")
	testing.expect(t, !ok)
	testing.expect(t, !set_bus_gain(&f.audio, "Nope", 1))

	set_buses(&f.audio, names)
	testing.expect_value(t, f.audio.buses[0], music)

	// A source's bus is its index, and one that the project does not name is Master.
	write_sound(t, f, SOUND, SAMPLES[:])
	listener(f)
	e := source(f, {1, 0, 0})
	ecs.get_write(&f.world, e, Audio_Source).bus = 1
	other := source(f, {2, 0, 0})
	ecs.get_write(&f.world, other, Audio_Source).bus = 9
	frame(f)
	testing.expect_value(t, record.plays[0].bus, music)
	testing.expect_value(t, record.plays[1].bus, boundary.MASTER_BUS)
}
