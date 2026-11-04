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

// Mix_Voice is the mix thread's. It reads a sound through a two-frame window, a and b, which it interpolates by frac.
@(private)
Mix_Voice :: struct {
	active:     bool,
	generation: u32,
	bus:        u32,
	loop:       bool,
	params:     audio.Voice_Params,
	sound:      ^Sound_Data,
	stream:     ^Stream,
	// Waiting for a stream's first read. Such a voice neither plays nor advances.
	primed:     bool,
	cursor:     u64,
	a, b:       [2]f32,
	frac:       f32,
	// How many reads have found the end. The window is past the end at 2.
	past_end:   u8,
	// The gains that the last block ended on.
	gains:      [2]f32,
	started:    bool,
	filter:     [2]f32,
	filtering:  bool,
	// The frames of a stop's fade, and those left. Counted, so that the gain ends at exactly 0.
	fade_total: i32,
	fade_left:  i32,
}

@(private)
Mix_Bus :: struct {
	active:      bool,
	parent:      u32,
	gain:        f32,
	gain_target: f32,
	effects:     [audio.MAX_BUS_EFFECTS]^Effect_State,
	buffer:      [BLOCK_FRAMES][2]f32,
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

@(private)
run_command :: proc(m: ^Mixer, c: ^Command) {
	switch c.kind {
	case .Play:
		v := &m.voices[c.voice]
		v^ = {
			active     = true,
			generation = c.generation,
			bus        = c.bus,
			loop       = bool(c.flag),
			params     = c.params,
			sound      = c.sound,
			stream     = c.stream,
		}
		if v.stream == nil {
			prime_voice(m, v)
		}
	case .Set:
		v := &m.voices[c.voice]
		if v.active && v.generation == c.generation {
			v.params = c.params
		}
	case .Stop:
		v := &m.voices[c.voice]
		if v.active && v.generation == c.generation && v.fade_total == 0 {
			// At least a block, so that a stop does not click.
			v.fade_total = max(i32(c.value * audio.SAMPLE_RATE), BLOCK_FRAMES)
			v.fade_left = v.fade_total
		}
	case .Bus_Create:
		bus := &m.buses[c.bus]
		bus.active = true
		bus.parent = c.parent
		bus.gain = 1
		bus.gain_target = 1
		slice.zero(bus.buffer[:])
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
	case .Paused:
		m.paused = bool(c.flag)
	case .Reset:
		reset_on_mix_thread(m)
	}
}

@(private)
reset_on_mix_thread :: proc(m: ^Mixer) {
	for &v in m.voices {
		if v.active {
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
		if i > 0 {
			bus.active = false
		}
	}
	m.buses[0].gain = 1
	m.buses[0].gain_target = 1
	m.paused = false
	m.pause_gain = 1
	sync.atomic_add_explicit(&m.reset_done, 1, .Release)
}

// voice_end releases what a voice holds. A stream's reader may still be using the sound, so the stream releases it. A
// reset ignores index, as it frees every slot.
@(private)
voice_end :: proc(m: ^Mixer, v: ^Mix_Voice, index: int) {
	v.active = false
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
	distance := math.sqrt(x * x + params.position.y * params.position.y + params.position.z * params.position.z)
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

// prime_voice fills the window with the voice's first two frames.
@(private)
prime_voice :: proc(m: ^Mixer, v: ^Mix_Voice) {
	v.primed = true
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

@(private)
mix_voice :: proc(m: ^Mixer, v: ^Mix_Voice, index: int, count: int) {
	if !v.primed {
		if !stream_ready(v.stream) {
			return
		}
		prime_voice(m, v)
	}
	source: [BLOCK_FRAMES][2]f32
	produced := read_source(m, v, source[:count])
	frames := source[:produced]
	occlude(v, frames)

	target := voice_gains(v.params)
	if !v.started {
		v.started = true
		v.gains = target
	}
	bus := &m.buses[v.bus]
	spatial := bool(v.params.spatial)
	for &frame, i in frames {
		gains := v.gains + (target - v.gains) * (f32(i + 1) / f32(count))
		if spatial {
			mono := (frame.x + frame.y) * 0.5
			frame = {mono, mono}
		}
		frame *= gains
		if v.fade_total > 0 {
			frame *= f32(v.fade_left) / f32(v.fade_total)
			v.fade_left = max(v.fade_left - 1, 0)
		}
		bus.buffer[i] += frame
	}
	v.gains = target
	if produced < count || (v.fade_total > 0 && v.fade_left == 0) {
		voice_end(m, v, index)
	}
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

// mix_buses runs each bus's effects and gain, adds it to its parent, and clears it. A bus's parent has a lower index.
@(private)
mix_buses :: proc(m: ^Mixer, out: [][2]f32) {
	count := len(out)
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
		for &frame, f in frames {
			frame *= bus.gain + (bus.gain_target - bus.gain) * (f32(f + 1) / f32(count))
		}
		bus.gain = bus.gain_target
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

@(private)
render_block :: proc(m: ^Mixer, out: [][2]f32) {
	drain_commands(m)
	count := len(out)
	target: f32 = 0 if m.paused else 1
	if m.paused && m.pause_gain <= 0 {
		slice.zero(out)
		return
	}
	for &v, i in m.voices {
		if v.active {
			mix_voice(m, &v, i, count)
		}
	}
	mix_buses(m, out)
	if m.pause_gain != target {
		for &frame, i in out {
			frame *= m.pause_gain + (target - m.pause_gain) * (f32(i + 1) / f32(count))
		}
		m.pause_gain = target
	}
	sync.atomic_add_explicit(&m.frames_mixed, u64(count), .Relaxed)
}
