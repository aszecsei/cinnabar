package cutscene

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// MAX_EVENT_HANDLERS is how many native handlers register_event_handler holds.
MAX_EVENT_HANDLERS :: 64

// Event_Handler_Proc is a native handler of a cutscene's event: the player that sent it, its full name (such as
// door_open, or alarm_begin and alarm_end for a range), and its values. It runs in the frame code, in the cutscene fixed
// system or in update. The name and the values are frame memory.
Event_Handler_Proc :: #type proc(
	data: rawptr,
	player: Player_Handle,
	name: string,
	args: []script.Event_Arg,
)

// Event_Handler is a native handler of one event's name. It holds a procedure of the DLL image, so register clears the
// handlers, and register_world registers them again after a code reload.
@(private)
Event_Handler :: struct {
	name:      string,
	hash:      u32,
	procedure: Event_Handler_Proc,
	data:      rawptr,
}

// Fired_Kind is what an event track sends for an event: a range's end, a trigger, or a range's begin. At one time, on
// one track, ends go first, so a range that ends where the next begins closes before it opens.
@(private)
Fired_Kind :: enum u8 {
	End,
	Trigger,
	Begin,
}

// Fired is an event that an event track sends at the end of the phase, when flush_events sorts the phase's events by
// time, then the track's order, then the kind, then the event's order.
@(private)
Fired :: struct {
	time:  i64,
	track: u32,
	kind:  Fired_Kind,
	event: u32,
}

// Move is how an event track's evaluation reached its time, which says which events it sends (see
// docs/cinematics/tracks.md#event-tracks).
@(private)
Move :: enum u8 {
	// Playback: every key and range that it crosses.
	Play,
	// A forward seek: the keys and the ranges crossed whole that fire on seek, and the begins and ends of the ranges
	// that it lands in and leaves.
	Seek,
	// A skip's jump: the keys and the ranges crossed whole that fire when skipped, and the begins and ends of the
	// ranges that it lands in and leaves.
	Skip,
}

// register_event_handler registers a native handler of the events of one name, from every cutscene, beside the
// behaviours' on_<name>. name must outlive the registration, as a string literal does. Call it in register_world, after
// register, so a code reload registers it again. It gives false, and logs, when the name has a handler already or the
// handlers are full.
register_event_handler :: proc(
	s: ^State,
	name: string,
	procedure: Event_Handler_Proc,
	data: rawptr = nil,
) -> bool {
	for h in s.handlers[:s.handler_count] {
		if h.name == name {
			log.errorf("cutscene: the event %q has a handler already", name)
			return false
		}
	}
	if s.handler_count == MAX_EVENT_HANDLERS || procedure == nil || name == "" {
		log.errorf("cutscene: cannot register a handler of the event %q", name)
		return false
	}
	s.handlers[s.handler_count] = {name, format.animation_graph_hash(name), procedure, data}
	s.handler_count += 1
	return true
}

// event_track sends the events that the move to the context's time crosses (see docs/cinematics/tracks.md#event-tracks).
// It writes nothing to the world: it records the events, and run_phase sends the phase's events in order at its end.
// Only an evaluation that plays sends events, so the editor's preview and scrub send none.
@(private)
event_track :: proc(ctx: ^Track_Context) {
	e := ctx.evaluation
	if e.audition != .Play {
		return
	}
	if seek, sought := ctx.seek.?; sought {
		move_events(ctx, seek.from, seek.to, .Seek)
	}
	if ctx.to > ctx.from {
		move_events(ctx, ctx.from, ctx.to, .Skip if ctx.skipped else .Play)
	}
}

// move_events records what a move over (from, to] sends for each of the track's events. A range is open at t when
// start <= t < end. A range that the move leaves sends its end, and one that it lands in sends its begin, whatever the
// move. A range that the move crosses whole, entering and leaving it, sends both only when the move sends it, as a key
// does. A move compares the ranges that are open with those open at to, so the first forward move
// after a seek backwards sends the begins and ends that the seek passed.
@(private = "file")
move_events :: proc(ctx: ^Track_Context, from, to: i64, move: Move) {
	e := ctx.evaluation
	track := ctx.track
	for ev, j in format.cutscene_track_events(ctx.data, ctx.blob, track) {
		index := track.first_event + u32(j)
		sends: bool
		switch move {
		case .Play:
			sends = true
		case .Seek:
			sends = .Fire_On_Seek in ev.flags
		case .Skip:
			sends = .Fire_When_Skipped in ev.flags
		}
		start, end := i64(ev.start), i64(ev.end)
		if .Range not_in ev.flags {
			if sends && start > from && start <= to {
				append(&e.fired, Fired{start, ctx.track_index, .Trigger, index})
			}
			continue
		}
		was_open := ev.id in e.open_ranges
		is_open := start <= to && to < end
		switch {
		case was_open && !is_open:
			change_range(e, ev.id, false)
			append(&e.fired, Fired{clamp(end, from + 1, to), ctx.track_index, .End, index})
		case !was_open && is_open:
			change_range(e, ev.id, true)
			append(&e.fired, Fired{clamp(start, from + 1, to), ctx.track_index, .Begin, index})
		case !was_open && !is_open && sends && start > from && end <= to:
			append(&e.fired, Fired{start, ctx.track_index, .Begin, index})
			append(&e.fired, Fired{end, ctx.track_index, .End, index})
		}
	}
}

// change_range is the one writer of an evaluation's open ranges, by event ID: a range is open from the begin that the
// track sent to its end. Only an open range sends an end, so each end follows its begin.
@(private = "file")
change_range :: proc(e: ^Evaluation, id: u32, open: bool) {
	if open {
		e.open_ranges[id] = {}
	} else {
		delete_key(&e.open_ranges, id)
	}
}

// end_ranges sends the end of each range that is still open, in the tracks' order, when the cutscene finishes: at its
// end, at a skip to its end, or at a stop. A failure does not call it, and sends nothing.
@(private)
end_ranges :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) {
	if len(e.open_ranges) == 0 {
		return
	}
	for track, i in format.cutscene_tracks(data, blob) {
		if track.kind != .Event {
			continue
		}
		for ev, j in format.cutscene_track_events(data, blob, track) {
			if .Range in ev.flags && ev.id in e.open_ranges {
				change_range(e, ev.id, false)
				append(&e.fired, Fired{i64(e.time), u32(i), .End, track.first_event + u32(j)})
			}
		}
	}
	flush_events(s, e, w, data, blob)
}

// forget_ranges forgets the open ranges without sending their ends, for a change of audition: an evaluation that does
// not play sent no begins.
@(private)
forget_ranges :: proc(e: ^Evaluation) {
	clear(&e.open_ranges)
}

// keep_ranges forgets, after a reload, the open ranges that are no longer ranges of the blob's event tracks, without
// sending their ends. The next evaluation sends the begins and ends that the new blob's ranges imply.
@(private)
keep_ranges :: proc(e: ^Evaluation, w: ^ecs.World, data: []byte, blob: ^format.Cutscene_Blob) {
	gone := make([dynamic]u32, w.platform.frame_allocator)
	for id in e.open_ranges {
		found := false
		for track in format.cutscene_tracks(data, blob) {
			if track.kind != .Event {
				continue
			}
			for ev in format.cutscene_track_events(data, blob, track) {
				found ||= ev.id == id && .Range in ev.flags
			}
		}
		if !found {
			append(&gone, id)
		}
	}
	for id in gone {
		delete_key(&e.open_ranges, id)
	}
}

// Sent is an event as flush_events sends it, in frame memory, so a handler that ends the player, and unloads its blob,
// leaves the events after it whole.
@(private = "file")
Sent :: struct {
	name:   string,
	entity: Maybe(ecs.Entity),
	args:   []script.Event_Arg,
}

// flush_events sends the events that the evaluation's tracks recorded, sorted by time, then the track's order, then the
// kind and the event's order: each to its track's binding's behaviours with script.send, or to every behaviour with
// script.broadcast for a track without a binding, and to the native handlers of its name. A track whose binding is
// missing sends only to the handlers.
@(private)
flush_events :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) {
	if len(e.fired) == 0 {
		return
	}
	slice.sort_by(e.fired[:], proc(a, b: Fired) -> bool {
		if a.time != b.time {
			return a.time < b.time
		}
		if a.track != b.track {
			return a.track < b.track
		}
		if a.kind != b.kind {
			return a.kind < b.kind
		}
		return a.event < b.event
	})
	allocator := w.platform.frame_allocator
	tracks := format.cutscene_tracks(data, blob)
	events := format.cutscene_events(data, blob)
	guids := format.cutscene_guids(data, blob)
	sent := make([]Sent, len(e.fired), allocator)
	for f, i in e.fired {
		ev := events[f.event]
		track := tracks[f.track]
		name := format.blob_string(data, ev.name)
		switch f.kind {
		case .Trigger:
			name = strings.clone(name, allocator)
		case .Begin:
			name = fmt.aprintf("%s_begin", name, allocator = allocator)
		case .End:
			name = fmt.aprintf("%s_end", name, allocator = allocator)
		}
		values := format.cutscene_values_of(data, blob, ev)
		args := make([]script.Event_Arg, len(values), allocator)
		for v, j in values {
			switch v.kind {
			case .Number:
				args[j] = v.number
			case .Bool:
				args[j] = v.index == 1
			case .String:
				args[j] = strings.clone(format.blob_string(data, v.text), allocator)
			case .Vector:
				args[j] = v.vector
			case .Entity:
				entity, _ := binding_entity(&e.bindings, w, int(v.index))
				args[j] = entity
			case .Position:
				args[j] = ecs.World_Position{v.position}
			case .Asset:
				args[j] = guids[v.index]
			}
		}
		sent[i] = {
			name = name,
			args = args,
		}
		if track.binding != format.CUTSCENE_NONE {
			entity, alive := binding_entity(&e.bindings, w, int(track.binding))
			sent[i].entity = entity if alive else ecs.Entity(0)
		}
	}
	clear(&e.fired)
	player := e.player
	for event in sent {
		if s.scripts != nil {
			switch entity in event.entity {
			case nil:
				script.broadcast(s.scripts, event.name, ..event.args)
			case ecs.Entity:
				if entity != 0 {
					script.send(s.scripts, entity, event.name, ..event.args)
				}
			}
		}
		hash := format.animation_graph_hash(event.name)
		for h in s.handlers[:s.handler_count] {
			if h.hash == hash && h.name == event.name {
				h.procedure(h.data, player, event.name, event.args)
			}
		}
	}
}
