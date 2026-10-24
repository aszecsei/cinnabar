package link

import "base:runtime"
import "core:encoding/endian"
import "core:mem"
import "core:reflect"

#assert(ODIN_ENDIAN == .Little, "the wire format copies numbers as they are in memory")

// Every message starts with this header: the payload's length in bytes, the message kind, flags (zero for now) and
// the request ID. A response has the request ID of its request, and an event has request ID 0.
HEADER_SIZE :: 12

// A longer payload is a broken or hostile peer, and the reader closes the link.
MAX_PAYLOAD :: 64 * mem.Megabyte

Header :: struct {
	length:  u32,
	kind:    u16,
	flags:   u16,
	request: u32,
}

read_header :: proc(data: []byte) -> (header: Header, ok: bool) {
	if len(data) < HEADER_SIZE {
		return
	}
	header = {
		length  = endian.unchecked_get_u32le(data[0:]),
		kind    = endian.unchecked_get_u16le(data[4:]),
		flags   = endian.unchecked_get_u16le(data[6:]),
		request = endian.unchecked_get_u32le(data[8:]),
	}
	return header, header.length <= MAX_PAYLOAD
}

// write_message appends a message, with its header, to buf.
write_message :: proc(buf: ^[dynamic]byte, message: Message, request: u32 = 0) {
	message := message
	assert(message != nil, "link: cannot write an empty message")
	start := len(buf)
	resize(buf, start + HEADER_SIZE)
	variant := reflect.get_union_variant(message)
	encode_value(buf, variant.data, type_info_of(variant.id))
	length := len(buf) - start - HEADER_SIZE
	header := buf[start:][:HEADER_SIZE]
	endian.unchecked_put_u32le(header[0:], u32(length))
	endian.unchecked_put_u16le(header[4:], u16(reflect.get_union_variant_raw_tag(message)))
	endian.unchecked_put_u16le(header[6:], 0)
	endian.unchecked_put_u32le(header[8:], request)
}

// kind_of is the kind of a message type: its index in Message, from 1.
kind_of :: proc($T: typeid) -> u16 {
	info := runtime.type_info_base(type_info_of(Message)).variant.(runtime.Type_Info_Union)
	for variant, i in info.variants {
		if variant.id == T {
			return u16(i + 1)
		}
	}
	panic("link: kind_of a type that is not a message")
}

// decode_message decodes a payload of the given kind. Strings and slices are allocated with allocator. A payload
// that does not decode to exactly one message of the kind is refused.
decode_message :: proc(kind: u16, payload: []byte, allocator: mem.Allocator) -> (message: Message, ok: bool) {
	info := runtime.type_info_base(type_info_of(Message)).variant.(runtime.Type_Info_Union)
	if kind == 0 || int(kind) > len(info.variants) {
		return
	}
	r := Reader {
		data      = payload,
		allocator = allocator,
	}
	// A union's value is at its start, before the tag.
	if !decode_value(&r, &message, info.variants[kind - 1]) || r.pos != len(payload) {
		return {}, false
	}
	reflect.set_union_variant_raw_tag(message, i64(kind))
	return message, true
}

@(private)
encode_value :: proc(buf: ^[dynamic]byte, data: rawptr, ti: ^runtime.Type_Info) {
	base := runtime.type_info_base(ti)
	#partial switch info in base.variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Enum:
		append(buf, ..([^]byte)(data)[:base.size])
	case runtime.Type_Info_Boolean:
		append(buf, 1 if (^bool)(data)^ else 0)
	case runtime.Type_Info_String:
		s := (^string)(data)^
		write_count(buf, len(s))
		append(buf, s)
	case runtime.Type_Info_Array:
		for i in 0 ..< info.count {
			encode_value(buf, rawptr(uintptr(data) + uintptr(i * info.elem_size)), info.elem)
		}
	case runtime.Type_Info_Slice:
		s := (^runtime.Raw_Slice)(data)^
		write_count(buf, s.len)
		for i in 0 ..< s.len {
			encode_value(buf, rawptr(uintptr(s.data) + uintptr(i * info.elem_size)), info.elem)
		}
	case runtime.Type_Info_Struct:
		for i in 0 ..< info.field_count {
			encode_value(buf, rawptr(uintptr(data) + info.offsets[i]), info.types[i])
		}
	case:
		// The schema test walks every message, so an unsupported field fails there first.
		panic("link: a message has a field type that the wire format does not support")
	}
}

@(private)
write_count :: proc(buf: ^[dynamic]byte, count: int) {
	bytes: [4]byte
	endian.unchecked_put_u32le(bytes[:], u32(count))
	append(buf, ..bytes[:])
}

@(private)
Reader :: struct {
	data:      []byte,
	pos:       int,
	allocator: mem.Allocator,
}

@(private)
decode_value :: proc(r: ^Reader, data: rawptr, ti: ^runtime.Type_Info) -> bool {
	base := runtime.type_info_base(ti)
	#partial switch info in base.variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Enum:
		bytes := take(r, base.size) or_return
		mem.copy(data, raw_data(bytes), base.size)
	case runtime.Type_Info_Boolean:
		bytes := take(r, 1) or_return
		if bytes[0] > 1 {
			return false
		}
		(^bool)(data)^ = bytes[0] == 1
	case runtime.Type_Info_String:
		count := read_count(r) or_return
		bytes := take(r, count) or_return
		s, err := runtime.make_slice([]byte, count, r.allocator)
		if err != nil {
			return false
		}
		copy(s, bytes)
		(^string)(data)^ = string(s)
	case runtime.Type_Info_Array:
		for i in 0 ..< info.count {
			decode_value(r, rawptr(uintptr(data) + uintptr(i * info.elem_size)), info.elem) or_return
		}
	case runtime.Type_Info_Slice:
		count := read_count(r) or_return
		// Every element takes at least one byte, so a count beyond the rest of the payload is a lie.
		if count > len(r.data) - r.pos {
			return false
		}
		elems, err := mem.alloc(count * info.elem_size, info.elem.align, r.allocator)
		if err != nil {
			return false
		}
		for i in 0 ..< count {
			decode_value(r, rawptr(uintptr(elems) + uintptr(i * info.elem_size)), info.elem) or_return
		}
		(^runtime.Raw_Slice)(data)^ = {elems, count}
	case runtime.Type_Info_Struct:
		for i in 0 ..< info.field_count {
			decode_value(r, rawptr(uintptr(data) + info.offsets[i]), info.types[i]) or_return
		}
	case:
		return false
	}
	return true
}

@(private)
take :: proc(r: ^Reader, count: int) -> ([]byte, bool) {
	if count < 0 || count > len(r.data) - r.pos {
		return nil, false
	}
	bytes := r.data[r.pos:][:count]
	r.pos += count
	return bytes, true
}

@(private)
read_count :: proc(r: ^Reader) -> (count: int, ok: bool) {
	bytes := take(r, 4) or_return
	return int(endian.unchecked_get_u32le(bytes)), true
}
