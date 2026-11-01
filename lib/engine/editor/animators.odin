package editor

import "base:runtime"
import "core:hash"
import "core:log"

import "cinnabar:engine/anim"
import anim_graph "cinnabar:engine/anim/graph"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"

#assert(len(format.Animation_Graph_Parameter_Kind) == len(link.Animator_Parameter_Kind))
#assert(int(format.Animation_Graph_Parameter_Kind.Trigger) == int(link.Animator_Parameter_Kind.Trigger))

// animator_graph is the blob of an Animator's graph, when its instance was made from it. The frame's table in
// anim.State is gone by the time that the editor polls, so this reads what animate's prepare has already loaded.
@(private = "file")
animator_graph :: proc(e: ^Editor, a: ^anim.Animator) -> (data: []byte, blob: ^format.Animation_Graph_Blob, ok: bool) {
	if e.assets == nil || a.graph == {} {
		return
	}
	h := asset.find(e.assets, a.graph) or_return
	data = asset.data(e.assets, h) or_return
	blob = format.animation_graph_view(data) or_return
	return data, blob, blob.header.key == a.instance.key
}

// animator_view is what an entity's Animator plays: empty but for the entity without one, or before its graph is ready.
@(private = "file")
animator_view :: proc(e: ^Editor, w: ^ecs.World, entity: ecs.Entity, allocator: runtime.Allocator) -> (view: link.Animator_View) {
	view.entity = u64(entity)
	a := ecs.get(w, entity, anim.Animator)
	if a == nil {
		return
	}
	data, blob, ok := animator_graph(e, a)
	if !ok {
		return
	}
	states := format.animation_graph_states(data, blob)
	inst := &a.instance
	if int(inst.state) >= len(states) {
		return
	}
	view.graph = ([16]u8)(a.graph)
	view.state = states[inst.state].node
	if inst.source != anim_graph.NONE && int(inst.source) < len(states) {
		view.source = states[inst.source].node
	}
	view.transition = inst.transition
	view.fade, view.fade_duration, view.progress = inst.fade, inst.fade_duration, inst.progress
	parameters := format.animation_graph_parameters(data, blob)
	view.parameters = make([]link.Animator_Parameter, len(parameters), allocator)
	for p, i in parameters {
		value := inst.parameters[i]
		if p.kind == .Trigger {
			value = 1 if inst.triggers & (1 << u32(i)) != 0 else 0
		}
		view.parameters[i] = {name = format.blob_string(data, p.name), kind = link.Animator_Parameter_Kind(p.kind), value = value}
	}
	return
}

// send_animators sends the view of each watched entity's Animator that changed since the editor last got it, and one
// empty view for an Animator that has gone, so the editor keeps no old state.
@(private)
send_animators :: proc(e: ^Editor, w: ^ecs.World, out: ^[dynamic]byte, allocator: runtime.Allocator) {
	for &watched in e.watched {
		view := animator_view(e, w, watched.entity, allocator)
		if view.graph == {} {
			if watched.animator_sent != 0 {
				watched.animator_sent = 0
				link.write_message(out, view)
			}
			continue
		}
		encoded := make([dynamic]byte, allocator)
		link.write_message(&encoded, view)
		// A hash of 0 means that the editor knows of none, so a real 0 counts as 1.
		h := max(hash.fnv64a(encoded[link.HEADER_SIZE:]), 1)
		if h != watched.animator_sent {
			watched.animator_sent = h
			append(out, ..encoded[:])
		}
	}
}

// set_animator_parameter sets a parameter of an entity's Animator by its name, as a script does. Outside Play and Paused,
// or before the graph is ready, nothing plays that would read it, and a new instance would lose it.
@(private)
set_animator_parameter :: proc(e: ^Editor, w: ^ecs.World, message: link.Set_Animator_Parameter) {
	if e.mode == .Edit {
		return
	}
	a := ecs.get(w, ecs.Entity(message.entity), anim.Animator)
	if a == nil {
		return
	}
	data, blob, ok := animator_graph(e, a)
	if !ok {
		return
	}
	name_hash := format.animation_graph_hash(message.name)
	for p, i in format.animation_graph_parameters(data, blob) {
		if p.hash != name_hash {
			continue
		}
		if p.kind != .Trigger {
			anim.set_parameter(a, i, message.value)
		} else if message.value != 0 {
			anim.fire(a, i)
		} else {
			a.instance.triggers &~= 1 << u32(i)
		}
		return
	}
	log.warnf("editor: the Animator's graph has no parameter named %s", message.name)
}
