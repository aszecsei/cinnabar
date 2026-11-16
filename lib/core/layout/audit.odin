package layout

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"

// Range is an address range, [lo, hi): the image of a loaded DLL, for audit.
Range :: struct {
	lo, hi: uintptr,
}

// Finding is a value that audit found inside the range: where it is, as a field path from the root, and its address.
Finding :: struct {
	path:    string,
	address: uintptr,
}

// Deeper than MAX_DEPTH, since a value walk also counts the pointers, slices and maps it goes through.
@(private = "file")
AUDIT_DEPTH :: 32

// audit walks the value at data, of type T, through its type info and returns every address in it that lies in image:
// procedures, pointers, string data, slices' and dynamic arrays' data, the allocators of dynamic arrays and maps, and
// any's data. It follows struct fields, arrays, slices, dynamic arrays, maps, unions' variants and typed pointers, each
// pointer's target once, and skips types that hold no address. A typeid is a hash, not an address, so it cannot show.
// The host runs it after on_reload with the old DLL's image (see docs/overview/hot-reload.md#rules). root begins each
// path. The paths are in allocator.
audit :: proc(
	data: rawptr,
	$T: typeid,
	image: Range,
	root: string,
	allocator := context.allocator,
) -> []Finding {
	return audit_typeid(data, T, image, root, allocator)
}

// audit_typeid is audit of a type known only when the program runs, such as a project's state that a procedure gives.
audit_typeid :: proc(
	data: rawptr,
	id: typeid,
	image: Range,
	root: string,
	allocator := context.allocator,
) -> []Finding {
	a := Auditor {
		image     = image,
		allocator = allocator,
		findings  = make([dynamic]Finding, allocator),
		visited   = make(map[Visit]struct{}, context.temp_allocator),
		holds     = make(map[^runtime.Type_Info]bool, context.temp_allocator),
	}
	strings.builder_init(&a.path, context.temp_allocator)
	strings.write_string(&a.path, root)
	walk(&a, data, type_info_of(id), true, 0)
	return a.findings[:]
}

@(private = "file")
Visit :: struct {
	address: uintptr,
	id:      typeid,
}

@(private = "file")
Auditor :: struct {
	image:     Range,
	allocator: runtime.Allocator,
	findings:  [dynamic]Finding,
	// The path of the value that walk is at. Each step appends its part and truncates it again.
	path:      strings.Builder,
	// The pointers' targets already walked, so a cycle ends.
	visited:   map[Visit]struct{},
	// may_hold_address of each type, once.
	holds:     map[^runtime.Type_Info]bool,
}

// walk checks the value at data and goes into it. follow is false inside a raw union, whose members overlap: their
// addresses are checked, but nothing is read through them.
@(private = "file")
walk :: proc(a: ^Auditor, data: rawptr, ti: ^runtime.Type_Info, follow: bool, depth: int) {
	if data == nil || ti == nil || depth > AUDIT_DEPTH || !may_hold_address(a, ti) {
		return
	}
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		walk(a, data, v.base, follow, depth)
	case runtime.Type_Info_Procedure, runtime.Type_Info_Multi_Pointer:
		check(a, (^uintptr)(data)^)
	case runtime.Type_Info_Pointer:
		target := (^rawptr)(data)^
		if check(a, uintptr(target)) || !follow || v.elem == nil || target == nil {
			return
		}
		visit := Visit{uintptr(target), v.elem.id}
		if visit in a.visited {
			return
		}
		a.visited[visit] = {}
		mark := push(a, "^")
		walk(a, target, v.elem, true, depth + 1)
		pop(a, mark)
	case runtime.Type_Info_String:
		// A cstring is a pointer; a string's and a string16's data come first.
		check(a, (^uintptr)(data)^)
	case runtime.Type_Info_Any:
		check(a, uintptr((^runtime.Raw_Any)(data).data))
	case runtime.Type_Info_Struct:
		raw_union := .raw_union in v.flags
		for i in 0 ..< int(v.field_count) {
			mark := push(a, ".", v.names[i])
			walk(
				a,
				rawptr(uintptr(data) + v.offsets[i]),
				v.types[i],
				follow && !raw_union,
				depth + 1,
			)
			pop(a, mark)
		}
	case runtime.Type_Info_Union:
		if !follow {
			return
		}
		variant := reflect.union_variant_typeid(any{data, ti.id})
		if variant == nil {
			return
		}
		mark := push(a, ".(", fmt.tprint(variant), ")")
		walk(a, data, type_info_of(variant), true, depth + 1)
		pop(a, mark)
	case runtime.Type_Info_Array:
		walk_elements(a, data, v.count, v.elem, v.elem_size, follow, depth)
	case runtime.Type_Info_Enumerated_Array:
		walk_elements(a, data, v.count, v.elem, v.elem_size, follow, depth)
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		count := clamp((^int)(uintptr(data) + v.len_offset)^, 0, v.capacity)
		walk_elements(a, data, count, v.elem, v.elem_size, follow, depth)
	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(data)
		if !check(a, uintptr(raw.data)) && follow {
			walk_elements(a, raw.data, raw.len, v.elem, v.elem_size, true, depth + 1)
		}
	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(data)
		check_allocator(a, raw.allocator)
		if !check(a, uintptr(raw.data)) && follow {
			walk_elements(a, raw.data, raw.len, v.elem, v.elem_size, true, depth + 1)
		}
	case runtime.Type_Info_Map:
		raw := (^runtime.Raw_Map)(data)
		check_allocator(a, raw.allocator)
		if raw.data == 0 || check(a, runtime.map_data(raw^)) || !follow {
			return
		}
		it: int
		for key, value in reflect.iterate_map(any{data, ti.id}, &it) {
			mark := push(a, "[", fmt.tprint(key), "]")
			walk(a, value.data, v.value, true, depth + 1)
			key_mark := push(a, ".key")
			walk(a, key.data, v.key, true, depth + 1)
			pop(a, key_mark)
			pop(a, mark)
		}
	}
}

@(private = "file")
walk_elements :: proc(
	a: ^Auditor,
	data: rawptr,
	count: int,
	elem: ^runtime.Type_Info,
	elem_size: int,
	follow: bool,
	depth: int,
) {
	if data == nil || !may_hold_address(a, elem) {
		return
	}
	for i in 0 ..< count {
		mark := push(a, "[", fmt.tprint(i), "]")
		walk(a, rawptr(uintptr(data) + uintptr(i * elem_size)), elem, follow, depth + 1)
		pop(a, mark)
	}
}

// check records address if it is in the image, and returns whether it was.
@(private = "file")
check :: proc(a: ^Auditor, address: uintptr) -> bool {
	if address < a.image.lo || address >= a.image.hi {
		return false
	}
	append(&a.findings, Finding{strings.clone(strings.to_string(a.path), a.allocator), address})
	return true
}

// check_allocator checks a container's allocator, whose procedure is the image's own when the DLL's runtime made it.
@(private = "file")
check_allocator :: proc(a: ^Auditor, allocator: runtime.Allocator) {
	mark := push(a, ".allocator")
	check(a, uintptr(rawptr(allocator.procedure)))
	pop(a, mark)
}

@(private = "file")
push :: proc(a: ^Auditor, parts: ..string) -> int {
	mark := strings.builder_len(a.path)
	for part in parts {
		strings.write_string(&a.path, part)
	}
	return mark
}

@(private = "file")
pop :: proc(a: ^Auditor, mark: int) {
	resize(&a.path.buf, mark)
}

// may_hold_address is whether a value of the type can hold an address that audit checks, so a walk skips, for
// instance, a slice of floats at once.
@(private = "file")
may_hold_address :: proc(a: ^Auditor, ti: ^runtime.Type_Info) -> bool {
	if ti == nil {
		return false
	}
	if holds, ok := a.holds[ti]; ok {
		return holds
	}
	// A type that refers to itself does so through a pointer, which holds an address.
	a.holds[ti] = false
	holds := false
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		holds = may_hold_address(a, v.base)
	case runtime.Type_Info_Pointer,
	     runtime.Type_Info_Multi_Pointer,
	     runtime.Type_Info_Procedure,
	     runtime.Type_Info_String,
	     runtime.Type_Info_Any,
	     runtime.Type_Info_Slice,
	     runtime.Type_Info_Dynamic_Array,
	     runtime.Type_Info_Map:
		holds = true
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			if may_hold_address(a, v.types[i]) {
				holds = true
				break
			}
		}
	case runtime.Type_Info_Union:
		for variant in v.variants {
			if may_hold_address(a, variant) {
				holds = true
				break
			}
		}
	case runtime.Type_Info_Array:
		holds = may_hold_address(a, v.elem)
	case runtime.Type_Info_Enumerated_Array:
		holds = may_hold_address(a, v.elem)
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		holds = may_hold_address(a, v.elem)
	}
	a.holds[ti] = holds
	return holds
}
