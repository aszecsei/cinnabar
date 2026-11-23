package audio

import "core:c"
import "core:fmt"

import boundary "cinnabar:core/audio"
import "cinnabar:core/luau"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The Audio library that scripts see (see docs/audio/design.md#scripts).

@(private = "file")
REGISTRY_KEY :: "cinnabar.audio"

// register_scripts defines the Audio library, which reaches s, and exposes Audio_Source and Audio_Listener. A game's
// Register_Proc calls it, so init and every reload define them again.
register_scripts :: proc(r: ^script.Runtime, s: ^State) {
	script.set_registry_pointer(r, REGISTRY_KEY, s)
	script.expose(r, Audio_Source, DEFAULT_AUDIO_SOURCE)
	script.expose(r, Audio_Listener)
	script.define(
		r,
		"Audio.play",
		play_binding,
		"(sound: Asset, position: WorldPosition?, gain: number?, bus: string?, pitch: number?, start: number?) -> ()",
	)
	script.define(
		r,
		"Audio.set_bus_gain",
		set_bus_gain_binding,
		"(bus: string, gain: number) -> ()",
	)
	script.define(
		r,
		"Audio.duck",
		duck_binding,
		"(bus: string, target: string, gain: number, attack: number?, release: number?, threshold: number?) -> ()",
	)
}

@(private = "file")
state_of :: proc(L: ^luau.State) -> ^State {
	return script.registry_pointer(L, REGISTRY_KEY, State)
}

// A bus by name, which must be Master or one of the project's.
@(private = "file")
check_bus :: proc(L: ^luau.State, s: ^State, idx: c.int) -> int {
	name := string(luau.L_checkstring(L, idx))
	index, ok := bus_index(s, name)
	if !ok {
		script.raise(L, fmt.tprintf("there is no bus %q: audio.buses names the project's", name))
	}
	return index
}

@(private = "file")
play_binding :: proc(L: ^luau.State) -> c.int {
	s, r := state_of(L), script.runtime_of(L)
	sound := script.to_asset(r, L, 1)
	if sound == {} {
		script.raise(L, "Audio.play takes a sound: an asset from Field.asset(\"audio\")")
	}
	position: Maybe(ecs.World_Position)
	if !luau.isnoneornil(L, 2) {
		position = script.check_position(L, 2)
	}
	gain := f32(luau.L_optnumber(L, 3, 1))
	bus := 0
	if !luau.isnoneornil(L, 4) {
		bus = check_bus(L, s, 4)
	}
	pitch := f32(luau.L_optnumber(L, 5, 1))
	start := f64(luau.L_optnumber(L, 6, 0))
	play(s, sound, position, gain, bus, pitch, start)
	return 0
}

// The duck's times and threshold when a script leaves them out: 50 ms to fall, 300 ms to come back, and any sound above
// about -50 dB.
@(private = "file")
DUCK_ATTACK :: 0.05
@(private = "file")
DUCK_RELEASE :: 0.3
@(private = "file")
DUCK_THRESHOLD :: 0.003

@(private = "file")
duck_binding :: proc(L: ^luau.State) -> c.int {
	s := state_of(L)
	from := check_bus(L, s, 1)
	to := check_bus(L, s, 2)
	duck := boundary.Duck {
		gain      = f32(luau.L_checknumber(L, 3)),
		attack    = f32(luau.L_optnumber(L, 4, DUCK_ATTACK)),
		release   = f32(luau.L_optnumber(L, 5, DUCK_RELEASE)),
		threshold = f32(luau.L_optnumber(L, 6, DUCK_THRESHOLD)),
	}
	if from == to {
		script.raise(L, "Audio.duck takes two different buses")
	}
	s.platform.audio.bus_set_duck(bus_handle(s, from), bus_handle(s, to), &duck)
	return 0
}

@(private = "file")
set_bus_gain_binding :: proc(L: ^luau.State) -> c.int {
	s := state_of(L)
	name := string(luau.L_checkstring(L, 1))
	if !set_bus_gain(s, name, f32(luau.L_checknumber(L, 2))) {
		script.raise(L, fmt.tprintf("there is no bus %q: audio.buses names the project's", name))
	}
	return 0
}
