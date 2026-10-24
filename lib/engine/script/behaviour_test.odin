package script

import "core:testing"
import "core:time"

import "cinnabar:engine/ecs"

// The callbacks report these codes, so a test can check their order.
@(private)
DOOR :: `
Door = Behaviour.define("Door", {speed = Field.number(2), label = Field.string("door")})
function Door:awake() Test.report(1) end
function Door:on_enable() Test.report(2) end
function Door:start() Test.report(3) end
function Door:update(dt) Test.report(4) end
function Door:on_disable() Test.report(5) end
function Door:on_destroy() Test.report(6) end
`

@(private)
FRAME :: 16 * time.Millisecond

// phase runs one script phase, as the game does each frame.
@(private)
phase :: proc(f: ^World_Fixture) {
	run_phase(&f.runtime, FRAME, {})
}

@(test)
callbacks_run_in_unity_order :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	thread, ok := spawn_source(&f.runtime, "=door", DOOR + `
local e = World.spawn()
local d = e:add(Door, {speed = 5})
Test.report(d.speed)
Test.report(d.label == "door" and 1 or 0)
Test.report(e:get(Door) == d and 1 or 0)
Test.report(d.entity == e and 1 or 0)
coroutine.yield()
e:destroy()
`)
	testing.expect(t, ok)
	// A script's add runs awake and on_enable at once.
	expect_reports(t, f, {1, 2, 5, 1, 1, 1})
	phase(f)
	expect_reports(t, f, {3, 4})
	phase(f)
	expect_reports(t, f, {4})
	// destroy waits for the end of the phase, and on_destroy follows on_disable.
	begin_phase(&f.runtime, FRAME, {})
	testing.expect_value(t, resume(&f.runtime, thread), Resume_Result.Finished)
	end_phase(&f.runtime)
	expect_reports(t, f, {5, 6})
	release(&f.runtime, thread)
}

@(test)
disabling_a_behaviour_stops_its_update :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	thread, ok := spawn_source(&f.runtime, "=door", DOOR + `
local d = World.spawn():add(Door, {enabled = false})
Test.report(d.enabled and 1 or 0)
coroutine.yield()
d.enabled = true
d.enabled = true
Test.report(d.enabled and 1 or 0)
`)
	testing.expect(t, ok)
	// A disabled instance wakes, but gets no on_enable, start or update.
	expect_reports(t, f, {1, 0})
	phase(f)
	expect_reports(t, f, {})
	testing.expect_value(t, resume(&f.runtime, thread), Resume_Result.Finished)
	// Only one on_enable for two writes of true.
	expect_reports(t, f, {2, 1})
	phase(f)
	expect_reports(t, f, {3, 4})
	release(&f.runtime, thread)
}

@(test)
deactivation_reaches_children_and_defers_awake :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	thread, ok := spawn_source(&f.runtime, "=door", DOOR + `
local parent = World.spawn()
local child = World.spawn()
child:set_parent(parent)
parent:set_active(false)
Test.report(parent.active_self and 1 or 0)
Test.report(child.active_self and 1 or 0)
Test.report(child.active_in_hierarchy and 1 or 0)
child:add(Door)
Test.report(10)
coroutine.yield()
parent:set_active(true)
Test.report(11)
parent:set_active(false)
`)
	testing.expect(t, ok)
	// The Door on the inactive child does not wake.
	expect_reports(t, f, {0, 1, 0, 10})
	phase(f)
	expect_reports(t, f, {})
	testing.expect_value(t, resume(&f.runtime, thread), Resume_Result.Finished)
	// awake and on_enable run before set_active returns, and on_disable when it deactivates again.
	expect_reports(t, f, {1, 2, 11, 5})
	release(&f.runtime, thread)
}

@(test)
coroutines_wait_for_frames_time_and_events :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=waits", `
local Waiter = Behaviour.define("Waiter")
function Waiter:start()
	self:start_coroutine(function()
		Test.report(10)
		wait_frames(2)
		Test.report(11)
		wait(0.05)
		Test.report(12)
		local amount = wait_event(self.entity, "hit")
		Test.report(amount)
	end)
end
function Waiter:on_hit(amount) Test.report(amount + 100) end
target = World.spawn()
target:add(Waiter)
`)
	testing.expect(t, ok)
	phase(f)
	// The coroutine runs until its first wait before start_coroutine returns.
	expect_reports(t, f, {10})
	phase(f)
	expect_reports(t, f, {})
	phase(f)
	expect_reports(t, f, {11})
	phase(f)
	expect_reports(t, f, {})
	f.world.clock.time += 60 * time.Millisecond
	phase(f)
	expect_reports(t, f, {12})

	found := make([dynamic]ecs.Entity, context.temp_allocator)
	ecs.collect(&f.world, {BEHAVIOURS_ID}, &found)
	testing.expect_value(t, len(found), 1)
	send(&f.runtime, found[0], "hit", f64(7))
	phase(f)
	// The handler first, then the coroutine that waited for the event.
	expect_reports(t, f, {107, 7})
}

@(test)
deactivation_stops_coroutines :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	thread, ok := spawn_source(&f.runtime, "=stop", `
local Ticker = Behaviour.define("Ticker")
function Ticker:start()
	self:start_coroutine(function()
		while true do
			Test.report(1)
			wait_frames(1)
		end
	end)
end
local e = World.spawn()
e:add(Ticker)
coroutine.yield()
e:set_active(false)
coroutine.yield()
e:set_active(true)
`)
	testing.expect(t, ok)
	phase(f)
	phase(f)
	expect_reports(t, f, {1, 1})
	testing.expect_value(t, resume(&f.runtime, thread), Resume_Result.Yielded)
	phase(f)
	expect_reports(t, f, {})
	// Unity does not restart a stopped coroutine when the entity comes back, and start does not run again.
	testing.expect_value(t, resume(&f.runtime, thread), Resume_Result.Finished)
	phase(f)
	expect_reports(t, f, {})
	release(&f.runtime, thread)
}

@(test)
script_events_reach_every_effective_instance :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=events", `
local A = Behaviour.define("A")
function A:on_ping(n) Test.report(n) end
local B = Behaviour.define("B")
function B:on_ping(n) Test.report(n + 1) end
local e = World.spawn()
e:add(A)
e:add(B, {enabled = false})
e:send("ping", 10)
local other = World.spawn()
other:add(B)
other:send("ping", 20)
`)
	testing.expect(t, ok)
	phase(f)
	expect_reports(t, f, {10, 21})
}

@(test)
a_failing_callback_does_not_stop_the_others :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	context.logger = capture_world_errors(f)
	_, ok := spawn_source(&f.runtime, "=errors", `
local Broken = Behaviour.define("Broken")
function Broken:update() error("broken update") end
function Broken:start() wait(1) end
local Fine = Behaviour.define("Fine")
function Fine:update() Test.report(1) end
local e = World.spawn()
e:add(Broken)
e:add(Fine)
`)
	testing.expect(t, ok)
	phase(f)
	expect_reports(t, f, {1})
	expect_world_error(t, f, "broken update")
	expect_world_error(t, f, "wait works only in a coroutine")
	// The traceback names the callback.
	expect_world_error(t, f, "errors:4 function start")
}

@(test)
native_despawns_reach_on_destroy :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=door", DOOR + "World.spawn():add(Door)")
	testing.expect(t, ok)
	expect_reports(t, f, {1, 2})
	found := make([dynamic]ecs.Entity, context.temp_allocator)
	ecs.collect(&f.world, {BEHAVIOURS_ID}, &found)
	testing.expect_value(t, len(found), 1)
	ecs.despawn(&f.world, found[0])
	phase(f)
	expect_reports(t, f, {5, 6})
	testing.expect_value(t, f.runtime.instances[0].flags, Instance_Flags{})
}

@(test)
inspect_reads_declared_fields_without_running_scripts :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	_, ok := spawn_source(&f.runtime, "=inspect", DOOR + `
local e = World.spawn()
local d = e:add(Door, {speed = 5})
d.label = "front"
d.extra = "runtime state, not a field"
Test.report(1)
`)
	testing.expect(t, ok)
	found: [dynamic]ecs.Entity
	defer delete(found)
	ecs.collect(&f.world, {BEHAVIOURS_ID}, &found)
	testing.expect_value(t, len(found), 1)
	expect_reports(t, f, {1, 2, 1})

	snapshots := inspect(&f.runtime, found[0], context.temp_allocator)

	// Inspecting calls no callback.
	expect_reports(t, f, {})
	testing.expect_value(t, len(snapshots), 1)
	door := snapshots[0]
	testing.expect_value(t, door.class, "Door")
	testing.expect(t, door.enabled)
	testing.expect_value(t, len(door.fields), 2)
	testing.expect_value(t, door.fields[0].name, "label")
	testing.expect_value(t, door.fields[0].kind, Behaviour_Field_Kind.String)
	testing.expect_value(t, door.fields[0].text, "front")
	testing.expect_value(t, door.fields[1].name, "speed")
	testing.expect_value(t, door.fields[1].number, 5)
}

@(test)
quiet_changes_run_no_callbacks :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	thread, ok := spawn_source(&f.runtime, "=door", DOOR + `
World.spawn():add(Door)
local b = World.spawn()
b:add(Door)
b:set_active(false)
`)
	testing.expect(t, ok)
	expect_reports(t, f, {1, 2, 1, 2, 5})
	release(&f.runtime, thread)
	// Without Inactive, collect finds the active door, and with it, the inactive one.
	actives := make([dynamic]ecs.Entity, context.temp_allocator)
	inactives := make([dynamic]ecs.Entity, context.temp_allocator)
	ecs.collect(f.runtime.world, {BEHAVIOURS_ID}, &actives)
	ecs.collect(f.runtime.world, {BEHAVIOURS_ID, ecs.INACTIVE_ID}, &inactives)
	testing.expect(t, len(actives) == 1 && len(inactives) == 1)
	active, inactive := actives[0], inactives[0]

	// As in the editor's edit mode: a despawn ends its behaviour, and an activation waits, without script code.
	set_quiet(&f.runtime, true)
	ecs.despawn(f.runtime.world, active)
	ecs.set_active(f.runtime.world, inactive, true)
	settle(&f.runtime)
	expect_reports(t, f, {})
	testing.expect_value(t, behaviour_count(&f.runtime), 1)

	// The next script phase starts the one that is left. It was awake, so it gets no on_enable.
	set_quiet(&f.runtime, false)
	phase(f)
	expect_reports(t, f, {3, 4})
}
