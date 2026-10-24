package script

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/luau"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// Module_Fixture adds a loose cache in a temporary directory to the script fixture.
@(private)
Module_Fixture :: struct {
	using base: ^Fixture,
	assets:     ^asset.Assets,
	dir:        string,
	next:       u8,
}

@(private)
setup_modules :: proc(t: ^testing.T) -> Module_Fixture {
	f: Module_Fixture
	f.base = setup(t, register_first_build)
	f.platform.asset_allocator = runtime.heap_allocator()
	f.platform.file_read = core.file_read
	f.platform.file_modified = core.file_modified
	f.platform.time_seconds = proc() -> f64 {return 0}
	temp, err := os.make_directory_temp("", "module_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	f.assets = new(asset.Assets)
	asset.init(f.assets, &f.platform, asset.loose_cache(f.dir))
	f.runtime.assets = f.assets
	return f
}

@(private)
teardown_modules :: proc(f: Module_Fixture) {
	asset.destroy(f.assets)
	free(f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	teardown(f.base)
}

// add_script compiles source and writes its blob into the cache, as the cooker would.
@(private)
add_script :: proc(t: ^testing.T, f: ^Module_Fixture, name, source: string, requires: []format.Require_Entry = nil) -> format.Guid {
	f.next += 1
	guid := format.Guid{0 = f.next}
	bytecode := compile(source)
	defer luau.free_bytecode(raw_data(bytecode))
	blob := format.script_write({guid = guid, bytecode = bytecode, requires = requires, source_path = name}, context.temp_allocator)
	buffer: [32]u8
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(guid, &buffer)), blob) == nil)
	return guid
}

@(test)
a_module_runs_once_and_its_result_is_shared :: proc(t: ^testing.T) {
	f := setup_modules(t)
	defer teardown_modules(f)
	context.user_ptr = f.base
	util := add_script(t, &f, "game/util.luau", "Test.report(1); return {value = 2}")
	other := add_script(t, &f, "game/other.luau", "return require('./util')", {{"./util", util}})
	main := add_script(
		t,
		&f,
		"game/main.luau",
		"local a = require('./util'); local b = require('./other'); Test.report(a.value); Test.report(a == b and 3 or 0)",
		{{"./other", other}, {"./util", util}},
	)
	_, ok := spawn_script(&f.runtime, main)
	testing.expect(t, ok)
	testing.expect_value(t, len(f.reports), 3)
	if len(f.reports) == 3 {
		testing.expect_value(t, f.reports[0], 1)
		testing.expect_value(t, f.reports[1], 2)
		testing.expect_value(t, f.reports[2], 3)
	}
}

@(test)
a_module_that_returns_nothing_gives_true :: proc(t: ^testing.T) {
	f := setup_modules(t)
	defer teardown_modules(f)
	context.user_ptr = f.base
	empty := add_script(t, &f, "game/empty.luau", "local x = 1")
	main := add_script(t, &f, "game/main.luau", "Test.report(require('./empty') == true and 1 or 0)", {{"./empty", empty}})
	_, ok := spawn_script(&f.runtime, main)
	testing.expect(t, ok)
	testing.expect_value(t, len(f.reports), 1)
	if len(f.reports) == 1 {
		testing.expect_value(t, f.reports[0], 1)
	}
}

@(test)
modules_have_their_own_globals :: proc(t: ^testing.T) {
	f := setup_modules(t)
	defer teardown_modules(f)
	context.user_ptr = f.base
	writer := add_script(t, &f, "game/writer.luau", "leaked = 1; return true")
	main := add_script(t, &f, "game/main.luau", "require('./writer'); Test.report(leaked == nil and 1 or 0)", {{"./writer", writer}})
	_, ok := spawn_script(&f.runtime, main)
	testing.expect(t, ok)
	testing.expect_value(t, len(f.reports), 1)
	if len(f.reports) == 1 {
		testing.expect_value(t, f.reports[0], 1)
	}
}

@(test)
require_fails_without_a_cooked_path :: proc(t: ^testing.T) {
	f := setup_modules(t)
	defer teardown_modules(f)
	context.user_ptr = f.base
	context.logger = capture_errors(f.base)
	main := add_script(t, &f, "game/main.luau", "require('./unknown')")
	_, ok := spawn_script(&f.runtime, main)
	testing.expect(t, !ok)
	expect_error(t, f.base, `game/main.luau:1: the cooker did not resolve require("./unknown")`)

	_, ok = spawn_source(&f.runtime, "=source", "require('./unknown')")
	testing.expect(t, !ok)
	expect_error(t, f.base, "require works only in cooked scripts")
}

@(test)
a_failed_module_can_be_required_again :: proc(t: ^testing.T) {
	f := setup_modules(t)
	defer teardown_modules(f)
	context.user_ptr = f.base
	context.logger = capture_errors(f.base)
	broken := add_script(t, &f, "game/broken.luau", "Test.report(1); error('broken at load')")
	main := add_script(
		t,
		&f,
		"game/main.luau",
		"local ok = pcall(require, './broken'); Test.report(ok and 0 or 2); ok = pcall(require, './broken'); Test.report(ok and 0 or 3)",
		{{"./broken", broken}},
	)
	_, ok := spawn_script(&f.runtime, main)
	testing.expect(t, ok)
	// The module ran both times, so its first report is there twice.
	testing.expect_value(t, len(f.reports), 4)
	if len(f.reports) == 4 {
		testing.expect_value(t, f.reports[1], 2)
		testing.expect_value(t, f.reports[3], 3)
	}
}

@(test)
a_require_cycle_fails_at_runtime_too :: proc(t: ^testing.T) {
	f := setup_modules(t)
	defer teardown_modules(f)
	context.user_ptr = f.base
	context.logger = capture_errors(f.base)
	// The cooker rejects cycles. A blob from an old cook can still have one.
	a_guid := format.Guid{0 = 100}
	b := add_script(t, &f, "game/b.luau", "return require('./a')", {{"./a", a_guid}})
	f.next = 99
	a := add_script(t, &f, "game/a.luau", "return require('./b')", {{"./b", b}})
	testing.expect_value(t, a, a_guid)
	main := add_script(t, &f, "game/main.luau", "require('./a')", {{"./a", a}})
	_, ok := spawn_script(&f.runtime, main)
	testing.expect(t, !ok)
	expect_error(t, f.base, "require cycle at game/a.luau")
}
