// Package anim plays animation graphs, and clips without one, on skinned meshes. An Animator's graph moves in fixed
// ticks by the parameters that gameplay sets, and gives its events, which go to the entity's behaviours, and its root
// motion, which gameplay reads from Root_Motion; each presented frame poses the entity between the last two ticks into
// a palette, which the renderer skins its mesh with. What a graph does is lib/engine/anim/graph's, which reads nothing
// of the world; this package only copies parameters in and outputs out (see docs/animation/design.md#the-ecs).
package anim

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"

import anim_graph "cinnabar:engine/anim/graph"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

// The animation components' stable IDs (see docs/world/ecs.md#component-registry). 80 to 95 are animation's.
ANIMATOR_ID :: ecs.Component_Id(80)
ROOT_MOTION_ID :: ecs.Component_Id(81)

// Animator plays an animation graph on its entity's skinned Mesh_Renderer, or without a graph, a clip, looping or
// held. The graph's clips' skin is the mesh's. It moves in fixed ticks, by speed times the tick.
Animator :: struct {
	graph:    format.Guid `asset:"animation_graph"`,
	clip:     format.Guid `asset:"animation"`,
	speed:    f32 `editor:"range=0,4"`,
	// Without a graph: whether the clip loops, or holds at its end.
	loop:     bool,
	// A stopped Animator holds its pose, and keeps its triggers for when it plays.
	playing:  bool,
	// The current state's index, and its clip's time after the last tick, which the editor shows.
	state:    u16 `editor:"read" script:"-"`,
	time:     f32 `editor:"read" script:"-"`,
	// The Animator's graph in prepare's table of the frame.
	slot:     u16 `editor:"-" script:"-"`,
	instance: anim_graph.Instance `editor:"-" script:"-"`,
}
#assert(size_of(Animator) <= ecs.MAX_COMPONENT_SIZE)

DEFAULT_ANIMATOR :: Animator {
	speed   = 1,
	loop    = true,
	playing = true,
}

// Root_Motion is what an Animator's graph reports of its root joint's motion, which the pose then leaves out: an
// entity without it keeps the motion in its pose. Only animate writes it, and nothing applies it: gameplay moves the
// entity by it, or does not (see docs/animation/design.md#root-motion). The moves are in the model's space, turned to
// the root's heading at their start, along x and z.
Root_Motion :: struct {
	// The last tick's move and turn about y, in radians.
	translation:       [3]f32 `editor:"read" script:"read"`,
	yaw:               f32 `editor:"read" script:"read"`,
	// The ticks of this frame, one after another, from prepare on.
	frame_translation: [3]f32 `editor:"read" script:"read"`,
	frame_yaw:         f32 `editor:"read" script:"read"`,
}

// Event_Value is an event's argument.
Event_Value :: union {
	f64,
	string,
}

// Event is an event that an Animator's graph raised in a tick: a marker of a clip, or a state's entry or exit. Its
// strings are the State's own, until the list that holds it is cleared.
Event :: struct {
	entity: ecs.Entity,
	kind:   anim_graph.Fired_Kind,
	name:   string,
	// The state that raised it.
	state:  string,
	args:   [format.MAX_ANIMATION_GRAPH_ARGS]Event_Value,
}

// Resolved is an Animator's graph and its clips' blobs, loaded, which a frame's ticks read, or a clip without a graph.
// It is ready when every blob is loaded and the clips fit one skin.
@(private)
Resolved :: struct {
	graph_guid: format.Guid,
	clip_guid:  format.Guid,
	loop:       bool,
	key:        u64,
	ready:      bool,
	graph:      anim_graph.Graph,
	skin_data:  []byte,
	skin:       ^format.Skin_Blob,
}

// Job_Event is a tick's event as a job records it, which flush_job_events turns into an Event.
@(private)
Job_Event :: struct {
	entity: ecs.Entity,
	slot:   u16,
	fired:  anim_graph.Fired,
}

// State is the animation's queries, the assets that it reads graphs and clips from, the frame's graphs, and the events
// of the last tick and of the frame. It lives in Game_State.
State :: struct {
	assets:       ^asset.Assets,
	world:        ^ecs.World,
	animators:    ecs.Query,
	job_events:   ecs.Job_Buffer,
	// prepare's graphs, in frame memory, which the ticks read until asset.poll.
	graphs:       []Resolved,
	// The events of the tick numbered tick, and of every tick since begin_frame. Their strings are on the heap.
	tick_events:  [dynamic]Event,
	tick:         u64,
	frame_events: [dynamic]Event,
}

register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Animator, ANIMATOR_ID, DEFAULT_ANIMATOR)
	ecs.register_component(r, Root_Motion, ROOT_MOTION_ID)
}

// register makes the queries, the events' job buffer and the animate system. Call it after the world's components
// are registered, in init and in on_reload.
register :: proc(s: ^State, w: ^ecs.World, assets: ^asset.Assets) {
	s.assets, s.world = assets, w
	s.graphs = nil
	terms := []ecs.Term{ecs.write(w, Animator), ecs.optional(ecs.write(w, Root_Motion))}
	s.animators = ecs.query(w, terms)
	s.job_events = ecs.register_job_buffer(w, {name = "animation events", user = s, make = make_job_events, flush = flush_job_events})
	ecs.register_system(w, {name = "animate", stage = .Fixed, procedure = animate, terms = terms, data = s})
}

// destroy frees the events' strings and lists.
destroy :: proc(s: ^State) {
	clear_events(s, &s.tick_events)
	clear_events(s, &s.frame_events)
	delete(s.tick_events)
	delete(s.frame_events)
}

// prepare loads each Animator's graph and clips into the frame's table, so the animate system's jobs read no assets,
// and starts the instance of an Animator whose graph is new or changed, keeping the parameters that it still has. It
// starts each Root_Motion's frame from nothing. Call it in the frame code before the ticks.
prepare :: proc(s: ^State, w: ^ecs.World) {
	table := make([dynamic]Resolved, w.platform.frame_allocator)
	it := ecs.query_iter(w, s.animators)
	for view in ecs.query_next(&it) {
		motions := ecs.column(view, 1, Root_Motion)
		for &a, i in ecs.column(view, 0, Animator) {
			slot := resolve(s, &table, &a, w.platform.frame_allocator)
			a.slot = u16(slot)
			r := &table[slot]
			if r.ready && a.instance.key != r.key {
				old := a.instance
				anim_graph.init(&r.graph, &a.instance, r.key)
				anim_graph.keep_parameters(&r.graph, &a.instance, &old)
				a.state, a.time = a.instance.state, current_time(&a.instance)
				warn_graph(r)
			}
			if motions != nil {
				motions[i].frame_translation, motions[i].frame_yaw = {}, 0
			}
		}
	}
	s.graphs = table[:]
}

// begin_frame clears the frame's events. Call it in the frame code before the ticks, with physics.begin_frame.
begin_frame :: proc(s: ^State) {
	clear_events(s, &s.frame_events)
}

// animate moves each playing Animator whose graph is ready by a tick, and records its events and root motion.
animate :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	events: ^[dynamic]Job_Event
	it := ecs.query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		motions := ecs.column(view, 1, Root_Motion)
		for &a, i in ecs.column(view, 0, Animator) {
			r := ready_graph(s, &a) or_continue
			out: anim_graph.Tick_Output
			if a.playing {
				anim_graph.advance(&r.graph, &a.instance, ctx.dt * max(a.speed, 0), &out)
			}
			a.state, a.time = a.instance.state, current_time(&a.instance)
			if motions != nil {
				m := &motions[i]
				m.translation, m.yaw = out.translation, out.yaw
				m.frame_translation += rotate_y(out.translation, m.frame_yaw)
				m.frame_yaw += out.yaw
			}
			if out.event_count == 0 {
				continue
			}
			if events == nil {
				events = (^[dynamic]Job_Event)(ecs.job_buffer(ctx, s.job_events))
			}
			for f in out.events[:out.event_count] {
				append(events, Job_Event{entities[i], a.slot, f})
			}
			if out.dropped > 0 {
				log.warnf("anim: an entity's graph raised %d events past MAX_TICK_EVENTS in a tick", out.dropped)
			}
		}
	}
}

// ready_graph is an Animator's graph in the frame's table, if prepare made it ready and started the Animator's
// instance for it. An Animator that the ticks spawned waits for the next frame.
@(private)
ready_graph :: proc(s: ^State, a: ^Animator) -> (^Resolved, bool) {
	if int(a.slot) >= len(s.graphs) {
		return nil, false
	}
	r := &s.graphs[a.slot]
	if !r.ready || a.instance.key != r.key || r.graph_guid != a.graph || (a.graph == {} && (r.clip_guid != a.clip || r.loop != a.loop)) {
		return nil, false
	}
	return r, true
}

// current_time is the time of the current state's first clip, which the editor shows.
@(private)
current_time :: proc(inst: ^anim_graph.Instance) -> f32 {
	for s in inst.samples[:inst.sample_count] {
		if s.state == inst.state && .Frozen not_in s.flags {
			return s.time
		}
	}
	return 0
}

@(private)
make_job_events :: proc(user: rawptr, allocator: runtime.Allocator) -> rawptr {
	events := new([dynamic]Job_Event, allocator)
	events^ = make([dynamic]Job_Event, allocator)
	return events
}

// flush_job_events turns the tick's events into Events, in the order that the world gives the jobs, so their order
// does not depend on the jobs' timing, and keeps them for the tick and the frame.
@(private)
flush_job_events :: proc(user: rawptr, buffers: []rawptr) {
	s := (^State)(user)
	clear_events(s, &s.tick_events)
	s.tick = s.world.clock.tick
	for b in buffers {
		for e in (^[dynamic]Job_Event)(b) {
			if int(e.slot) >= len(s.graphs) {
				continue
			}
			event := make_event(s, &s.graphs[e.slot], e)
			append(&s.tick_events, event)
			append(&s.frame_events, copy_event(s, event))
		}
	}
}

@(private)
make_event :: proc(s: ^State, r: ^Resolved, e: Job_Event) -> Event {
	g := &r.graph
	allocator := s.world.platform.heap_allocator
	record := format.animation_graph_events(g.data, g.blob)[e.fired.event]
	state := format.animation_graph_states(g.data, g.blob)[e.fired.state]
	event := Event {
		entity = e.entity,
		kind   = e.fired.kind,
		name   = strings.clone(format.blob_string(g.data, record.name), allocator),
		state  = strings.clone(format.blob_string(g.data, state.name), allocator),
	}
	for a, i in record.args {
		switch a.kind {
		case .None:
		case .Number:
			event.args[i] = f64(a.number)
		case .Text:
			event.args[i] = strings.clone(format.blob_string(g.data, a.text), allocator)
		}
	}
	return event
}

@(private)
copy_event :: proc(s: ^State, e: Event) -> Event {
	allocator := s.world.platform.heap_allocator
	c := e
	c.name = strings.clone(e.name, allocator)
	c.state = strings.clone(e.state, allocator)
	for &a in c.args {
		if text, is_text := a.(string); is_text {
			a = strings.clone(text, allocator)
		}
	}
	return c
}

@(private)
clear_events :: proc(s: ^State, events: ^[dynamic]Event) {
	if s.world == nil {
		return
	}
	allocator := s.world.platform.heap_allocator
	for e in events {
		delete(e.name, allocator)
		delete(e.state, allocator)
		for a in e.args {
			if text, is_text := a.(string); is_text {
				delete(text, allocator)
			}
		}
	}
	clear(events)
}

// tick_events are the events of the last tick, which the next tick's Fixed systems see (see
// docs/animation/design.md#events-in-the-world).
tick_events :: proc(s: ^State) -> []Event {
	if s.world == nil || s.tick + 1 != s.world.clock.tick {
		return nil
	}
	return s.tick_events[:]
}

// frame_events are the events of every tick since begin_frame, which the frame's Update and Late systems see.
frame_events :: proc(s: ^State) -> []Event {
	return s.frame_events[:]
}

// send_events sends the tick's events to the behaviours of their entities, as on_animation_event with the event's name
// and its arguments. Call it after the tick's Fixed systems, after physics.send_events and before
// script.fixed_events, which delivers them; it is frame code, where script.send is safe.
send_events :: proc(s: ^State, w: ^ecs.World, r: ^script.Runtime) {
	if s.tick != w.clock.tick {
		return
	}
	for e in s.tick_events {
		if !ecs.is_alive(w, e.entity) || !ecs.has(w, e.entity, script.Behaviours) {
			continue
		}
		args: [1 + format.MAX_ANIMATION_GRAPH_ARGS]script.Event_Arg
		args[0] = e.name
		count := 1
		for a in e.args {
			switch v in a {
			case f64:
				args[count] = v
				count += 1
			case string:
				args[count] = v
				count += 1
			}
		}
		script.send(r, e.entity, "animation_event", ..args[:count])
	}
}

// present poses every Animator whose graph is ready between the last two ticks, by the clock's alpha, into a pose for
// the renderer, without the root motion of those with a Root_Motion. It loads the blobs again, since asset.poll may
// have changed them since prepare. The poses and their palettes are in allocator, which is frame memory.
present :: proc(s: ^State, w: ^ecs.World, allocator: mem.Allocator) -> []render.Skin_Pose {
	poses := make([dynamic]render.Skin_Pose, allocator)
	table := make([dynamic]Resolved, allocator)
	it := ecs.query_iter(w, s.animators)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		motions := ecs.column(view, 1, Root_Motion)
		for &a, i in ecs.column(view, 0, Animator) {
			slot := resolve(s, &table, &a, allocator)
			r := &table[slot]
			if !r.ready || a.instance.key != r.key {
				continue
			}
			joints := format.skin_joints(r.skin_data, r.skin)
			rest := make([]anim_graph.Joint_Pose, len(joints), allocator)
			scratch := make([]anim_graph.Joint_Pose, len(joints), allocator)
			locals := make([]anim_graph.Joint_Pose, len(joints), allocator)
			models := make([]matrix[4, 4]f32, len(joints), allocator)
			palette := make([][3][4]f32, len(joints), allocator)
			anim_graph.rest_pose(joints, rest)
			anim_graph.present(&r.graph, &a.instance, w.clock.alpha, rest, scratch, locals)
			if motions != nil {
				anim_graph.remove_root_motion(&r.graph, locals)
			}
			sphere := anim_graph.compose(joints, locals, models, palette)
			append(&poses, render.Skin_Pose{entity = entities[i], palette = palette, sphere = sphere})
		}
	}
	return poses[:]
}

// preview_pose moves a graph that plays apart from any entity, as the editor's preview plays one, by dt seconds, and
// gives its pose. The instance is the caller's; it starts again with a new blob, keeping the parameters that the graph
// still has. data is the graph's blob, which may be one that the editor has not saved, and the clips and the skin load by
// their GUIDs. The pose leaves out root motion, so the mesh stays in view. It is not ready until they have all loaded.
preview_pose :: proc(assets: ^asset.Assets, data: []byte, inst: ^anim_graph.Instance, dt: f32, allocator: mem.Allocator) -> (palette: [][3][4]f32, sphere: [4]f32, ok: bool) {
	s := State {
		assets = assets,
	}
	r := load_graph(&s, &Animator{}, allocator, data)
	if !r.ready {
		return
	}
	if inst.key != r.key {
		old := inst^
		anim_graph.init(&r.graph, inst, r.key)
		anim_graph.keep_parameters(&r.graph, inst, &old)
	}
	out: anim_graph.Tick_Output
	anim_graph.advance(&r.graph, inst, dt, &out)
	joints := format.skin_joints(r.skin_data, r.skin)
	rest := make([]anim_graph.Joint_Pose, len(joints), allocator)
	scratch := make([]anim_graph.Joint_Pose, len(joints), allocator)
	locals := make([]anim_graph.Joint_Pose, len(joints), allocator)
	models := make([]matrix[4, 4]f32, len(joints), allocator)
	palette = make([][3][4]f32, len(joints), allocator)
	anim_graph.rest_pose(joints, rest)
	anim_graph.present(&r.graph, inst, 1, rest, scratch, locals)
	anim_graph.remove_root_motion(&r.graph, locals)
	sphere = anim_graph.compose(joints, locals, models, palette)
	return palette, sphere, true
}

// resolve is the index in a table of an Animator's graph, which it loads and adds if the table does not have it.
@(private)
resolve :: proc(s: ^State, table: ^[dynamic]Resolved, a: ^Animator, allocator: mem.Allocator) -> int {
	for &r, i in table {
		if r.graph_guid == a.graph && (a.graph != {} || (r.clip_guid == a.clip && r.loop == a.loop)) {
			return i
		}
	}
	append(table, load_graph(s, a, allocator))
	return len(table) - 1
}

// load_graph loads an Animator's graph and its clips, or its clip without a graph, and their skin, and finds the
// root motion joint by its name. With graph_bytes, those are the graph's blob, and the Animator names none.
@(private)
load_graph :: proc(s: ^State, a: ^Animator, allocator: mem.Allocator, graph_bytes: []byte = nil) -> (r: Resolved) {
	r = {graph_guid = a.graph, clip_guid = a.clip, loop = a.loop}
	r.graph.root, r.graph.root_parent, r.graph.root_parent_rotation = -1, 1, 1
	clips: []anim_graph.Clip
	ok: bool
	if a.graph != {} || graph_bytes != nil {
		if graph_bytes != nil {
			r.graph.data = graph_bytes
			r.graph.blob, ok = format.animation_graph_view(graph_bytes)
		} else {
			r.graph.data, r.graph.blob, ok = graph_data(s, a.graph)
		}
		if !ok {
			return
		}
		records := format.animation_graph_clips(r.graph.data, r.graph.blob)
		clips = make([]anim_graph.Clip, len(records), allocator)
		for c, i in records {
			clips[i].data, clips[i].blob, ok = clip_data(s, c.clip)
			if !ok {
				return
			}
		}
		r.key = r.graph.blob.header.key
	} else {
		clips = make([]anim_graph.Clip, 1, allocator)
		clips[0].data, clips[0].blob, ok = clip_data(s, a.clip)
		if !ok {
			return
		}
		r.graph.loop = a.loop
		r.key = clips[0].blob.header.key ~ (2 if a.loop else 1)
	}
	if len(clips) == 0 {
		return
	}
	r.graph.clips = clips
	r.skin_data, r.skin, ok = skin_data(s, clips[0].blob.skin)
	if !ok {
		return
	}
	joints := format.skin_joints(r.skin_data, r.skin)
	for c in clips {
		if c.blob.skin != clips[0].blob.skin || c.blob.joint_count != u32(len(joints)) {
			return
		}
	}
	if r.graph.blob != nil {
		find_root(&r, joints, format.blob_string(r.graph.data, r.graph.blob.root_motion))
	}
	r.ready = true
	return
}

// find_root finds the root motion joint by its name, and its parent's rest pose in the model's space.
@(private)
find_root :: proc(r: ^Resolved, joints: []format.Skin_Joint, name: string) {
	if name == "" {
		return
	}
	for j, i in joints {
		if format.blob_string(r.skin_data, j.name) != name {
			continue
		}
		parent: matrix[4, 4]f32 = 1
		rotation: quaternion128 = 1
		// The ancestors, from the root joint's parent up, which compose from the top down.
		chain: [64]int
		count := 0
		for p := j.parent; p >= 0 && count < len(chain); p = joints[p].parent {
			chain[count] = int(p)
			count += 1
		}
		for k := count - 1; k >= 0; k -= 1 {
			pose := joint_rest(joints[chain[k]])
			parent = parent * linalg.matrix4_from_trs_f32(pose.translation, pose.rotation, pose.scale)
			rotation = rotation * pose.rotation
		}
		r.graph.root, r.graph.root_parent, r.graph.root_parent_rotation, r.graph.root_rest = i, parent, rotation, joint_rest(j)
		return
	}
}

@(private)
joint_rest :: proc(j: format.Skin_Joint) -> anim_graph.Joint_Pose {
	return {j.translation, quaternion(real = j.rotation.w, imag = j.rotation.x, jmag = j.rotation.y, kmag = j.rotation.z), j.scale}
}

// warn_graph tells of what the cooker could not check, when an Animator starts a graph: a root motion joint that
// the skin does not have, and markers past their clips' ends.
@(private)
warn_graph :: proc(r: ^Resolved) {
	g := &r.graph
	if g.blob == nil {
		return
	}
	path := format.blob_string(g.data, g.blob.source_path)
	if name := format.blob_string(g.data, g.blob.root_motion); name != "" && g.root < 0 {
		log.warnf("anim: %s: the skin has no joint %s for root motion", path, name)
	}
	markers := format.animation_graph_markers(g.data, g.blob)
	for c, i in format.animation_graph_clips(g.data, g.blob) {
		for m in markers[c.first_marker:][:c.marker_count] {
			if m.time > g.clips[i].blob.duration {
				log.warnf("anim: %s: clip %s has an event at %.3f s, past its end at %.3f s", path, format.blob_string(g.data, c.name), m.time, g.clips[i].blob.duration)
			}
		}
	}
}

// rotate_y turns a vector about y by an angle.
@(private)
rotate_y :: proc "contextless" (v: [3]f32, angle: f32) -> [3]f32 {
	s, c := math.sin(angle), math.cos(angle)
	return {c * v.x + s * v.z, v.y, -s * v.x + c * v.z}
}

// parameter is the index of an Animator's graph's parameter by its name, in the frame's table, and its kind. It is
// safe in Fixed systems' jobs, which may then set it with set_parameter or fire.
parameter :: proc(s: ^State, a: ^Animator, name: string) -> (index: int, kind: format.Animation_Graph_Parameter_Kind, ok: bool) {
	r := ready_graph(s, a) or_return
	if r.graph.blob == nil {
		return
	}
	hash := format.animation_graph_hash(name)
	for p, i in format.animation_graph_parameters(r.graph.data, r.graph.blob) {
		if p.hash == hash {
			return i, p.kind, true
		}
	}
	return
}

// set_parameter sets a float parameter, or a bool's to 1 or 0, which the next tick reads.
set_parameter :: proc(a: ^Animator, index: int, value: f32) {
	if index >= 0 && index < len(a.instance.parameters) {
		a.instance.parameters[index] = value
	}
}

// fire sets a trigger for the next tick.
fire :: proc(a: ^Animator, index: int) {
	if index >= 0 && index < len(a.instance.parameters) {
		a.instance.triggers |= 1 << u32(index)
	}
}

// state_name is the name of an Animator's current state, or "" without a graph or before it is ready.
state_name :: proc(s: ^State, a: ^Animator) -> string {
	r, ok := ready_graph(s, a)
	if !ok || r.graph.blob == nil {
		return ""
	}
	return format.blob_string(r.graph.data, format.animation_graph_states(r.graph.data, r.graph.blob)[a.instance.state].name)
}

// root_motion_world is an entity's last tick of root motion in the world: its move, turned and scaled by the entity's
// Transform, and its turn about the world's y. It reads only the entity's own components; what to do with them is the
// caller's.
root_motion_world :: proc(w: ^ecs.World, e: ecs.Entity) -> (delta: [3]f32, turn: quaternion128, ok: bool) {
	m := ecs.get(w, e, Root_Motion)
	t := ecs.get(w, e, ecs.Transform)
	if m == nil || t == nil {
		return {}, 1, false
	}
	return linalg.quaternion_mul_vector3(t.rotation, m.translation * t.scale), linalg.quaternion_angle_axis_f32(m.yaw, {0, 1, 0}), true
}

// graph_data is an animation graph's blob, which it loads if it is not loaded.
graph_data :: proc(s: ^State, guid: format.Guid) -> (data: []byte, blob: ^format.Animation_Graph_Blob, ok: bool) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.load(s.assets, guid) or_return
	data = asset.data(s.assets, h) or_return
	blob = format.animation_graph_view(data) or_return
	return data, blob, true
}

// clip_data is an animation clip's blob, which it loads if it is not loaded.
clip_data :: proc(s: ^State, guid: format.Guid) -> (data: []byte, blob: ^format.Animation_Blob, ok: bool) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.load(s.assets, guid) or_return
	data = asset.data(s.assets, h) or_return
	blob = format.animation_view(data) or_return
	return data, blob, true
}

// skin_data is a skin's blob, which it loads if it is not loaded.
skin_data :: proc(s: ^State, guid: format.Guid) -> (data: []byte, blob: ^format.Skin_Blob, ok: bool) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.load(s.assets, guid) or_return
	data = asset.data(s.assets, h) or_return
	blob = format.skin_view(data) or_return
	return data, blob, true
}
