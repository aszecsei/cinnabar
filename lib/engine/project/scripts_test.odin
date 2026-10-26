package project

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "cinnabar:core"
import script_host "cinnabar:core/script"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

// The Script_Quality that the test's registration defines the bindings with, and the files that save_quality wrote.
@(private = "file")
test_quality: ^Script_Quality
@(private = "file")
written: map[string]string

// The script fails the test with an error if an assertion does not hold.
@(private = "file")
QUALITY_SCRIPT :: `
local q = Render.quality()
assert(q.preset == "High" and q.aa == "Taa" and q.render_scale == 1 and q.ray_traced_shadows == false, "the renderer's quality")
assert(#Render.presets() == 4 and Render.presets()[1] == "Low")
local caps = Render.caps()
assert(table.find(caps.aa, "Fsr") and not caps.ray_query and caps.vendor == "Amd")

-- The fields that a change gives, and the others as they were.
Render.set_quality({ aa = "Fsr", render_scale = 0.5, ao = "Hbao", lod_error = 2 })
q = Render.quality()
assert(q.aa == "Fsr" and q.render_scale == 0.5 and q.ao == "Hbao" and q.lod_error == 2 and q.shadows == "High" and q.preset == "Custom")

-- A field that does not exist, or a value that does not fit, raises an error and changes nothing.
local ok, err = pcall(Render.set_quality, { aa = "Msaa" })
assert(not ok and string.find(err, "quality.aa takes"), err)
ok, err = pcall(Render.set_quality, { speed = 2 })
assert(not ok and string.find(err, "no quality field"), err)
ok, err = pcall(Render.set_quality, { aa = "Off", ray_traced_shadows = {} })
assert(not ok and Render.quality().aa == "Fsr", err)

-- Traced shadows need Ray_Query, which the device does not have.
Render.set_quality({ ray_traced_shadows = true })
assert(Render.quality().ray_traced_shadows == false)

-- A preset sets every feature, then the other fields.
Render.set_quality({ preset = "Low", aa = "Smaa" })
assert(Render.save_quality())
`

@(test)
scripts_read_set_and_save_the_quality :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	written = make(map[string]string)
	defer {
		for _, text in written {
			delete(text)
		}
		delete(written)
	}
	platform := core.Platform_API {
		frame_allocator      = virtual.arena_allocator(&arena),
		script_open          = script_host.open,
		script_close         = script_host.close,
		script_push_binding  = script_host.push_binding,
		script_atom          = script_host.atom,
		script_direct_access = script_host.direct_access,
		file_read            = proc(path: string, align: int, allocator: runtime.Allocator) -> ([]byte, bool) {
			text, ok := written[path]
			return transmute([]byte)text, ok
		},
		file_write           = proc(path: string, data: []byte) -> bool {
			if old, ok := written[path]; ok {
				delete(old)
			}
			written[path] = strings.clone(string(data))
			return true
		},
	}
	// A Renderer is too large for the stack.
	renderer := new(render.Renderer)
	defer free(renderer)
	renderer.caps = {vendor = .Amd, upscalers = {.Fsr}}
	renderer.quality = render.preset_quality(.High, renderer.caps)
	q := script_quality(renderer, "game/project.settings")
	test_quality = &q

	r := new(script.Runtime)
	defer free(r)
	testing.expect(t, script.init(r, &platform, nil, nil, proc(r: ^script.Runtime) {define_quality_bindings(r, test_quality)}))
	defer script.destroy(r)
	_, ok := script.spawn_source(r, "=quality", QUALITY_SCRIPT)
	testing.expect(t, ok)

	want := render.preset_quality(.Low, renderer.caps)
	want.aa = .Smaa
	testing.expect_value(t, renderer.quality, want)
	saved: Settings
	parse(written["game/project.user.settings"], &saved)
	testing.expect_value(t, quality(saved, renderer.caps), want)
}
