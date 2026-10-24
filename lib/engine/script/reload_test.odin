package script

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import "cinnabar:engine/asset"
import "cinnabar:engine/ecs"
import format "cinnabar:engine/asset/format"

// Reload_Fixture adds a loose cache, which the tests write blobs into as the cooker would, to the world fixture.
@(private)
Reload_Fixture :: struct {
	using base: ^World_Fixture,
	assets:     ^asset.Assets,
	dir:        string,
	start:      time.Time,
}

@(private)
setup_reload :: proc(t: ^testing.T) -> Reload_Fixture {
	f: Reload_Fixture
	f.base = setup_world(t)
	f.platform.asset_allocator = runtime.heap_allocator()
	f.platform.file_read = core.file_read
	f.platform.file_modified = core.file_modified
	temp, err := os.make_directory_temp("", "reload_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	f.assets = new(asset.Assets)
	asset.init(f.assets, &f.platform, asset.loose_cache(f.dir))
	f.runtime.assets = f.assets
	f.start = time.now()
	return f
}

@(private)
teardown_reload :: proc(f: Reload_Fixture) {
	// The runtime's modules point into the assets, so the runtime goes first.
	destroy(&f.runtime)
	asset.destroy(f.assets)
	free(f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	teardown_world(f.base)
}

// write_script writes a script's blob, as the cooker would. Each version gets a later modification time, so a
// rewrite within the clock's resolution still looks new.
@(private)
write_script :: proc(t: ^testing.T, f: ^Reload_Fixture, n: u8, version: int, source: string, requires: []format.Require_Entry = nil, flags := format.Script_Flags{}) -> format.Guid {
	guid := format.Guid{0 = n, 1 = 0xee}
	bytecode := compile(source)
	defer luau.free_bytecode(raw_data(bytecode))
	blob := format.script_write({guid = guid, flags = flags, bytecode = bytecode, requires = requires, source_path = fmt.tprintf("game/%d.luau", n)}, context.temp_allocator)
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(guid, &buffer))
	testing.expect(t, os.write_entire_file(path, blob) == nil)
	modified := time.time_add(f.start, time.Duration(version) * time.Second)
	testing.expect(t, os.change_times(path, modified, modified) == nil)
	return guid
}

// hot_reload is what the game does at the end of a frame: the asset runtime swaps the rewritten blobs, and the
// script runtime reloads them.
@(private)
hot_reload :: proc(f: ^Reload_Fixture) {
	f.assets.last_poll = -1
	reload_changed(&f.runtime, asset.poll(f.assets))
}

@(private)
UTIL :: 1
@(private)
MAIN :: 2

@(private)
reporting_main :: proc(t: ^testing.T, f: ^Reload_Fixture) {
	util := write_script(t, f, UTIL, 0, "return {value = 1, old = true}")
	main := write_script(t, f, MAIN, 0, `
local util = require("./util")
while true do
	Test.report(util.value)
	Test.report(util.old and 1 or 0)
	Test.report(util.new and 1 or 0)
	coroutine.yield()
end`, {{"./util", util}})
	_, ok := spawn_script(&f.runtime, main)
	testing.expect(t, ok)
	expect_reports(t, f, {1, 1, 0})
}

@(test)
a_reloaded_module_is_patched_in_place :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	reporting_main(t, &f)
	write_script(t, &f, UTIL, 1, "return {value = 2, new = true}")
	hot_reload(&f)
	// The main script holds the same table, which now has the new keys, and lacks the removed one.
	phase(f.base)
	expect_reports(t, f, {2, 0, 1})
}

@(test)
a_failing_version_keeps_the_old_one :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	context.logger = capture_world_errors(f.base)
	reporting_main(t, &f)
	write_script(t, &f, UTIL, 1, "error('broken in the new version')")
	hot_reload(&f)
	expect_world_error(t, f.base, "broken in the new version")
	expect_world_error(t, f.base, "keeps its old version")
	phase(f.base)
	expect_reports(t, f, {1, 1, 0})
}

@(test)
a_behaviour_class_reloads_into_its_instances :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	door := write_script(t, &f, 3, 0, `
local Door = Behaviour.define("Door", {speed = Field.number(1)})
function Door:start() self.count = 10 end
function Door:update() Test.report(1) end
return Door`)
	e := ecs.spawn(&f.world)
	testing.expect(t, attach_script(&f.runtime, e, door))
	phase(f.base)
	expect_reports(t, f, {1})

	write_script(t, &f, 3, 1, `
local Door = Behaviour.define("Door", {speed = Field.number(1), extra = Field.number(5)})
function Door:update() Test.report(2) Test.report(self.count) Test.report(self.extra) end
function Door:on_reload() Test.report(9) end
return Door`)
	hot_reload(&f)
	expect_reports(t, f, {9})
	// The instance keeps its state, gets the new field's default, and runs the new update.
	phase(f.base)
	expect_reports(t, f, {2, 10, 5})

	// A version without update stops the calls.
	write_script(t, &f, 3, 2, `
local Door = Behaviour.define("Door", {speed = Field.number(1)})
return Door`)
	hot_reload(&f)
	phase(f.base)
	expect_reports(t, f, {})
}

@(test)
a_main_script_restarts :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	main := write_script(t, &f, MAIN, 0, "while true do Test.report(1) coroutine.yield() end")
	script, ok := spawn_script(&f.runtime, main)
	testing.expect(t, ok)
	expect_reports(t, f, {1})
	write_script(t, &f, MAIN, 1, "while true do Test.report(2) coroutine.yield() end")
	hot_reload(&f)
	// The new version runs from the top, until its first wait, and the old thread is gone.
	expect_reports(t, f, {2})
	phase(f.base)
	expect_reports(t, f, {2})
	// The handle still stops it after the restart.
	stop(&f.runtime, script)
	phase(f.base)
	expect_reports(t, f, {})
}

@(test)
modules_reload_before_main_scripts_restart :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	// The main script reads the module once, at its top level, so it sees only the version that it required.
	util := write_script(t, &f, UTIL, 0, "return {value = 1}")
	main := write_script(t, &f, MAIN, 0, `
local value = require("./util").value
while true do Test.report(value) coroutine.yield() end`, {{"./util", util}})
	_, ok := spawn_script(&f.runtime, main)
	testing.expect(t, ok)
	expect_reports(t, f, {1})
	// The main script's blob comes first in the asset table, so its swap comes first in poll's list too.
	write_script(t, &f, MAIN, 1, `
local value = require("./util").value
while true do Test.report(value + 10) coroutine.yield() end`, {{"./util", util}})
	write_script(t, &f, UTIL, 1, "return {value = 2}")
	hot_reload(&f)
	expect_reports(t, f, {12})
}

@(test)
attached_scripts_take_field_values_and_skip_bad_ones :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	door := write_script(t, &f, 4, 0, `
local Door = Behaviour.define("Door", {speed = Field.number(1), label = Field.string("door")})
function Door:start()
	Test.report(self.speed)
	Test.report(self.label == "door" and 1 or 0)
end
return Door`)
	e := ecs.spawn(&f.world)
	fields := []Behaviour_Field{{name = "speed", kind = .Number, number = 3}, {name = "label", kind = .Boolean, boolean = true}, {name = "colour", kind = .Number, number = 2}}
	testing.expect(t, attach_script(&f.runtime, e, door, fields))
	phase(f.base)
	// The wrong type and the unknown field are skipped with warnings, and the rest is set.
	expect_reports(t, f, {3, 1})
}

@(test)
editor_operations_set_reset_and_detach_behaviours :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	door := write_script(t, &f, 5, 0, `
local Door = Behaviour.define("Door", {speed = Field.number(1)})
function Door:update() Test.report(self.speed) end
function Door:on_destroy() Test.report(-1) end
return Door`)
	e := ecs.spawn(&f.world)
	testing.expect(t, attach_script(&f.runtime, e, door))
	phase(f.base)
	expect_reports(t, f, {1})

	testing.expect_value(t, set_behaviour_field(&f.runtime, e, door, {name = "speed", kind = .Number, number = 4}), "")
	testing.expect_value(t, set_behaviour_field(&f.runtime, e, door, {name = "speed", kind = .String, text = "x"}), "Door.speed takes a number")
	testing.expect_value(t, set_behaviour_field(&f.runtime, e, door, {name = "size", kind = .Number}), "Door has no field size")
	phase(f.base)
	expect_reports(t, f, {4})

	snapshots := inspect(&f.runtime, e, context.temp_allocator)
	testing.expect_value(t, snapshots[0].script, door)

	testing.expect_value(t, set_behaviour_field(&f.runtime, e, door, {name = "speed"}, reset = true), "")
	phase(f.base)
	expect_reports(t, f, {1})

	testing.expect(t, detach_script(&f.runtime, e, door))
	expect_reports(t, f, {-1})
	testing.expect(t, !detach_script(&f.runtime, e, door))
	testing.expect_value(t, set_behaviour_field(&f.runtime, e, door, {name = "speed", kind = .Number}), "the entity has no Door")
}
