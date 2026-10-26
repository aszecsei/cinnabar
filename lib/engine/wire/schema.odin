package wire

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:strings"

// schema describes every message of a link's union as JSON, for the editor's C# source generator (see
// docs/editor/link.md#editor-link). Its version is the protocol version.
schema :: proc(messages: typeid, allocator := context.allocator) -> string {
	body := schema_body(messages, context.temp_allocator)
	return fmt.aprintf("{{\n  \"version\": \"%016x\",\n%s}}\n", protocol_version(messages), body, allocator = allocator)
}

// protocol_version is a hash of the schema, so any change to a message changes it.
protocol_version :: proc(messages: typeid) -> u64 {
	return hash.fnv64a(transmute([]byte)schema_body(messages, context.temp_allocator))
}

@(private = "file")
Schema_Writer :: struct {
	b:       strings.Builder,
	// Named structs and enums that fields use, in the order that they are first used.
	structs: [dynamic]^runtime.Type_Info,
	enums:   [dynamic]^runtime.Type_Info,
}

@(private = "file")
schema_body :: proc(messages: typeid, allocator: runtime.Allocator) -> string {
	w := Schema_Writer {
		b       = strings.builder_make(allocator),
		structs = make([dynamic]^runtime.Type_Info, context.temp_allocator),
		enums   = make([dynamic]^runtime.Type_Info, context.temp_allocator),
	}
	info := runtime.type_info_base(type_info_of(messages)).variant.(runtime.Type_Info_Union)
	strings.write_string(&w.b, "  \"messages\": [\n")
	for variant, i in info.variants {
		write_struct(&w, variant, i + 1)
		strings.write_string(&w.b, ",\n" if i + 1 < len(info.variants) else "\n")
	}
	strings.write_string(&w.b, "  ],\n  \"structs\": [\n")
	// Writing a struct can find more structs, so the list grows while it is walked.
	for i := 0; i < len(w.structs); i += 1 {
		write_struct(&w, w.structs[i], 0)
		strings.write_string(&w.b, ",\n" if i + 1 < len(w.structs) else "\n")
	}
	strings.write_string(&w.b, "  ],\n  \"enums\": [\n")
	for e, i in w.enums {
		enum_info := runtime.type_info_base(e).variant.(runtime.Type_Info_Enum)
		fmt.sbprintf(&w.b, "    {{\"name\": %q, \"type\": %q, \"values\": [", type_name(e), type_string(&w, enum_info.base))
		for name, j in enum_info.names {
			fmt.sbprintf(&w.b, "{{\"name\": %q, \"value\": %d}}%s", name, enum_info.values[j], ", " if j + 1 < len(enum_info.names) else "")
		}
		strings.write_string(&w.b, "]}")
		strings.write_string(&w.b, ",\n" if i + 1 < len(w.enums) else "\n")
	}
	strings.write_string(&w.b, "  ]\n")
	return strings.to_string(w.b)
}

@(private = "file")
write_struct :: proc(w: ^Schema_Writer, ti: ^runtime.Type_Info, kind: int) {
	info, is_struct := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	if !is_struct {
		panic("wire: a message must be a struct")
	}
	fmt.sbprintf(&w.b, "    {{")
	if kind > 0 {
		fmt.sbprintf(&w.b, "\"kind\": %d, ", kind)
	}
	fmt.sbprintf(&w.b, "\"name\": %q, \"fields\": [", type_name(ti))
	for i in 0 ..< info.field_count {
		fmt.sbprintf(&w.b, "{{\"name\": %q, \"type\": %q}}", info.names[i], type_string(w, info.types[i]))
		if i + 1 < info.field_count {
			strings.write_string(&w.b, ", ")
		}
	}
	strings.write_string(&w.b, "]}")
}

// type_string writes a field's type: a number type such as u32, bool, string, [N]T, []T, or the name of a struct or
// an enum, which it adds to the schema's lists.
@(private = "file")
type_string :: proc(w: ^Schema_Writer, ti: ^runtime.Type_Info) -> string {
	base := runtime.type_info_base(ti)
	#partial switch info in base.variant {
	case runtime.Type_Info_Integer:
		return fmt.tprintf("%s%d", "i" if info.signed else "u", base.size * 8)
	case runtime.Type_Info_Float:
		return fmt.tprintf("f%d", base.size * 8)
	case runtime.Type_Info_Boolean:
		if base.size != 1 {
			panic("wire: only bool is supported, not b16, b32 or b64")
		}
		return "bool"
	case runtime.Type_Info_String:
		if info.is_cstring || info.encoding != .UTF_8 {
			panic("wire: only UTF-8 string is supported")
		}
		return "string"
	case runtime.Type_Info_Array:
		return fmt.tprintf("[%d]%s", info.count, type_string(w, info.elem))
	case runtime.Type_Info_Slice:
		return fmt.tprintf("[]%s", type_string(w, info.elem))
	case runtime.Type_Info_Enum:
		add_unique(&w.enums, ti)
		return type_name(ti)
	case runtime.Type_Info_Struct:
		add_unique(&w.structs, ti)
		return type_name(ti)
	}
	panic("wire: a message has a field type that the wire format does not support")
}

@(private = "file")
type_name :: proc(ti: ^runtime.Type_Info) -> string {
	named, ok := ti.variant.(runtime.Type_Info_Named)
	if !ok {
		panic("wire: structs and enums in messages must be named types")
	}
	return named.name
}

@(private = "file")
add_unique :: proc(list: ^[dynamic]^runtime.Type_Info, ti: ^runtime.Type_Info) {
	for t in list {
		if t.id == ti.id {
			return
		}
	}
	append(list, ti)
}
