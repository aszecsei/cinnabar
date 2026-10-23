package engine

import "base:runtime"
import "core:hash"
import "core:reflect"

// Deep enough for any real state; it stops recursion through self-referential types.
@(private = "file")
MAX_DEPTH :: 16

// layout_hash hashes the field names, offsets and types reachable from T.
// The host compares it across reloads to detect a Game_State layout change.
layout_hash :: proc($T: typeid) -> u64 {
	h := hash.fnv64a(nil)
	hash_type(&h, type_info_of(T), 0)
	return h
}

@(private = "file")
hash_type :: proc(h: ^u64, ti: ^runtime.Type_Info, depth: int) {
	if ti == nil || depth > MAX_DEPTH {
		return
	}
	mix(h, u64(reflect.type_kind(ti.id)))
	mix(h, u64(ti.size))
	mix(h, u64(ti.align))

	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		mix_string(h, v.name)
		hash_type(h, v.base, depth + 1)
	case runtime.Type_Info_Struct:
		for i in 0 ..< v.field_count {
			mix_string(h, v.names[i])
			mix(h, u64(v.offsets[i]))
			hash_type(h, v.types[i], depth + 1)
		}
	case runtime.Type_Info_Union:
		for variant in v.variants {
			hash_type(h, variant, depth + 1)
		}
	case runtime.Type_Info_Array:
		mix(h, u64(v.count))
		hash_type(h, v.elem, depth + 1)
	case runtime.Type_Info_Enumerated_Array:
		mix(h, u64(v.count))
		hash_type(h, v.elem, depth + 1)
		hash_type(h, v.index, depth + 1)
	case runtime.Type_Info_Pointer:
		hash_type(h, v.elem, depth + 1)
	case runtime.Type_Info_Multi_Pointer:
		hash_type(h, v.elem, depth + 1)
	case runtime.Type_Info_Slice:
		hash_type(h, v.elem, depth + 1)
	case runtime.Type_Info_Dynamic_Array:
		hash_type(h, v.elem, depth + 1)
	}
}

@(private = "file")
mix :: proc(h: ^u64, v: u64) {
	v := v
	h^ = hash.fnv64a(([^]byte)(&v)[:size_of(v)], h^)
}

@(private = "file")
mix_string :: proc(h: ^u64, s: string) {
	mix(h, u64(len(s)))
	h^ = hash.fnv64a(transmute([]byte)s, h^)
}
