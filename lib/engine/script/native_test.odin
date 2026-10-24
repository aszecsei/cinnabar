package script

import "core:testing"

import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:engine/ecs"

@(test)
native_modules_run_as_machine_code :: proc(t: ^testing.T) {
	f := setup_reload(t)
	defer teardown_reload(f)
	context.user_ptr = f.base
	fast := write_script(t, &f, 4, 0, `
local function sum(n) local total = 0 for i = 1, n do total += i end return total end
return {sum = sum, native = function() return Test.native() end}`, flags = {.Native})
	main := write_script(t, &f, MAIN, 0, `
local fast = require("./fast")
Test.report(fast.sum(100))
Test.report(fast.native() and 1 or 0)
Test.report(Test.native() and 1 or 0)`, {{"./fast", fast}})
	_, ok := spawn_script(&f.runtime, main)
	testing.expect(t, ok)
	// A native module gives the same results. Without a code generator, it runs as bytecode.
	native := f64(1) if luau.codegen_supported() else 0
	expect_reports(t, f, {5050, native, 0})

	// A hot reload compiles the new version too.
	write_script(t, &f, 4, 1, `return {sum = function() return 0 end, native = function() return Test.native() end}`, flags = {.Native})
	hot_reload(&f)
	_, ok = spawn_source(&f.runtime, "=after", "")
	testing.expect(t, ok)
}

// Direct access is on when the host was built with LUAU_DIRECT_ACCESS. The tests of this package run both ways.
@(test)
direct_access_gives_the_same_results :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	testing.expect_value(t, f.runtime.direct_access, script_host.LUAU_DIRECT_ACCESS)
	before := f.runtime.bindings.direct_calls
	testing.expect(t, run(t, f, `
local e = World.spawn()
local h = e:add(Health, {value = 1})
for i = 1, 10 do h.value += 1 end
Test.report(h.value)
local q = Quaternion.angle_axis(90, vector.create(0, 1, 0))
Test.report(math.round(q.w * 1000))
Test.report(math.round(q:inverse().y * 1000))
-- One instruction that reads the same field name from two component types, so the cached slot changes owner.
local score = World.spawn():add(Score, {bonus = 1000, value = 50})
local function value(ref) return ref.value end
Test.report(value(h) + value(score) + value(h))
Test.report(math.round(e.transform.forward.z))
`))
	expect_reports(t, f, {11, 707, -707, 72, 1})
	calls := f.runtime.bindings.direct_calls - before
	if script_host.LUAU_DIRECT_ACCESS {
		testing.expectf(t, calls > 0, "no direct access calls")
	} else {
		testing.expect_value(t, calls, 0)
	}
	_ = ecs.Entity(0)
}
