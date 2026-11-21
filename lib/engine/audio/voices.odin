package audio

import "core:log"

import boundary "cinnabar:core/audio"
import "cinnabar:engine/ecs"

// The most voices that the audio follows for their callers at once: placed at an entity, or stopped at a time on the
// clock (see docs/audio/design.md#voices-that-a-caller-owns).
MAX_OWNED_VOICES :: 64

// Owned_Voice is a voice that start_voice started for a caller, which the audio follows: at an entity, whose presented
// pose each update places it at, heard from the nearest listener with its distances; or flat, with only its stop. Its
// gain and pitch are the caller's, from set_voice. stop_at is a time on the clock to stop it at, over fade seconds, or
// 0 for none. A slot with the nil voice is free.
@(private)
Owned_Voice :: struct {
	voice:        boundary.Voice,
	entity:       ecs.Entity,
	min_distance: f32,
	max_distance: f32,
	gain:         f32,
	pitch:        f32,
	stop_at:      u64,
	fade:         f32,
}

// set_voice sets a voice's gain and its pitch, which is clamped to MIN_PITCH to MAX_PITCH. A voice at an entity takes
// them in the next update, with its place; a flat one takes them at once.
set_voice :: proc(s: ^State, voice: boundary.Voice, gain: f32, pitch: f32) {
	if owned := find_owned(s, voice); owned != nil && owned.entity != 0 {
		owned.gain, owned.pitch = gain, clamp_pitch(pitch)
		return
	}
	params := boundary.Voice_Params {
		gain  = gain,
		pitch = clamp_pitch(pitch),
	}
	s.platform.audio.voice_set(voice, &params)
}

// stop_voice_at stops a voice when the clock reaches a time, over fade seconds, so the voice plays on after its caller
// lets it go, as music that runs past a cutscene's end does. The voice keeps its gain and pitch until then. When the audio
// follows too many voices, it stops the voice now.
stop_voice_at :: proc(s: ^State, voice: boundary.Voice, at: u64, fade: f32) {
	owned := find_owned(s, voice)
	if owned == nil {
		owned = own_voice(s, {voice = voice})
	}
	if owned == nil {
		s.platform.audio.voice_stop(voice, fade)
		return
	}
	owned.stop_at, owned.fade = max(at, 1), fade
}

// own_voice takes a slot for a voice that the audio follows, and warns once when every slot is taken.
@(private)
own_voice :: proc(s: ^State, owned: Owned_Voice) -> ^Owned_Voice {
	for &slot in s.owned {
		if slot.voice == {} {
			slot = owned
			return &slot
		}
	}
	if .Owned not_in s.warned {
		s.warned += {.Owned}
		log.warnf(
			"audio: more than %d voices placed at entities or stopped later, so a voice is not followed",
			MAX_OWNED_VOICES,
		)
	}
	return nil
}

@(private)
find_owned :: proc(s: ^State, voice: boundary.Voice) -> ^Owned_Voice {
	if voice == {} {
		return nil
	}
	for &slot in s.owned {
		if slot.voice == voice {
			return &slot
		}
	}
	return nil
}

// disown_voice stops following a voice, as its caller stops it.
@(private)
disown_voice :: proc(s: ^State, voice: boundary.Voice) {
	if owned := find_owned(s, voice); owned != nil {
		owned^ = {}
	}
}

// update_owned follows the owned voices: one that ended goes, one whose stop time came stops, and one at an entity
// moves with the entity's presented pose. A voice whose entity is gone keeps its last place.
@(private)
update_owned :: proc(s: ^State, w: ^ecs.World) {
	api := &s.platform.audio
	now := api.clock()
	for &owned in s.owned {
		if owned.voice == {} {
			continue
		}
		if !api.voice_playing(owned.voice) {
			owned = {}
			continue
		}
		if owned.stop_at != 0 && now >= owned.stop_at {
			api.voice_stop(owned.voice, owned.fade)
			owned = {}
			continue
		}
		if owned.entity != 0 && ecs.is_alive(w, owned.entity) {
			params := placed_params(s, w, owned)
			api.voice_set(owned.voice, &params)
		}
	}
}

// placed_params is an owned voice's parameters at its entity's presented pose, heard from the nearest of the last
// update's listeners. Without a listener or a pose, it plays flat.
@(private)
placed_params :: proc(s: ^State, w: ^ecs.World, owned: Owned_Voice) -> boundary.Voice_Params {
	params := boundary.Voice_Params {
		gain         = owned.gain,
		pitch        = owned.pitch,
		min_distance = owned.min_distance,
		max_distance = owned.max_distance,
	}
	pose, has_pose := ecs.presented(w, owned.entity)
	if !has_pose {
		return params
	}
	listener, found := nearest_listener(s.listeners, pose.position)
	if !found {
		if .No_Listener not_in s.warned {
			s.warned += {.No_Listener}
			log.warn(
				"audio: a voice at an entity plays with no Audio_Listener in the world, so it plays flat",
			)
		}
		return params
	}
	params.spatial = true
	params.position = listener_space(listener, pose.position)
	return params
}
