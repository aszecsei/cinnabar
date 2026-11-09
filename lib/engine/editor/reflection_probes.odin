package editor

import "core:hash"

import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"

// The editor's side of the reflection probes (see docs/editor/shell-and-panels.md#properties): the captures that it asks
// for, and the state of each watched probe, which the Properties panel shows.

// capture_probes asks the renderer for a capture of each of the entities' probes, or of every probe with none. A probe
// that holds no slot is not captured. Without a renderer, nothing is.
@(private)
capture_probes :: proc(e: ^Editor, entities: []u64) {
	if e.renderer == nil {
		return
	}
	if len(entities) == 0 {
		render.capture_reflection_probes(e.renderer)
		return
	}
	for entity in entities {
		render.capture_reflection_probe(e.renderer, ecs.Entity(entity))
	}
}

// reflection_probe_view is the state of an entity's probe, and the time of its last capture, which the view gives as
// an age: None without a probe, a renderer or the probes' cubes, which the reflections being off frees.
@(private = "file")
reflection_probe_view :: proc(e: ^Editor, w: ^ecs.World, entity: ecs.Entity) -> (view: link.Reflection_Probe_View, time: f64) {
	view.entity = u64(entity)
	if e.renderer == nil || !ecs.has(w, entity, render.Reflection_Probe) {
		return
	}
	if _, _, made := render.reflection_probe_cubes(e.renderer); !made {
		return
	}
	state := render.reflection_probe_state(e.renderer, entity)
	view.capturing = state.capturing || state.forced
	switch {
	case !state.slot:
		view.status = .No_Slot
	case state.cube == nil:
		view.status = .Waiting
	case:
		cube := state.cube.?
		view.status, view.complete, time = .Captured, cube.complete, cube.time
		now := e.platform.time_seconds != nil ? e.platform.time_seconds() : time
		view.age = f32(max(now - time, 0))
	}
	return
}

// send_reflection_probes sends the view of each watched entity's probe that changed since the editor last got it, but
// for its age, which a new capture's time changes: the first after a watch, whatever it is, so the editor drops a view
// that it kept from an earlier watch, then one None view for a probe that has gone, so the editor keeps no old state.
@(private)
send_reflection_probes :: proc(e: ^Editor, w: ^ecs.World, out: ^[dynamic]byte) {
	for &watched in e.session.watched {
		view, time := reflection_probe_view(e, w, watched.entity)
		h: u64
		if view.status != .None {
			key := struct #packed {
				status:    link.Reflection_Probe_Status,
				capturing: bool,
				complete:  bool,
				time:      f64,
			}{view.status, view.capturing, view.complete, time}
			// 0 is None's, so a real 0 counts as 1.
			h = max(hash.fnv64a(([^]byte)(&key)[:size_of(key)]), 1)
		}
		if sent, ok := watched.probe_sent.?; !ok || sent != h {
			watched.probe_sent = h
			link.write_message(out, view)
		}
	}
}
