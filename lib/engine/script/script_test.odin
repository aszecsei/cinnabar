package script

import "core:c"
import "core:log"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"

@(private)
Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	runtime:  Runtime,
	// What the scripts reported through Test.report.
	reports:  [dynamic]f64,
	// The errors that the runtime logged. The test runner fails a test that logs an error, so tests that expect
	// errors capture them with capture_errors.
	errors:   [dynamic]string,
}

// capture_errors returns a logger that records errors in the fixture instead of failing the test.
@(private)
capture_errors :: proc(f: ^Fixture) -> log.Logger {
	return {
		procedure = proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
			f := (^Fixture)(data)
			if level >= .Error {
				append(&f.errors, strings.clone(text))
			}
		},
		data = f,
		lowest_level = .Error,
	}
}

@(private)
expect_error :: proc(t: ^testing.T, f: ^Fixture, fragment: string, loc := #caller_location) {
	for e in f.errors {
		if strings.contains(e, fragment) {
			return
		}
	}
	testing.expectf(t, false, "no error contains %q: %v", fragment, f.errors, loc = loc)
}

// The fixture holds the bindings table, so it lives on the heap and does not move. Bindings find it through
// context.user_ptr, so each test sets that.
@(private)
setup :: proc(t: ^testing.T, register: Register_Proc) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator     = virtual.arena_allocator(&f.frame),
		script_open         = script_host.open,
		script_close        = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom         = script_host.atom,
	}
	f.reports = make([dynamic]f64)
	f.errors = make([dynamic]string)
	testing.expect(t, init(&f.runtime, &f.platform, nil, nil, register))
	return f
}

@(private)
teardown :: proc(f: ^Fixture) {
	destroy(&f.runtime)
	delete(f.reports)
	for e in f.errors {
		delete(e)
	}
	delete(f.errors)
	virtual.arena_destroy(&f.frame)
	free(f)
}

@(private)
report :: proc(L: ^luau.State) -> c.int {
	f := (^Fixture)(context.user_ptr)
	append(&f.reports, luau.L_checknumber(L, 1))
	return 0
}

@(private)
register_first_build :: proc(r: ^Runtime) {
	define(r, "Test.value", proc(L: ^luau.State) -> c.int {
		luau.pushnumber(L, 1)
		return 1
	})
	define(r, "Test.report", report)
}

// The next build registers its bindings in another order, and Test.value has a new procedure.
@(private)
register_second_build :: proc(r: ^Runtime) {
	define(r, "Test.report", report)
	define(r, "Test.later", proc(L: ^luau.State) -> c.int {
		luau.pushnumber(L, 3)
		return 1
	})
	define(r, "Test.value", proc(L: ^luau.State) -> c.int {
		luau.pushnumber(L, 2)
		return 1
	})
}

COROUTINE_SCRIPT :: `
local value = Test.value
Test.report(value())
coroutine.yield()
Test.report(value())
Test.report(Test.later())
`

@(test)
a_suspended_coroutine_survives_a_code_reload :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	thread, ok := spawn_source(&f.runtime, "=coroutine", COROUTINE_SCRIPT)
	testing.expect(t, ok)

	reload(&f.runtime, &f.platform, register_second_build)
	testing.expect_value(t, resume(&f.runtime, thread), Resume_Result.Finished)
	testing.expect_value(t, len(f.reports), 3)
	if len(f.reports) == 3 {
		testing.expect_value(t, f.reports[0], 1)
		testing.expect_value(t, f.reports[1], 2)
		testing.expect_value(t, f.reports[2], 3)
	}
	release(&f.runtime, thread)
}

@(test)
scripts_cannot_replace_the_globals :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	context.logger = capture_errors(f)
	_, ok := spawn_source(&f.runtime, "=replace", "Debug.log = nil")
	testing.expect(t, !ok)
	_, ok = spawn_source(&f.runtime, "=replace", "Test.report = nil")
	testing.expect(t, !ok)
	expect_error(t, f, "attempt to modify a readonly table")
	// A script's own globals go to its thread's table, and shadow the shared ones only there.
	_, ok = spawn_source(&f.runtime, "=own", "Test = nil; mine = 1")
	testing.expect(t, ok)
	_, ok = spawn_source(&f.runtime, "=other", "Test.report(mine == nil and 1 or 0)")
	testing.expect(t, ok)
	testing.expect_value(t, len(f.reports), 1)
	if len(f.reports) == 1 {
		testing.expect_value(t, f.reports[0], 1)
	}
}

@(test)
a_library_added_by_a_reload_is_read_only :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	context.logger = capture_errors(f)
	reload(&f.runtime, &f.platform, proc(r: ^Runtime) {
		register_first_build(r)
		define(r, "Added.value", proc(L: ^luau.State) -> c.int {
			luau.pushnumber(L, 4)
			return 1
		})
	})
	_, ok := spawn_source(&f.runtime, "=added", "Test.report(Added.value())")
	testing.expect(t, ok)
	_, ok = spawn_source(&f.runtime, "=replace", "Added.value = nil")
	testing.expect(t, !ok)
	expect_error(t, f, "attempt to modify a readonly table")
}

@(test)
the_watchdog_fails_a_runaway_resume :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	context.logger = capture_errors(f)
	f.runtime.budget = 10 * time.Millisecond
	_, ok := spawn_source(&f.runtime, "=runaway", "while true do end")
	testing.expect(t, !ok)
	expect_error(t, f, "runaway:1: script ran past its time budget")
	// The VM is still usable.
	_, ok = spawn_source(&f.runtime, "=after", "Test.report(1)")
	testing.expect(t, ok)
}

@(test)
a_syntax_error_fails_spawn :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	context.logger = capture_errors(f)
	_, ok := spawn_source(&f.runtime, "=broken", "local = 1")
	testing.expect(t, !ok)
	expect_error(t, f, "broken:1: Expected identifier")
}

@(test)
debug_log_accepts_any_values :: proc(t: ^testing.T) {
	f := setup(t, register_first_build)
	defer teardown(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=log", "Debug.log('frame', 1, true, nil, vector.create(1, 2, 3))")
	testing.expect(t, ok)
}
