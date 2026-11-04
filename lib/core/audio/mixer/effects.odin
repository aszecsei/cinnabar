package audio_mixer

import "core:math"
import "core:mem"
import "core:sync"

import audio "cinnabar:core/audio"

// The longest delay, in frames: 2 seconds.
@(private)
DELAY_FRAMES :: 2 * audio.SAMPLE_RATE

// The reverb's delay lines, in frames, about 30 to 53 ms. Their lengths share no factor, so their echoes do not line up.
@(private)
REVERB_LINES := [4]int{1423, 1777, 2137, 2557}
@(private)
REVERB_TOTAL :: 1423 + 1777 + 2137 + 2557
// What each line takes of each side of the input: a tail about as loud as what made it, with four lines adding up.
@(private)
REVERB_INPUT :: 0.15

// Effect_State is an effect's parameters and memory, in one allocation with its delay lines. The game's thread allocates
// and frees it, and the mix thread runs it.
@(private)
Effect_State :: struct {
	kind:     audio.Effect_Kind,
	// In the list of states to free.
	next:     ^Effect_State,
	// A biquad's coefficients and its memory for each channel.
	b0, b1, b2, a1, a2: f32,
	z1, z2:   [2]f32,
	// A delay.
	lines:    [^][2]f32,
	head:     int,
	length:   int,
	feedback: f32,
	wet:      f32,
	// A reverb: its lines, one channel each, their heads, gains and damping memory.
	reverb:   [^]f32,
	heads:    [4]int,
	gains:    [4]f32,
	damped:   [4]f32,
	damping:  f32,
}

// effect_create allocates a kind's state, zeroed. It is the game thread's.
@(private)
effect_create :: proc(m: ^Mixer, kind: audio.Effect_Kind) -> ^Effect_State {
	extra := 0
	#partial switch kind {
	case .Delay:
		extra = DELAY_FRAMES * size_of([2]f32)
	case .Reverb:
		extra = REVERB_TOTAL * size_of(f32)
	}
	memory := m.host.allocate(uint(size_of(Effect_State) + extra), align_of(Effect_State))
	if memory == nil {
		return nil
	}
	effect := (^Effect_State)(memory)
	effect.kind = kind
	lines := rawptr(uintptr(memory) + size_of(Effect_State))
	#partial switch kind {
	case .Delay:
		effect.lines = ([^][2]f32)(lines)
	case .Reverb:
		effect.reverb = ([^]f32)(lines)
	}
	return effect
}

// effect_retire hands a state back to the game's thread, in a list that update takes whole.
@(private)
effect_retire :: proc(m: ^Mixer, effect: ^Effect_State) {
	for {
		head := sync.atomic_load_explicit(&m.retired, .Relaxed)
		effect.next = head
		_, swapped := sync.atomic_compare_exchange_weak_explicit(&m.retired, head, effect, .Release, .Relaxed)
		if swapped {
			return
		}
	}
}

@(private)
free_retired_effects :: proc(m: ^Mixer) {
	effect := sync.atomic_exchange_explicit(&m.retired, nil, .Acquire)
	for effect != nil {
		next := effect.next
		m.host.free(effect)
		effect = next
	}
}

// effect_configure applies new parameters and keeps the state's memory.
@(private)
effect_configure :: proc(e: ^Effect_State, settings: audio.Effect) {
	p := settings.parameters
	#partial switch e.kind {
	case .Low_Pass, .High_Pass:
		biquad_configure(e, p[0], p[1])
	case .Delay:
		e.length = clamp(int(p[0] * audio.SAMPLE_RATE), 1, DELAY_FRAMES)
		e.feedback = clamp(p[1], 0, 0.99)
		e.wet = clamp(p[2], 0, 1)
	case .Reverb:
		decay := max(p[0], 0.01)
		for length, i in REVERB_LINES {
			// The gain that takes a line's echo down 60 dB in decay seconds.
			e.gains[i] = math.pow(f32(10), -3 * f32(length) / (audio.SAMPLE_RATE * decay))
		}
		e.damping = clamp(p[1], 0, 1)
		e.wet = clamp(p[2], 0, 1)
	}
}

// The Audio EQ Cookbook's low-pass and high-pass.
@(private)
biquad_configure :: proc(e: ^Effect_State, cutoff, resonance: f32) {
	omega := math.TAU * clamp(cutoff, 10, audio.SAMPLE_RATE * 0.49) / audio.SAMPLE_RATE
	alpha := math.sin(omega) / (2 * max(resonance, 0.1))
	cosine := math.cos(omega)
	a0 := 1 + alpha
	e.a1 = -2 * cosine / a0
	e.a2 = (1 - alpha) / a0
	if e.kind == .Low_Pass {
		e.b1 = (1 - cosine) / a0
		e.b0 = e.b1 / 2
	} else {
		e.b1 = -(1 + cosine) / a0
		e.b0 = -e.b1 / 2
	}
	e.b2 = e.b0
}

// effect_clear forgets everything that an effect has heard, and keeps its parameters.
@(private)
effect_clear :: proc(e: ^Effect_State) {
	e.z1, e.z2 = {}, {}
	e.head, e.heads, e.damped = 0, {}, {}
	if e.lines != nil {
		mem.zero(e.lines, DELAY_FRAMES * size_of([2]f32))
	}
	if e.reverb != nil {
		mem.zero(e.reverb, REVERB_TOTAL * size_of(f32))
	}
}

// effect_process runs an effect over a block, in place.
@(private)
effect_process :: proc(e: ^Effect_State, frames: [][2]f32) {
	#partial switch e.kind {
	case .Low_Pass, .High_Pass:
		for &frame in frames {
			output := frame * e.b0 + e.z1
			e.z1 = frame * e.b1 - output * e.a1 + e.z2
			e.z2 = frame * e.b2 - output * e.a2
			frame = output
		}
	case .Delay:
		for &frame in frames {
			delayed := e.lines[e.head]
			e.lines[e.head] = frame + delayed * e.feedback
			e.head += 1
			if e.head >= e.length {
				e.head = 0
			}
			frame += delayed * e.wet
		}
	case .Reverb:
		reverb_process(e, frames)
	}
}

// reverb_process is a feedback delay network: four lines that feed each other through a Householder matrix, which keeps
// the energy, with a damping filter and a gain below 1 for each. The filter takes what leaves the matrix, whole. It must
// not take only part of that: at high frequencies, the rest would come back at up to twice its level, and the tail would
// grow until the limiter held it at full scale. The lines' outputs go to the two sides in turn.
@(private)
reverb_process :: proc(e: ^Effect_State, frames: [][2]f32) {
	for &frame in frames {
		input := (frame.x + frame.y) * REVERB_INPUT
		outputs: [4]f32
		line := e.reverb
		for length, i in REVERB_LINES {
			outputs[i] = line[e.heads[i]]
			line = line[length:]
		}
		sum := (outputs[0] + outputs[1] + outputs[2] + outputs[3]) * 0.5
		line = e.reverb
		for length, i in REVERB_LINES {
			e.damped[i] += (outputs[i] - sum - e.damped[i]) * (1 - e.damping * 0.9)
			line[e.heads[i]] = input + e.damped[i] * e.gains[i]
			e.heads[i] += 1
			if e.heads[i] >= length {
				e.heads[i] = 0
			}
			line = line[length:]
		}
		frame += [2]f32{outputs[0] + outputs[2], outputs[1] + outputs[3]} * 0.5 * e.wet
	}
}
