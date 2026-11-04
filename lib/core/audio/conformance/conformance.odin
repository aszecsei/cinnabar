// Package audio_conformance is the suite that every backend passes, driven through Audio_API with no engine world. A
// backend's tests call each procedure with its table. See docs/audio/backends.md#conformance.
package audio_conformance

import "core:testing"

import audio "cinnabar:core/audio"

@(private)
SAMPLES := [8]i16{0, 100, 200, 300, 400, 500, 600, 700}

@(private)
sound :: proc(api: ^audio.Audio_API) -> audio.Sound {
	return api.sound_create(&audio.Sound_Desc{frames = len(SAMPLES), samples = &SAMPLES[0], channels = 1})
}

@(private)
params :: proc() -> audio.Voice_Params {
	return {gain = 1, pitch = 1, min_distance = 1, max_distance = 10}
}

// info reports this boundary's version and layout, and names the backend.
info :: proc(t: ^testing.T, api: ^audio.Audio_API) {
	backend := api.info()
	testing.expect_value(t, backend.api_version, audio.API_VERSION)
	testing.expect_value(t, backend.layout, audio.layout_signature())
	testing.expect(t, backend.name != nil && backend.version != nil)
}

// a_looping_voice_plays_until_stopped: a stop makes the handle stale at once, whatever the fade.
a_looping_voice_plays_until_stopped :: proc(t: ^testing.T, api: ^audio.Audio_API) {
	s := sound(api)
	testing.expect(t, s.generation != 0)
	voice := api.voice_play(&audio.Voice_Desc{sound = s, params = params(), loop = true})
	testing.expect(t, voice.generation != 0)
	testing.expect(t, bool(api.voice_playing(voice)))
	next := params()
	next.gain = 0.5
	api.voice_set(voice, &next)
	api.update()
	testing.expect(t, bool(api.voice_playing(voice)))
	api.voice_stop(voice, 0.1)
	testing.expect(t, !bool(api.voice_playing(voice)))
	api.sound_destroy(s)
	api.update()
}

// stale_handles_do_nothing: no call on a stale or nil handle takes effect or fails.
stale_handles_do_nothing :: proc(t: ^testing.T, api: ^audio.Audio_API) {
	s := sound(api)
	voice := api.voice_play(&audio.Voice_Desc{sound = s, params = params(), loop = true})
	api.voice_stop(voice, 0)
	next := params()
	api.voice_set(voice, &next)
	api.voice_stop(voice, 0)
	testing.expect(t, !bool(api.voice_playing(voice)))
	testing.expect(t, !bool(api.voice_playing({})))

	api.sound_destroy(s)
	api.sound_destroy(s)
	testing.expect_value(t, api.voice_play(&audio.Voice_Desc{sound = s, params = params()}), audio.Voice{})
	testing.expect_value(t, api.voice_play(&audio.Voice_Desc{params = params()}), audio.Voice{})
	api.bus_set_gain({30, 99}, 1)
	api.update()
}

// a_destroyed_sound_keeps_its_voices: a voice goes on until it ends, though its sound's handle is stale.
a_destroyed_sound_keeps_its_voices :: proc(t: ^testing.T, api: ^audio.Audio_API) {
	s := sound(api)
	voice := api.voice_play(&audio.Voice_Desc{sound = s, params = params(), loop = true})
	api.sound_destroy(s)
	api.update()
	testing.expect(t, bool(api.voice_playing(voice)))
	api.voice_stop(voice, 0)
	api.update()
}

// buses_nest: a bus takes a parent, a voice takes a bus, and a bus has effect slots.
buses_nest :: proc(t: ^testing.T, api: ^audio.Audio_API) {
	music := api.bus_create("music", {})
	testing.expect(t, music.generation != 0)
	child := api.bus_create("child", music)
	testing.expect(t, child.generation != 0)
	api.bus_set_gain(child, 0.5)
	api.bus_set_gain(audio.MASTER_BUS, 1)
	api.bus_set_effect(child, 0, &audio.Effect{kind = .Low_Pass, parameters = {1000, 0.7, 0}})
	api.bus_set_effect(child, 0, &audio.Effect{kind = .None})
	s := sound(api)
	voice := api.voice_play(&audio.Voice_Desc{sound = s, bus = child, params = params(), loop = true})
	testing.expect(t, bool(api.voice_playing(voice)))
	testing.expect_value(t, api.bus_create("orphan", {31, 99}), audio.Bus{})
	api.reset()
}

// reset_leaves_nothing: every voice, sound and bus but Master goes, and the backend works after it.
reset_leaves_nothing :: proc(t: ^testing.T, api: ^audio.Audio_API) {
	s := sound(api)
	bus := api.bus_create("gone", {})
	voice := api.voice_play(&audio.Voice_Desc{sound = s, bus = bus, params = params(), loop = true})
	testing.expect_value(t, api.reset(), 1)
	testing.expect(t, !bool(api.voice_playing(voice)))
	testing.expect_value(t, api.voice_play(&audio.Voice_Desc{sound = s, params = params()}), audio.Voice{})

	stats: audio.Stats
	api.stats(&stats)
	testing.expect_value(t, stats.voices, 0)
	testing.expect_value(t, stats.sounds, 0)

	again := sound(api)
	testing.expect_value(t, api.voice_play(&audio.Voice_Desc{sound = again, bus = bus, params = params()}), audio.Voice{})
	testing.expect(t, bool(api.voice_playing(api.voice_play(&audio.Voice_Desc{sound = again, params = params(), loop = true}))))
	testing.expect_value(t, api.reset(), 1)
}

// a_full_pool_refuses: a voice past the pool's size is the nil voice, and the others go on.
a_full_pool_refuses :: proc(t: ^testing.T, api: ^audio.Audio_API) {
	s := sound(api)
	first := api.voice_play(&audio.Voice_Desc{sound = s, params = params(), loop = true})
	refused := false
	for _ in 0 ..< 4096 {
		if api.voice_play(&audio.Voice_Desc{sound = s, params = params(), loop = true}) == {} {
			refused = true
			break
		}
	}
	testing.expect(t, refused)
	testing.expect(t, bool(api.voice_playing(first)))
	stats: audio.Stats
	api.stats(&stats)
	testing.expect(t, stats.voices_refused > 0)
	api.reset()
}

// run runs the whole suite.
run :: proc(t: ^testing.T, api: ^audio.Audio_API) {
	info(t, api)
	a_looping_voice_plays_until_stopped(t, api)
	stale_handles_do_nothing(t, api)
	a_destroyed_sound_keeps_its_voices(t, api)
	buses_nest(t, api)
	reset_leaves_nothing(t, api)
	a_full_pool_refuses(t, api)
	api.reset()
}
