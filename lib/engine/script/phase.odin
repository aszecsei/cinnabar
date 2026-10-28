package script

import "core:c"
import "core:fmt"
import "core:log"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import "cinnabar:core/profile"
import "cinnabar:engine/ecs"

// Events delivered in one phase can send more events. Delivery stops after this many rounds, so a loop of events
// cannot hang the frame.
MAX_EVENT_ROUNDS :: 16

// run_phase is the script phase (phase 5 and 6 in docs/overview/architecture.md#frame), in Unity's order: despawns and
// activity changes, awake and start, events, update, coroutines, and the scripts' structural changes. See
// docs/scripting/behaviours.md#frame.
run_phase :: proc(r: ^Runtime, dt: time.Duration, input: core.Input) {
	p := &r.platform.profile
	profile.scope_text(p, "Script phase", .Frame)
	begin_phase(r, dt, input)
	drain_log(r)
	wake_and_start(r)
	deliver_events(r)
	profile.begin(p, profile.name(p, "Update", .Frame))
	for &i, index in r.instances[:r.instance_used] {
		if effective(&i) && i.flags >= {.Started, .Updates} {
			luau.pushnumber(r.L, time.duration_seconds(dt))
			call_method(r, {u32(index), i.generation}, "update", 1)
		}
	}
	profile.end(p)
	profile.begin(p, profile.name(p, "Coroutines", .Frame))
	run_coroutines(r)
	profile.end(p)
	// Events that update and the coroutines sent are delivered in the same phase.
	deliver_events(r)
	end_phase(r)
}

// wake_and_start runs awake and on_enable for the instances that native code attached, and start for the instances
// that are enabled and active and have not started. The script phase and the fixed step both begin with it.
@(private)
wake_and_start :: proc(r: ^Runtime) {
	p := &r.platform.profile
	profile.begin(p, profile.name(p, "Awake", .Frame))
	for &i, index in r.instances[:r.instance_used] {
		if .Live in i.flags && .Needs_Awake in i.flags {
			wake(r, {u32(index), i.generation})
		}
	}
	profile.end(p)
	profile.begin(p, profile.name(p, "Start", .Frame))
	for &i, index in r.instances[:r.instance_used] {
		if effective(&i) && .Started not_in i.flags {
			i.flags += {.Started}
			call_method(r, {u32(index), i.generation}, "start")
		}
	}
	profile.end(p)
}

// set_quiet stops or starts the callbacks that the world's changes run, as the editor's edit mode does (see
// docs/editor/document-and-scenes.md#modes). While quiet, a despawned behaviour, or one that an edit removes, ends without on_disable or
// on_destroy, and a deactivated one stops its coroutines without on_disable. An activated one gets awake and on_enable
// in the next script phase that runs, and one that was awake gets no on_enable. The script phase itself still runs
// everything: the game does not run it while quiet.
set_quiet :: proc(r: ^Runtime, quiet: bool) {
	r.quiet = quiet
}

// settle applies the world's changes to the scripts without running script code, as a frame that runs no script phase
// does: the behaviours of despawned entities end, and their memory is free to collect.
settle :: proc(r: ^Runtime) {
	if r.L == nil {
		return
	}
	quiet := r.quiet
	r.quiet = true
	drain_log(r)
	r.quiet = quiet
}

// drain_log runs the callbacks for the world's changes: on_disable and on_destroy for despawned behaviours, and the
// activation callbacks. Bindings that change activity drain it at once, so their callbacks run before they return.
@(private)
drain_log :: proc(r: ^Runtime) {
	if r.world == nil {
		return
	}
	for entry in ecs.take_log(r.world, frame(r)) {
		switch entry.kind {
		case .Removed:
			if entry.id == BEHAVIOURS_ID {
				on_record_removed(r, c.int(i32(u32(entry.data))))
			}
		case .Activated:
			set_entity_active(r, entry.entity, true)
		case .Deactivated:
			set_entity_active(r, entry.entity, false)
		}
	}
}

// Event_Arg is a value that native code sends with an event.
Event_Arg :: union {
	f64,
	bool,
	string,
	[3]f32,
	ecs.Entity,
	ecs.World_Position,
}

// send queues an event for an entity's behaviours, like a script's entity:send. Call it from the frame code, not
// from jobs. The handlers are on_<name>.
send :: proc(r: ^Runtime, e: ecs.Entity, name: string, args: ..Event_Arg) {
	L := r.L
	base := luau.gettop(L)
	push_entity(L, e)
	luau.pushodinstring(L, name)
	for arg in args {
		switch v in arg {
		case f64:
			luau.pushnumber(L, v)
		case bool:
			luau.pushboolean(L, b32(v))
		case string:
			luau.pushodinstring(L, v)
		case [3]f32:
			push_vector(L, v)
		case ecs.Entity:
			push_entity(L, v)
		case ecs.World_Position:
			push_position(L, v)
		}
	}
	queue_event(r, L, base + 1, luau.gettop(L) - base)
	luau.settop(L, base)
}

// send_binding is entity:send(name, ...), like Unity's SendMessage.
@(private)
send_binding :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	alive_entity(L, 1)
	luau.L_checkstring(L, 2)
	queue_event(r, L, 1, luau.gettop(L))
	return 0
}

// queue_event appends the values from first, count of them, to the queue as one event: entity, name, arguments.
@(private = "file")
queue_event :: proc(r: ^Runtime, L: ^luau.State, first, count: c.int) {
	luau.getref(L, r.events)
	queue := luau.gettop(L)
	luau.createtable(L, count, 0)
	for k in 0 ..< count {
		luau.pushvalue(L, first + k)
		luau.rawseti(L, -2, k + 1)
	}
	luau.rawseti(L, queue, luau.objlen(L, queue) + 1)
	luau.pop(L, 1)
}

// deliver_events calls on_<name> on each effective instance of the event's entity, in the order the instances were
// added, and then resumes the coroutines that wait_event waits for.
@(private)
deliver_events :: proc(r: ^Runtime) {
	L := r.L
	profile.scope_text(&r.platform.profile, "Events", .Frame)
	for round := 0; ; round += 1 {
		luau.getref(L, r.events)
		if luau.objlen(L, -1) == 0 {
			luau.pop(L, 1)
			return
		}
		// Events sent during delivery go to a new queue, for the next round.
		luau.newtable(L)
		luau.unref(L, r.events)
		r.events = luau.ref(L, -1)
		luau.pop(L, 1)
		if round == MAX_EVENT_ROUNDS {
			log.warnf("script: events kept sending events for %d rounds, so the rest are dropped", MAX_EVENT_ROUNDS)
			luau.pop(L, 1)
			return
		}
		queue := luau.gettop(L)
		for k in 1 ..= luau.objlen(L, queue) {
			luau.rawgeti(L, queue, k)
			deliver_one(r, L, luau.gettop(L))
			luau.pop(L, 1)
		}
		luau.pop(L, 1)
	}
}

@(private = "file")
deliver_one :: proc(r: ^Runtime, L: ^luau.State, event: c.int) {
	luau.rawgeti(L, event, 1)
	e := to_entity(L, -1)
	luau.rawgeti(L, event, 2)
	handler := fmt.caprintf("on_%s", luau.toodinstring(L, -1), allocator = frame(r))
	name := luau.gettop(L)
	argc := luau.objlen(L, event) - 2
	if r.world != nil && ecs.is_alive(r.world, e) {
		for h in entity_instances(r, e) {
			if i := instance_at(r, h); i != nil && effective(i) {
				for k in 1 ..= argc {
					luau.rawgeti(L, event, k + 2)
				}
				call_method(r, h, handler, argc)
			}
		}
	}
	for &w, index in r.waiters[:r.waiter_used] {
		if !w.live || w.stopped || w.running || w.wait.kind != .Event || w.wait.entity != e {
			continue
		}
		luau.getref(L, w.wait.event)
		same := luau.rawequal(L, -1, name)
		luau.pop(L, 1)
		if !same {
			continue
		}
		for k in 1 ..= argc {
			luau.rawgeti(L, event, k + 2)
		}
		luau.xmove(L, w.state, argc)
		run_waiter(r, index, argc)
	}
	luau.pop(L, 2)
}
