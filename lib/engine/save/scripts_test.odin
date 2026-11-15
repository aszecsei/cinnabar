package save

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "cinnabar:core"
import script_host "cinnabar:core/script"
import "cinnabar:engine/script"

@(private = "file")
written: map[string]string

@(private = "file")
SAVE_SCRIPT :: `
assert(Save.read("records") == nil, "a save that was never written is nil")
assert(Save.write("records", { best = 41.25, name = "Mara \"M\"\nline", sound = false }))
local back = Save.read("records")
assert(back ~= nil and back.best == 41.25 and back.name == "Mara \"M\"\nline" and back.sound == false)

-- A file with a bad line reads the other lines.
local partial = Save.read("partial")
assert(partial ~= nil and partial.kept == 1 and partial.lost == nil)

local ok, err = pcall(Save.write, "records", { nested = { 1, 2 } })
assert(not ok and string.find(err, "holds a table"), err)
ok, err = pcall(Save.write, "records", { ["bad key"] = 1 })
assert(not ok and string.find(err, "is not a key"), err)
ok, err = pcall(Save.write, "records", { n = 0 / 0 })
assert(not ok and string.find(err, "finite"), err)
ok, err = pcall(Save.write, "../escape", {})
assert(not ok and string.find(err, "not a save's name"), err)
ok, err = pcall(Save.read, "a/b")
assert(not ok and string.find(err, "not a save's name"), err)
-- A refused write leaves the file as it was.
assert(Save.read("records").best == 41.25)
`

@(test)
scripts_write_and_read_a_save :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	written = make(map[string]string)
	defer {
		for path, text in written {
			delete(text)
			delete(path)
		}
		delete(written)
	}
	written[strings.clone("saves\\partial.save")] = strings.clone("save 1\nkept = 1\nlost = ?\n")
	platform := core.Platform_API {
		frame_allocator = virtual.arena_allocator(&arena),
		save_dir = "saves",
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
		file_read = proc(
			path: string,
			align: int,
			allocator: runtime.Allocator,
		) -> (
			[]byte,
			bool,
		) {
			text, ok := written[path]
			return transmute([]byte)text, ok
		},
		file_write = proc(path: string, data: []byte) -> bool {
			if old, ok := written[path]; ok {
				delete(old)
				written[path] = strings.clone(string(data))
			} else {
				written[strings.clone(path)] = strings.clone(string(data))
			}
			return true
		},
	}
	r := new(script.Runtime)
	defer free(r)
	testing.expect(t, script.init(r, &platform, nil, nil, register_scripts))
	defer script.destroy(r)
	_, ok := script.spawn_source(r, "=save", SAVE_SCRIPT)
	testing.expect(t, ok)
	testing.expect_value(
		t,
		written["saves\\records.save"],
		"save 1\nbest = 41.25\nname = \"Mara \\\"M\\\"\\nline\"\nsound = false\n",
	)
}
