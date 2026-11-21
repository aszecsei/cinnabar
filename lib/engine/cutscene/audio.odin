package cutscene

import "core:math"

import boundary "cinnabar:core/audio"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/audio"
import "cinnabar:engine/ecs"

// AUDIO_DRIFT is how far, in seconds, a voice of an audio track can be from where the cutscene's time puts it before the
// track seeks it: one and a half of the mixer's blocks of 240 frames (see docs/cinematics/tracks.md#audio-tracks). The
// project's cutscene.audio_drift replaces it.
AUDIO_DRIFT :: 1.5 * 240.0 / boundary.SAMPLE_RATE

// SCRUB_INTERVAL is the least time on the audio's clock between two scrubs of one audio track, in frames: about three
// frames at 60 Hz, so a dragged playhead plays a grain every few frames and not a pile of them.
SCRUB_INTERVAL :: 2400

// Audition is how an evaluation's audio tracks sound. A player's evaluation plays. The editor gives the others theirs
// (see docs/cinematics/tracks.md#audio-tracks).
Audition :: enum u8 {
	// The sections play voices, which pause with the world, as in the game.
	Play,
	// The sections play voices that play while the world does not run, for the editor's playback in its edit mode.
	Preview,
	// The sections play no voices. A seek plays a short grain of each section at the new time, for the editor's scrub.
	Scrub,
}

// Sound_Voice is the one state of an audio section's voice in an evaluation, by the section's ID. No entry is a section
// with no voice: not under the time, paused, or before it starts. Change it only with change_sound.
Sound_Voice :: union {
	Sound_Playing,
	Sound_Released,
}

// Sound_Playing is a section whose voice the track holds and keeps to the cutscene's time: the voice, the audio that
// plays it, in Game_State, the track's ID, and the evaluation's jumps when the track last placed it, so a seek since
// then seeks it. The section's end on the root's time, its ease out and whether it plays through a skip let the voice go
// without the blob.
Sound_Playing :: struct {
	voice:    boundary.Voice,
	audio:    ^audio.State,
	track:    u32,
	jumps:    u32,
	end:      i32,
	ease_out: i32,
	through:  bool,
}

// Sound_Released is a section that plays through a skip, whose voice the track let go when the skip began or the
// cutscene ended: it plays on at its own rate to the section's end, and the section does not start again while the time
// is under it.
Sound_Released :: struct {}

// Sound_Leave is how a section's voice leaves: stopped over a fade, or let go to play on until a time on the audio's
// clock and then fade.
@(private)
Sound_Leave :: union {
	Sound_Stop,
	Sound_Hand_Off,
}

@(private)
Sound_Stop :: struct {
	fade: f32,
}

@(private)
Sound_Hand_Off :: struct {
	at:   u64,
	fade: f32,
}

// Audio_Scrub is what an audio track scrubbed last: the evaluation's jumps then, and the time on the audio's clock.
@(private)
Audio_Scrub :: struct {
	jumps: u32,
	at:    u64,
}

// audio_track is the audio kind's evaluate procedure, in the Late phase (see docs/cinematics/tracks.md#audio-tracks).
// Each section under the frame's time plays its sound from offset + the integral of its pitch since its start, flat, or
// at the track's binding. Each evaluation sets the voice's gain and pitch, seeks it after a jump, and else keeps it to
// the cutscene's time within the drift limit. A pause stops the voices, and play starts them again where they should
// be. A skip fades them out over its fade, and lets those that play through it go. A jump starts nothing that it
// passes.
audio_track :: proc(ctx: ^Track_Context) {
	s := ctx.cutscenes
	if s == nil || s.audio == nil {
		return
	}
	e := ctx.evaluation
	sections := format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track)
	if e.audition == .Scrub {
		scrub_track(ctx, sections)
		return
	}
	entity, bound := track_entity(ctx)
	attached := ctx.track.binding != format.CUTSCENE_NONE
	p, in_player := player_of(s, e)
	status := status_of(p.state) if in_player else Player_Status.Playing
	rate := (f64(1) if ctx.clock == .Real else f64(s.rate)) * ctx.rate
	now := shown_time(ctx, status)
	// How far ahead of the frame, in the cutscene's ticks, a section that is about to start starts its voice on the
	// audio's clock, so the sound starts at its exact place and nothing of its attack is cut.
	lead := f64(audio.SEEK_LEAD) / boundary.SAMPLE_RATE * format.CUTSCENE_TICKS_PER_SECOND * rate
	for section in sections {
		entry, held := e.sounds[{ctx.scope, section.id}]
		early :=
			status == .Playing &&
			rate > 0 &&
			!ctx.skipped &&
			now < f64(section.start) &&
			f64(section.start) - now <= lead
		if !(covers_time(ctx, section, now) || early) || (attached && !bound) {
			if held {
				change_sound(e, {ctx.scope, section.id}, nil, Sound_Stop{audio.STOP_FADE})
			}
			continue
		}
		playing, has_voice := entry.(Sound_Playing)
		if _, released := entry.(Sound_Released); released {
			continue
		}
		if status == .Skipping {
			if has_voice {
				// Only a section that plays through the skip is let go. The others start again when play goes on.
				next: Maybe(Sound_Voice)
				if playing.through {
					next = Sound_Released{}
				}
				change_sound(e, {ctx.scope, section.id}, next, skip_leave(s, p, ctx.root, playing, e.time))
			}
			continue
		}
		if early && has_voice {
			// It waits for its start on the audio's clock. A seek since it was scheduled starts it again.
			if playing.jumps != e.jumps {
				change_sound(e, {ctx.scope, section.id}, nil, Sound_Stop{audio.STOP_FADE})
			}
			continue
		}
		// An early section is placed at its start, and starts there when the audio's clock reaches it.
		at := f64(section.start) if early else now
		length, loaded := audio.sound_length(s.audio, section.asset)
		place, inside := sound_place(ctx.data, ctx.blob, section, at, length)
		if status != .Playing || rate <= 0 || !loaded || !inside {
			if has_voice {
				change_sound(e, {ctx.scope, section.id}, nil, Sound_Stop{audio.STOP_FADE})
			}
			continue
		}
		local := i32(at) - section.start
		sample, _ := sample(ctx, section, i32(at))
		gain := f64(sample.weight) * f64(ctx.track.gain)
		pitch := f64(1)
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			keys := format.cutscene_channel_keys(ctx.data, ctx.blob, channel)
			switch format.blob_string(ctx.data, channel.name) {
			case format.CUTSCENE_AUDIO_GAIN:
				gain *= f64(curve_value(keys, local))
			case format.CUTSCENE_AUDIO_PITCH:
				pitch = f64(curve_value(keys, local))
			}
		}
		follows := ctx.track.time_scale == .Follow
		if follows {
			pitch *= rate
		}
		loop_length := length if .Loop in section.flags else 0
		if has_voice && audio.voice_playing(s.audio, playing.voice) {
			audio.set_voice(s.audio, playing.voice, f32(gain), f32(pitch))
			heard := clamp(pitch, audio.MIN_PITCH, audio.MAX_PITCH)
			if playing.jumps != e.jumps || ctx.skipped || ctx.wrapped {
				ahead := audio.clock(s.audio) + audio.SEEK_LEAD
				target := place + f64(audio.SEEK_LEAD) / boundary.SAMPLE_RATE * heard
				if loop_length > 0 {
					target = math.mod(target, loop_length)
				}
				audio.seek_voice(s.audio, playing.voice, target, ahead)
				next := playing
				next.jumps = e.jumps
				change_sound(e, {ctx.scope, section.id}, next, nil)
			} else if follows || rate == 1 {
				audio.keep_to_clock(
					s.audio,
					playing.voice,
					place,
					audio.clock(s.audio),
					s.audio_drift,
					heard,
					loop_length,
				)
			}
			continue
		}
		if ctx.skipped {
			// A jump starts nothing that it passes, and the section starts when play goes on.
			continue
		}
		start_clock := audio.clock(s.audio)
		if early {
			start_clock += u64(
				(f64(section.start) - now) /
				format.CUTSCENE_TICKS_PER_SECOND /
				rate *
				boundary.SAMPLE_RATE,
			)
		}
		voice := audio.start_voice(
			s.audio,
			{
				sound = section.asset,
				bus = int(section.bus),
				gain = f32(gain),
				pitch = f32(pitch),
				start = place,
				clock = start_clock,
				loop = .Loop in section.flags,
				unpaused = e.audition == .Preview,
				entity = entity if attached else 0,
				min_distance = section.min_distance,
				max_distance = section.max_distance,
			},
			ctx.world,
		)
		if voice == {} {
			if has_voice {
				change_sound(e, {ctx.scope, section.id}, nil, Sound_Stop{audio.STOP_FADE})
			}
			continue
		}
		change_sound(
			e,
			{ctx.scope, section.id},
			Sound_Playing {
				voice = voice,
				audio = s.audio,
				track = ctx.track.id,
				jumps = e.jumps,
				end = i32(math.ceil(root_time(ctx, f64(section.end)))),
				ease_out = section.ease_out,
				through = .Plays_Through_Skip in section.flags,
			},
			nil,
		)
	}
}

// scrub_track plays a short grain of each section under the time after a seek, at most once in SCRUB_INTERVAL, for an
// evaluation that scrubs. A scrub plays no voices of its own.
@(private)
scrub_track :: proc(ctx: ^Track_Context, sections: []format.Cutscene_Section) {
	s := ctx.cutscenes
	e := ctx.evaluation
	last, seen := e.scrubs[{ctx.scope, ctx.track.id}]
	now := audio.clock(s.audio)
	if seen && (last.jumps == e.jumps || now - last.at < SCRUB_INTERVAL) {
		return
	}
	e.scrubs[{ctx.scope, ctx.track.id}] = {e.jumps, now}
	t := f64(ctx.time)
	for section in sections {
		if !covers_time(ctx, section, t) {
			continue
		}
		length, loaded := audio.sound_length(s.audio, section.asset)
		place, inside := sound_place(ctx.data, ctx.blob, section, t, length)
		if !loaded || !inside {
			continue
		}
		sample, _ := sample(ctx, section, ctx.time)
		gain := sample.weight * ctx.track.gain
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			if format.blob_string(ctx.data, channel.name) == format.CUTSCENE_AUDIO_GAIN {
				gain *= curve_value(
					format.cutscene_channel_keys(ctx.data, ctx.blob, channel),
					ctx.time - section.start,
				)
			}
		}
		audio.scrub(s.audio, section.asset, place, int(section.bus), gain)
	}
}

// change_sound is the one writer of a section's voice. It stops the old voice, or lets it go, as leave says, when the
// next state does not hold the same voice. nil forgets the section.
@(private)
change_sound :: proc(
	e: ^Evaluation,
	section: Scoped,
	next: Maybe(Sound_Voice),
	leave: Sound_Leave,
) {
	if old, held := e.sounds[section].(Sound_Playing); held {
		keeps := false
		if state, some := next.?; some {
			new, still := state.(Sound_Playing)
			keeps = still && new.voice == old.voice
		}
		if !keeps {
			switch how in leave {
			case Sound_Stop:
				audio.stop_voice(old.audio, old.voice, how.fade)
			case Sound_Hand_Off:
				audio.stop_voice_at(old.audio, old.voice, how.at, how.fade)
			case:
				audio.stop_voice(old.audio, old.voice)
			}
		}
	}
	if state, ok := next.?; ok {
		e.sounds[section] = state
	} else {
		delete_key(&e.sounds, section)
	}
}

// skip_leave is how a voice leaves as a skip begins: one that plays through the skip goes on to its section's end at its
// own rate, and the others fade out over what is left of the skip's fade out.
@(private)
skip_leave :: proc(
	s: ^State,
	p: ^Player,
	blob: ^format.Cutscene_Blob,
	playing: Sound_Playing,
	time: i32,
) -> Sound_Leave {
	if playing.through {
		return hand_off(playing, time)
	}
	fade := f64(blob.skip_fade) / format.CUTSCENE_TICKS_PER_SECOND
	if p != nil {
		if skipping, ok := p.state.(Player_Skipping); ok && skipping.fade == .Out {
			fade -= f64(skipping.elapsed) / 1e9
		}
	}
	return Sound_Stop{max(f32(fade), audio.STOP_FADE)}
}

// hand_off lets a voice go at a time on the cutscene's time: it plays on, at its own rate, until its section's end on the
// audio's clock, and fades out over its ease out before it.
@(private)
hand_off :: proc(playing: Sound_Playing, time: i32) -> Sound_Hand_Off {
	TICKS :: f64(format.CUTSCENE_TICKS_PER_SECOND)
	ease := f64(playing.ease_out) / TICKS
	left := max(f64(playing.end - time) / TICKS - ease, 0)
	fade := f32(ease) if ease > 0 else audio.STOP_FADE
	return {audio.clock(playing.audio) + u64(left * boundary.SAMPLE_RATE), fade}
}

// release_sounds lets go of the voices of the sections that play through a skip and whose ends are after the time, as the
// cutscene reaches its end, by playback or a skip: they play on to their ends. restore calls it before end_holds stops
// the others. A cutscene that ends before its end, as a stop, a failure or a reset ends it, lets none go.
@(private)
release_sounds :: proc(e: ^Evaluation, w: ^ecs.World, blob: ^format.Cutscene_Blob) {
	if e.time < blob.range_end {
		return
	}
	ids := make([dynamic]Scoped, 0, len(e.sounds), w.platform.frame_allocator)
	for id in e.sounds {
		append(&ids, id)
	}
	for id in ids {
		if playing, ok := e.sounds[id].(Sound_Playing);
		   ok && playing.through && e.time < playing.end {
			change_sound(e, id, Sound_Released{}, hand_off(playing, e.time))
		}
	}
}

// end_sounds stops every voice that the evaluation's audio tracks hold, and forgets the sections and the scrubs.
// end_holds calls it.
@(private)
end_sounds :: proc(e: ^Evaluation, w: ^ecs.World) {
	ids := make([dynamic]Scoped, 0, len(e.sounds), w.platform.frame_allocator)
	for id in e.sounds {
		append(&ids, id)
	}
	for id in ids {
		change_sound(e, id, nil, Sound_Stop{audio.STOP_FADE})
	}
	clear(&e.scrubs)
}

// covers_time is whether an audio section is under a time in ticks on its scope's time, which can fall between two:
// [start, end), and its end too at the range's end. In a sub-sequence, no section is under the time while a
// sub-sequence section above it is not.
@(private)
covers_time :: proc(ctx: ^Track_Context, section: format.Cutscene_Section, t: f64) -> bool {
	return(
		ctx.covered &&
		t >= f64(section.start) &&
		(t < f64(section.end) || (t == f64(section.end) && section.end == ctx.range_end)) \
	)
}

// shown_time is the time, in ticks, that the frame shows: on the game's clock, a playing cutscene's time at its last tick
// less the part of a tick that presentation is behind it, so the sounds keep to the picture between ticks. It can be
// before the range's start, in the frames before the first tick reaches it.
@(private)
shown_time :: proc(ctx: ^Track_Context, status: Player_Status) -> f64 {
	t := f64(ctx.time)
	if ctx.clock != .Game || status != .Playing || ctx.world.clock.tick_rate == 0 {
		return t
	}
	clock := &ctx.world.clock
	behind := f64(1 - clock.alpha) * format.CUTSCENE_TICKS_PER_SECOND / f64(clock.tick_rate)
	return t - behind * ctx.rate
}

// sound_place is where an audio section's sound is at a time in ticks: its offset, and the integral of its pitch from
// the section's start, in seconds. A loop wraps it in the sound's length. inside is false past the end of a sound that
// does not loop.
sound_place :: proc(
	data: []byte,
	blob: ^format.Cutscene_Blob,
	section: format.Cutscene_Section,
	t: f64,
	length: f64,
) -> (
	seconds: f64,
	inside: bool,
) {
	TICKS :: f64(format.CUTSCENE_TICKS_PER_SECOND)
	local := max(t - f64(section.start), 0)
	played := local / TICKS
	for channel in format.cutscene_section_channels(data, blob, section) {
		if format.blob_string(data, channel.name) == format.CUTSCENE_AUDIO_PITCH {
			played = curve_integral(format.cutscene_channel_keys(data, blob, channel), local)
		}
	}
	seconds = f64(section.offset) / TICKS + played
	if .Loop in section.flags && length > 0 {
		return math.mod(seconds, length), true
	}
	return seconds, seconds < length
}

// player_of is the player whose evaluation this is, and false for an evaluation outside a player.
@(private)
player_of :: proc(s: ^State, e: ^Evaluation) -> (^Player, bool) {
	for &p in s.players {
		if live := live_of(&p.state); live != nil && &live.evaluation == e {
			return &p, true
		}
	}
	return nil, false
}

// set_audition is the one writer of how an evaluation's audio tracks sound, and whether its event tracks send events. A
// change ends the voices that the tracks hold, so no voice of one audition plays on under another; the next evaluation
// starts them as the new one says. It forgets the open ranges of the event tracks without sending their ends.
set_audition :: proc(e: ^Evaluation, w: ^ecs.World, audition: Audition) {
	if e.audition != audition {
		end_sounds(e, w)
		forget_ranges(e, w)
		e.audition = audition
	}
}

// set_rate sets the rate of the game's clock against real time: its time scale, and 0 while the game is paused. An audio
// track that follows the scale plays at it, and a rate of 0 stops the voices of the cutscenes on the game's clock.
set_rate :: proc(s: ^State, rate: f32) {
	s.rate = rate if rate == rate else 1
}

// set_audio_drift sets how far a voice can drift from the cutscene's time before its track seeks it, in seconds. 0 or
// less sets AUDIO_DRIFT.
set_audio_drift :: proc(s: ^State, seconds: f64) {
	s.audio_drift = seconds if seconds > 0 else AUDIO_DRIFT
}

// prepare_sounds loads the sounds of a cutscene's audio sections while its player loads, so no frame that starts one
// reads or decodes it. A sound that does not load logs once and plays nothing.
@(private)
prepare_sounds :: proc(s: ^State, data: []byte, blob: ^format.Cutscene_Blob) {
	if s.audio == nil {
		return
	}
	for track in format.cutscene_tracks(data, blob) {
		if track.kind != .Audio {
			continue
		}
		for section in format.cutscene_track_sections(data, blob, track) {
			audio.prepare_sound(s.audio, section.asset)
		}
	}
}
