package link

import "core:mem"
import "core:strings"
import "core:testing"

@(private = "file")
round_trip :: proc(t: ^testing.T, message: Message) -> Message {
	buf: [dynamic]byte
	defer delete(buf)
	write_message(&buf, message, request = 7)
	header, ok := read_header(buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, int(header.length), len(buf) - HEADER_SIZE)
	testing.expect_value(t, header.request, u32(7))
	decoded, decoded_ok := decode_message(header.kind, buf[HEADER_SIZE:], context.temp_allocator)
	testing.expect(t, decoded_ok)
	return decoded
}

@(test)
every_message_round_trips :: proc(t: ^testing.T) {
	messages := []Message {
		Hello{protocol = 0x1234_5678_9abc_def0, editor = "cinnabar editor"},
		Welcome{protocol = 1, game = "mygame", layout_hash = 0xffff_ffff_ffff_ffff},
		Refused{reason = "versions differ", protocol = 2},
		Log{level = .Warning, time = -5, location = "host.odin:12:main()", text = "ünïcode"},
		Game_Reloaded{kind = .Soft_Restart},
		Viewport_Size{width = 1920, height = -1},
		Frame_Target{prefix = "cinnabar.g3", generation = 3, width = 640, height = 360},
		Frame_Acknowledged{generation = 3, frame = 1 << 40},
	}
	for message in messages {
		decoded := round_trip(t, message)
		testing.expectf(t, equal(decoded, message), "%v decoded as %v", message, decoded)
	}
}

@(private = "file")
equal :: proc(a, b: Message) -> bool {
	switch x in a {
	case Hello:
		y, ok := b.(Hello)
		return ok && x == y
	case Welcome:
		y, ok := b.(Welcome)
		return ok && x == y
	case Refused:
		y, ok := b.(Refused)
		return ok && x == y
	case Log:
		y, ok := b.(Log)
		return ok && x == y
	case Game_Reloaded:
		y, ok := b.(Game_Reloaded)
		return ok && x == y
	case Viewport_Size:
		y, ok := b.(Viewport_Size)
		return ok && x == y
	case Frame_Target:
		y, ok := b.(Frame_Target)
		return ok && x == y
	case Frame_Acknowledged:
		y, ok := b.(Frame_Acknowledged)
		return ok && x == y
	}
	return false
}

@(test)
a_short_or_long_payload_is_refused :: proc(t: ^testing.T) {
	buf: [dynamic]byte
	defer delete(buf)
	write_message(&buf, Hello{protocol = 1, editor = "editor"})
	header, _ := read_header(buf[:])
	payload := buf[HEADER_SIZE:]

	_, short_ok := decode_message(header.kind, payload[:len(payload) - 1], context.temp_allocator)
	testing.expect(t, !short_ok)
	long := make([]byte, len(payload) + 1, context.temp_allocator)
	copy(long, payload)
	_, long_ok := decode_message(header.kind, long, context.temp_allocator)
	testing.expect(t, !long_ok)
}

@(test)
an_unknown_kind_is_refused :: proc(t: ^testing.T) {
	_, zero_ok := decode_message(0, nil, context.temp_allocator)
	testing.expect(t, !zero_ok)
	_, past_ok := decode_message(200, nil, context.temp_allocator)
	testing.expect(t, !past_ok)
}

@(test)
a_string_longer_than_the_payload_is_refused :: proc(t: ^testing.T) {
	// Refused's first field is a string. Its count claims a gigabyte.
	payload := []byte{0, 0, 0, 0x40}
	_, ok := decode_message(3, payload, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
a_header_with_a_huge_payload_is_refused :: proc(t: ^testing.T) {
	bytes := []byte{0xff, 0xff, 0xff, 0xff, 1, 0, 0, 0, 0, 0, 0, 0}
	_, ok := read_header(bytes)
	testing.expect(t, !ok)
}

@(test)
the_schema_lists_every_message_and_type :: proc(t: ^testing.T) {
	text := schema(context.temp_allocator)
	for name in ([]string{"Hello", "Welcome", "Refused", "Log", "Game_Reloaded", "Viewport_Size", "Frame_Target", "Frame_Acknowledged", "Log_Level", "Reload_Kind"}) {
		testing.expectf(t, strings.contains(text, name), "the schema has no %s", name)
	}
	testing.expect(t, strings.contains(text, `"kind": 1, "name": "Hello"`))
	testing.expect(t, strings.contains(text, `{"name": "Soft_Restart", "value": 1}`))
}

@(test)
the_version_is_stable_and_in_the_schema :: proc(t: ^testing.T) {
	version := protocol_version()
	testing.expect(t, version != 0)
	testing.expect_value(t, protocol_version(), version)
	text := schema(context.temp_allocator)
	testing.expect(t, strings.contains(text, strings.to_lower(tprint_hex(version), context.temp_allocator)))
}

@(private = "file")
tprint_hex :: proc(v: u64) -> string {
	digits := "0123456789abcdef"
	out := make([]byte, 16, context.temp_allocator)
	for i in 0 ..< 16 {
		out[15 - i] = digits[(v >> uint(i * 4)) & 0xf]
	}
	return string(out)
}

@(test)
decoding_allocates_only_from_the_given_allocator :: proc(t: ^testing.T) {
	buf: [dynamic]byte
	defer delete(buf)
	write_message(&buf, Log{level = .Info, location = "a", text = "b"})
	header, _ := read_header(buf[:])

	arena_buf: [256]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	message, ok := decode_message(header.kind, buf[HEADER_SIZE:], mem.arena_allocator(&arena))

	testing.expect(t, ok)
	testing.expect_value(t, message.(Log).text, "b")
	testing.expect(t, arena.offset > 0)
}

// The editor's LinkWireTests.TheBytesMatchTheOdinEncoding checks the same bytes, so both ends agree on the format.
@(test)
the_bytes_match_the_editor_encoding :: proc(t: ^testing.T) {
	buf: [dynamic]byte
	defer delete(buf)
	write_message(&buf, Frame_Acknowledged{generation = 3, frame = 0x0102030405060708})
	expected := []byte{12, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 8, 7, 6, 5, 4, 3, 2, 1}
	testing.expectf(t, string(buf[:]) == string(expected), "wrote %v", buf[:])
}
