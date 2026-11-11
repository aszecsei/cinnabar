// Package audio is the game's side of the audio system: the Audio_Source and Audio_Listener components, sounds by asset,
// spatial sound from presented poses, occlusion by physics rays, and the Audio library that scripts see. The mixing is
// the backend's, behind Platform_API.audio. See docs/audio/design.md#the-game-side.
//
// Tone, in tone.odin, writes to the device itself. It is for testing the device, and a game runs it or this, not both,
// as the device takes one writer (see docs/core/audio.md#test-tone).
package audio

import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import "core:time"

import "cinnabar:core"
import boundary "cinnabar:core/audio"
import "cinnabar:core/audio/codec"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"

// The most sounds that a game has made at once. A source past it does not play, and logs once.
MAX_SOUNDS :: 256
// The most Audio_Sources that play at once.
MAX_SOURCES :: 256
// The most sounds that a frame's scripts play, and that are playing from Audio.play at once.
MAX_ONE_SHOTS :: 64
// How many occlusion rays a frame casts, in turn over the sources: enough to follow a moving source without a ray for each
// source each frame.
OCCLUSION_RAYS :: 8
// How long a voice takes to follow a change of occlusion, in seconds, so that a source does not jump behind a wall.
OCCLUSION_SMOOTHING :: 0.1
// The fade of a source that stops or goes away, in seconds, so that it does not click.
STOP_FADE :: 0.03
// The distances of a sound from Audio.play, in meters.
ONE_SHOT_MIN_DISTANCE :: 1
ONE_SHOT_MAX_DISTANCE :: 50

@(private)
Sound_Slot :: struct {
	guid:       format.Guid,
	// The nil sound for one that would not load, until its blob changes.
	handle:     boundary.Sound,
	// The blob's time when it was read.
	modified:   i64,
	// Grows with each new version of the blob. A source that started an older one starts again.
	version:    u32,
}

// Source_Slot is a playing Audio_Source's voice. update_sources claims a slot for a source that starts to play, and frees
// it when the source has no voice and is not playing: its sound ended, it was stopped, or its entity went.
@(private)
Source_Slot :: struct {
	used:      bool,
	entity:    ecs.Entity,
	voice:     boundary.Voice,
	guid:      format.Guid,
	version:   u32,
	// Whether the entity had a source this frame.
	seen:      bool,
	// What the last ray found, and where the voice is on its way there.
	blocked:   bool,
	occlusion: f32,
}

@(private)
One_Shot :: struct {
	guid:     format.Guid,
	position: ecs.World_Position,
	spatial:  bool,
	gain:     f32,
	bus:      int,
	voice:    boundary.Voice,
	// Fixed at the start: a short sound does not earn a ray each frame.
	occluded: f32,
}

// State is in Game_State. Its sounds, voices and buses are the backend's, and only their handles are here, so a code
// reload keeps them all. A soft restart stops them (see docs/audio/design.md#lifetimes).
State :: struct {
	platform:        ^core.Platform_API,
	assets:          ^asset.Assets,
	features:        boundary.Features,
	sounds:          [MAX_SOUNDS]Sound_Slot,
	sound_count:     int,
	// The next sound whose blob update looks at.
	sound_cursor:    int,
	sources:         [MAX_SOURCES]Source_Slot,
	occlusion_cursor: int,
	one_shots:       [MAX_ONE_SHOTS]One_Shot,
	one_shot_count:  int,
	buses:           [MAX_BUSES]boundary.Bus,
	bus_names:       Bus_Names,
	paused:          bool,
	// The warnings given, each once.
	warned:          bit_set[Warning],
}

// Warning is a warning that the audio gives once: a spatial source with no listener, and each of the limits.
@(private)
Warning :: enum {
	No_Listener,
	Sounds,
	Sources,
	One_Shots,
}

// The most buses that a project names, besides Master.
MAX_BUSES :: 16
MAX_BUS_NAME :: 31

// Bus_Names are the buses that the project's audio.buses names, in order. An Audio_Source's bus is 0 for Master, and
// otherwise one more than an index into these.
Bus_Names :: struct {
	count:   int,
	lengths: [MAX_BUSES]u8,
	names:   [MAX_BUSES][MAX_BUS_NAME]u8,
}

// add_bus_name appends a bus. It returns false when the name is empty, too long, Master, taken, or past MAX_BUSES.
add_bus_name :: proc(names: ^Bus_Names, name: string) -> bool {
	if name == "" || len(name) > MAX_BUS_NAME || name == MASTER_NAME || names.count >= MAX_BUSES {
		return false
	}
	for i in 0 ..< names.count {
		if bus_name(names, i) == name {
			return false
		}
	}
	copy(names.names[names.count][:], name)
	names.lengths[names.count] = u8(len(name))
	names.count += 1
	return true
}

bus_name :: proc(names: ^Bus_Names, index: int) -> string {
	return string(names.names[index][:names.lengths[index]])
}

// The name of the bus that every backend has.
MASTER_NAME :: "Master"

// init takes the assets that sounds load from. It starts nothing: the backend's threads wait for the first voice.
init :: proc(s: ^State, platform: ^core.Platform_API, assets: ^asset.Assets) {
	s^ = {
		platform = platform,
		assets   = assets,
		features = platform.audio.info().features,
	}
}

// reload takes the new Platform_API after a code reload. The voices keep playing.
reload :: proc(s: ^State, platform: ^core.Platform_API) {
	s.platform = platform
}

// destroy stops what the game plays, and reports how it went.
destroy :: proc(s: ^State) {
	api := &s.platform.audio
	for &source in s.sources {
		if source.voice != {} {
			api.voice_stop(source.voice, STOP_FADE)
		}
	}
	for &shot in s.one_shots[:s.one_shot_count] {
		if shot.voice != {} {
			api.voice_stop(shot.voice, STOP_FADE)
		}
	}
	for &sound in s.sounds[:s.sound_count] {
		if sound.handle != {} {
			api.sound_destroy(sound.handle)
		}
	}
	stats: boundary.Stats
	api.stats(&stats)
	if stats.frames_mixed > 0 {
		log.infof("audio: mixed %d frames, with %d frames of streams starved and %d voices refused", stats.frames_mixed, stats.stream_starved, stats.voices_refused)
	}
}

// set_buses makes the buses that the project names and that do not exist yet. A bus that the project stops naming stays
// until a soft restart, as it may have voices in it.
set_buses :: proc(s: ^State, names: Bus_Names) {
	names := names
	old := s.buses
	old_names := s.bus_names
	s.bus_names = names
	s.buses = {}
	for i in 0 ..< names.count {
		name := bus_name(&names, i)
		for j in 0 ..< old_names.count {
			if bus_name(&old_names, j) == name {
				s.buses[i] = old[j]
			}
		}
		if s.buses[i] == {} {
			s.buses[i] = s.platform.audio.bus_create(strings.clone_to_cstring(name, s.platform.frame_allocator), {})
		}
	}
}

// bus_index is the index that an Audio_Source's bus field holds for a name.
bus_index :: proc(s: ^State, name: string) -> (index: int, ok: bool) {
	if name == MASTER_NAME {
		return 0, true
	}
	for i in 0 ..< s.bus_names.count {
		if bus_name(&s.bus_names, i) == name {
			return i + 1, true
		}
	}
	return 0, false
}

// The bus's handle, or Master's for an index that the project does not name.
@(private)
bus_handle :: proc(s: ^State, index: int) -> boundary.Bus {
	if index >= 1 && index <= s.bus_names.count {
		return s.buses[index - 1]
	}
	return boundary.MASTER_BUS
}

// set_bus_gain sets a bus's gain by name. It returns false for a name that the project does not give.
set_bus_gain :: proc(s: ^State, name: string, gain: f32) -> bool {
	index := bus_index(s, name) or_return
	s.platform.audio.bus_set_gain(bus_handle(s, index), gain)
	return true
}

// set_bus_effect puts an effect in a slot of a bus by name. It returns false for a name that the project does not give.
set_bus_effect :: proc(s: ^State, name: string, slot: int, effect: boundary.Effect) -> bool {
	index := bus_index(s, name) or_return
	effect := effect
	s.platform.audio.bus_set_effect(bus_handle(s, index), u32(slot), &effect)
	return true
}

// play queues a sound for this frame's update, at a position if it has one, and returns false if the frame has queued
// too many. The sound plays once, to its end. Call it from the frame's code or its scripts.
play :: proc(s: ^State, sound: format.Guid, position: Maybe(ecs.World_Position) = nil, gain: f32 = 1, bus := 0) -> bool {
	if s.one_shot_count >= MAX_ONE_SHOTS {
		if .One_Shots not_in s.warned {
			s.warned += {.One_Shots}
			log.warnf("audio: more than %d sounds from play at once, so a sound does not play", MAX_ONE_SHOTS)
		}
		return false
	}
	at, spatial := position.?
	s.one_shots[s.one_shot_count] = {
		guid     = sound,
		position = at,
		spatial  = spatial,
		gain     = gain,
		bus      = bus,
	}
	s.one_shot_count += 1
	return true
}

// The listener's pose this frame, once update has found it.
@(private)
Listener :: struct {
	entity: ecs.Entity,
	pose:   ecs.Transform,
	found:  bool,
}

// update does a frame's work: it follows the world's sources and listener, and starts what scripts asked for. Call it
// once per frame after the world's Late stage, where render extraction reads the world, and whether the world runs or
// not (see docs/world/render-extraction.md#render-extraction). run is whether the world runs: while it does not, as in
// the editor's edit mode, voices hold and none start. physics may be nil, which means that nothing occludes.
update :: proc(s: ^State, w: ^ecs.World, ph: ^physics.State, run: bool, dt: time.Duration) {
	api := &s.platform.audio
	api.update()
	if s.paused == run {
		s.paused = !run
		api.set_paused(b32(!run))
	}
	check_blobs(s)
	listener := find_listener(s, w)
	update_sources(s, w, ph, listener, run, f32(time.duration_seconds(dt)))
	update_one_shots(s, w, ph, listener, run)
}

@(private)
find_listener :: proc(s: ^State, w: ^ecs.World) -> (listener: Listener) {
	entities := make([dynamic]ecs.Entity, s.platform.frame_allocator)
	ecs.collect(w, {AUDIO_LISTENER_ID}, &entities)
	for e in entities {
		if pose, ok := ecs.presented(w, e); ok {
			return {e, pose, true}
		}
	}
	return
}

// listener_space is a world position in the listener's axes, in meters: the listener is at the origin, X is to its right
// and Y is up. Differences of World_Positions are exact, so this stays good far from the origin.
@(private)
listener_space :: proc(listener: Listener, position: ecs.World_Position) -> [3]f32 {
	return linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(listener.pose.rotation), ecs.position_sub(position, listener.pose.position))
}

// is_blocked casts a ray from the listener to the source. The source's and the listener's own bodies do not count.
@(private)
is_blocked :: proc(w: ^ecs.World, ph: ^physics.State, listener: Listener, entity: ecs.Entity, position: ecs.World_Position) -> bool {
	if ph == nil || !listener.found {
		return false
	}
	delta := ecs.position_sub(position, listener.pose.position)
	distance := linalg.length(delta)
	if distance < 0.001 {
		return false
	}
	ignore := [?]ecs.Entity{entity, listener.entity}
	filter := physics.FILTER_ALL
	filter.ignore = ignore[:]
	_, hit := physics.raycast(ph, w, listener.pose.position, delta, distance, filter)
	return hit
}

@(private)
update_sources :: proc(s: ^State, w: ^ecs.World, ph: ^physics.State, listener: Listener, run: bool, dt: f32) {
	api := &s.platform.audio
	entities := make([dynamic]ecs.Entity, s.platform.frame_allocator)
	ecs.collect(w, {AUDIO_SOURCE_ID}, &entities)
	by_entity := make(map[ecs.Entity]int, len(s.sources), s.platform.frame_allocator)
	for &slot, i in s.sources {
		slot.seen = false
		if slot.used {
			by_entity[slot.entity] = i
		}
	}
	for e in entities {
		source := ecs.get(w, e, Audio_Source)
		index, tracked := by_entity[e]
		if !tracked {
			if !run || !source.playing || source.sound == {} {
				continue
			}
			index = free_source(s)
			if index < 0 {
				continue
			}
			s.sources[index] = {
				used   = true,
				entity = e,
			}
		}
		slot := &s.sources[index]
		ended := follow_source(s, w, ph, listener, slot, e, source^, run)
		// A slot with no voice whose source does not play, or whose sound just ended, is free for another source.
		if ended || (slot.voice == {} && !source.playing) {
			slot^ = {}
		} else {
			slot.seen = true
		}
	}
	// What is left had its entity despawned or disabled, or its component removed.
	for &slot in s.sources {
		if slot.used && !slot.seen {
			if slot.voice != {} {
				api.voice_stop(slot.voice, STOP_FADE)
			}
			slot = {}
		}
	}
	update_occlusion(s, w, ph, listener, dt)
}

@(private)
free_source :: proc(s: ^State) -> int {
	for &slot, i in s.sources {
		if !slot.used {
			return i
		}
	}
	if .Sources not_in s.warned {
		s.warned += {.Sources}
		log.warnf("audio: more than %d Audio_Sources at once, so a source does not play", MAX_SOURCES)
	}
	return -1
}

// follow_source brings a source's voice in line with its component: stopped, started again for a new sound, or moved.
// ended is true when a sound that does not loop ended, which clears the component's playing. update_sources then frees
// the slot, as it does for any slot with no voice whose source does not play; a source that plays again later takes a
// slot as a new one does. A source that plays but has no voice yet, as while its sound is cooked or the world does not
// run, keeps its slot.
@(private)
follow_source :: proc(s: ^State, w: ^ecs.World, ph: ^physics.State, listener: Listener, slot: ^Source_Slot, e: ecs.Entity, source: Audio_Source, run: bool) -> (ended: bool) {
	api := &s.platform.audio
	sound := find_sound(s, source.sound)
	if slot.voice != {} {
		stale := !source.playing || source.sound != slot.guid || (sound != nil && sound.version != slot.version)
		if stale {
			api.voice_stop(slot.voice, STOP_FADE)
			slot.voice = {}
		} else if run && !api.voice_playing(slot.voice) {
			// It ended. A looping voice ends only when its stream's file changed, and starts again below.
			slot.voice = {}
			if !source.loop {
				if written := ecs.get_write(w, e, Audio_Source); written != nil {
					written.playing = false
				}
				return true
			}
		}
	}
	pose, has_pose := ecs.presented(w, e)
	if !has_pose {
		return
	}
	spatial := source.spatial && listener.found
	if source.spatial && !listener.found && .No_Listener not_in s.warned {
		s.warned += {.No_Listener}
		log.warn("audio: a spatial Audio_Source plays with no Audio_Listener in the world, so it plays centred at full gain")
	}
	params := boundary.Voice_Params {
		gain         = source.gain,
		pitch        = source.pitch,
		min_distance = source.min_distance,
		max_distance = source.max_distance,
		occlusion    = slot.occlusion,
		spatial      = b32(spatial),
	}
	if spatial {
		params.position = listener_space(listener, pose.position)
	}
	if slot.voice != {} {
		api.voice_set(slot.voice, &params)
		return
	}
	if !run || !source.playing || sound == nil || sound.handle == {} {
		return
	}
	// A voice starts with its occlusion, rather than fade into it from nothing.
	slot.blocked = spatial && source.occluded && is_blocked(w, ph, listener, e, pose.position)
	slot.occlusion = 1 if slot.blocked else 0
	params.occlusion = slot.occlusion
	slot.guid = source.sound
	slot.version = sound.version
	slot.voice = api.voice_play(&boundary.Voice_Desc{sound = sound.handle, bus = bus_handle(s, int(source.bus)), params = params, loop = b32(source.loop)})
	return
}

// update_occlusion casts a few rays, in turn over the sources, and moves each source's occlusion toward what its last
// ray found. The value reaches the voice in the next frame's voice_set.
@(private)
update_occlusion :: proc(s: ^State, w: ^ecs.World, ph: ^physics.State, listener: Listener, dt: f32) {
	rays := 0
	for _ in 0 ..< MAX_SOURCES {
		if rays >= OCCLUSION_RAYS {
			break
		}
		s.occlusion_cursor = (s.occlusion_cursor + 1) % MAX_SOURCES
		slot := &s.sources[s.occlusion_cursor]
		if !slot.used || slot.voice == {} {
			continue
		}
		source := ecs.get(w, slot.entity, Audio_Source)
		if source == nil || !source.occluded || !source.spatial {
			slot.blocked = false
			continue
		}
		if pose, ok := ecs.presented(w, slot.entity); ok {
			slot.blocked = is_blocked(w, ph, listener, slot.entity, pose.position)
			rays += 1
		}
	}
	step := clamp(dt / OCCLUSION_SMOOTHING, 0, 1)
	for &slot in s.sources {
		if slot.used {
			target: f32 = 1 if slot.blocked else 0
			slot.occlusion += (target - slot.occlusion) * step
		}
	}
}

// update_one_shots starts what play queued, and moves what plays as the listener moves. Finished ones go, keeping the
// others in order.
@(private)
update_one_shots :: proc(s: ^State, w: ^ecs.World, ph: ^physics.State, listener: Listener, run: bool) {
	api := &s.platform.audio
	kept := 0
	for i in 0 ..< s.one_shot_count {
		shot := s.one_shots[i]
		params := boundary.Voice_Params {
			gain         = shot.gain,
			pitch        = 1,
			min_distance = ONE_SHOT_MIN_DISTANCE,
			max_distance = ONE_SHOT_MAX_DISTANCE,
			spatial      = b32(shot.spatial && listener.found),
		}
		if params.spatial {
			params.position = listener_space(listener, shot.position)
		}
		if shot.voice == {} {
			if !run {
				s.one_shots[kept] = shot
				kept += 1
				continue
			}
			sound := find_sound(s, shot.guid)
			if sound == nil || sound.handle == {} {
				continue
			}
			if params.spatial && is_blocked(w, ph, listener, 0, shot.position) {
				shot.occluded = 1
			}
			params.occlusion = shot.occluded
			shot.voice = api.voice_play(&boundary.Voice_Desc{sound = sound.handle, bus = bus_handle(s, shot.bus), params = params})
			if shot.voice == {} {
				continue
			}
		} else if !api.voice_playing(shot.voice) {
			continue
		} else {
			params.occlusion = shot.occluded
			api.voice_set(shot.voice, &params)
		}
		s.one_shots[kept] = shot
		kept += 1
	}
	s.one_shot_count = kept
}

// find_sound gives a sound's slot, and makes the sound the first time. A sound that would not load has the nil handle,
// and logs once, until its blob changes. It is nil for the zero GUID, and past MAX_SOUNDS.
@(private)
find_sound :: proc(s: ^State, guid: format.Guid) -> ^Sound_Slot {
	if guid == {} {
		return nil
	}
	for &sound in s.sounds[:s.sound_count] {
		if sound.guid == guid {
			return &sound
		}
	}
	if s.sound_count >= MAX_SOUNDS {
		if .Sounds not_in s.warned {
			s.warned += {.Sounds}
			log.warnf("audio: more than %d sounds, so a sound does not play", MAX_SOUNDS)
		}
		return nil
	}
	sound := &s.sounds[s.sound_count]
	s.sound_count += 1
	sound^ = {
		guid = guid,
	}
	load_sound(s, sound)
	return sound
}

// can_stream is whether the backend can read a sound of this format as it plays.
@(private)
can_stream :: proc(features: boundary.Features, sound_format: boundary.Sound_Format) -> bool {
	if .Streaming not_in features {
		return false
	}
	switch sound_format {
	case .PCM:
		return true
	case .ADPCM:
		return .Stream_ADPCM in features
	case .Vorbis:
		return .Stream_Vorbis in features
	case .Opus:
		return .Stream_Opus in features
	}
	return false
}

// load_sound reads a blob's start, and then all of it, or only tells the backend where it is if it streams. All of a
// memory sound goes to the backend as PCM, decoded here if it is compressed, and the backend copies it, so it stays out of
// the asset system: nothing else reads it. The time comes first, so a blob that changes during the read is read again.
@(private)
load_sound :: proc(s: ^State, sound: ^Sound_Slot) {
	api := &s.platform.audio
	buffer: [32]u8
	name := format.guid_format(sound.guid, &buffer)
	location, found := asset.blob_location(s.assets, sound.guid)
	path := location.path
	if found {
		sound.modified = s.platform.file_modified(path)
	}
	if !found || sound.modified == 0 {
		log.errorf("audio: no blob for sound %s at %s. Cook the content.", name, path)
		return
	}
	// A blob that a bundle compresses does not stream: the asset runtime decompresses all of it.
	if location.raw {
		blob: format.Audio_Blob
		if s.platform.file_read_range(path, location.offset, mem.ptr_to_bytes(&blob)) != size_of(blob) || blob.header.layout != format.audio_layout() || !format.audio_check(&blob, sound.guid) {
			log.errorf("audio: %s is not a cooked sound of its GUID. Cook the content.", path)
			return
		}
		if bool(blob.stream) && can_stream(s.features, blob.format) {
			desc := boundary.Sound_Desc {
				frames   = blob.frames,
				channels = blob.channels,
				path     = strings.clone_to_cstring(path, s.platform.frame_allocator),
				offset   = u64(location.offset) + u64(blob.data.offset),
				size     = u64(blob.data.size),
				format   = blob.format,
				skip     = blob.skip,
			}
			sound.handle = api.sound_create(&desc)
			return
		}
	}
	data, _, ok := asset.read(s.assets, sound.guid)
	if !ok {
		log.errorf("audio: cannot read %s", path)
		return
	}
	defer delete(data, s.platform.asset_allocator)
	view, valid := format.audio_view(data)
	if !valid {
		log.errorf("audio: %s is not a cooked sound of its GUID. Cook the content.", path)
		return
	}
	desc := boundary.Sound_Desc {
		frames   = view.frames,
		channels = view.channels,
	}
	if view.format == .PCM {
		desc.samples = raw_data(format.audio_samples(data, view))
		sound.handle = api.sound_create(&desc)
		return
	}
	samples := make([]i16, view.frames * u64(view.channels), s.platform.asset_allocator)
	defer delete(samples, s.platform.asset_allocator)
	if !codec.decode_all(view.format, format.audio_data(data, view), int(view.channels), view.frames, u64(view.skip), samples, s.platform.asset_allocator) {
		log.errorf("audio: cannot decode %s. Cook the content.", path)
		return
	}
	desc.samples = raw_data(samples)
	sound.handle = api.sound_create(&desc)
}

// check_blobs looks at one sound's blob each frame, in turn, and makes a new sound of one that the cooker wrote again.
// The old sound's voices go on until follow_source starts its sources again.
@(private)
check_blobs :: proc(s: ^State) {
	if s.sound_count == 0 {
		return
	}
	s.sound_cursor = (s.sound_cursor + 1) % s.sound_count
	sound := &s.sounds[s.sound_cursor]
	location, found := asset.blob_location(s.assets, sound.guid)
	modified := s.platform.file_modified(location.path) if found else 0
	if modified == 0 || modified == sound.modified {
		return
	}
	if sound.handle != {} {
		s.platform.audio.sound_destroy(sound.handle)
		sound.handle = {}
	}
	load_sound(s, sound)
	sound.version += 1
}

