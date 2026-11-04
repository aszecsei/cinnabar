// Package audio_null is an audio backend that makes no sound. It checks every handle as a real backend does, so it runs
// the engine's tests of the boundary without a device or a thread, and it is the backend of a game with audio turned
// off. See docs/audio/backends.md#the-null-backend.
package audio_null

import "base:runtime"
import "core:fmt"
import "core:strings"

import audio "cinnabar:core/audio"

MAX_SOUNDS :: 4096
MAX_VOICES :: 256
MAX_BUSES :: 32

@(private)
Slot :: struct {
	generation: u32,
	alive:      bool,
}

// The host is one per process, so the backend's state is too. Slot 0 of the buses is Master.
@(private)
state: struct {
	host:           ^audio.Host,
	sounds:         [MAX_SOUNDS]Slot,
	voices:         [MAX_VOICES]Slot,
	buses:          [MAX_BUSES]Slot,
	voices_refused: u32,
}

// load gives the null backend's table.
load :: proc(host: ^audio.Host, name := "") -> ^audio.Audio_API {
	state.host = host
	state.buses[0] = {
		generation = audio.MASTER_BUS.generation,
		alive      = true,
	}
	return &api
}

@(private)
api := audio.Audio_API {
	info           = info,
	update         = update,
	sound_create   = sound_create,
	sound_destroy  = sound_destroy,
	voice_play     = voice_play,
	voice_set      = voice_set,
	voice_stop     = voice_stop,
	voice_playing  = voice_playing,
	bus_create     = bus_create,
	bus_set_gain   = bus_set_gain,
	bus_set_effect = bus_set_effect,
	set_paused     = set_paused,
	stats          = stats,
	reset          = reset,
	shutdown       = shutdown,
}

@(private)
report :: proc(level: audio.Log_Level, format: string, args: ..any) {
	message := fmt.tprintf(format, ..args)
	state.host.log(level, strings.clone_to_cstring(message, context.temp_allocator))
}

@(private)
info :: proc "c" () -> audio.Backend_Info {
	return {
		api_version = audio.API_VERSION,
		features = {.Spatial, .Streaming, .Buses, .Effects},
		layout = audio.layout_signature(),
		name = "null",
		version = "1",
	}
}

@(private)
take :: proc "contextless" (slots: []Slot) -> (index: u32, generation: u32, ok: bool) {
	for &slot, i in slots {
		if !slot.alive {
			slot.alive = true
			slot.generation += 1
			return u32(i), slot.generation, true
		}
	}
	return
}

@(private)
find :: proc "contextless" (slots: []Slot, handle: audio.Handle) -> ^Slot {
	if handle.generation == 0 || int(handle.index) >= len(slots) {
		return nil
	}
	slot := &slots[handle.index]
	return slot if slot.alive && slot.generation == handle.generation else nil
}

@(private)
update :: proc "c" () {}

@(private)
sound_create :: proc "c" (desc: ^audio.Sound_Desc) -> audio.Sound {
	context = runtime.default_context()
	if desc == nil || (desc.channels != 1 && desc.channels != 2) || (desc.samples == nil && desc.path == nil) {
		report(.Error, "audio: null: sound_create: invalid description")
		return {}
	}
	index, generation, ok := take(state.sounds[:])
	if !ok {
		report(.Error, "audio: null: sound_create: the pool is full")
		return {}
	}
	return {index, generation}
}

@(private)
sound_destroy :: proc "c" (sound: audio.Sound) {
	context = runtime.default_context()
	slot := find(state.sounds[:], audio.Handle(sound))
	if slot == nil {
		report(.Warning, "audio: null: sound_destroy: stale sound %v", sound)
		return
	}
	slot.alive = false
}

@(private)
voice_play :: proc "c" (desc: ^audio.Voice_Desc) -> audio.Voice {
	context = runtime.default_context()
	if desc == nil || find(state.sounds[:], audio.Handle(desc.sound)) == nil {
		report(.Warning, "audio: null: voice_play: stale sound")
		return {}
	}
	bus := desc.bus if desc.bus != {} else audio.MASTER_BUS
	if find(state.buses[:], audio.Handle(bus)) == nil {
		report(.Warning, "audio: null: voice_play: stale bus %v", bus)
		return {}
	}
	index, generation, ok := take(state.voices[:])
	if !ok {
		if state.voices_refused == 0 {
			report(.Warning, "audio: null: voice_play: the pool is full")
		}
		state.voices_refused += 1
		return {}
	}
	return {index, generation}
}

@(private)
voice_set :: proc "c" (voice: audio.Voice, params: ^audio.Voice_Params) {
	context = runtime.default_context()
	if params == nil || find(state.voices[:], audio.Handle(voice)) == nil {
		report(.Warning, "audio: null: voice_set: stale voice %v", voice)
	}
}

@(private)
voice_stop :: proc "c" (voice: audio.Voice, fade: f32) {
	context = runtime.default_context()
	slot := find(state.voices[:], audio.Handle(voice))
	if slot == nil {
		report(.Warning, "audio: null: voice_stop: stale voice %v", voice)
		return
	}
	slot.alive = false
}

@(private)
voice_playing :: proc "c" (voice: audio.Voice) -> b32 {
	return find(state.voices[:], audio.Handle(voice)) != nil
}

@(private)
bus_create :: proc "c" (name: cstring, parent: audio.Bus) -> audio.Bus {
	context = runtime.default_context()
	parent := parent if parent != {} else audio.MASTER_BUS
	if find(state.buses[:], audio.Handle(parent)) == nil {
		report(.Warning, "audio: null: bus_create: stale parent %v", parent)
		return {}
	}
	index, generation, ok := take(state.buses[:])
	if !ok {
		report(.Error, "audio: null: bus_create: the pool is full")
		return {}
	}
	return {index, generation}
}

@(private)
bus_set_gain :: proc "c" (bus: audio.Bus, gain: f32) {
	context = runtime.default_context()
	if find(state.buses[:], audio.Handle(bus)) == nil {
		report(.Warning, "audio: null: bus_set_gain: stale bus %v", bus)
	}
}

@(private)
bus_set_effect :: proc "c" (bus: audio.Bus, slot: u32, effect: ^audio.Effect) {
	context = runtime.default_context()
	if find(state.buses[:], audio.Handle(bus)) == nil || slot >= audio.MAX_BUS_EFFECTS || effect == nil {
		report(.Warning, "audio: null: bus_set_effect: invalid bus %v or slot %d", bus, slot)
	}
}

@(private)
set_paused :: proc "c" (paused: b32) {}

@(private)
count_alive :: proc "contextless" (slots: []Slot) -> (count: u32) {
	for slot in slots {
		if slot.alive {
			count += 1
		}
	}
	return
}

@(private)
stats :: proc "c" (out: ^audio.Stats) {
	out^ = {
		voices         = count_alive(state.voices[:]),
		sounds         = count_alive(state.sounds[:]),
		voices_refused = state.voices_refused,
	}
}

@(private)
reset :: proc "c" () -> i32 {
	count := i32(count_alive(state.voices[:]))
	for &slot in state.voices {
		slot.alive = false
	}
	for &slot in state.sounds {
		slot.alive = false
	}
	for &slot in state.buses[1:] {
		slot.alive = false
	}
	return count
}

@(private)
shutdown :: proc "c" () {
	reset()
}
