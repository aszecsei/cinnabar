package script_host

import "core:c"
import "core:strings"
import "core:testing"
import "core:time"

import "cinnabar:core/luau"

@(private)
Fixture :: struct {
	bindings: Bindings,
	L:        ^luau.State,
}

@(private)
setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	f.bindings.ctx = context
	f.L = open(&f.bindings)
	testing.expect(t, f.L != nil)
	return f
}

@(private)
teardown :: proc(f: ^Fixture) {
	close(f.L)
	free(f)
}

// run compiles and runs source on the main thread. On an error, the message is left on the stack.
@(private)
run :: proc(L: ^luau.State, source: string) -> luau.Status {
	size: c.size_t
	bytecode := luau.compile(raw_data(source), c.size_t(len(source)), nil, &size)
	defer luau.free_bytecode(bytecode)
	if status := luau.load(L, "=test", bytecode, size, 0); status != .OK {
		return status
	}
	return luau.pcall(L, 0, 0, 0)
}

@(private)
global_number :: proc(L: ^luau.State, name: cstring) -> f64 {
	luau.getglobal(L, name)
	defer luau.pop(L, 1)
	return luau.tonumber(L, -1)
}

@(private)
add :: proc(L: ^luau.State) -> c.int {
	luau.pushnumber(L, luau.L_checknumber(L, 1) + luau.L_checknumber(L, 2))
	return 1
}

@(private)
subtract :: proc(L: ^luau.State) -> c.int {
	luau.pushnumber(L, luau.L_checknumber(L, 1) - luau.L_checknumber(L, 2))
	return 1
}

@(test)
dispatch_calls_the_registered_binding :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	register(&f.bindings, "Test.combine", add)
	push_binding(f.L, "Test.combine")
	luau.setglobal(f.L, "combine")
	testing.expect_value(t, run(f.L, "result = combine(2, 3)"), luau.Status.OK)
	testing.expect_value(t, global_number(f.L, "result"), 5)
}

// A code reload clears the table and registers the procedures of the new DLL, in any order. Closures that the VM
// already holds call the new procedures.
@(test)
closures_call_the_procedure_registered_after_a_reload :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	register(&f.bindings, "Test.other", add)
	register(&f.bindings, "Test.combine", add)
	push_binding(f.L, "Test.combine")
	luau.setglobal(f.L, "combine")
	testing.expect_value(t, run(f.L, "local f = combine; before = f(5, 3); function later() return f(5, 3) end"), luau.Status.OK)

	clear(&f.bindings)
	register(&f.bindings, "Test.combine", subtract)
	register(&f.bindings, "Test.other", add)
	testing.expect_value(t, run(f.L, "after = later()"), luau.Status.OK)
	testing.expect_value(t, global_number(f.L, "before"), 8)
	testing.expect_value(t, global_number(f.L, "after"), 2)
}

@(test)
a_removed_binding_raises_an_error_that_names_it :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	register(&f.bindings, "Test.combine", add)
	push_binding(f.L, "Test.combine")
	luau.setglobal(f.L, "combine")
	clear(&f.bindings)
	testing.expect_value(t, run(f.L, "combine(1, 2)"), luau.Status.ERRRUN)
	message := luau.toodinstring(f.L, -1)
	testing.expectf(t, strings.contains(message, "binding Test.combine no longer exists"), "message: %s", message)
}

@(test)
a_binding_can_yield :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	register(&f.bindings, "Test.wait", proc(L: ^luau.State) -> c.int {return YIELD})
	push_binding(f.L, "Test.wait")
	luau.setglobal(f.L, "wait")

	co := luau.newthread(f.L)
	source := "steps = 1; wait(); steps = 2"
	size: c.size_t
	bytecode := luau.compile(raw_data(source), c.size_t(len(source)), nil, &size)
	defer luau.free_bytecode(bytecode)
	testing.expect_value(t, luau.load(co, "=test", bytecode, size, 0), luau.Status.OK)
	testing.expect_value(t, luau.resume(co, nil, 0), luau.Status.YIELD)
	testing.expect_value(t, global_number(f.L, "steps"), 1)
	testing.expect_value(t, luau.resume(co, nil, 0), luau.Status.OK)
	testing.expect_value(t, global_number(f.L, "steps"), 2)
}

@(test)
interned_names_give_strings_their_atom :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	expected := atom("cinnabar_test_name")
	testing.expect(t, expected >= 0)
	testing.expect_value(t, atom("cinnabar_test_name"), expected)
	testing.expect_value(t, atom_name(expected), "cinnabar_test_name")

	result: c.int
	luau.pushstring(f.L, "cinnabar_test_name")
	luau.tostringatom(f.L, -1, &result)
	testing.expect_value(t, i16(result), expected)
	luau.pushstring(f.L, "cinnabar_test_never_interned")
	luau.tostringatom(f.L, -1, &result)
	testing.expect_value(t, result, -1)
}

@(test)
the_watchdog_stops_a_runaway_script :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	f.bindings.deadline = time.tick_add(time.tick_now(), 20 * time.Millisecond)
	testing.expect_value(t, run(f.L, "while true do end"), luau.Status.ERRRUN)
	message := luau.toodinstring(f.L, -1)
	testing.expectf(t, strings.contains(message, "time budget"), "message: %s", message)
}

@(test)
large_blocks_are_allocated_and_released :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	start := heap_bytes(f.L)
	// A TValue is 16 bytes, so this array is a large block.
	testing.expect_value(t, run(f.L, "big = table.create(200000, 0)"), luau.Status.OK)
	testing.expect(t, heap_bytes(f.L) - start >= 200000 * 16)
	testing.expect_value(t, run(f.L, "big = nil"), luau.Status.OK)
	luau.gc(f.L, .COLLECT, 0)
	testing.expect(t, heap_bytes(f.L) - start < LARGE_BLOCK)
}
