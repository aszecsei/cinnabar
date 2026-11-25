package save

import "core:c"
import "core:fmt"
import "core:log"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "cinnabar:core/luau"
import "cinnabar:engine/script"

// The Save library that scripts see (see docs/scripting/api.md#save): Save.read and Save.write, which keep a table of
// strings, numbers and booleans in <Platform_API.save_dir>/<name>.save.

// The file's extension.
EXTENSION :: ".save"

// register_scripts defines the Save library. A game's Register_Proc calls it, so init and every reload define it
// again. The bindings keep nothing: they find the folder in the platform when a script calls them.
register_scripts :: proc(r: ^script.Runtime) {
	script.define(r, "Save.read", read_binding, "(name: string) -> SaveData?")
	script.define(r, "Save.write", write_binding, "(name: string, data: SaveData) -> boolean")
}

// path_of is the file of a save, in the frame's memory.
@(private = "file")
path_of :: proc(r: ^script.Runtime, name: string) -> string {
	allocator := r.platform.frame_allocator
	path, _ := filepath.join(
		{r.platform.save_dir, strings.concatenate({name, EXTENSION}, allocator)},
		allocator,
	)
	return path
}

// checked_name is argument 1, which must pass check_name.
@(private = "file")
checked_name :: proc(L: ^luau.State, r: ^script.Runtime, binding: string) -> string {
	size: c.size_t
	text := luau.L_checklstring(L, 1, &size)
	name := string(text[:size])
	if !check_name(name) {
		script.raise(
			L,
			fmt.aprintf(
				"%s: %q is not a save's name: use 1 to %d of a to z, 0 to 9, _ and -",
				binding,
				name,
				MAX_NAME,
				allocator = r.platform.frame_allocator,
			),
		)
	}
	return name
}

// Save.read(name) is the table of a save's entries, or nil when there is no file. A malformed line is logged as a
// warning, and the other lines are in the table.
@(private = "file")
read_binding :: proc(L: ^luau.State) -> c.int {
	r := script.runtime_of(L)
	name := checked_name(L, r, "Save.read")
	data, ok := r.platform.file_read(path_of(r, name), 1, r.platform.frame_allocator)
	if !ok {
		luau.pushnil(L)
		return 1
	}
	entries, problems := parse(string(data), r.platform.frame_allocator)
	if len(problems) > 0 {
		luau.L_where(L, 1)
		location := luau.toodinstring(L, -1)
		for p in problems {
			log.warnf("%sSave.read(%q): line %d: %s", location, name, p.line, p.message)
		}
		luau.pop(L, 1)
	}
	luau.createtable(L, 0, c.int(len(entries)))
	for e in entries {
		luau.pushodinstring(L, e.key)
		value: script.Value
		switch v in e.value {
		case f64:
			value = v
		case bool:
			value = v
		case string:
			value = v
		}
		script.push_value(r, L, value)
		luau.rawset(L, -3)
	}
	return 1
}

// Save.write(name, data) writes the table to the save's file, whole and at once, and is whether it did. A key that is
// not valid, a value that is not a string, a number or a boolean, and a number that is not finite raise an error and
// write nothing.
@(private = "file")
write_binding :: proc(L: ^luau.State) -> c.int {
	r := script.runtime_of(L)
	name := checked_name(L, r, "Save.write")
	luau.L_checktype(L, 2, .TABLE)
	allocator := r.platform.frame_allocator
	entries := make([dynamic]Entry, allocator)
	luau.pushnil(L)
	for luau.next(L, 2) {
		if luau.type(L, -2) != .STRING {
			script.raise(L, "Save.write: the keys must be strings")
		}
		key := luau.toodinstring(L, -2)
		if !check_key(key) {
			script.raise(
				L,
				fmt.aprintf(
					"Save.write: %q is not a key: use A to Z, a to z, 0 to 9, _ and .",
					key,
					allocator = allocator,
				),
			)
		}
		read, ok := script.check_value(r, L, -1, {.Number, .Boolean, .String})
		if !ok {
			script.raise(
				L,
				fmt.aprintf(
					"Save.write: %q holds a %s, and a save holds strings, numbers and booleans",
					key,
					luau.L_typename(L, -1),
					allocator = allocator,
				),
			)
		}
		value: Value
		// check_value gives no other kind.
		#partial switch v in read {
		case f64:
			if v - v != 0 {
				script.raise(
					L,
					fmt.aprintf(
						"Save.write: %q is not a finite number",
						key,
						allocator = allocator,
					),
				)
			}
			value = v
		case bool:
			value = v
		case string:
			value = v
		}
		append(&entries, Entry{key, value})
		luau.pop(L, 1)
	}
	slice.sort_by(entries[:], proc(a, b: Entry) -> bool {return a.key < b.key})
	text := format(entries[:], allocator)
	luau.pushboolean(L, b32(r.platform.file_write(path_of(r, name), transmute([]byte)text)))
	return 1
}
