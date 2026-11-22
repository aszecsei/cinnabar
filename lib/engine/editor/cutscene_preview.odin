package editor

import "core:log"
import "core:reflect"
import "core:slice"
import "core:time"

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/cutscene"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/script"

// The cutscene preview (see docs/editor/cutscene-editor.md#preview): in Edit, the cutscene editor's tab shows its
// cutscene in the world at its playhead, outside the document. The game loads the cutscene as a player does, without a
// player's slot or its hold on gameplay, and evaluates it at the time that the editor sends, or on its own clock while
// it plays. Its writes are one more layer with the overrides: lift_overrides puts them back and lay_overrides evaluates
// again, so what reads or edits the document sees the document. One preview is open at a time, and it ends with the
// overrides and the session.

// Cutscene_Preview is the open preview: its ticket, its cutscene, its live player, its clock, and what it held of the
// world when it was last lifted, for the editor's marks.
Cutscene_Preview :: struct {
	ticket:   u64,
	guid:     format.Guid,
	// The blob is the cook daemon's from the editor's unsaved text, set live from the preview area, whose file time is
	// modified.
	unsaved:  bool,
	modified: i64,
	live:     cutscene.Player_Live,
	clock:    Preview_Clock,
	// The fields that its tracks wrote at its last lift, and the entities that they are on, in the host's heap.
	held:     [dynamic]cutscene.Field,
}

// Preview_Clock is whether the preview stands at its time or moves on the game's clock.
Preview_Clock :: union {
	Preview_Paused,
	Preview_Playing,
}

Preview_Paused :: struct {}

// Preview_Playing is a preview that moves at rate times real time, forward or, below 0, backward, and from loop_end back
// to loop_start when it loops.
Preview_Playing :: struct {
	rate:       f32,
	looping:    bool,
	loop_start: i32,
	loop_end:   i32,
	// What the clock gave that is less than one tick, as cutscene.advance keeps it, for a backward play.
	carry:      i64,
}

// Cutscene_Previews is the session's preview, and the highest ticket that the editor opened one with. An Open with a
// ticket no higher is late, and a message for another ticket is dropped.
Cutscene_Previews :: struct {
	open: Maybe(Cutscene_Preview),
	last: u64,
}

// handle_cutscene_preview_message handles the preview's messages, and reports whether the message was one. despawned
// is whether it despawned entities.
@(private)
handle_cutscene_preview_message :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	message: link.Message,
) -> (
	handled: bool,
	despawned: bool,
) {
	#partial switch m in message {
	case link.Cutscene_Preview_Open:
		despawned = open_cutscene_preview(e, w, scripts, m)
	case link.Cutscene_Preview_Time:
		if p, ok := current_preview(e, m.ticket); ok {
			p.clock = Preview_Paused{}
			set_preview_time(e, w, p, m.tick)
		}
	case link.Cutscene_Preview_Play:
		if p, ok := current_preview(e, m.ticket); ok {
			p.clock = Preview_Playing {
				rate       = m.rate,
				looping    = m.looping,
				loop_start = m.loop_start,
				loop_end   = m.loop_end,
			}
			set_preview_time(e, w, p, m.tick)
		}
	case link.Cutscene_Preview_Settings:
		if p, ok := current_preview(e, m.ticket); ok {
			cutscene.set_mix(&p.live.evaluation, w, m.silent, m.scrub_sound, m.events)
		}
	case link.Cutscene_Preview_Close:
		if _, ok := current_preview(e, m.ticket); ok {
			despawned = end_cutscene_preview(e, w, nil)
		}
	case:
		return false, false
	}
	return true, despawned
}

// current_preview is the open preview when it has the ticket.
@(private)
current_preview :: proc(e: ^Editor, ticket: u64) -> (^Cutscene_Preview, bool) {
	p, open := &e.session.cutscene_previews.open.?
	if !open || p.ticket != ticket {
		return nil, false
	}
	return p, true
}

// open_cutscene_preview opens a preview, after it ends the one before it, or tells the editor why it cannot. It runs
// in poll, while the layer is lifted.
@(private)
open_cutscene_preview :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	m: link.Cutscene_Preview_Open,
) -> (
	despawned: bool,
) {
	previews := &e.session.cutscene_previews
	if m.ticket <= previews.last {
		return
	}
	previews.last = m.ticket
	despawned = end_cutscene_preview(e, w, nil)
	_, mirrors := e.session.mirror.?
	if e.session.mode != .Edit || !mirrors || e.cutscenes == nil || e.assets == nil {
		send_preview_ended(e, m.ticket, .Not_Editing)
		return
	}
	guid := format.Guid(m.cutscene)
	modified: i64
	if m.unsaved {
		if data, newer, changed := asset.preview_blob(e.assets, guid, 0); changed {
			defer delete(data, e.platform.asset_allocator)
			if asset.set_live(e.assets, guid, data) {
				modified = newer
			}
		}
	}
	live, failure := cutscene.open_live(e.cutscenes, preview_context(e, w, scripts), guid, nil)
	if failure != nil {
		log.warnf("editor: the cutscene preview did not open: %v", failure)
		if modified != 0 {
			asset.clear_live(e.assets, guid)
		}
		send_preview_ended(e, m.ticket, .Failed)
		return
	}
	cutscene.set_audition(&live.evaluation, w, .Scrub)
	previews.open = Cutscene_Preview {
		ticket   = m.ticket,
		guid     = guid,
		unsaved  = m.unsaved,
		modified = modified,
		live     = live,
		clock    = Preview_Paused{},
		held     = make([dynamic]cutscene.Field, e.platform.heap_allocator),
	}
	p := &previews.open.?
	set_preview_time(e, w, p, m.tick)
	_, blob, _ := cutscene.cutscene_data(e.cutscenes, &p.live.evaluation)
	link.write_message(
		&e.session.outbox,
		link.Cutscene_Preview_Opened {
			ticket = m.ticket,
			tick = p.live.evaluation.time,
			range_start = blob.range_start,
			range_end = blob.range_end,
		},
	)
	return
}

// set_preview_time moves the preview's time, within its range. The next lay seeks to it.
@(private)
set_preview_time :: proc(e: ^Editor, w: ^ecs.World, p: ^Cutscene_Preview, tick: i32) {
	data, blob, ok := cutscene.cutscene_data(e.cutscenes, &p.live.evaluation)
	if !ok {
		return
	}
	cutscene.seek(e.cutscenes, &p.live.evaluation, w, data, blob, tick)
	if playing, is_playing := &p.clock.(Preview_Playing); is_playing {
		playing.carry = 0
	}
	cutscene.set_audition(&p.live.evaluation, w, audition_of(p.clock))
}

// audition_of is how the preview's audio tracks sound: they play while it plays, and play grains under the playhead as
// it is scrubbed.
@(private)
audition_of :: proc(clock: Preview_Clock) -> cutscene.Audition {
	switch _ in clock {
	case Preview_Playing:
		return .Preview
	case Preview_Paused:
	}
	return .Scrub
}

// end_cutscene_preview ends the open preview: the world is the document's again, whatever its tracks' When Finished
// says, its voices stop, its spawned entities go, its live blob ends, and with a reason, the editor learns why. It gives
// whether it despawned.
@(private)
end_cutscene_preview :: proc(
	e: ^Editor,
	w: ^ecs.World,
	reason: Maybe(link.Cutscene_Preview_End_Reason),
) -> (
	despawned: bool,
) {
	previews := &e.session.cutscene_previews
	p, open := &previews.open.?
	if !open {
		return
	}
	// A preview is no player that finishes: lift puts back what tracks set to keep wrote too, and a scrub's audition
	// stops the voices that a finish would let play on.
	cutscene.lift(e.cutscenes, &p.live.evaluation, w)
	cutscene.set_audition(&p.live.evaluation, w, .Scrub)
	despawned = cutscene.close_live(e.cutscenes, w, &p.live) > 0
	if p.modified != 0 {
		asset.clear_live(e.assets, p.guid)
	}
	if r, ended := reason.?; ended {
		send_preview_ended(e, p.ticket, r)
	}
	delete(p.held)
	previews.open = nil
	return
}

// free_cutscene_previews forgets the preview without touching the world, which a new game state does not have.
@(private)
free_cutscene_previews :: proc(previews: ^Cutscene_Previews) {
	if p, open := &previews.open.?; open {
		delete(p.held)
	}
	previews^ = {}
}

@(private)
send_preview_ended :: proc(e: ^Editor, ticket: u64, reason: link.Cutscene_Preview_End_Reason) {
	link.write_message(
		&e.session.outbox,
		link.Cutscene_Preview_Ended{ticket = ticket, reason = reason},
	)
}

// lift_cutscene_preview puts back what the preview wrote, and remembers it for the editor's marks. It gives whether it
// changed the world.
@(private)
lift_cutscene_preview :: proc(e: ^Editor, w: ^ecs.World) -> (lifted: bool) {
	p, open := &e.session.cutscene_previews.open.?
	if !open {
		return
	}
	clear(&p.held)
	for saved in cutscene.saved_fields(&p.live.evaluation, e.platform.frame_allocator) {
		append(&p.held, saved)
	}
	return cutscene.lift(e.cutscenes, &p.live.evaluation, w)
}

// lay_cutscene_preview evaluates the preview at its time, over the world. It gives whether it changed the world.
@(private)
lay_cutscene_preview :: proc(e: ^Editor, w: ^ecs.World) -> (laid: bool) {
	p, open := &e.session.cutscene_previews.open.?
	if !open {
		return
	}
	return evaluate_preview(e, w, p)
}

@(private)
evaluate_preview :: proc(e: ^Editor, w: ^ecs.World, p: ^Cutscene_Preview) -> bool {
	s := e.cutscenes
	ev := &p.live.evaluation
	data, blob, ok := cutscene.cutscene_data(s, ev)
	if !ok {
		return false
	}
	cutscene.evaluate(s, ev, w, data, blob, .Fixed)
	cutscene.evaluate(s, ev, w, data, blob, .Late)
	cutscene.show_live(s, w, &p.live)
	return true
}

// update_cutscene_preview moves an open preview that plays by the frame's real time, follows a new blob from the cook
// daemon and a reload's bindings, and evaluates it again, in Edit, once a frame. It gives whether it changed the world,
// whose transforms then need propagating, and whether it despawned.
update_cutscene_preview :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	dt: time.Duration,
) -> (
	changed: bool,
	despawned: bool,
) {
	p, open := &e.session.cutscene_previews.open.?
	if !open || e.session.overrides.layer != .Laid {
		return
	}
	if p.unsaved {
		if data, newer, newer_blob := asset.preview_blob(e.assets, p.guid, p.modified);
		   newer_blob {
			if asset.set_live(e.assets, p.guid, data) {
				p.modified = newer
			}
			delete(data, e.platform.asset_allocator)
		}
	}
	c := preview_context(e, w, scripts)
	gone, failure := cutscene.follow_live_bindings(e.cutscenes, c, &p.live, true)
	if failure == nil {
		more: int
		more, failure = cutscene.follow_live_children(e.cutscenes, c, &p.live)
		gone += more
	}
	despawned = gone > 0
	if failure != nil {
		log.warnf("editor: the cutscene preview ended: %v", failure)
		if end_cutscene_preview(e, w, link.Cutscene_Preview_End_Reason.Failed) {
			despawned = true
		}
		return true, despawned
	}
	data, blob, ok := cutscene.cutscene_data(e.cutscenes, &p.live.evaluation)
	if !ok {
		return
	}
	if playing, is_playing := &p.clock.(Preview_Playing); is_playing {
		if advance_preview(e, w, p, playing, data, blob, dt) {
			p.clock = Preview_Paused{}
			cutscene.set_audition(&p.live.evaluation, w, .Scrub)
			link.write_message(
				&e.session.outbox,
				link.Cutscene_Preview_Tick {
					ticket = p.ticket,
					tick = p.live.evaluation.time,
					playing = false,
				},
			)
		}
	}
	changed = evaluate_preview(e, w, p)
	// The events that a play crossed go to the scripts in this frame, as a player's do at the end of update.
	cutscene.send_events(e.cutscenes)
	return changed, despawned
}

// advance_preview moves a playing preview's time by the frame's real time at its rate. Forward, it moves as a player's
// clock does, so camera cuts blend; backward, and at a loop, it seeks. It gives whether the play stopped at an end of
// the range.
@(private)
advance_preview :: proc(
	e: ^Editor,
	w: ^ecs.World,
	p: ^Cutscene_Preview,
	playing: ^Preview_Playing,
	data: []byte,
	blob: ^format.Cutscene_Blob,
	dt: time.Duration,
) -> (
	stopped: bool,
) {
	s := e.cutscenes
	ev := &p.live.evaluation
	start, end := blob.range_start, blob.range_end
	if playing.looping {
		start = clamp(playing.loop_start, blob.range_start, blob.range_end)
		end = clamp(playing.loop_end, start, blob.range_end)
	}
	scaled := time.Duration(f64(dt) * f64(abs(playing.rate)))
	if playing.rate >= 0 {
		t := cutscene.advance(ev, blob, scaled)
		switch {
		case playing.looping && t >= end && end > start:
			cutscene.seek(s, ev, w, data, blob, start + (t - end) % (end - start))
		case !playing.looping && t >= blob.range_end:
			return true
		}
		return false
	}
	n := playing.carry + i64(scaled) * format.CUTSCENE_TICKS_PER_SECOND
	ticks := n / i64(time.Second)
	playing.carry = n % i64(time.Second)
	t := i64(ev.time) - ticks
	switch {
	case playing.looping && t <= i64(start) && end > start:
		t = i64(end) - (i64(start) - t) % i64(end - start)
	case !playing.looping && t <= i64(blob.range_start):
		cutscene.seek(s, ev, w, data, blob, blob.range_start)
		return true
	}
	if i32(t) != ev.time {
		cutscene.seek(s, ev, w, data, blob, i32(t))
	}
	return false
}

// send_cutscene_preview_tick tells the editor the preview's time while it plays, in each poll.
@(private)
send_cutscene_preview_tick :: proc(e: ^Editor, out: ^[dynamic]byte) {
	p, open := &e.session.cutscene_previews.open.?
	if !open {
		return
	}
	if _, playing := p.clock.(Preview_Playing); playing {
		link.write_message(
			out,
			link.Cutscene_Preview_Tick {
				ticket = p.ticket,
				tick = p.live.evaluation.time,
				playing = true,
			},
		)
	}
}

@(private)
preview_context :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
) -> cutscene.Player_Context {
	return {world = w, scenes = e.scenes, scripts = scripts, unheld = true}
}

// preview_entities adds the entities that the preview writes or spawned.
@(private)
preview_entities :: proc(e: ^Editor, w: ^ecs.World, entities: ^[dynamic]u64) {
	p, open := &e.session.cutscene_previews.open.?
	if !open {
		return
	}
	add :: proc(entities: ^[dynamic]u64, entity: ecs.Entity) {
		if entity != 0 && !slice.contains(entities[:], u64(entity)) {
			append(entities, u64(entity))
		}
	}
	for f in p.held {
		add(entities, f.entity)
	}
	for root in cutscene.spawned_roots(&p.live, w, e.platform.frame_allocator) {
		add(entities, root)
	}
}

// preview_held_fields adds the fields of an entity that the preview holds, as the editor names them: a pose holds each
// field of its Transform or Local_Transform, and another field is named by the component's field that holds it.
@(private)
preview_held_fields :: proc(
	e: ^Editor,
	w: ^ecs.World,
	entity: ecs.Entity,
	held: ^[dynamic]link.Held_Field,
) {
	p, open := &e.session.cutscene_previews.open.?
	if !open {
		return
	}
	add :: proc(held: ^[dynamic]link.Held_Field, field: link.Held_Field) {
		if !slice.contains(held[:], field) {
			append(held, field)
		}
	}
	for f in p.held {
		if f.entity != entity {
			continue
		}
		switch f.component {
		case ecs.TRANSFORM_ID:
			for name in ([]string{"position", "rotation", "scale"}) {
				add(held, {u64(ecs.TRANSFORM_ID), format.scene_field_hash(name)})
			}
		case ecs.LOCAL_TRANSFORM_ID:
			for name in ([]string{"offset", "rotation", "scale"}) {
				add(held, {u64(ecs.LOCAL_TRANSFORM_ID), format.scene_field_hash(name)})
			}
		case:
			info := ecs.registry_find(&w.registry, f.component)
			if info == nil {
				continue
			}
			for field in reflect.struct_fields_zipped(info.type) {
				if u32(field.offset) <= f.offset &&
				   f.offset < u32(field.offset) + u32(reflect.size_of_typeid(field.type.id)) {
					add(held, {u64(f.component), format.scene_field_hash(field.name)})
					break
				}
			}
		}
	}
}
