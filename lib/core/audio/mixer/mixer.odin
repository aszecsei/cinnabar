// Package audio_mixer is the engine's own audio backend: voices, buses and effects, mixed on a thread of their own into
// the core audio device, with a second thread that reads streams from disk. It is host code, so it keeps playing through
// a code reload. See docs/audio/design.md#the-mixer.
//
// The game's thread owns the handle tables, and tells the mix thread what to do through a queue of commands. The mix
// thread owns the voices and the buses, and tells the game's thread what ended through atomics. Nothing on the mix
// thread takes a lock, allocates, frees, logs or reads a file.
package audio_mixer

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:thread"

import audio "cinnabar:core/audio"

MAX_SOUNDS :: 1024
MAX_VOICES :: 128
MAX_BUSES :: 32
MAX_STREAMS :: 16

// One mixed block is 5 ms, which is how often commands take effect.
BLOCK_FRAMES :: 240
// How much the mix thread keeps queued at the device: 40 ms. Its own thread does not stop when the frames stop (see
// docs/core/audio.md#queue-depth-and-code-reload), so this only has to outlast its own scheduling.
QUEUE_TARGET :: 8 * BLOCK_FRAMES
// How often the mix thread looks at the queue, in milliseconds.
MIX_WAIT_MS :: 2

@(private)
COMMAND_CAPACITY :: 4096
// How long a command that must not be lost waits for room, or a reset waits for the threads, in milliseconds.
@(private)
WAIT_LIMIT_MS :: 2000

@(private)
Command_Kind :: enum u32 {
	Play,
	Set,
	Stop,
	Bus_Create,
	Bus_Gain,
	Bus_Effect,
	Paused,
	Reset,
}

// Command is one thing for the mix thread to do. Which fields it reads follows from its kind.
@(private)
Command :: struct {
	kind:       Command_Kind,
	voice:      u32,
	generation: u32,
	bus:        u32,
	parent:     u32,
	slot:       u32,
	value:      f32,
	flag:       b32,
	params:     audio.Voice_Params,
	sound:      ^Sound_Data,
	stream:     ^Stream,
	effect:     ^Effect_State,
	settings:   audio.Effect,
}

// Sound_Data is a sound's memory, or where its file is. users counts its handle and its voices: whichever goes last, the
// game's thread frees it in update.
@(private)
Sound_Data :: struct {
	frames:   u64,
	samples:  [^]i16,
	path:     cstring,
	offset:   u64,
	size:     u64,
	channels: u32,
	format:   audio.Sound_Format,
	skip:     u32,
	users:    i32,
	// In the list of sounds to free.
	next:     ^Sound_Data,
}

@(private)
Sound_Slot :: struct {
	generation: u32,
	data:       ^Sound_Data,
}

// Voice_Slot is a voice's handle. A slot comes free when its voice has finished on the mix thread, which is later than
// stopped while the voice fades.
@(private)
Voice_Slot :: struct {
	generation: u32,
	busy:       bool,
	stopped:    bool,
	// The mix thread's, once the voice has ended.
	finished:   b32,
}

@(private)
Bus_Slot :: struct {
	generation: u32,
	alive:      bool,
	kinds:      [audio.MAX_BUS_EFFECTS]audio.Effect_Kind,
}

// The indices only grow, and read <= write. Each is on its own cache line.
@(private)
Index :: struct #align (64) {
	value: u64,
}

Mixer :: struct {
	host:           ^audio.Host,
	ready:          bool,
	// Whether voice_play starts the threads. Tests leave it false, and call render and stream_step themselves.
	threaded:       bool,

	// The game thread's.
	sounds:         [MAX_SOUNDS]Sound_Slot,
	voice_slots:    [MAX_VOICES]Voice_Slot,
	bus_slots:      [MAX_BUSES]Bus_Slot,
	bus_count:      u32,
	dying:          ^Sound_Data,
	pool_warned:    bool,
	failed_seen:    u32,
	faults_seen:    u32,
	voices_refused: u32,
	mix_thread:     ^thread.Thread,
	stream_thread:  ^thread.Thread,

	commands:       [COMMAND_CAPACITY]Command,
	command_read:   Index,
	command_write:  Index,

	// Shared, through atomics.
	closing:        b32,
	reset_done:     u32,
	retired:        ^Effect_State,
	frames_mixed:   u64,
	stream_starved: u64,
	stream_failed:  u32,
	faults:         u32,

	streams:        [MAX_STREAMS]Stream,

	// The mix thread's.
	voices:         [MAX_VOICES]Mix_Voice,
	buses:          [MAX_BUSES]Mix_Bus,
	paused:         bool,
	pause_gain:     f32,
	reset_count:    u32,
}

// The host is one per process, so the backend's state is too.
@(private)
state: Mixer

// load gives the mixer's table. The first call sets it up, and it starts no thread until a voice plays.
load :: proc(host: ^audio.Host, name := "") -> ^audio.Audio_API {
	if !state.ready {
		init(&state, host)
		state.threaded = true
	}
	return &api
}

// init sets up a mixer with no threads.
init :: proc(m: ^Mixer, host: ^audio.Host) {
	m.host = host
	m.ready = true
	m.bus_count = 1
	m.bus_slots[0] = {
		generation = audio.MASTER_BUS.generation,
		alive      = true,
	}
	m.buses[0] = {
		active      = true,
		gain        = 1,
		gain_target = 1,
	}
	m.pause_gain = 1
}

@(private)
api := audio.Audio_API {
	info = proc "c" () -> audio.Backend_Info {
		return {
			api_version = audio.API_VERSION,
			features = {.Spatial, .Streaming, .Buses, .Effects, .Stream_ADPCM, .Stream_Vorbis, .Stream_Opus},
			layout = audio.layout_signature(),
			name = "mixer",
			version = "1",
		}
	},
	update = proc "c" () {
		context = runtime.default_context()
		update(&state)
	},
	sound_create = proc "c" (desc: ^audio.Sound_Desc) -> audio.Sound {
		context = runtime.default_context()
		return sound_create(&state, desc)
	},
	sound_destroy = proc "c" (sound: audio.Sound) {
		context = runtime.default_context()
		sound_destroy(&state, sound)
	},
	voice_play = proc "c" (desc: ^audio.Voice_Desc) -> audio.Voice {
		context = runtime.default_context()
		return voice_play(&state, desc)
	},
	voice_set = proc "c" (voice: audio.Voice, params: ^audio.Voice_Params) {
		context = runtime.default_context()
		voice_set(&state, voice, params)
	},
	voice_stop = proc "c" (voice: audio.Voice, fade: f32) {
		context = runtime.default_context()
		voice_stop(&state, voice, fade)
	},
	voice_playing = proc "c" (voice: audio.Voice) -> b32 {
		return voice_playing(&state, voice)
	},
	bus_create = proc "c" (name: cstring, parent: audio.Bus) -> audio.Bus {
		context = runtime.default_context()
		return bus_create(&state, parent)
	},
	bus_set_gain = proc "c" (bus: audio.Bus, gain: f32) {
		context = runtime.default_context()
		bus_set_gain(&state, bus, gain)
	},
	bus_set_effect = proc "c" (bus: audio.Bus, slot: u32, effect: ^audio.Effect) {
		context = runtime.default_context()
		bus_set_effect(&state, bus, slot, effect)
	},
	set_paused = proc "c" (paused: b32) {
		context = runtime.default_context()
		set_paused(&state, paused)
	},
	stats = proc "c" (out: ^audio.Stats) {
		stats(&state, out)
	},
	reset = proc "c" () -> i32 {
		context = runtime.default_context()
		return reset(&state)
	},
	shutdown = proc "c" () {
		context = runtime.default_context()
		shutdown(&state)
	},
}

@(private)
report :: proc(m: ^Mixer, level: audio.Log_Level, format: string, args: ..any) {
	buffer: [256]u8
	text := fmt.bprintf(buffer[:len(buffer) - 1], format, ..args)
	buffer[len(text)] = 0
	m.host.log(level, cstring(&buffer[0]))
}

// push queues a command, and returns false if the queue is full. Without a mix thread, the caller is the only thread, so
// the command runs at once.
@(private)
push :: proc(m: ^Mixer, command: Command) -> bool {
	write := sync.atomic_load_explicit(&m.command_write.value, .Relaxed)
	read := sync.atomic_load_explicit(&m.command_read.value, .Acquire)
	if write - read >= COMMAND_CAPACITY {
		return false
	}
	m.commands[write & (COMMAND_CAPACITY - 1)] = command
	sync.atomic_store_explicit(&m.command_write.value, write + 1, .Release)
	if m.mix_thread == nil {
		drain_commands(m)
	}
	return true
}

// push_wait queues a command that must not be lost. A full queue means that the mix thread has stalled, so this waits
// for it, within reason.
@(private)
push_wait :: proc(m: ^Mixer, command: Command) {
	for _ in 0 ..< WAIT_LIMIT_MS {
		if push(m, command) {
			return
		}
		sleep_ms(1)
	}
	report(m, .Error, "audio: mixer: the command queue stayed full, so a %v was lost", command.kind)
}

// update is the game thread's work once a frame: it frees what the mix thread has finished with.
update :: proc(m: ^Mixer) {
	free_retired_effects(m)
	link := &m.dying
	for link^ != nil {
		data := link^
		if sync.atomic_load_explicit(&data.users, .Acquire) > 0 {
			link = &data.next
			continue
		}
		link^ = data.next
		free_sound(m, data)
	}
	failed := sync.atomic_load_explicit(&m.stream_failed, .Relaxed)
	if failed != m.failed_seen {
		report(m, .Warning, "audio: mixer: %d streams could not read their files", failed - m.failed_seen)
		m.failed_seen = failed
	}
	faults := sync.atomic_load_explicit(&m.faults, .Relaxed)
	if faults != m.faults_seen {
		report(m, .Error, "audio: mixer: %d blocks of the mix were out of range, so they went silent and the effects were cleared", faults - m.faults_seen)
		m.faults_seen = faults
	}
}

@(private)
free_sound :: proc(m: ^Mixer, data: ^Sound_Data) {
	if data.samples != nil {
		m.host.free(data.samples)
	}
	if data.path != nil {
		m.host.free(rawptr(data.path))
	}
	m.host.free(data)
}

sound_create :: proc(m: ^Mixer, desc: ^audio.Sound_Desc) -> audio.Sound {
	if desc == nil || (desc.channels != 1 && desc.channels != 2) || desc.frames == 0 || (desc.samples == nil && desc.path == nil) || desc.format > .Opus || (desc.format != .PCM && (desc.samples != nil || desc.size == 0)) {
		report(m, .Error, "audio: mixer: sound_create: invalid description")
		return {}
	}
	index := -1
	for &slot, i in m.sounds {
		if slot.data == nil {
			index = i
			break
		}
	}
	if index < 0 {
		report(m, .Error, "audio: mixer: sound_create: more than %d sounds", MAX_SOUNDS)
		return {}
	}
	data := (^Sound_Data)(m.host.allocate(size_of(Sound_Data), align_of(Sound_Data)))
	if data == nil {
		return {}
	}
	data^ = {
		frames   = desc.frames,
		offset   = desc.offset,
		size     = desc.size,
		channels = desc.channels,
		format   = desc.format,
		skip     = desc.skip,
		users    = 1,
	}
	if desc.samples != nil {
		size := int(desc.frames) * int(desc.channels) * size_of(i16)
		data.samples = ([^]i16)(m.host.allocate(uint(size), align_of(i16)))
		if data.samples == nil {
			m.host.free(data)
			return {}
		}
		runtime.mem_copy_non_overlapping(data.samples, desc.samples, size)
	} else {
		size := len(desc.path) + 1
		path := m.host.allocate(uint(size), 1)
		if path == nil {
			m.host.free(data)
			return {}
		}
		runtime.mem_copy_non_overlapping(path, rawptr(desc.path), size)
		data.path = cstring(path)
	}
	slot := &m.sounds[index]
	slot.generation += 1
	slot.data = data
	return {u32(index), slot.generation}
}

@(private)
find_sound :: proc(m: ^Mixer, sound: audio.Sound) -> ^Sound_Slot {
	if sound.generation == 0 || sound.index >= MAX_SOUNDS {
		return nil
	}
	slot := &m.sounds[sound.index]
	return slot if slot.data != nil && slot.generation == sound.generation else nil
}

sound_destroy :: proc(m: ^Mixer, sound: audio.Sound) {
	slot := find_sound(m, sound)
	if slot == nil {
		return
	}
	data := slot.data
	slot.data = nil
	sync.atomic_sub_explicit(&data.users, 1, .Release)
	data.next = m.dying
	m.dying = data
}

@(private)
find_voice :: proc "contextless" (m: ^Mixer, voice: audio.Voice) -> ^Voice_Slot {
	if voice.generation == 0 || voice.index >= MAX_VOICES {
		return nil
	}
	slot := &m.voice_slots[voice.index]
	return slot if slot.busy && slot.generation == voice.generation else nil
}

@(private)
find_bus :: proc(m: ^Mixer, bus: audio.Bus) -> ^Bus_Slot {
	bus := bus if bus != {} else audio.MASTER_BUS
	if bus.generation == 0 || bus.index >= m.bus_count {
		return nil
	}
	slot := &m.bus_slots[bus.index]
	return slot if slot.alive && slot.generation == bus.generation else nil
}

voice_play :: proc(m: ^Mixer, desc: ^audio.Voice_Desc) -> audio.Voice {
	if desc == nil {
		return {}
	}
	sound := find_sound(m, desc.sound)
	if sound == nil || find_bus(m, desc.bus) == nil {
		return {}
	}
	index := -1
	for &slot, i in m.voice_slots {
		if !slot.busy || sync.atomic_load_explicit(&slot.finished, .Acquire) {
			index = i
			break
		}
	}
	stream: ^Stream
	if index >= 0 && sound.data.samples == nil {
		stream = stream_take(m, sound.data, bool(desc.loop))
	}
	if index < 0 || (sound.data.samples == nil && stream == nil) {
		m.voices_refused += 1
		if !m.pool_warned {
			m.pool_warned = true
			report(m, .Warning, "audio: mixer: out of voices or streams (%d and %d), so a sound does not play", MAX_VOICES, MAX_STREAMS)
		}
		return {}
	}
	if m.threaded {
		start_threads(m, stream != nil)
	}
	slot := &m.voice_slots[index]
	slot.generation += 1
	slot.busy = true
	slot.stopped = false
	sync.atomic_store_explicit(&slot.finished, false, .Relaxed)
	sync.atomic_add_explicit(&sound.data.users, 1, .Relaxed)
	bus := desc.bus if desc.bus != {} else audio.MASTER_BUS
	push_wait(m, {kind = .Play, voice = u32(index), generation = slot.generation, bus = bus.index, flag = desc.loop, params = desc.params, sound = sound.data, stream = stream})
	return {u32(index), slot.generation}
}

voice_set :: proc(m: ^Mixer, voice: audio.Voice, params: ^audio.Voice_Params) {
	slot := find_voice(m, voice)
	if slot == nil || slot.stopped || params == nil {
		return
	}
	// The next frame sends newer values, so a full queue can drop this.
	push(m, {kind = .Set, voice = voice.index, generation = voice.generation, params = params^})
}

voice_stop :: proc(m: ^Mixer, voice: audio.Voice, fade: f32) {
	slot := find_voice(m, voice)
	if slot == nil || slot.stopped {
		return
	}
	slot.stopped = true
	push_wait(m, {kind = .Stop, voice = voice.index, generation = voice.generation, value = fade})
}

voice_playing :: proc "contextless" (m: ^Mixer, voice: audio.Voice) -> b32 {
	slot := find_voice(m, voice)
	return slot != nil && !slot.stopped && !sync.atomic_load_explicit(&slot.finished, .Acquire)
}

// A bus's index is above its parent's, because the parent came first and buses go only at a reset. So the mix thread
// mixes the buses from the last to the first.
bus_create :: proc(m: ^Mixer, parent: audio.Bus) -> audio.Bus {
	if find_bus(m, parent) == nil {
		return {}
	}
	if m.bus_count >= MAX_BUSES {
		report(m, .Error, "audio: mixer: bus_create: more than %d buses", MAX_BUSES)
		return {}
	}
	parent := parent if parent != {} else audio.MASTER_BUS
	index := m.bus_count
	m.bus_count += 1
	slot := &m.bus_slots[index]
	slot.generation += 1
	slot.alive = true
	slot.kinds = {}
	push_wait(m, {kind = .Bus_Create, bus = index, parent = parent.index})
	return {index, slot.generation}
}

bus_set_gain :: proc(m: ^Mixer, bus: audio.Bus, gain: f32) {
	if find_bus(m, bus) == nil {
		return
	}
	bus := bus if bus != {} else audio.MASTER_BUS
	push_wait(m, {kind = .Bus_Gain, bus = bus.index, value = gain})
}

// bus_set_effect keeps a slot's state when only its parameters change, so a delay's tail goes on. A new kind's state is
// allocated here, not on the mix thread, which retires the old one for update to free.
bus_set_effect :: proc(m: ^Mixer, bus: audio.Bus, slot: u32, effect: ^audio.Effect) {
	found := find_bus(m, bus)
	if found == nil || slot >= audio.MAX_BUS_EFFECTS || effect == nil {
		return
	}
	bus := bus if bus != {} else audio.MASTER_BUS
	command := Command {
		kind     = .Bus_Effect,
		bus      = bus.index,
		slot     = slot,
		settings = effect^,
		flag     = found.kinds[slot] != effect.kind,
	}
	if bool(command.flag) && effect.kind != .None {
		command.effect = effect_create(m, effect.kind)
		if command.effect == nil {
			return
		}
	}
	found.kinds[slot] = effect.kind
	push_wait(m, command)
}

set_paused :: proc(m: ^Mixer, paused: b32) {
	push_wait(m, {kind = .Paused, flag = paused})
}

stats :: proc "contextless" (m: ^Mixer, out: ^audio.Stats) {
	out^ = {
		frames_mixed   = sync.atomic_load_explicit(&m.frames_mixed, .Relaxed),
		stream_starved = sync.atomic_load_explicit(&m.stream_starved, .Relaxed),
		voices_refused = m.voices_refused,
	}
	for &slot in m.voice_slots {
		if slot.busy && !sync.atomic_load_explicit(&slot.finished, .Acquire) {
			out.voices += 1
		}
	}
	for &stream in m.streams {
		if sync.atomic_load_explicit(&stream.state, .Relaxed) != .Free {
			out.streams += 1
		}
	}
	for slot in m.sounds {
		if slot.data != nil {
			out.sounds += 1
		}
	}
}

// reset waits for the mix thread and the stream thread to let go of everything, and then frees it. A soft restart is
// not in a hurry.
reset :: proc(m: ^Mixer) -> (stopped: i32) {
	target := sync.atomic_load_explicit(&m.reset_done, .Acquire) + 1
	push_wait(m, {kind = .Reset})
	for _ in 0 ..< WAIT_LIMIT_MS {
		if sync.atomic_load_explicit(&m.reset_done, .Acquire) == target {
			break
		}
		sleep_ms(1)
	}
	if m.stream_thread == nil {
		stream_step(m)
	}
	for _ in 0 ..< WAIT_LIMIT_MS {
		if !streams_busy(m) {
			break
		}
		sleep_ms(1)
	}
	if sync.atomic_load_explicit(&m.reset_done, .Acquire) != target || streams_busy(m) {
		// Freeing now could pull memory from under a thread, so this keeps it.
		report(m, .Error, "audio: mixer: a thread did not stop for a reset, so its memory stays")
		return
	}
	for &slot in m.voice_slots {
		if slot.busy && !slot.stopped && !sync.atomic_load_explicit(&slot.finished, .Relaxed) {
			stopped += 1
		}
		slot.busy = false
		slot.stopped = false
		sync.atomic_store_explicit(&slot.finished, false, .Relaxed)
	}
	for &slot in m.sounds {
		if slot.data != nil {
			sync.atomic_sub_explicit(&slot.data.users, 1, .Relaxed)
			free_sound(m, slot.data)
			slot.data = nil
		}
	}
	for data := m.dying; data != nil; {
		next := data.next
		free_sound(m, data)
		data = next
	}
	m.dying = nil
	for &slot in m.bus_slots[1:] {
		slot.alive = false
	}
	m.bus_slots[0].kinds = {}
	m.bus_count = 1
	m.pool_warned = false
	free_retired_effects(m)
	return
}

// shutdown stops the threads and frees everything. A later load starts over.
shutdown :: proc(m: ^Mixer) {
	reset(m)
	sync.atomic_store_explicit(&m.closing, true, .Release)
	if m.mix_thread != nil {
		thread.join(m.mix_thread)
		thread.destroy(m.mix_thread)
		m.mix_thread = nil
	}
	if m.stream_thread != nil {
		thread.join(m.stream_thread)
		thread.destroy(m.stream_thread)
		m.stream_thread = nil
	}
	for &stream in m.streams {
		if stream.decoder_memory != nil {
			m.host.free(raw_data(stream.decoder_memory))
			stream.decoder_memory = nil
		}
		if stream.ring != nil {
			m.host.free(stream.ring)
			stream.ring = nil
		}
	}
	m.ready = false
	sync.atomic_store_explicit(&m.closing, false, .Release)
}

@(private)
start_threads :: proc(m: ^Mixer, streaming: bool) {
	if m.mix_thread == nil {
		m.mix_thread = thread.create_and_start_with_data(m, mix_thread_proc, runtime.default_context(), .High, name = "audio mixer")
	}
	if streaming && m.stream_thread == nil {
		m.stream_thread = thread.create_and_start_with_data(m, stream_thread_proc, runtime.default_context(), .Normal, name = "audio streams")
	}
}

@(private)
mix_thread_proc :: proc(data: rawptr) {
	m := (^Mixer)(data)
	timer := timer_create()
	defer timer_destroy(timer)
	block: [BLOCK_FRAMES]audio.Device_Frame
	for !sync.atomic_load_explicit(&m.closing, .Acquire) {
		// Commands go through even when the queue needs nothing, as a reset waits for one.
		drain_commands(m)
		status: audio.Device_Status
		m.host.device_status(&status)
		for queued := status.queued; queued < QUEUE_TARGET; queued += BLOCK_FRAMES {
			render(m, block[:])
			m.host.device_write(&block[0], BLOCK_FRAMES)
		}
		timer_wait(timer, MIX_WAIT_MS)
	}
}
