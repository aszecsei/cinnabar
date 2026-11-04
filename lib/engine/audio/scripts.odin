package audio

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The Audio library that scripts see (see docs/audio/design.md#scripts).

@(private = "file")
REGISTRY_KEY :: "cinnabar.audio"

// register_scripts defines the Audio library, which reaches s, and exposes Audio_Source and Audio_Listener. A game's
// Register_Proc calls it, so init and every reload define them again.
register_scripts :: proc(r: ^script.Runtime, s: ^State) {
	luau.pushlightuserdata(r.L, s)
	luau.setfield(r.L, luau.REGISTRYINDEX, REGISTRY_KEY)
	script.expose(r, Audio_Source, DEFAULT_AUDIO_SOURCE)
	script.expose(r, Audio_Listener)
	script.define(r, "Audio.play", play_binding, "(sound: Asset, position: WorldPosition?, gain: number?, bus: string?) -> ()")
	script.define(r, "Audio.set_bus_gain", set_bus_gain_binding, "(bus: string, gain: number) -> ()")
}

@(private = "file")
state_of :: proc(L: ^luau.State) -> ^State {
	luau.getfield(L, luau.REGISTRYINDEX, REGISTRY_KEY)
	s := (^State)(luau.touserdata(L, -1))
	luau.pop(L, 1)
	return s
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
	play(s, sound, position, gain, bus)
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
