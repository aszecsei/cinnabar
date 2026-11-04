// Package audio_opus binds libopus, which `just opus` builds from vendor/opus. The cooker encodes with it, and the
// runtime decodes with it. See docs/content/kinds/audio.md#audio.
package audio_opus

import "core:c"

foreign import lib "../../../../build/obj/opus/Release/opus.lib"

APPLICATION_AUDIO :: 2049
SIGNAL_MUSIC :: 3002

SET_BITRATE_REQUEST :: 4002
SET_COMPLEXITY_REQUEST :: 4010
SET_SIGNAL_REQUEST :: 4024
GET_LOOKAHEAD_REQUEST :: 4027
RESET_STATE :: 4028

OK :: 0

Encoder :: struct {}
Decoder :: struct {}

@(default_calling_convention = "c", link_prefix = "opus_")
foreign lib {
	encoder_get_size :: proc(channels: c.int) -> c.int ---
	encoder_init :: proc(st: ^Encoder, rate: i32, channels: c.int, application: c.int) -> c.int ---
	encode :: proc(st: ^Encoder, pcm: [^]i16, frame_size: c.int, data: [^]byte, max_data_bytes: i32) -> i32 ---
	encoder_ctl :: proc(st: ^Encoder, request: c.int, #c_vararg args: ..any) -> c.int ---
	decoder_get_size :: proc(channels: c.int) -> c.int ---
	decoder_init :: proc(st: ^Decoder, rate: i32, channels: c.int) -> c.int ---
	decode :: proc(st: ^Decoder, data: [^]byte, length: i32, pcm: [^]i16, frame_size: c.int, decode_fec: c.int) -> c.int ---
	decoder_ctl :: proc(st: ^Decoder, request: c.int, #c_vararg args: ..any) -> c.int ---
}
