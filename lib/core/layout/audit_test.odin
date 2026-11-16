package layout

import win "core:sys/windows"
import "core:testing"

// The test executable's image, which plays the old DLL's: its procedures and string literals are in it, and what the
// test allocates is not.
@(private = "file")
own_image :: proc() -> Range {
	base := uintptr(win.GetModuleHandleW(nil))
	dos := (^win.IMAGE_DOS_HEADER)(base)
	nt := (^win.IMAGE_NT_HEADERS64)(base + uintptr(dos.e_lfanew))
	return {base, base + uintptr(nt.OptionalHeader.SizeOfImage)}
}

@(private = "file")
on_hit :: proc(damage: int) {}

@(private = "file")
Item :: struct {
	name:  string,
	count: int,
}

@(private = "file")
Node :: struct {
	next:  ^Node,
	label: string,
}

@(private = "file")
Audited :: struct {
	callbacks: struct {
		on_hit: proc(damage: int),
	},
	items:     []Item,
	by_name:   map[string]Item,
	choice:    union {
		int,
		Item,
	},
	ring:      ^Node,
	samples:   [dynamic]f32,
	kind:      typeid,
}

@(test)
audit_names_each_address_in_the_image :: proc(t: ^testing.T) {
	image := own_image()

	items := make([]Item, 2, context.temp_allocator)
	items[0] = {
		name  = clone_string("allocated"),
		count = 1,
	}
	items[1] = {
		name  = "literal",
		count = 2,
	}
	by_name := make(map[string]Item, context.temp_allocator)
	by_name[clone_string("key")] = {
		name = "value",
	}
	ring := new(Node, context.temp_allocator)
	ring^ = {
		next  = ring,
		label = "ring",
	}
	samples := make([dynamic]f32, 1000, context.temp_allocator)
	s := Audited {
		items = items,
		by_name = by_name,
		choice = Item{name = "chosen"},
		ring = ring,
		samples = samples,
		kind = typeid_of(Item),
	}
	s.callbacks.on_hit = on_hit

	findings := audit(&s, Audited, image, "State", context.temp_allocator)
	paths := make(map[string]uintptr, context.temp_allocator)
	for f in findings {
		paths[f.path] = f.address
	}
	testing.expect_value(t, paths["State.callbacks.on_hit"], uintptr(rawptr(on_hit)))
	testing.expect(t, "State.items[1].name" in paths)
	testing.expect(t, "State.by_name[key].name" in paths)
	testing.expect(t, "State.choice.(Item).name" in paths)
	testing.expect(t, "State.ring^.label" in paths)
	// The map and the dynamic array were made with this image's temp allocator.
	testing.expect(t, "State.by_name.allocator" in paths)
	testing.expect(t, "State.samples.allocator" in paths)
	testing.expect_value(t, len(findings), 7)

	outside := audit(&s, Audited, {1, 2}, "State", context.temp_allocator)
	testing.expect_value(t, len(outside), 0)
}

@(test)
audit_checks_a_containers_allocator :: proc(t: ^testing.T) {
	// The dynamic array's allocator is this image's runtime heap, as a DLL's own would be.
	values := make([dynamic]int, 0, 4, context.allocator)
	defer delete(values)
	findings := audit(&values, [dynamic]int, own_image(), "values", context.temp_allocator)
	testing.expect_value(t, len(findings), 1)
	if len(findings) == 1 {
		testing.expect_value(t, findings[0].path, "values.allocator")
	}
}

@(private = "file")
clone_string :: proc(s: string) -> string {
	b := make([]byte, len(s), context.temp_allocator)
	copy(b, s)
	return string(b)
}
