package audio_mixer

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import audio "cinnabar:core/audio"
import "cinnabar:core/audio/conformance"
import audio_host "cinnabar:core/audio/host"

// These tests drive one mixer each, with no threads, and read the samples that it renders. The table's state is one per
// process, so its test takes the lock.
@(private = "file")
table_lock: sync.Mutex

@(private = "file")
table_host: audio.Host

@(private = "file")
Fixture :: struct {
	host: audio.Host,
	m:    ^Mixer,
}

@(private = "file")
fake_write :: proc "c" (frames: [^]audio.Device_Frame, count: i32) -> i32 {
	return count
}

@(private = "file")
fake_status :: proc "c" (out: ^audio.Device_Status) {
	out^ = {}
}

@(private = "file")
setup :: proc(f: ^Fixture) {
	f.host = audio_host.table(fake_write, fake_status)
	f.m = new(Mixer)
	init(f.m, &f.host)
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	shutdown(f.m)
	free(f.m)
}

// A plain voice at full gain, not spatial.
@(private = "file")
plain :: proc() -> audio.Voice_Params {
	return {gain = 1, pitch = 1}
}

@(private = "file")
spatial_at :: proc(position: [3]f32, occlusion: f32 = 0) -> audio.Voice_Params {
	return {position = position, gain = 1, pitch = 1, occlusion = occlusion, min_distance = 1, max_distance = 100, spatial = true}
}

@(private = "file")
memory_sound :: proc(m: ^Mixer, samples: []i16, channels: u32 = 1) -> audio.Sound {
	return sound_create(m, &audio.Sound_Desc{frames = u64(len(samples)) / u64(channels), samples = raw_data(samples), channels = channels})
}

@(private = "file")
play :: proc(m: ^Mixer, sound: audio.Sound, params: audio.Voice_Params, loop := false, bus := audio.Bus{}) -> audio.Voice {
	return voice_play(m, &audio.Voice_Desc{sound = sound, bus = bus, params = params, loop = b32(loop)})
}

// A sine of a whole number of cycles, at full scale times gain.
@(private = "file")
sine :: proc(frames, cycles: int, gain: f32 = 0.5, allocator := context.temp_allocator) -> []i16 {
	samples := make([]i16, frames, allocator)
	for &sample, i in samples {
		sample = i16(math.sin(f32(i) * f32(cycles) * math.TAU / f32(frames)) * gain * 32767)
	}
	return samples
}

// The root-mean-square level of the left channel.
@(private = "file")
level :: proc(frames: []audio.Device_Frame) -> f32 {
	sum: f32
	for frame in frames {
		sum += frame.x * frame.x
	}
	return math.sqrt(sum / f32(len(frames)))
}

@(private = "file")
close_to :: proc(a, b: f32, tolerance: f32 = 0.001) -> bool {
	return abs(a - b) <= tolerance
}

// A voice plays its samples exactly, then ends, with its handle saying so.
@(test)
a_voice_plays_exact_samples_and_ends :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{3276, -3276, 6553, 13107}
	sound := memory_sound(f.m, samples[:])
	voice := play(f.m, sound, plain())
	testing.expect(t, bool(voice_playing(f.m, voice)))

	out: [8]audio.Device_Frame
	render(f.m, out[:])
	for sample, i in samples {
		expected := f32(sample) / 32768
		testing.expect_value(t, out[i], audio.Device_Frame{expected, expected})
	}
	for i in len(samples) ..< len(out) {
		testing.expect_value(t, out[i], audio.Device_Frame{0, 0})
	}
	testing.expect(t, !bool(voice_playing(f.m, voice)))
}

// A stereo sound keeps its sides, and a spatial one is mixed down to one point.
@(test)
stereo_keeps_its_sides_unless_spatial :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{16384, 0, 16384, 0}
	sound := memory_sound(f.m, samples[:], 2)
	play(f.m, sound, plain())
	out: [2]audio.Device_Frame
	render(f.m, out[:])
	testing.expect_value(t, out[0], audio.Device_Frame{0.5, 0})

	play(f.m, sound, spatial_at({0, 0, 1}))
	render(f.m, out[:])
	// Half of the left side's 0.5, at the centre's equal-power gain.
	testing.expect(t, close_to(out[0].x, 0.25 * math.SQRT_TWO / 2))
	testing.expect(t, close_to(out[0].x, out[0].y))
}

// A loop has no seam: it reads the first frame right after the last.
@(test)
a_loop_is_seamless :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{1000, 2000, 3000}
	sound := memory_sound(f.m, samples[:])
	voice := play(f.m, sound, plain(), loop = true)
	out: [BLOCK_FRAMES + 7]audio.Device_Frame
	render(f.m, out[:])
	for frame, i in out {
		testing.expect_value(t, frame.x, f32(samples[i % 3]) / 32768)
	}
	testing.expect(t, bool(voice_playing(f.m, voice)))
}

// Pitch 2 reads every other frame, and 0.5 interpolates between them.
@(test)
pitch_changes_the_rate :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{0, 1000, 2000, 3000, 4000, 5000}
	sound := memory_sound(f.m, samples[:])
	params := plain()
	params.pitch = 2
	play(f.m, sound, params)
	out: [3]audio.Device_Frame
	render(f.m, out[:])
	testing.expect_value(t, out[1].x, f32(2000) / 32768)
	testing.expect_value(t, out[2].x, f32(4000) / 32768)

	render(f.m, out[:])
	params.pitch = 0.5
	play(f.m, sound, params)
	render(f.m, out[:])
	testing.expect_value(t, out[1].x, f32(500) / 32768)
	testing.expect_value(t, out[2].x, f32(1000) / 32768)
}

// Panning keeps the power the same wherever the source is, and puts it on the source's side.
@(test)
panning_keeps_the_power :: proc(t: ^testing.T) {
	for x in ([?]f32{-1, -0.5, 0, 0.5, 1}) {
		gains := voice_gains(spatial_at({x, 0, math.sqrt(1 - x * x)}))
		testing.expect(t, close_to(gains.x * gains.x + gains.y * gains.y, 1))
		testing.expect(t, (x >= 0) == (gains.y >= gains.x))
	}
	right := voice_gains(spatial_at({1, 0, 0}))
	testing.expect(t, close_to(right.x, 0))
	testing.expect(t, close_to(right.y, 1))
	// On the listener, it has no side.
	here := voice_gains(spatial_at({0, 0, 0}))
	testing.expect(t, close_to(here.x, here.y))
}

// Full volume up to min_distance, falling with distance, silent from max_distance. Not spatial ignores all of it.
@(test)
distance_attenuates :: proc(t: ^testing.T) {
	power :: proc(distance: f32) -> f32 {
		gains := voice_gains(spatial_at({0, 0, distance}))
		return gains.x * gains.x + gains.y * gains.y
	}
	testing.expect(t, close_to(power(0.5), 1))
	testing.expect(t, close_to(power(1), 1))
	testing.expect(t, power(2) < 0.3)
	testing.expect(t, power(4) < power(2))
	testing.expect(t, power(50) < power(4))
	testing.expect(t, power(99) > 0)
	testing.expect_value(t, power(100), 0)
	testing.expect_value(t, power(1000), 0)
	flat := plain()
	flat.position = {0, 0, 1000}
	testing.expect_value(t, voice_gains(flat), [2]f32{1, 1})
}

// Occlusion takes level from everything, and more from the highs than from the lows.
@(test)
occlusion_takes_the_highs_first :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	FRAMES :: 4800
	measure :: proc(m: ^Mixer, cycles: int, occlusion: f32) -> f32 {
		sound := memory_sound(m, sine(FRAMES, cycles))
		voice := play(m, sound, spatial_at({0, 0, 1}, occlusion), loop = true)
		out := make([]audio.Device_Frame, FRAMES, context.temp_allocator)
		render(m, out)
		voice_stop(m, voice, 0)
		silence: [BLOCK_FRAMES]audio.Device_Frame
		render(m, silence[:])
		sound_destroy(m, sound)
		return level(out)
	}
	// 100 Hz and 8 kHz.
	low := measure(f.m, 10, 1) / measure(f.m, 10, 0)
	high := measure(f.m, 800, 1) / measure(f.m, 800, 0)
	testing.expect(t, low < 0.5)
	testing.expect(t, low > 0.25)
	testing.expect(t, high < low * 0.25)
}

// A change of gain ramps across a block, so a loud constant sound has no step in it.
@(test)
a_change_has_no_step :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{16384}
	sound := memory_sound(f.m, samples[:])
	voice := play(f.m, sound, plain(), loop = true)
	out: [BLOCK_FRAMES * 3]audio.Device_Frame
	render(f.m, out[:BLOCK_FRAMES])
	params := plain()
	params.gain = 0
	voice_set(f.m, voice, &params)
	render(f.m, out[BLOCK_FRAMES:])
	largest: f32
	for i in 1 ..< len(out) {
		largest = max(largest, abs(out[i].x - out[i - 1].x))
	}
	testing.expect(t, largest < 0.01)
	testing.expect_value(t, out[len(out) - 1].x, 0)
}

// A stop fades out, and goes stale at once.
@(test)
a_stop_fades :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{16384}
	sound := memory_sound(f.m, samples[:])
	voice := play(f.m, sound, plain(), loop = true)
	voice_stop(f.m, voice, 0.1)
	testing.expect(t, !bool(voice_playing(f.m, voice)))
	out: [4800 + BLOCK_FRAMES]audio.Device_Frame
	render(f.m, out[:])
	testing.expect(t, out[0].x > 0.49)
	testing.expect(t, close_to(out[2400].x, 0.25, 0.01))
	testing.expect_value(t, out[len(out) - 1].x, 0)
	testing.expect(t, !f.m.voices[voice.index].active)
}

// A destroyed sound outlives its voices, and update frees it after them.
@(test)
a_sound_lasts_as_long_as_its_voices :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{16384, 16384, 16384, 16384}
	sound := memory_sound(f.m, samples[:])
	play(f.m, sound, plain())
	sound_destroy(f.m, sound)
	update(f.m)
	testing.expect(t, f.m.dying != nil)
	out: [2]audio.Device_Frame
	render(f.m, out[:])
	testing.expect_value(t, out[1].x, 0.5)
	update(f.m)
	testing.expect(t, f.m.dying != nil)
	render(f.m, out[:])
	render(f.m, out[:])
	update(f.m)
	testing.expect(t, f.m.dying == nil)
}

// A bus's gain reaches what passes through it, through its parents, and Master limits the sum.
@(test)
buses_nest_and_master_limits :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{16384}
	sound := memory_sound(f.m, samples[:])
	music := bus_create(f.m, {})
	child := bus_create(f.m, music)
	bus_set_gain(f.m, music, 0.5)
	bus_set_gain(f.m, child, 0.5)
	play(f.m, sound, plain(), loop = true, bus = child)
	out: [BLOCK_FRAMES * 2]audio.Device_Frame
	render(f.m, out[:])
	testing.expect(t, close_to(out[len(out) - 1].x, 0.125))

	// Far past full scale: bent below 1, and steady.
	loud := plain()
	loud.gain = 64
	play(f.m, sound, loud, loop = true)
	render(f.m, out[:])
	testing.expect(t, out[len(out) - 1].x <= 1)
	testing.expect(t, out[len(out) - 1].x > LIMITER_THRESHOLD)
	testing.expect_value(t, limit(0.5), 0.5)
	testing.expect_value(t, limit(-0.5), -0.5)
	testing.expect(t, limit(-40) >= -1)
}

@(private = "file")
effect_level :: proc(f: ^Fixture, effect: audio.Effect, cycles: int) -> f32 {
	FRAMES :: 4800
	sound := memory_sound(f.m, sine(FRAMES, cycles))
	bus := bus_create(f.m, {})
	bus_set_effect(f.m, bus, 0, &audio.Effect{kind = effect.kind, parameters = effect.parameters})
	voice := play(f.m, sound, plain(), loop = true, bus = bus)
	out := make([]audio.Device_Frame, FRAMES * 2, context.temp_allocator)
	render(f.m, out)
	voice_stop(f.m, voice, 0)
	bus_set_effect(f.m, bus, 0, &audio.Effect{})
	silence: [BLOCK_FRAMES]audio.Device_Frame
	render(f.m, silence[:])
	update(f.m)
	sound_destroy(f.m, sound)
	// After the filter settles.
	return level(out[FRAMES:])
}

// A low-pass keeps the lows and a high-pass keeps the highs.
@(test)
filters_filter :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	testing.expect(t, effect_level(&f, {kind = .Low_Pass, parameters = {1000, 0.7, 0}}, 10) > 0.3)
	testing.expect(t, effect_level(&f, {kind = .Low_Pass, parameters = {1000, 0.7, 0}}, 800) < 0.03)
	testing.expect(t, effect_level(&f, {kind = .High_Pass, parameters = {1000, 0.7, 0}}, 10) < 0.03)
	testing.expect(t, effect_level(&f, {kind = .High_Pass, parameters = {1000, 0.7, 0}}, 800) > 0.3)
}

// An impulse comes back after the delay's time, at the wet level, and again at the feedback.
@(test)
a_delay_echoes :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{16384}
	sound := memory_sound(f.m, samples[:])
	bus := bus_create(f.m, {})
	bus_set_effect(f.m, bus, 0, &audio.Effect{kind = .Delay, parameters = {0.01, 0.5, 0.8}})
	play(f.m, sound, plain(), bus = bus)
	out: [1200]audio.Device_Frame
	render(f.m, out[:])
	testing.expect_value(t, out[0].x, 0.5)
	testing.expect_value(t, out[479].x, 0)
	testing.expect(t, close_to(out[480].x, 0.5 * 0.8))
	testing.expect(t, close_to(out[960].x, 0.5 * 0.8 * 0.5))
}

// A reverb's tail outlasts the sound, stays finite and dies away. Keeping the parameters' state keeps the tail.
@(test)
a_reverb_has_a_tail_that_dies :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := sine(4800, 100)
	sound := memory_sound(f.m, samples)
	bus := bus_create(f.m, {})
	bus_set_effect(f.m, bus, 0, &audio.Effect{kind = .Reverb, parameters = {0.5, 0.3, 0.5}})
	play(f.m, sound, plain(), bus = bus)
	out := make([]audio.Device_Frame, 4800, context.temp_allocator)
	render(f.m, out)
	render(f.m, out)
	early := level(out)
	testing.expect(t, early > 0.001)
	state := f.m.buses[bus.index].effects[0]
	bus_set_effect(f.m, bus, 0, &audio.Effect{kind = .Reverb, parameters = {0.5, 0.5, 0.5}})
	for _ in 0 ..< 20 {
		render(f.m, out)
		for frame in out {
			testing.expect(t, abs(frame.x) < 2 && abs(frame.y) < 2)
		}
	}
	testing.expect(t, f.m.buses[bus.index].effects[0] == state)
	testing.expect(t, level(out) < early * 0.01)
}

// No effect can run away, whatever goes in and whatever its parameters: a loud sound with every frequency in it, through
// the longest and darkest settings, stays under what the effect can add. An effect that feeds back more than it takes
// would play full scale until the game stops. A delay's bound is its comb filter's peak, 1 / (1 - feedback).
@(test)
effects_stay_bounded :: proc(t: ^testing.T) {
	Case :: struct {
		kind:       audio.Effect_Kind,
		parameters: [3]f32,
		bound:      f32,
	}
	cases := []Case {
		{.Reverb, {1.2, 0.4, 0.15}, 2},
		{.Reverb, {30, 0, 1}, 8},
		{.Reverb, {30, 1, 1}, 8},
		{.Reverb, {0.01, 0.5, 1}, 4},
		{.Delay, {0.001, 0.99, 1}, 101},
		{.Delay, {2, 0.99, 1}, 101},
		{.Low_Pass, {20000, 10, 0}, 16},
		{.High_Pass, {10, 10, 0}, 16},
	}
	for c in cases {
		f: Fixture
		setup(&f)
		defer teardown(&f)
		// Noise, of every frequency, at nearly full scale, for 1 second.
		noise := make([]i16, audio.SAMPLE_RATE, context.temp_allocator)
		state: u32 = 12345
		for &sample in noise {
			state = state * 1664525 + 1013904223
			sample = i16(state >> 16)
		}
		sound := memory_sound(f.m, noise)
		bus := bus_create(f.m, {})
		bus_set_effect(f.m, bus, 0, &audio.Effect{kind = c.kind, parameters = c.parameters})
		play(f.m, sound, plain(), bus = bus)
		// Before the limiter, which would hide it, so read the bus as it goes into Master.
		largest: f32
		SECONDS :: 12
		for _ in 0 ..< SECONDS * audio.SAMPLE_RATE / BLOCK_FRAMES {
			drain_commands(f.m)
			for &v, i in f.m.voices {
				if v.active {
					mix_voice(f.m, &v, i, BLOCK_FRAMES)
				}
			}
			frames := f.m.buses[bus.index].buffer[:]
			for effect in f.m.buses[bus.index].effects {
				if effect != nil {
					effect_process(effect, frames)
				}
			}
			for frame in frames {
				largest = max(largest, abs(frame.x), abs(frame.y))
			}
			slice.zero(frames)
		}
		testing.expectf(t, largest < c.bound, "%v %v reached %v", c.kind, c.parameters, largest)
	}
}

// mygame's reverb, on a loud sound: the tail is about as loud as the sound, and gone in about its decay time.
@(test)
a_reverb_tail_is_in_proportion :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	noise := make([]i16, audio.SAMPLE_RATE / 2, context.temp_allocator)
	state: u32 = 12345
	for &sample in noise {
		state = state * 1664525 + 1013904223
		sample = i16(state >> 16)
	}
	sound := memory_sound(f.m, noise)
	bus := bus_create(f.m, {})
	bus_set_effect(f.m, bus, 0, &audio.Effect{kind = .Reverb, parameters = {1.2, 0.4, 1}})
	play(f.m, sound, plain(), bus = bus)
	out := make([]audio.Device_Frame, audio.SAMPLE_RATE / 2, context.temp_allocator)
	render(f.m, out)
	loud := level(out)
	render(f.m, out[:4800])
	tail := level(out[:4800])
	testing.expectf(t, tail > 0.01 && tail < loud, "the tail is %v after a sound of %v", tail, loud)
	for _ in 0 ..< 4 {
		render(f.m, out)
	}
	testing.expectf(t, level(out) < tail * 0.01, "after 2 s, the tail is %v from %v", level(out), tail)
}

// A mix that is far out of range, or not a number, goes silent, and not to full scale. It clears the effects, so that it
// does not come back, and the next mix plays. update reports it.
@(test)
a_fault_goes_silent :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	// The error is expected. The host's logger is one per process, so another test's could take it.
	f.host.log = proc "c" (level: audio.Log_Level, message: cstring) {}
	samples := [?]i16{16384}
	sound := memory_sound(f.m, samples[:])
	bus := bus_create(f.m, {})
	bus_set_effect(f.m, bus, 0, &audio.Effect{kind = .Delay, parameters = {0.001, 0, 1}})
	wild := plain()
	wild.gain = math.inf_f32(1)
	voice := play(f.m, sound, wild, loop = true, bus = bus)
	out: [BLOCK_FRAMES]audio.Device_Frame
	render(f.m, out[:])
	for frame in out {
		testing.expect_value(t, frame, audio.Device_Frame{0, 0})
	}
	testing.expect(t, f.m.faults > 0)
	update(f.m)
	testing.expect_value(t, f.m.faults_seen, f.m.faults)

	voice_stop(f.m, voice, 0)
	render(f.m, out[:])
	sane := play(f.m, sound, plain(), loop = true)
	testing.expect(t, sane.generation != 0)
	render(f.m, out[:])
	render(f.m, out[:])
	testing.expect_value(t, out[len(out) - 1].x, 0.5)
}

// While paused, no voice advances and the output is silent. It picks up where it stopped, without a click.
@(test)
a_pause_holds_every_voice :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{16384}
	sound := memory_sound(f.m, samples[:])
	voice := play(f.m, sound, plain(), loop = true)
	out: [BLOCK_FRAMES]audio.Device_Frame
	render(f.m, out[:])
	testing.expect_value(t, out[len(out) - 1].x, 0.5)

	set_paused(f.m, true)
	render(f.m, out[:])
	testing.expect(t, out[0].x > 0.49)
	testing.expect_value(t, out[len(out) - 1].x, 0)
	cursor := f.m.voices[voice.index].cursor
	render(f.m, out[:])
	testing.expect_value(t, out[0].x, 0)
	testing.expect_value(t, f.m.voices[voice.index].cursor, cursor)

	set_paused(f.m, false)
	render(f.m, out[:])
	testing.expect(t, out[0].x < 0.01)
	testing.expect_value(t, out[len(out) - 1].x, 0.5)
	testing.expect(t, bool(voice_playing(f.m, voice)))
}

@(private = "file")
Stream_File :: struct {
	dir:  string,
	path: string,
}

// A file like a blob: a header that a stream's offset skips, then the samples.
@(private = "file")
write_stream_file :: proc(t: ^testing.T, samples: []i16) -> Stream_File {
	dir, err := os.make_directory_temp("", "audio_mixer_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	path := fmt.tprintf("%s/sound.blob", dir)
	data := make([]byte, 16 + len(samples) * size_of(i16), context.temp_allocator)
	copy(data[16:], slice.to_bytes(samples))
	testing.expect(t, os.write_entire_file(path, data) == nil)
	return {dir, path}
}

@(private = "file")
stream_sound :: proc(m: ^Mixer, file: Stream_File, frames: int, channels: u32 = 1) -> audio.Sound {
	return sound_create(m, &audio.Sound_Desc{frames = u64(frames), path = strings.clone_to_cstring(file.path, context.temp_allocator), offset = 16, channels = channels})
}

// A stream plays the same samples as a memory sound of them, over more than a ring's length, and ends.
@(test)
a_stream_matches_a_memory_sound :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	FRAMES :: 2 * STREAM_RING_FRAMES + 123
	samples := make([]i16, FRAMES * 2, context.temp_allocator)
	for &sample, i in samples {
		sample = i16(i * 7)
	}
	file := write_stream_file(t, samples)
	defer os.remove_all(file.dir)

	memory := memory_sound(f.m, samples, 2)
	streamed := stream_sound(f.m, file, FRAMES, 2)
	a := play(f.m, memory, plain())
	reference := make([]audio.Device_Frame, FRAMES + 2, context.temp_allocator)
	render(f.m, reference)
	testing.expect(t, !bool(voice_playing(f.m, a)))
	testing.expect_value(t, reference[FRAMES - 1], audio.Device_Frame{f32(samples[FRAMES * 2 - 2]) / 32768, f32(samples[FRAMES * 2 - 1]) / 32768})

	b := play(f.m, streamed, plain())
	out := make([]audio.Device_Frame, FRAMES + 2, context.temp_allocator)
	for start := 0; start < len(out); start += STREAM_CHUNK_FRAMES / 2 {
		stream_step(f.m)
		render(f.m, out[start:min(start + STREAM_CHUNK_FRAMES / 2, len(out))])
	}
	same := true
	for frame, i in out {
		same &&= frame == reference[i]
	}
	testing.expect(t, same)
	testing.expect(t, !bool(voice_playing(f.m, b)))
	stats_out: audio.Stats
	stats(f.m, &stats_out)
	testing.expect_value(t, stats_out.stream_starved, 0)
	stream_step(f.m)
	stats(f.m, &stats_out)
	testing.expect_value(t, stats_out.streams, 0)
}

// A looping stream wraps without a seam, even a sound shorter than a chunk.
@(test)
a_looping_stream_wraps :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := [?]i16{1000, 2000, 3000}
	file := write_stream_file(t, samples[:])
	defer os.remove_all(file.dir)
	sound := stream_sound(f.m, file, 3)
	voice := play(f.m, sound, plain(), loop = true)
	stream_step(f.m)
	out: [BLOCK_FRAMES + 2]audio.Device_Frame
	render(f.m, out[:])
	for frame, i in out {
		testing.expect_value(t, frame.x, f32(samples[i % 3]) / 32768)
	}
	testing.expect(t, bool(voice_playing(f.m, voice)))
}

// A voice waits for its first read, so it does not start with a gap, and a reader that falls behind counts.
@(test)
a_stream_waits_for_its_first_read_and_counts_starving :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := make([]i16, 2 * STREAM_RING_FRAMES, context.temp_allocator)
	for &sample in samples {
		sample = 16384
	}
	file := write_stream_file(t, samples)
	defer os.remove_all(file.dir)
	sound := stream_sound(f.m, file, len(samples))
	play(f.m, sound, plain())

	out := make([]audio.Device_Frame, STREAM_RING_FRAMES / 4, context.temp_allocator)
	render(f.m, out)
	testing.expect_value(t, out[0].x, 0)
	stats_out: audio.Stats
	stats(f.m, &stats_out)
	testing.expect_value(t, stats_out.stream_starved, 0)

	stream_step(f.m)
	render(f.m, out)
	testing.expect_value(t, out[0].x, 0.5)
	big := make([]audio.Device_Frame, STREAM_RING_FRAMES + 100, context.temp_allocator)
	render(f.m, big)
	stats(f.m, &stats_out)
	testing.expect(t, stats_out.stream_starved > 0)
}

// The reader closes the file after each read, so the cooker can replace it while it plays. The voice then ends, as what
// follows may not line up with what played, and the game restarts it.
@(test)
a_replaced_file_ends_its_voice :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f)
	defer teardown(&f)
	samples := make([]i16, 2 * STREAM_RING_FRAMES, context.temp_allocator)
	file := write_stream_file(t, samples)
	defer os.remove_all(file.dir)
	sound := stream_sound(f.m, file, len(samples))
	voice := play(f.m, sound, plain())
	stream_step(f.m)

	time.sleep(20 * time.Millisecond)
	temporary := fmt.tprintf("%s.tmp", file.path)
	testing.expect(t, os.write_entire_file(temporary, []byte{1, 2, 3}) == nil)
	testing.expect_value(t, os.rename(temporary, file.path), nil)

	out := make([]audio.Device_Frame, STREAM_CHUNK_FRAMES + 10, context.temp_allocator)
	render(f.m, out)
	stream_step(f.m)
	big := make([]audio.Device_Frame, STREAM_RING_FRAMES, context.temp_allocator)
	render(f.m, big)
	testing.expect(t, !bool(voice_playing(f.m, voice)))
}

// A file that went away ends the voice, and update reports it.
@(test)
a_missing_file_ends_its_voice :: proc(t: ^testing.T) {
	f: Fixture
	{
		context.logger = log.nil_logger()
		setup(&f)
	}
	defer teardown(&f)
	dir, err := os.make_directory_temp("", "audio_mixer_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	sound := stream_sound(f.m, {dir, fmt.tprintf("%s/gone.blob", dir)}, 100)
	voice := play(f.m, sound, plain())
	stream_step(f.m)
	out: [10]audio.Device_Frame
	render(f.m, out[:])
	testing.expect(t, !bool(voice_playing(f.m, voice)))
	testing.expect_value(t, f.m.stream_failed, 1)
	update(f.m)
	testing.expect_value(t, f.m.failed_seen, 1)
}

// A stream's voice past the pool of streams is refused, and a freed stream can play again.
@(test)
streams_are_limited :: proc(t: ^testing.T) {
	f: Fixture
	{
		context.logger = log.nil_logger()
		setup(&f)
	}
	defer teardown(&f)
	samples := [?]i16{1000, 2000, 3000}
	file := write_stream_file(t, samples[:])
	defer os.remove_all(file.dir)
	sound := stream_sound(f.m, file, 3)
	voices: [MAX_STREAMS]audio.Voice
	for &voice in voices {
		voice = play(f.m, sound, plain(), loop = true)
		testing.expect(t, voice.generation != 0)
	}
	testing.expect_value(t, play(f.m, sound, plain(), loop = true), audio.Voice{})
	testing.expect_value(t, f.m.voices_refused, 1)
	stream_step(f.m)
	voice_stop(f.m, voices[0], 0)
	out: [BLOCK_FRAMES]audio.Device_Frame
	render(f.m, out[:])
	stream_step(f.m)
	testing.expect(t, play(f.m, sound, plain(), loop = true).generation != 0)
}

// The whole table, with its threads, feeding a device that takes anything. It passes the suite, and shuts down clean.
@(test)
the_table_passes_conformance :: proc(t: ^testing.T) {
	sync.guard(&table_lock)
	{
		context.logger = log.nil_logger()
		table_host = audio_host.table(fake_write, fake_status)
	}
	api := load(&table_host)
	conformance.run(t, api)
	testing.expect(t, state.mix_thread != nil)
	api.shutdown()
	testing.expect(t, state.mix_thread == nil)
}

// A stream through the table, with its threads, reaches the device.
@(test)
the_threads_play_a_stream :: proc(t: ^testing.T) {
	sync.guard(&table_lock)
	sync.atomic_store(&device_peak, 0)
	{
		context.logger = log.nil_logger()
		table_host = audio_host.table(recording_write, fake_status)
	}
	samples := make([]i16, 48000, context.temp_allocator)
	for &sample in samples {
		sample = 16384
	}
	file := write_stream_file(t, samples)
	defer os.remove_all(file.dir)

	api := load(&table_host)
	defer api.shutdown()
	sound := api.sound_create(&audio.Sound_Desc{frames = 48000, path = strings.clone_to_cstring(file.path, context.temp_allocator), offset = 16, channels = 1})
	voice := api.voice_play(&audio.Voice_Desc{sound = sound, params = plain(), loop = true})
	testing.expect(t, bool(api.voice_playing(voice)))
	for _ in 0 ..< 2000 {
		if sync.atomic_load(&device_peak) >= 0.49 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&device_peak) >= 0.49)
	testing.expect_value(t, api.reset(), 1)
}

@(private = "file")
device_peak: f32

@(private = "file")
recording_write :: proc "c" (frames: [^]audio.Device_Frame, count: i32) -> i32 {
	peak := sync.atomic_load(&device_peak)
	for i in 0 ..< count {
		peak = max(peak, frames[i].x)
	}
	sync.atomic_store(&device_peak, peak)
	return count
}
