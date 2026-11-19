package audio_mixer

import "core:math"
import "core:slice"
import "core:sync"

import audio "cinnabar:core/audio"

// What a full occlusion does to a voice: its level and its high frequencies. A wall takes the highs first, so the source
// sounds behind something rather than only far away.
OCCLUSION_GAIN :: 0.35
OCCLUSION_OPEN_HZ :: 20000
OCCLUSION_CLOSED_HZ :: 800

// Below this, a sample passes the limiter unchanged.
LIMITER_THRESHOLD :: 0.9

// A mix past this, or one that is not a number, is a fault and not a loud sound: even every voice at full gain does not
// reach it. The limiter would play it at full scale, so the block goes silent instead.
FAULT_LEVEL :: 1024

// Keeps pitch in the range where the interpolation works.
MIN_PITCH :: 0.01
MAX_PITCH :: 8

// How long a seek fades out from the old place, and in at the new one: 5 ms each way.
SEEK_FADE_FRAMES :: BLOCK_FRAMES

// Mix_Voice is the mix thread's. It reads a sound through a two-frame window, a and b, which it interpolates by frac.
@(private)
Mix_Voice :: struct {
	// Nil while the slot is free.
	phase:       Voice_Phase,
	generation:  u32,
	bus:         u32,
	loop:        bool,
	unpaused:    bool,
	params:      audio.Voice_Params,
	sound:       ^Sound_Data,
	stream:      ^Stream,
	// The frames that it plays after each start before it fades out, over length_fade frames. 0 plays to the end.
	length:      u64,
	length_fade: i32,
	// A memory sound's next frame.
	cursor:      u64,
	a, b:        [2]f32,
	// The frame of the sound that a is.
	place:       u64,
	frac:        f32,
	// How many reads have found the end. The window is past the end at 2.
	past_end:    u8,
	// The gains that the last block ended on.
	gains:       [2]f32,
	started:     bool,
	filter:      [2]f32,
	filtering:   bool,
	// The fades in and out: level moves by step each frame, and stays between 0 and 1.
	level:       f32,
	step:        f32,
	// 1 while it plays, and 0 while a pause holds it. It moves over a block, so a pause does not click.
	pause_gain:  f32,
	// How many seeks it has started from, which its place is published with.
	seeks:       u32,
}

// Voice_Phase is where a voice is in its life. set_phase is its only writer.
@(private)
Voice_Phase :: union {
	Voice_Waiting,
	Voice_Playing,
	Voice_Moving,
	Voice_Ending,
}

// Voice_Waiting waits to start at a frame of its sound: for its clock, and for its stream to answer the read with ticket.
// It neither plays nor advances. A late start throws away frames to keep to its clock, and a stream's are counted in
// discarded until the ring has them all.
@(private)
Voice_Waiting :: struct {
	frame:     u64,
	clock:     u64,
	ticket:    u32,
	// The seek that it waits for, by its count on the voice: 0 for its first start.
	seek:      u32,
	fade:      i32,
	discarded: u64,
}

// Voice_Playing counts the frames that it has played since it started, for its length.
@(private)
Voice_Playing :: struct {
	played: u64,
}

// Voice_Moving fades out on its way to another frame, for a seek.
@(private)
Voice_Moving :: struct {
	frame: u64,
	clock: u64,
	seek:  u32,
}

// Voice_Ending fades out on its way to its end.
@(private)
Voice_Ending :: struct {}

// Bus_Duck is one bus that a bus ducks.
@(private)
Bus_Duck :: struct {
	target:   u32,
	settings: audio.Duck,
}

@(private)
Mix_Bus :: struct {
	active:       bool,
	parent:       u32,
	gain:         f32,
	gain_target:  f32,
	effects:      [audio.MAX_BUS_EFFECTS]^Effect_State,
	// The buses that this one ducks, and how many.
	ducks:        [audio.MAX_BUS_DUCKS]Bus_Duck,
	duck_count:   int,
	// The peak of the last block that it gave its parent, which the buses that it ducks follow.
	peak:         f32,
	// What ducking does to this bus's gain, and the rate at which it comes back.
	duck_gain:    f32,
	duck_release: f32,
	buffer:       [BLOCK_FRAMES][2]f32,
}

// drain_commands runs every queued command. It is the mix thread's, or the only thread's before the mix thread starts.
@(private)
drain_commands :: proc(m: ^Mixer) {
	read := sync.atomic_load_explicit(&m.command_read.value, .Relaxed)
	write := sync.atomic_load_explicit(&m.command_write.value, .Acquire)
	for read != write {
		run_command(m, &m.commands[read & (COMMAND_CAPACITY - 1)])
		read += 1
		sync.atomic_store_explicit(&m.command_read.value, read, .Release)
	}
}

// voice_of is the voice that a command names, or nil once it has ended.
@(private)
voice_of :: proc(m: ^Mixer, c: ^Command) -> ^Mix_Voice {
	v := &m.voices[c.voice]
	return v if v.phase != nil && v.generation == c.generation else nil
}

@(private)
run_command :: proc(m: ^Mixer, c: ^Command) {
	switch c.kind {
	case .Play:
		v := &m.voices[c.voice]
		v^ = {
			generation  = c.generation,
			bus         = c.bus,
			loop        = bool(c.flag),
			unpaused    = bool(c.unpaused),
			params      = c.params,
			sound       = c.sound,
			stream      = c.stream,
			length      = c.length,
			length_fade = frames_of(c.value),
			pause_gain  = 0 if m.paused && !c.unpaused else 1,
		}
		// A stream's first read is its first ticket.
		set_phase(
			m,
			v,
			c.voice,
			Voice_Waiting {
				frame = c.frame,
				clock = c.clock,
				ticket = c.ticket,
				fade = frames_of(c.value),
			},
		)
	case .Set:
		if v := voice_of(m, c); v != nil {
			v.params = c.params
		}
	case .Seek:
		v := voice_of(m, c)
		if v == nil {
			break
		}
		switch &phase in v.phase {
		case Voice_Playing:
			set_phase(m, v, c.voice, Voice_Moving{c.frame, c.clock, c.ticket})
		case Voice_Moving:
			phase = {c.frame, c.clock, c.ticket}
		case Voice_Waiting:
			wait_at(m, v, c.voice, c.frame, c.clock, c.ticket, phase.fade)
		case Voice_Ending:
		}
	case .Stop:
		v := voice_of(m, c)
		if v == nil {
			break
		}
		switch _ in v.phase {
		case Voice_Waiting:
			// It has made no sound to fade.
			set_phase(m, v, c.voice, nil)
		case Voice_Playing, Voice_Moving:
			// At least a block, so that a stop does not click.
			set_phase(m, v, c.voice, Voice_Ending{}, max(frames_of(c.value), BLOCK_FRAMES))
		case Voice_Ending:
		}
	case .Bus_Create:
		bus := &m.buses[c.bus]
		bus^ = {
			active      = true,
			parent      = c.parent,
			gain        = 1,
			gain_target = 1,
			duck_gain   = 1,
		}
	case .Bus_Gain:
		m.buses[c.bus].gain_target = c.value
	case .Bus_Effect:
		effects := &m.buses[c.bus].effects
		if c.flag {
			if effects[c.slot] != nil {
				effect_retire(m, effects[c.slot])
			}
			effects[c.slot] = c.effect
		}
		if effects[c.slot] != nil {
			effect_configure(effects[c.slot], c.settings)
		}
	case .Bus_Duck:
		if !set_duck(&m.buses[c.bus], c.parent, c.duck) {
			sync.atomic_add_explicit(&m.ducks_refused, 1, .Relaxed)
		}
	case .Paused:
		m.paused = bool(c.flag)
	case .Reset:
		reset_on_mix_thread(m)
	}
}

// frames_of is a time in frames, which a fade takes. Nothing that is not a number takes no time.
@(private)
frames_of :: proc(seconds: f32) -> i32 {
	return i32(clamp(seconds, 0, 60) * audio.SAMPLE_RATE) if seconds == seconds else 0
}

// set_duck adds, changes or, at a gain of 1, removes the duck of a target. It refuses a duck past MAX_BUS_DUCKS, which
// update reports.
@(private)
set_duck :: proc(bus: ^Mix_Bus, target: u32, settings: audio.Duck) -> bool {
	for i in 0 ..< bus.duck_count {
		if bus.ducks[i].target == target {
			if settings.gain >= 1 {
				bus.duck_count -= 1
				bus.ducks[i] = bus.ducks[bus.duck_count]
			} else {
				bus.ducks[i].settings = settings
			}
			return true
		}
	}
	if settings.gain >= 1 {
		return true
	}
	if bus.duck_count >= audio.MAX_BUS_DUCKS {
		return false
	}
	bus.ducks[bus.duck_count] = {target, settings}
	bus.duck_count += 1
	return true
}

// set_phase moves a voice to its next phase, and sets the fade that goes with it: a start fades in over fade frames, and
// a move or an end fades out over its frames from full. A move that ends where the voice waits for its new place.
@(private)
set_phase :: proc(m: ^Mixer, v: ^Mix_Voice, index: u32, next: Voice_Phase, fade: i32 = 0) {
	switch phase in next {
	case nil:
		voice_end(m, v, int(index))
		return
	case Voice_Waiting:
		v.level = 0
		v.step = 0
	case Voice_Playing:
		if phase.played == 0 {
			v.level = 0 if fade > 0 else 1
			v.step = 1 / f32(fade) if fade > 0 else 0
		}
	case Voice_Moving:
		v.step = -1 / f32(SEEK_FADE_FRAMES)
	case Voice_Ending:
		v.step = -1 / f32(max(fade, 1))
	}
	v.phase = next
	sync.atomic_store_explicit(&m.voice_slots[index].placed, false, .Relaxed)
	if _, playing := next.(Voice_Playing); playing {
		return
	}
	if moving, ok := next.(Voice_Moving); ok && v.level <= 0 {
		wait_at(m, v, index, moving.frame, moving.clock, moving.seek, SEEK_FADE_FRAMES)
	}
}

// wait_at makes a voice wait to start again at frame. A stream's reader is asked to read from there, under a new ticket,
// and the voice waits for its answer.
@(private)
wait_at :: proc(m: ^Mixer, v: ^Mix_Voice, index: u32, frame, clock: u64, seek: u32, fade: i32) {
	ticket: u32
	if v.stream != nil {
		ticket = stream_ask(v.stream, frame)
	}
	set_phase(
		m,
		v,
		index,
		Voice_Waiting{frame = frame, clock = clock, ticket = ticket, seek = seek, fade = fade},
	)
}

@(private)
reset_on_mix_thread :: proc(m: ^Mixer) {
	for &v in m.voices {
		if v.phase != nil {
			voice_end(m, &v, -1)
		}
	}
	for &bus, i in m.buses {
		for &effect in bus.effects {
			if effect != nil {
				effect_retire(m, effect)
				effect = nil
			}
		}
		bus.duck_count = 0
		bus.duck_gain = 1
		bus.peak = 0
		if i > 0 {
			bus.active = false
		}
	}
	m.buses[0].gain = 1
	m.buses[0].gain_target = 1
	m.paused = false
	sync.atomic_add_explicit(&m.reset_done, 1, .Release)
}

// voice_end releases what a voice holds. A stream's reader may still be using the sound, so the stream releases it. A
// reset ignores index, as it frees every slot.
@(private)
voice_end :: proc(m: ^Mixer, v: ^Mix_Voice, index: int) {
	v.phase = nil
	if v.stream != nil {
		sync.atomic_store_explicit(&v.stream.state, .Closing, .Release)
	} else {
		sync.atomic_sub_explicit(&v.sound.users, 1, .Release)
	}
	if index >= 0 {
		sync.atomic_store_explicit(&m.voice_slots[index].finished, true, .Release)
	}
}

// voice_gains is what the voice's parameters ask for at each channel.
voice_gains :: proc(params: audio.Voice_Params) -> [2]f32 {
	if !params.spatial {
		return params.gain
	}
	x := params.position.x
	distance := math.sqrt(
		x * x + params.position.y * params.position.y + params.position.z * params.position.z,
	)
	near, far := params.min_distance, params.max_distance
	attenuation: f32 = 1
	if far > near && near > 0 {
		if distance >= far {
			attenuation = 0
		} else if distance > near {
			// Inverse distance, shifted so it reaches 0 at far instead of stopping at near / far.
			attenuation = (near / distance - near / far) / (1 - near / far)
		}
	}
	occlusion := math.lerp(f32(1), OCCLUSION_GAIN, clamp(params.occlusion, 0, 1))
	// A source that is on the listener has no side to be on.
	pan := clamp(x / distance, -1, 1) if distance > 0.001 else 0
	angle := (pan + 1) * math.PI / 4
	return params.gain * attenuation * occlusion * [2]f32{math.cos(angle), math.sin(angle)}
}

// prime_voice fills the window with the frames at its place.
@(private)
prime_voice :: proc(m: ^Mixer, v: ^Mix_Voice) {
	v.past_end = 0
	v.a = next_frame(m, v)
	v.b = next_frame(m, v)
}

// next_frame reads the voice's next source frame, or silence past the end, which past_end counts. A mono sound is the
// same on both sides.
@(private)
next_frame :: proc(m: ^Mixer, v: ^Mix_Voice) -> [2]f32 {
	if v.stream != nil {
		frame, ok := stream_read(m, v.stream)
		if !ok {
			v.past_end += 1
		}
		return frame
	}
	sound := v.sound
	if v.cursor >= sound.frames {
		if !v.loop {
			v.past_end += 1
			return {}
		}
		v.cursor = 0
	}
	cursor := v.cursor
	v.cursor += 1
	if sound.channels == 1 {
		sample := f32(sound.samples[cursor]) / 32768
		return {sample, sample}
	}
	return {f32(sound.samples[cursor * 2]) / 32768, f32(sound.samples[cursor * 2 + 1]) / 32768}
}

// read_source writes interpolated frames into out, and returns how many before the voice's sound ended.
@(private)
read_source :: proc(m: ^Mixer, v: ^Mix_Voice, out: [][2]f32) -> int {
	pitch := clamp(v.params.pitch, MIN_PITCH, MAX_PITCH)
	for i in 0 ..< len(out) {
		out[i] = v.a + (v.b - v.a) * v.frac
		v.frac += pitch
		for v.frac >= 1 {
			v.frac -= 1
			v.a = v.b
			v.b = next_frame(m, v)
			v.place += 1
			if v.place >= v.sound.frames && v.loop {
				v.place = 0
			}
			if v.past_end >= 2 {
				return i + 1
			}
		}
	}
	return len(out)
}

// occlude runs a one-pole low-pass whose cutoff falls with the occlusion. It stays out of a voice that nothing occludes,
// and has never been.
@(private)
occlude :: proc(v: ^Mix_Voice, frames: [][2]f32) {
	occlusion := clamp(v.params.occlusion, 0, 1) if v.params.spatial else 0
	if occlusion <= 0 && !v.filtering {
		return
	}
	if !v.filtering {
		v.filtering = true
		v.filter = frames[0] if len(frames) > 0 else {}
	}
	cutoff := OCCLUSION_OPEN_HZ * math.pow(f32(OCCLUSION_CLOSED_HZ) / OCCLUSION_OPEN_HZ, occlusion)
	coefficient := 1 - math.exp(-math.TAU * cutoff / audio.SAMPLE_RATE)
	for &frame in frames {
		v.filter += (frame - v.filter) * coefficient
		frame = v.filter
	}
}

// start_voice starts a waiting voice once its stream has answered and its clock falls in this block, which starts at
// clock. begin is the frame of the block that it starts at. A late voice starts as far into its sound as it is late, at
// its pitch.
@(private)
start_voice :: proc(
	m: ^Mixer,
	v: ^Mix_Voice,
	index: u32,
	w: ^Voice_Waiting,
	clock: u64,
	count: int,
) -> (
	begin: int,
	started: bool,
) {
	if v.stream != nil && !stream_ready(v.stream, w.ticket) {
		return
	}
	late: u64
	if w.clock != 0 {
		if w.clock >= clock + u64(count) {
			return
		}
		if w.clock >= clock {
			begin = int(w.clock - clock)
		} else {
			late = clock - w.clock
		}
	}
	ahead := f64(late) * f64(clamp(v.params.pitch, MIN_PITCH, MAX_PITCH))
	whole := u64(ahead)
	frames := v.sound.frames
	frame := w.frame + whole
	if v.loop {
		frame %= frames
	} else if frame >= frames {
		set_phase(m, v, index, nil)
		return
	}
	if v.stream != nil {
		// The ring holds the sound from w.frame, so a late start throws its first frames away. Until the ring has them all,
		// the voice waits, and keeps count.
		for w.discarded < whole {
			read := v.stream.read.value
			if read == sync.atomic_load_explicit(&v.stream.write.value, .Acquire) {
				return
			}
			sync.atomic_store_explicit(&v.stream.read.value, read + 1, .Release)
			w.discarded += 1
		}
	} else {
		v.cursor = frame
	}
	v.place = frame
	v.frac = f32(ahead - f64(whole))
	prime_voice(m, v)
	v.seeks = w.seek
	set_phase(m, v, index, Voice_Playing{}, w.fade)
	return begin, true
}

@(private)
mix_voice :: proc(m: ^Mixer, v: ^Mix_Voice, index: int, count: int, clock: u64) {
	pause_target: f32 = 0 if m.paused && !v.unpaused else 1
	// A voice that a pause holds, or that has not started, makes no sound until the pause ends.
	_, waiting := v.phase.(Voice_Waiting)
	if pause_target == 0 && (v.pause_gain <= 0 || waiting) {
		return
	}
	begin := 0
	if w, waiting := &v.phase.(Voice_Waiting); waiting {
		started: bool
		begin, started = start_voice(m, v, u32(index), w, clock, count)
		if !started {
			return
		}
	}
	source: [BLOCK_FRAMES][2]f32
	produced := read_source(m, v, source[begin:count])
	frames := source[begin:][:produced]
	occlude(v, frames)

	target := voice_gains(v.params)
	if !v.started {
		v.started = true
		v.gains = target
	}
	bus := &m.buses[v.bus]
	spatial := bool(v.params.spatial)
	pause_from := v.pause_gain
	// Where a fade out reached nothing, which ends the voice or moves it.
	faded := -1
	for &frame, i in frames {
		place := f32(begin + i + 1) / f32(count)
		gains := v.gains + (target - v.gains) * place
		if spatial {
			mono := (frame.x + frame.y) * 0.5
			frame = {mono, mono}
		}
		v.level = clamp(v.level + v.step, 0, 1)
		// A smooth step, which leaves and reaches its ends with no slope, so a fade has no corner to hear.
		fade := v.level * v.level * (3 - 2 * v.level)
		frame *= gains * fade * (pause_from + (pause_target - pause_from) * place)
		bus.buffer[begin + i] += frame
		if v.level <= 0 && v.step < 0 {
			faded = i + 1
			break
		}
	}
	v.gains = target
	v.pause_gain = pause_target
	if v.level >= 1 {
		v.step = min(v.step, 0)
	}
	switch &phase in v.phase {
	case Voice_Moving:
		// A sound that ends during the fade has nothing left to fade, and still moves.
		if faded >= 0 || produced < count - begin {
			wait_at(m, v, u32(index), phase.frame, phase.clock, phase.seek, SEEK_FADE_FRAMES)
			return
		}
	case Voice_Ending:
		if faded >= 0 {
			set_phase(m, v, u32(index), nil)
			return
		}
	case Voice_Playing:
		phase.played += u64(produced)
		if v.length > 0 && phase.played >= v.length {
			set_phase(m, v, u32(index), Voice_Ending{}, max(v.length_fade, 1))
		}
	case Voice_Waiting:
	}
	if produced < count - begin {
		set_phase(m, v, u32(index), nil)
		return
	}
	publish_place(m, v, index, clock + u64(count))
}

// publish_place tells the game's thread where a voice is at the end of a block, through a sequence that is odd while
// it writes, so the game's thread never reads a frame and a clock of different blocks.
@(private)
publish_place :: proc(m: ^Mixer, v: ^Mix_Voice, index: int, clock: u64) {
	slot := &m.voice_slots[index]
	sequence := sync.atomic_load_explicit(&slot.place_sequence, .Relaxed)
	sync.atomic_store_explicit(&slot.place_sequence, sequence + 1, .Relaxed)
	sync.atomic_thread_fence(.Release)
	frame := f64(v.place) + f64(v.frac)
	sync.atomic_store_explicit(&slot.place_frame, transmute(u64)frame, .Relaxed)
	sync.atomic_store_explicit(&slot.place_clock, clock, .Relaxed)
	sync.atomic_store_explicit(&slot.placed, true, .Relaxed)
	sync.atomic_store_explicit(&slot.place_seeks, v.seeks, .Relaxed)
	sync.atomic_store_explicit(&slot.place_sequence, sequence + 2, .Release)
}

// limit passes a sample below the threshold unchanged, and bends the rest toward 1, so that a loud mix does not clip.
@(private)
limit :: proc(sample: f32) -> f32 {
	size := abs(sample)
	if size <= LIMITER_THRESHOLD {
		return sample
	}
	headroom: f32 = 1 - LIMITER_THRESHOLD
	bent := LIMITER_THRESHOLD + headroom * math.tanh((size - LIMITER_THRESHOLD) / headroom)
	return bent if sample > 0 else -bent
}

// duck_targets sets where each bus's duck gain goes in this block, from the peaks of the buses that duck it in the last
// block: the lowest gain of those above their thresholds, which it falls to at that duck's attack, and otherwise 1, which
// it comes back to at the release of the duck that held it last. Each rate is a step for each frame.
@(private)
duck_targets :: proc(m: ^Mixer) -> (targets: [MAX_BUSES]f32, steps: [MAX_BUSES]f32) {
	for &target in targets {
		target = 1
	}
	for &bus in m.buses {
		if !bus.active {
			continue
		}
		for duck in bus.ducks[:bus.duck_count] {
			if bus.peak <= duck.settings.threshold {
				continue
			}
			ducked := &m.buses[duck.target]
			gain := clamp(duck.settings.gain, 0, 1)
			if gain < targets[duck.target] {
				targets[duck.target] = gain
				steps[duck.target] = (1 - gain) / max(duck.settings.attack * audio.SAMPLE_RATE, 1)
				ducked.duck_release =
					(1 - gain) / max(duck.settings.release * audio.SAMPLE_RATE, 1)
			}
		}
	}
	for &bus, i in m.buses {
		if targets[i] >= 1 {
			steps[i] = bus.duck_release if bus.duck_release > 0 else 1
		}
	}
	return
}

// mix_buses runs each bus's effects and gain, adds it to its parent, and clears it. A bus's parent has a lower index.
@(private)
mix_buses :: proc(m: ^Mixer, out: [][2]f32) {
	count := len(out)
	duck_to, duck_step := duck_targets(m)
	for i := MAX_BUSES - 1; i >= 0; i -= 1 {
		bus := &m.buses[i]
		if !bus.active {
			continue
		}
		frames := bus.buffer[:count]
		for effect in bus.effects {
			if effect != nil {
				effect_process(effect, frames)
			}
		}
		peak: f32
		for &frame, f in frames {
			if bus.duck_gain > duck_to[i] {
				bus.duck_gain = max(bus.duck_gain - duck_step[i], duck_to[i])
			} else if bus.duck_gain < duck_to[i] {
				bus.duck_gain = min(bus.duck_gain + duck_step[i], duck_to[i])
			}
			frame *=
				(bus.gain + (bus.gain_target - bus.gain) * (f32(f + 1) / f32(count))) *
				bus.duck_gain
			peak = max(peak, abs(frame.x), abs(frame.y))
		}
		bus.gain = bus.gain_target
		bus.peak = peak
		if i > 0 {
			parent := &m.buses[bus.parent]
			for frame, f in frames {
				parent.buffer[f] += frame
			}
		} else if mix_is_sound(frames) {
			for frame, f in frames {
				out[f] = {limit(frame.x), limit(frame.y)}
			}
		} else {
			slice.zero(out)
			clear_effects(m)
			sync.atomic_add_explicit(&m.faults, 1, .Relaxed)
		}
		slice.zero(frames)
	}
}

// The comparison is this way around so that NaN fails it.
@(private)
mix_is_sound :: proc(frames: [][2]f32) -> bool {
	for frame in frames {
		if !(abs(frame.x) < FAULT_LEVEL) || !(abs(frame.y) < FAULT_LEVEL) {
			return false
		}
	}
	return true
}

// clear_effects empties every effect's memory, which is the only place where a fault can last.
@(private)
clear_effects :: proc(m: ^Mixer) {
	for &bus in m.buses {
		for effect in bus.effects {
			if effect != nil {
				effect_clear(effect)
			}
		}
	}
}

// render mixes the next frames into out. It is the mix thread's, or the test's. Commands take effect at each block.
render :: proc(m: ^Mixer, out: []audio.Device_Frame) {
	for start := 0; start < len(out); start += BLOCK_FRAMES {
		render_block(m, out[start:min(start + BLOCK_FRAMES, len(out))])
	}
}

// render_block mixes one block, which starts at the clock. The clock runs while paused, when the voices that a pause holds
// neither play nor advance, and the effects' tails ring out.
@(private)
render_block :: proc(m: ^Mixer, out: [][2]f32) {
	drain_commands(m)
	count := len(out)
	clock := sync.atomic_load_explicit(&m.frames_mixed, .Relaxed)
	for &v, i in m.voices {
		if v.phase != nil {
			mix_voice(m, &v, i, count, clock)
		}
	}
	mix_buses(m, out)
	sync.atomic_store_explicit(&m.frames_mixed, clock + u64(count), .Relaxed)
}
