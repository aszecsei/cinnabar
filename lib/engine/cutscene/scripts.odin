package cutscene

import "core:c"
import "core:fmt"
import "core:math"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The Cutscene library that scripts see, the Cutscene handle's methods, wait_cutscene, and the lifecycle events that
// players send to behaviours (see docs/cinematics/scripts.md).

@(private = "file")
REGISTRY_KEY :: "cinnabar.cutscene"

// register_scripts defines the Cutscene library, which reaches s, the Cutscene handle's methods and wait_cutscene. A
// game's Register_Proc calls it, so init and every reload define them again.
register_scripts :: proc(r: ^script.Runtime, s: ^State) {
	script.set_registry_pointer(r, REGISTRY_KEY, s)
	script.define(
		r,
		"Cutscene.play",
		play_binding,
		"(cutscene: Asset, options: CutsceneOptions?) -> Cutscene",
	)
	script.define(r, "wait_cutscene", wait_binding, "(cutscene: Cutscene) -> boolean")
	script.light_poll(r, .Cutscene, poll_cutscene)
	script.light_method(r, .Cutscene, "play", proc(L: ^luau.State) -> c.int {
		s, h := check_cutscene(L)
		start(s, world_of(L), h)
		return 0
	})
	script.light_method(r, .Cutscene, "pause", proc(L: ^luau.State) -> c.int {
		s, h := check_cutscene(L)
		pause(s, world_of(L), h)
		return 0
	})
	script.light_method(r, .Cutscene, "resume", proc(L: ^luau.State) -> c.int {
		s, h := check_cutscene(L)
		resume(s, world_of(L), h)
		return 0
	})
	script.light_method(r, .Cutscene, "stop", proc(L: ^luau.State) -> c.int {
		s, h := check_cutscene(L)
		stop(s, world_of(L), h)
		return 0
	})
	script.light_method(r, .Cutscene, "skip", proc(L: ^luau.State) -> c.int {
		s, h := check_cutscene(L)
		luau.pushboolean(L, b32(skip(s, world_of(L), h) == .Done))
		return 1
	})
	script.light_method(r, .Cutscene, "state", proc(L: ^luau.State) -> c.int {
		s, h := check_cutscene(L)
		name := STATE_NAMES[status(s, h)]
		if name == "" {
			luau.pushnil(L)
		} else {
			luau.pushodinstring(L, name)
		}
		return 1
	})
	script.light_method(r, .Cutscene, "error", proc(L: ^luau.State) -> c.int {
		s, h := check_cutscene(L)
		if failure, failed := player_failure(s, h); failed {
			luau.pushodinstring(L, failure_text(failure))
		} else {
			luau.pushnil(L)
		}
		return 1
	})
	script.light_method(r, .Cutscene, "time", proc(L: ^luau.State) -> c.int {
		s, h := check_cutscene(L)
		if t, live := player_time(s, h); live {
			luau.pushnumber(L, f64(t) / format.CUTSCENE_TICKS_PER_SECOND)
		} else {
			luau.pushnil(L)
		}
		return 1
	})
	script.light_method(r, .Cutscene, "length", proc(L: ^luau.State) -> c.int {
		s, h := check_cutscene(L)
		if e, live := player_evaluation(s, h); live {
			if _, blob, ok := cutscene_data(s, e); ok {
				luau.pushnumber(L, f64(blob.range_end) / format.CUTSCENE_TICKS_PER_SECOND)
				return 1
			}
		}
		luau.pushnil(L)
		return 1
	})
	script.light_method(r, .Cutscene, "binding", proc(L: ^luau.State) -> c.int {
		s, h := check_cutscene(L)
		luau.L_checkstring(L, 2)
		name := luau.toodinstring(L, 2)
		if e, live := player_evaluation(s, h); live {
			if data, blob, ok := cutscene_data(s, e); ok {
				if index, found := binding_index(data, blob, name); found {
					if entity, alive := binding_entity(&e.bindings, world_of(L), index); alive {
						script.push_entity(L, entity)
						return 1
					}
				}
			}
		}
		luau.pushnil(L)
		return 1
	})
}

// STATE_NAMES are the strings of Cutscene:state(), by status. A stale handle's is nil.
@(private = "file")
STATE_NAMES := [Player_Status]string {
	.Gone      = "",
	.Loading   = "loading",
	.Ready     = "ready",
	.Playing   = "playing",
	.Paused    = "paused",
	.Skipping  = "skipping",
	.Finishing = "finishing",
	.Restored  = "restored",
	.Failed    = "failed",
}

// handle_value is a player's handle as a script's Cutscene.
handle_value :: proc(h: Player_Handle) -> script.Light_Value {
	return {.Cutscene, u64(h.generation) << 16 | u64(h.slot)}
}

// handle_of is the player's handle of a script's Cutscene.
handle_of :: proc(payload: u64) -> Player_Handle {
	return {slot = u16(payload & 0xffff), generation = u32(payload >> 16)}
}

// failure_text is a failure's code, as Cutscene:error() and on_cutscene_failed give it. The log has the details.
failure_text :: proc(failure: Failure) -> string {
	switch f in failure {
	case Asset_Failure:
		switch f.reason {
		case .Missing:
			return "missing"
		case .Not_A_Cutscene:
			return "not_a_cutscene"
		case .Reference_Missing:
			return "reference_missing"
		case .Bad_Nesting:
			return "bad_nesting"
		}
	case Binding_Failure:
		switch f.reason {
		case .Missing:
			return "binding_missing"
		case .Spawn_Failed:
			return "spawn_failed"
		}
	}
	return "failed"
}

@(private = "file")
state_of :: proc(L: ^luau.State) -> ^State {
	return script.registry_pointer(L, REGISTRY_KEY, State)
}

@(private = "file")
world_of :: proc(L: ^luau.State) -> ^ecs.World {
	return script.runtime_of(L).world
}

// check_cutscene is the state and the handle of the Cutscene that a method is called on.
@(private = "file")
check_cutscene :: proc(L: ^luau.State) -> (^State, Player_Handle) {
	payload := script.check_light(L, 1, .Cutscene, "Cutscene")
	return state_of(L), handle_of(payload)
}

// Cutscene.play(cutscene, options?) makes a player of a cutscene asset, which plays once it has loaded, and gives its
// handle. options has bindings, a table from a binding's name to an entity, priority, start, in seconds on the
// cutscene's time, and wait_ready, which holds the player in Ready until :play(). A key that does not exist, or a value
// of the wrong type, raises an error, which plays nothing.
@(private = "file")
play_binding :: proc(L: ^luau.State) -> c.int {
	r := script.runtime_of(L)
	allocator := r.platform.frame_allocator
	guid := script.to_asset(r, L, 1)
	if guid == {} {
		luau.L_typeerrorL(L, 1, "Asset")
	}
	desc := Play_Desc {
		cutscene = guid,
		caller   = script.calling_entity(r),
	}
	wait_ready := false
	overrides := make([dynamic]Binding_Override, allocator)
	problem := ""
	if !luau.isnoneornil(L, 2) {
		luau.L_checktype(L, 2, .TABLE)
		luau.pushnil(L)
		for problem == "" && luau.next(L, 2) {
			defer luau.pop(L, 1)
			key := luau.type(L, -2) == .STRING ? luau.toodinstring(L, -2) : ""
			switch key {
			case "bindings":
				if luau.type(L, -1) != .TABLE {
					problem = "bindings takes a table from a binding's name to an entity"
					continue
				}
				problem = read_bindings(L, &overrides)
			case "priority":
				priority := luau.tonumber(L, -1)
				if luau.type(L, -1) != .NUMBER || priority != math.floor(priority) {
					problem = "priority takes a whole number"
					continue
				}
				desc.priority = i32(clamp(priority, f64(min(i32)), f64(max(i32))))
			case "start":
				seconds := luau.tonumber(L, -1)
				if luau.type(L, -1) != .NUMBER || !(seconds >= 0) {
					problem = "start takes a number of seconds, 0 or more"
					continue
				}
				ticks := math.round(seconds * format.CUTSCENE_TICKS_PER_SECOND)
				desc.start = i32(min(ticks, f64(max(i32))))
			case "wait_ready":
				if luau.type(L, -1) != .BOOLEAN {
					problem = "wait_ready takes a boolean"
					continue
				}
				wait_ready = bool(luau.toboolean(L, -1))
			case:
				problem = fmt.aprintf("there is no option %q", key, allocator = allocator)
			}
		}
	}
	if problem != "" {
		script.raise(L, fmt.aprintf("Cutscene.play: %s", problem, allocator = allocator))
	}
	desc.overrides = overrides[:]
	s := state_of(L)
	h: Player_Handle
	ok: bool
	if wait_ready {
		h, ok = load(s, r.world, desc)
	} else {
		h, ok = play(s, r.world, desc)
	}
	if !ok {
		script.raise(
			L,
			fmt.aprintf(
				"Cutscene.play: %d cutscenes are playing, so no other can",
				MAX_PLAYERS,
				allocator = allocator,
			),
		)
	}
	script.push_light(L, handle_value(h))
	return 1
}

// read_bindings reads the table of bindings at the top of the stack into overrides, by name, and gives a problem, or "".
@(private = "file")
read_bindings :: proc(L: ^luau.State, overrides: ^[dynamic]Binding_Override) -> string {
	table := luau.gettop(L)
	luau.pushnil(L)
	for luau.next(L, table) {
		defer luau.pop(L, 1)
		if luau.type(L, -2) != .STRING {
			luau.pop(L, 1)
			return "bindings takes a table from a binding's name to an entity"
		}
		entity := script.to_entity(L, -1)
		if entity == 0 {
			problem := fmt.aprintf(
				"the binding %s takes an entity",
				luau.toodinstring(L, -2),
				allocator = script.runtime_of(L).platform.frame_allocator,
			)
			luau.pop(L, 1)
			return problem
		}
		append(overrides, Binding_Override{luau.toodinstring(L, -2), entity})
	}
	return ""
}

// wait_cutscene(cutscene) waits in a coroutine until the player is Restored or Failed, or its handle is stale, and gives
// whether a skip took it to its end.
@(private = "file")
wait_binding :: proc(L: ^luau.State) -> c.int {
	payload := script.check_light(L, 1, .Cutscene, "Cutscene")
	return script.wait_light(L, {.Cutscene, payload})
}

// poll_cutscene ends a wait_cutscene when its player has ended or gone, with whether a skip took it to its end.
@(private = "file")
poll_cutscene :: proc(L: ^luau.State, payload: u64) -> (done: bool, results: c.int) {
	s := state_of(L)
	h := handle_of(payload)
	#partial switch status(s, h) {
	case .Restored:
		skipped, _ := player_skipped(s, h)
		luau.pushboolean(L, b32(skipped))
		return true, 1
	case .Failed, .Gone:
		luau.pushboolean(L, false)
		return true, 1
	}
	return false, 0
}

// Lifecycle_Event is the script event that a change of a player's state sends, if any (see
// docs/cinematics/scripts.md#events).
@(private)
Lifecycle_Event :: enum u8 {
	None,
	// From Ready to Playing or Skipping.
	Started,
	// To Restored.
	Finished,
	// To Failed.
	Failed,
}

// lifecycle_of is the script event of a change from one status to another.
@(private)
lifecycle_of :: proc(from, next: Player_Status) -> Lifecycle_Event {
	#partial switch next {
	case .Playing, .Skipping:
		if from == .Ready {
			return .Started
		}
	case .Restored:
		return .Finished
	case .Failed:
		return .Failed
	}
	return .None
}

// lifecycle_recipients is who gets the script event of a player's change, in the frame allocator: the entities of its
// bindings, and its caller, each once. A start goes to every bound entity. An end goes to the possessed ones, since the
// spawned ones are despawned with the player. A change with no event has no recipients.
@(private)
lifecycle_recipients :: proc(
	s: ^State,
	w: ^ecs.World,
	slot: int,
	event: Lifecycle_Event,
) -> []ecs.Entity {
	if s.scripts == nil || event == .None {
		return nil
	}
	started := event == .Started
	p := &s.players[slot]
	recipients := make([dynamic]ecs.Entity, w.platform.frame_allocator)
	add :: proc(recipients: ^[dynamic]ecs.Entity, e: ecs.Entity) {
		for r in recipients {
			if r == e {
				return
			}
		}
		append(recipients, e)
	}
	if live := live_of(&p.state); live != nil {
		for state in live.evaluation.bindings.states {
			entity: ecs.Entity
			switch b in state {
			case Binding_Possessed:
				entity = b.entity
			case Binding_Spawned:
				if started {
					entity = b.entity
				}
			case Binding_Missing, Binding_Mapped:
			}
			if entity != 0 && ecs.is_alive(w, entity) {
				add(&recipients, entity)
			}
		}
	}
	if p.caller != 0 && ecs.is_alive(w, p.caller) {
		add(&recipients, p.caller)
	}
	return recipients[:]
}

// send_lifecycle queues the script event of a player's change for its recipients: on_cutscene_started(cutscene) when it
// starts, on_cutscene_finished(cutscene, skipped) when it is Restored, and on_cutscene_failed(cutscene, reason) when it
// fails (see docs/cinematics/scripts.md#events). They go in the outbox after the events that the player's tracks queued
// and the ends of its open ranges, and send_events delivers them in that order. It touches no script itself.
@(private)
send_lifecycle :: proc(
	s: ^State,
	w: ^ecs.World,
	slot: int,
	event: Lifecycle_Event,
	recipients: []ecs.Entity,
) {
	if s.scripts == nil || len(recipients) == 0 {
		return
	}
	p := &s.players[slot]
	h := Player_Handle{u16(slot), p.generation}
	cutscene := handle_value(h)
	allocator := w.platform.frame_allocator
	name: string
	args: []script.Event_Arg
	switch event {
	case .None:
		return
	case .Started:
		name = "cutscene_started"
		args = make([]script.Event_Arg, 1, allocator)
		args[0] = cutscene
	case .Finished:
		skipped, _ := player_skipped(s, h)
		name = "cutscene_finished"
		args = make([]script.Event_Arg, 2, allocator)
		args[0], args[1] = cutscene, skipped
	case .Failed:
		failure, _ := player_failure(s, h)
		name = "cutscene_failed"
		args = make([]script.Event_Arg, 2, allocator)
		args[0], args[1] = cutscene, failure_text(failure)
	}
	for e in recipients {
		append(&s.outbox, Sent{player = h, name = name, entity = e, args = args, lifecycle = true})
	}
}
