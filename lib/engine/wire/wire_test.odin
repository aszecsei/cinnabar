package wire

import "core:strings"
import "core:testing"

@(private = "file")
Ping :: struct {
	sequence: u32,
	note:     string,
}

@(private = "file")
Color :: enum u8 {
	Red,
	Green,
}

@(private = "file")
Paint :: struct {
	color:  Color,
	points: [][2]f32,
	ok:     bool,
}

@(private = "file")
Test_Message :: union {
	Ping,
	Paint,
}

@(test)
any_union_of_messages_round_trips :: proc(t: ^testing.T) {
	testing.expect_value(t, kind_of(Test_Message, Ping), 1)
	testing.expect_value(t, kind_of(Test_Message, Paint), 2)

	buf: [dynamic]byte
	defer delete(buf)
	write_message(&buf, Test_Message(Paint{color = .Green, points = {{1, 2}, {3, 4}}, ok = true}), request = 9)
	header, ok := read_header(buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, header.kind, 2)
	testing.expect_value(t, header.request, 9)
	testing.expect_value(t, int(header.length), len(buf) - HEADER_SIZE)
	decoded, decoded_ok := decode_message(Test_Message, header.kind, buf[HEADER_SIZE:], context.temp_allocator)
	testing.expect(t, decoded_ok)
	paint, is_paint := decoded.(Paint)
	testing.expect(t, is_paint && paint.color == .Green && len(paint.points) == 2 && paint.points[1] == {3, 4} && paint.ok)

	// A kind that the union does not have, and a payload with a byte too many, are refused.
	_, unknown := decode_message(Test_Message, 3, nil, context.temp_allocator)
	testing.expect(t, !unknown)
	_, long := decode_message(Test_Message, header.kind, append_elem_copy(buf[HEADER_SIZE:], 0), context.temp_allocator)
	testing.expect(t, !long)
}

@(private = "file")
append_elem_copy :: proc(payload: []byte, extra: byte) -> []byte {
	result := make([]byte, len(payload) + 1, context.temp_allocator)
	copy(result, payload)
	result[len(payload)] = extra
	return result
}

@(test)
each_union_has_its_own_schema_and_version :: proc(t: ^testing.T) {
	text := schema(Test_Message, context.temp_allocator)
	for name in ([]string{`"Ping"`, `"Paint"`, `"Color"`, `"[][2]f32"`}) {
		testing.expectf(t, strings.contains(text, name), "the schema lacks %s", name)
	}
	Other :: union {
		Ping,
	}
	testing.expect(t, protocol_version(Test_Message) != protocol_version(Other))
}
