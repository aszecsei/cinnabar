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
// door_open, or alarm_begin and alarm_end for a range), and its values. It runs in the frame code, in send_events. The
// name and the values are frame memory.
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
// time on the root's time, then the track's order in the tree, then the kind, then the event's order. child is the
// cutscene of the tree that the track is in, 0 for the root, and track and event are indexes into its blob.
@(private)
Fired :: struct {
	time:  i64,
	order: u32,
	kind:  Fired_Kind,
	child: int,
	track: u32,
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
	fired :: proc(ctx: ^Track_Context, t: i64, kind: Fired_Kind, index: u32) -> Fired {
		at := t if ctx.child == 0 else i64(root_time(ctx, f64(t)))
		return {at, ctx.order, kind, ctx.child, ctx.track_index, index}
	}
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
				append(&e.fired, fired(ctx, start, .Trigger, index))
			}
			continue
		}
		was_open := will_be_open(e, ctx.child, {ctx.scope, ev.id}, index)
		is_open := start <= to && to < end
		switch {
		case was_open && !is_open:
			append(&e.fired, fired(ctx, clamp(end, from + 1, to), .End, index))
		case !was_open && is_open:
			append(&e.fired, fired(ctx, clamp(start, from + 1, to), .Begin, index))
		case !was_open && !is_open && sends && start > from && end <= to:
			append(&e.fired, fired(ctx, start, .Begin, index))
			append(&e.fired, fired(ctx, end, .End, index))
		}
	}
}

// will_be_open is whether a range is open once the phase's recorded events are queued: its last recorded begin or end, or
// whether it is open now. A seek and the playback after it, in one evaluation, both record against it.
@(private = "file")
will_be_open :: proc(e: ^Evaluation, child: int, id: Scoped, index: u32) -> bool {
	#reverse for f in e.fired {
		if f.child == child && f.event == index && f.kind != .Trigger {
			return f.kind == .Begin
		}
	}
	return id in e.open_ranges
}

// change_range is the one writer of an evaluation's open ranges, by event ID: a range is open from the moment that its
// begin is queued to the moment that its end is. flush_events changes it as it queues them, so an end is queued only for
// a range whose begin was. A change of audition and a reload drop ranges through it without sending their ends.
@(private = "file")
change_range :: proc(e: ^Evaluation, id: Scoped, open: bool) {
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
	for view in tree_views(s, e, w, data, blob) {
		orders := tree_orders(s, e, w, data, blob, view.child)
		for track, i in format.cutscene_tracks(view.data, view.blob) {
			if track.kind != .Event {
				continue
			}
			for ev, j in format.cutscene_track_events(view.data, view.blob, track) {
				if .Range in ev.flags && (Scoped{view.scope, ev.id}) in e.open_ranges {
					append(
						&e.fired,
						Fired {
							time = i64(e.time),
							order = orders[i],
							kind = .End,
							child = view.child,
							track = u32(i),
							event = track.first_event + u32(j),
						},
					)
				}
			}
		}
	}
	flush_events(s, e, w, data, blob)
}

// forget_ranges forgets the open ranges without sending their ends, for a change of audition: an evaluation that does
// not play sent no begins.
@(private)
forget_ranges :: proc(e: ^Evaluation, w: ^ecs.World) {
	ids := make([dynamic]Scoped, 0, len(e.open_ranges), w.platform.frame_allocator)
	for id in e.open_ranges {
		append(&ids, id)
	}
	for id in ids {
		change_range(e, id, false)
	}
}

// keep_ranges forgets, after a reload, the open ranges that are no longer ranges of the event tracks of the tree's
// blobs, without sending their ends. The next evaluation sends the begins and ends that the new blobs' ranges imply.
@(private)
keep_ranges :: proc(e: ^Evaluation, w: ^ecs.World, views: []Scope_View) {
	gone := make([dynamic]Scoped, w.platform.frame_allocator)
	for id in e.open_ranges {
		found := false
		for view in views {
			if view.scope != id.scope {
				continue
			}
			for track in format.cutscene_tracks(view.data, view.blob) {
				if track.kind != .Event {
					continue
				}
				for ev in format.cutscene_track_events(view.data, view.blob, track) {
					found ||= ev.id == id.id && .Range in ev.flags
				}
			}
		}
		if !found {
			append(&gone, id)
		}
	}
	for id in gone {
		change_range(e, id, false)
	}
}

// Sent is an event as send_events delivers it: its full name, its target, its values and its player's handle, in frame
// memory, so it needs neither the evaluation nor the blob once it is queued.
@(private)
Sent :: struct {
	player: Player_Handle,
	name:   string,
	// The binding's entity, the null entity for a binding that is missing, or nil for every behaviour.
	entity: Maybe(ecs.Entity),
	args:   []script.Event_Arg,
}

// flush_events queues the events that the evaluation's tracks recorded in the phase for send_events, sorted by time,
// then the track's order, then the kind and the event's order. A range opens as its begin is queued and closes as its
// end is, so an end is queued only after its begin. It runs where the phase runs, in a system's job too, so it calls no
// script and no handler.
@(private)
flush_events :: proc(
	s: ^State,
	e: ^Evaluation,
	w: ^ecs.World,
	root_data: []byte,
	root: ^format.Cutscene_Blob,
) {
	if len(e.fired) == 0 {
		return
	}
	slice.sort_by(e.fired[:], proc(a, b: Fired) -> bool {
		if a.time != b.time {
			return a.time < b.time
		}
		if a.order != b.order {
			return a.order < b.order
		}
		if a.kind != b.kind {
			return a.kind < b.kind
		}
		return a.event < b.event
	})
	allocator := w.platform.frame_allocator
	views := tree_views(s, e, w, root_data, root)
	for f in e.fired {
		view: Scope_View
		for v in views {
			if v.child == f.child {
				view = v
			}
		}
		if view.blob == nil {
			continue
		}
		data, blob := view.data, view.blob
		tracks := format.cutscene_tracks(data, blob)
		events := format.cutscene_events(data, blob)
		guids := format.cutscene_guids(data, blob)
		if int(f.track) >= len(tracks) || int(f.event) >= len(events) {
			continue
		}
		ev := events[f.event]
		track := tracks[f.track]
		name := format.blob_string(data, ev.name)
		switch f.kind {
		case .Trigger:
			name = strings.clone(name, allocator)
		case .Begin:
			change_range(e, {view.scope, ev.id}, true)
			name = fmt.aprintf("%s_begin", name, allocator = allocator)
		case .End:
			change_range(e, {view.scope, ev.id}, false)
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
				entity, _ := tree_binding(e, w, f.child, v.index)
				args[j] = entity
			case .Position:
				args[j] = ecs.World_Position{v.position}
			case .Asset:
				args[j] = guids[v.index]
			}
		}
		sent := Sent {
			player = e.player,
			name   = name,
			args   = args,
		}
		if track.binding != format.CUTSCENE_NONE {
			entity, alive := tree_binding(e, w, f.child, track.binding)

			sent.entity = entity if alive else ecs.Entity(0)
		}
		append(&s.outbox, sent)
	}
	clear(&e.fired)
}

// send_events delivers the queued events of every cutscene, in order: each to its track's binding's behaviours with
// script.send, or to every behaviour with script.broadcast for a track without a binding, and to the native handlers of
// its name. A track whose binding is missing sends only to the handlers. Call it from the frame code: update and
// advance_real call it, and the game calls it after each tick, so the tick's script.fixed_events delivers the events in
// the same tick. A handler that stops its player queues the ends of its open ranges after the events already queued.
send_events :: proc(s: ^State) {
	for i := 0; i < len(s.outbox); i += 1 {
		event := s.outbox[i]
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
				h.procedure(h.data, event.player, event.name, event.args)
			}
		}
	}
	clear(&s.outbox)
}
