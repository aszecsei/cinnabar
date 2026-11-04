// Package audio_boundary is the boundary between the engine and an audio backend: handles, descriptions, and the two
// tables of procedures, Audio_API (what a backend provides) and Host (what the host gives it). It is plain data and is
// compiled into the host, the game DLL and every backend. See docs/audio/backends.md#the-contract.
//
// A backend may be written in C or C++, so everything here has a C layout: procedures use the C calling convention,
// and take pointers and counts, never Odin slices or strings. lib/core/audio/audio.h is the same layout in C, and both
// sides assert the sizes below, so a change here must change it too.
package audio_boundary

import "cinnabar:core/layout"

// The version of Audio_API. The host refuses a backend whose info reports another one.
API_VERSION :: 2

// The rate of every sound and of the device, in frames per second. The cooker converts to it.
SAMPLE_RATE :: 48000

// A handle with generation 0 is the nil handle. A stale handle does nothing, which the backend may log.
Handle :: struct {
	index:      u32,
	generation: u32,
}

Sound :: distinct Handle
Voice :: distinct Handle
Bus :: distinct Handle

// Every backend has this bus, and every other bus reaches it. A nil Bus means it.
MASTER_BUS :: Bus{0, 1}

// The most effects on one bus.
MAX_BUS_EFFECTS :: 4

Feature :: enum u8 {
	// voice_set's position, distances and occlusion change what the voice sounds like.
	Spatial,
	// sound_create takes a path, and reads the sound as it plays.
	Streaming,
	// bus_create makes real buses.
	Buses,
	// bus_set_effect takes effect.
	Effects,
	// sound_create takes a path to a sound in this format, and reads it as it plays. Without one, the engine decodes such a
	// sound when it loads, and gives the backend PCM.
	Stream_ADPCM,
	Stream_Vorbis,
	Stream_Opus,
}

Features :: bit_set[Feature;u32]

// Backend_Info describes a backend. The strings are the backend's, and live as long as it is loaded. layout is the
// backend's layout_signature, which the host compares with its own.
Backend_Info :: struct {
	api_version: u32,
	features:    Features,
	layout:      u32,
	_:           u32,
	name:        cstring,
	version:     cstring,
}

// Sound_Format is how a file's samples are stored. A backend that advertises the format's Feature can stream it, and the
// engine decodes the sound first for one that does not. See docs/audio/backends.md#the-contract.
Sound_Format :: enum u32 {
	// Interleaved 16-bit samples.
	PCM,
	// Blocks of IMA ADPCM, which lib/core/audio/adpcm reads.
	ADPCM,
	// An Ogg Vorbis stream.
	Vorbis,
	// Opus packets at 48 kHz, each after its size in a little-endian u16.
	Opus,
}

// Sound_Desc is a sound at SAMPLE_RATE, with interleaved channels. A sound with samples is in memory, as 16-bit PCM, and
// the backend copies them before sound_create returns. A sound with a path instead has its data in that file, size bytes
// from offset, in format, and the backend reads them as it plays. The path is copied. The cooker can replace the file
// while it plays, so the backend must not hold it open between reads, and a voice ends when its file changes.
//
// Each pass over a compressed sound starts its decoder at the start of the data, throws away skip frames, keeps frames
// frames and ignores the rest. So a loop is the coded data of a sound that continues into itself.
Sound_Desc :: struct {
	frames:   u64,
	samples:  [^]i16,
	path:     cstring,
	offset:   u64,
	size:     u64,
	// 1 or 2.
	channels: u32,
	format:   Sound_Format,
	skip:     u32,
	_:        u32,
}

// Voice_Params is what a playing voice can change. The backend moves to new values without a click. position is the
// source's in the listener's axes, in meters, so the listener is at the origin: X is to its right, and Y is up.
Voice_Params :: struct {
	position:     [3]f32,
	gain:         f32,
	// The playback rate: 1 is the sound's own.
	pitch:        f32,
	// How much is between the source and the listener, from 0, nothing, to 1, a wall.
	occlusion:    f32,
	// Full volume at min_distance and nearer, and silence at max_distance and farther.
	min_distance: f32,
	max_distance: f32,
	// Without this, the position, the distances and the occlusion do nothing.
	spatial:      b32,
	_:            u32,
}

Voice_Desc :: struct {
	sound:  Sound,
	bus:    Bus,
	params: Voice_Params,
	loop:   b32,
	_:      u32,
}

Effect_Kind :: enum u32 {
	None,
	// parameters: cutoff in Hz, resonance Q.
	Low_Pass,
	// parameters: cutoff in Hz, resonance Q.
	High_Pass,
	// parameters: time in seconds, up to 2, feedback from 0 to below 1, wet level from 0 to 1.
	Delay,
	// parameters: decay in seconds, damping from 0 to 1, wet level from 0 to 1.
	Reverb,
}

Effect :: struct {
	kind:       Effect_Kind,
	parameters: [3]f32,
}

// Stats counts what a backend has done. A backend without a count leaves it 0.
Stats :: struct {
	frames_mixed:   u64,
	// Frames of streams that were not read in time, and played as silence.
	stream_starved: u64,
	voices:         u32,
	streams:        u32,
	sounds:         u32,
	// Voices refused because the pool was full.
	voices_refused: u32,
}

// =================================
// The tables
// =================================

// Audio_API is what a backend provides. The game calls it from one thread at a time, its frame code; the backend's own
// threads keep playing between calls, and through a code reload. reset and shutdown are the host's: the game never
// calls them. See docs/audio/backends.md#the-contract.
Audio_API :: struct {
	info:           proc "c" () -> Backend_Info,
	// Once a frame: the place for a backend's work on the game's thread, such as FMOD's System::update.
	update:         proc "c" (),
	// Returns the nil sound when it cannot, which it logs.
	sound_create:   proc "c" (desc: ^Sound_Desc) -> Sound,
	// Voices that play the sound go on until they end, and the handle goes stale at once.
	sound_destroy:  proc "c" (sound: Sound),
	// Starts a voice. Returns the nil voice when it cannot, such as with a full pool, which it logs once.
	voice_play:     proc "c" (desc: ^Voice_Desc) -> Voice,
	voice_set:      proc "c" (voice: Voice, params: ^Voice_Params),
	// Stops a voice over fade seconds, and the handle goes stale at once.
	voice_stop:     proc "c" (voice: Voice, fade: f32),
	// False once the voice has ended, or its handle is stale.
	voice_playing:  proc "c" (voice: Voice) -> b32,
	// Makes a bus that mixes into parent. Returns the nil bus when it cannot.
	bus_create:     proc "c" (name: cstring, parent: Bus) -> Bus,
	bus_set_gain:   proc "c" (bus: Bus, gain: f32),
	// Puts an effect in one of a bus's slots, below MAX_BUS_EFFECTS, in the order that the sound passes them. A slot of
	// kind None holds no effect.
	bus_set_effect: proc "c" (bus: Bus, slot: u32, effect: ^Effect),
	// While paused, no voice advances and the output is silent.
	set_paused:     proc "c" (paused: b32),
	stats:          proc "c" (out: ^Stats),
	// Stops every voice without a fade, destroys every sound and every bus but Master, and returns how many voices it
	// stopped, for a soft restart. The next game starts clean, and the device stays open.
	reset:          proc "c" () -> i32,
	shutdown:       proc "c" (),
}

Log_Level :: enum i32 {
	Debug,
	Info,
	Warning,
	Error,
}

// A device frame is a left and a right sample, 48 kHz.
Device_Frame :: [2]f32

// Device_Status is core's Audio_Status (see docs/core/audio.md#status).
Device_Status :: struct {
	queued:  i64,
	played:  u64,
	starved: u64,
	open:    b32,
	_:       u32,
}

// Host is what the host gives a backend: memory, the log, the audio device and files, all host code. The backend calls
// nothing else of the engine's. log and the device may be called from any thread, and the device by one at a time.
// A backend with its own output never calls the device, which then never opens (see docs/core/audio.md#the-device).
// allocate gives zeroed memory, and free works from any thread.
//
// file_open opens a file to read, and returns nil when it cannot. Windows refuses to rename over a file that is open,
// which is how the cooker writes a blob, so close it after each read (see docs/audio/design.md#streaming). file_read_at
// returns the bytes read, or a negative number on failure. file_modified is the open file's modification time, in
// nanoseconds, which tells a reader that the file was replaced since its last read.
Host :: struct {
	allocate:      proc "c" (size, align: uint) -> rawptr,
	free:          proc "c" (ptr: rawptr),
	log:           proc "c" (level: Log_Level, message: cstring),
	device_write:  proc "c" (frames: [^]Device_Frame, count: i32) -> i32,
	device_status: proc "c" (out: ^Device_Status),
	file_open:     proc "c" (path: cstring) -> rawptr,
	file_read_at:  proc "c" (file: rawptr, offset: u64, buffer: rawptr, size: u64) -> i64,
	file_modified: proc "c" (file: rawptr) -> i64,
	file_close:    proc "c" (file: rawptr),
}

// Format lists every type that crosses the boundary, for format_hash.
@(private)
Format :: struct {
	sound_desc:    Sound_Desc,
	voice_params:  Voice_Params,
	voice_desc:    Voice_Desc,
	effect:        Effect,
	stats:         Stats,
	info:          Backend_Info,
	device_status: Device_Status,
	api:           Audio_API,
	host:          Host,
}

// layout_signature is an FNV-1a hash of the sizes of every type that crosses the boundary, in this order, which
// audio.h's cn_audio_layout computes the same way. A backend in C cannot compute format_hash, which hashes Odin's type
// info, so the host compares this with the backend's Backend_Info.layout when it loads one (see
// docs/audio/backends.md#loading). It catches a backend built against another layout of the same API_VERSION.
layout_signature :: proc "contextless" () -> u32 {
	sizes := [?]u32 {
		u32(size_of(Backend_Info)),
		u32(size_of(Sound_Desc)),
		u32(size_of(Voice_Params)),
		u32(size_of(Voice_Desc)),
		u32(size_of(Effect)),
		u32(size_of(Stats)),
		u32(size_of(Device_Status)),
		u32(size_of(Audio_API)),
		u32(size_of(Host)),
	}
	h: u32 = 0x811c9dc5
	for s in sizes {
		for i in 0 ..< 4 {
			h = (h ~ ((s >> (8 * u32(i))) & 0xff)) * 0x01000193
		}
	}
	return h
}

// format_hash identifies the boundary's layouts. The game's abi_hash includes it.
format_hash :: proc() -> u64 {
	return layout.hash(Format)
}

// audio.h asserts the same sizes.
#assert(size_of(Handle) == 8)
#assert(size_of(Backend_Info) == 32)
#assert(size_of(Sound_Desc) == 56)
#assert(size_of(Voice_Params) == 40)
#assert(size_of(Voice_Desc) == 64)
#assert(size_of(Effect) == 16)
#assert(size_of(Stats) == 32)
#assert(size_of(Device_Status) == 32)
#assert(size_of(Audio_API) == 15 * size_of(rawptr))
#assert(size_of(Host) == 9 * size_of(rawptr))
