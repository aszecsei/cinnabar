package script

import "core:slice"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import "cinnabar:core/profile"
import "cinnabar:engine/ecs"

// fixed_update is the scripts' step in a fixed tick, after the Fixed systems: Time and Input for the tick, the world's
// changes, awake and start, fixed_update for the classes that define it, the events that it sent, and its structural
// changes. Call it in each tick that ecs.next_tick starts, with the frame's input; only the first tick of a frame gets
// the input edges, with those of the frames before it that ran no tick. See
// docs/physics/design.md#scripts-in-fixed-ticks.
fixed_update :: proc(r: ^Runtime, ticks: ^ecs.Ticks, input: core.Input) {
	if r.L == nil || r.world == nil {
		return
	}
	p := &r.platform.profile
	profile.scope_text(p, "Script fixed step", .Frame)
	r.fixed_ran = true
	tick_input := input
	if ecs.first_tick(ticks) {
		tick_input.pressed += r.pending_pressed
		tick_input.released += r.pending_released
		r.pending_pressed, r.pending_released = {}, {}
	} else {
		tick_input.pressed, tick_input.released = {}, {}
	}
	begin_fixed(r)
	set_input(r, tick_input)
	drain_log(r)
	wake_and_start(r)
	profile.begin(p, profile.name(p, "Fixed update", .Frame))
	dt := 1 / f64(r.world.clock.tick_rate)
	for &i, index in r.instances[:r.instance_used] {
		if effective(&i) && i.flags >= {.Started, .Fixed_Updates} {
			luau.pushnumber(r.L, dt)
			call_method(r, {u32(index), i.generation}, "fixed_update", 1)
		}
	}
	profile.end(p)
	deliver_events(r)
	end_fixed(r)
}

// fixed_events is the scripts' step at the end of a fixed tick, after the physics step: the events that the tick
// queued, then the coroutines that wait in wait_fixed, in the order they started, and their structural changes.
fixed_events :: proc(r: ^Runtime) {
	if r.L == nil || r.world == nil {
		return
	}
	profile.scope_text(&r.platform.profile, "Script fixed events", .Frame)
	begin_fixed(r)
	deliver_events(r)
	Due :: struct {
		index: int,
		seq:   u64,
	}
	due := make([dynamic]Due, frame(r))
	for &w, index in r.waiters[:r.waiter_used] {
		if w.live && !w.stopped && !w.running && w.wait.kind == .Fixed {
			append(&due, Due{index, w.seq})
		}
	}
	slice.sort_by(due[:], proc(a, b: Due) -> bool {return a.seq < b.seq})
	for d in due {
		w := &r.waiters[d.index]
		if w.live && w.seq == d.seq && !w.stopped {
			run_waiter(r, d.index)
		}
	}
	deliver_events(r)
	end_fixed(r)
}

// begin_fixed sets Time for the tick: delta is the tick's duration and time the world time at its end.
@(private = "file")
begin_fixed :: proc(r: ^Runtime) {
	r.bindings.ctx = context
	r.commands = {}
	set_time(r, 1 / f64(r.world.clock.tick_rate), time.duration_seconds(ecs.tick_time(r.world)), true)
}

// end_fixed applies the step's structural changes and runs the callbacks for them. The collector's step stays the
// script phase's.
@(private = "file")
end_fixed :: proc(r: ^Runtime) {
	if r.commands.data.allocator.procedure != nil {
		ecs.apply(r.world, {r.commands})
	}
	r.commands = {}
	drain_log(r)
}
