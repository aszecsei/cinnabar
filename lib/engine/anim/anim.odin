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
	// The clips that a driver poses the Animator with over its graph, while one holds it. Only begin_drive, drive and
	// end_drive write it, and scenes do not save it.
	driven:   Maybe(Driven) `editor:"-" script:"-"`,
}
#assert(size_of(Animator) <= ecs.MAX_COMPONENT_SIZE)

// An Animator blends at most this many driven clips over its graph's pose, so a driver can fade from one to another.
MAX_DRIVEN :: 2

// Driven_Sample is a clip that a system outside the graph, such as a cutscene, poses an Animator with: at a time that
// the driver gives, by a weight over the graph's pose (see docs/animation/design.md#driving-an-animator).
Driven_Sample :: struct {
	clip:        format.Guid,
	// Seconds into the clip, held to its length. It does not tick, and the clip raises no events.
	time:        f32,
	// From 0, the graph's pose, to 1, the clip's. Weights that add up to more than 1 are scaled to add up to 1.
	weight:      f32,
	root_motion: Driven_Root_Motion,
}

// Driven_Root_Motion is what a driven clip does with its root joint's motion.
Driven_Root_Motion :: enum u8 {
	// The pose leaves it out, so the clip plays in place, and the ticks report none of it.
	In_Place,
	// The ticks report it in Root_Motion, as the graph's is. The pose leaves it out when the entity has a Root_Motion,
	// and keeps it otherwise.
	Reported,
	// The pose keeps it, whether or not the entity has a Root_Motion, so the root moves in the mesh, and the ticks
	// report none of it.
	In_Pose,
}

// Driven is an Animator while a driver holds it: the generation that the driver's token must match, and its samples.
Driven :: struct {
	generation: u32,
	// Whether the graph's time stops, keeping its triggers, as playing = false stops it.
	hold:       bool,
	samples:    [MAX_DRIVEN]Driven_Sample,
	// The samples at the last tick, which the next tick's root motion is measured from.
	ticked:     [MAX_DRIVEN]Driven_Sample,
}

// Drive_Token is a driver's hold on an Animator, which begin_drive gives. Through a stale token, drive and end_drive
// do nothing.
Drive_Token :: struct {
	entity:     ecs.Entity,
	generation: u32,
}

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

// Driven_Clip is a driven clip's blob, loaded, which a frame's ticks read.
@(private)
Driven_Clip :: struct {
	guid: format.Guid,
	clip: anim_graph.Clip,
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
	// prepare's graphs, in frame memory, from prepare to end_frame, and nil between frames. A graph points into its asset's
	// blob, which asset.poll can free, so nothing reads the table after the frame ends: an Animator's slot then finds no
	// graph until the next prepare.
	graphs:       []Resolved,
	// The frame's driven clips, which prepare loads, and which go when the graphs go.
	driven_clips: []Driven_Clip,
	// The last driver's generation, which begin_drive counts up, so a token never matches a later driver's.
	next_drive:   u32,
	// The markers that drivers raised since the last flush (see raise_marker), as events that own their strings, so
	// they read no frame's graph table. The flush moves them before the tick's own events. At most MAX_RAISED.
	raised:       [dynamic]Event,
	// The events of the tick numbered tick, and of every tick since begin_frame. Their strings are on the heap.
	tick_events:  [dynamic]Event,
	tick:         u64,
	frame_events: [dynamic]Event,
}

register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Animator, ANIMATOR_ID, DEFAULT_ANIMATOR, category = "Animation")
	ecs.register_component(r, Root_Motion, ROOT_MOTION_ID, category = "Animation")
}

// register makes the queries, the events' job buffer and the animate system. Call it after the world's components
// are registered, in init and in on_reload.
register :: proc(s: ^State, w: ^ecs.World, assets: ^asset.Assets) {
	s.assets, s.world = assets, w
	s.graphs, s.driven_clips = nil, nil
	terms := []ecs.Term{ecs.write(w, Animator), ecs.optional(ecs.write(w, Root_Motion))}
	s.animators = ecs.query(w, terms)
	s.job_events = ecs.register_job_buffer(
		w,
		{name = "animation events", user = s, make = make_job_events, flush = flush_job_events},
	)
	ecs.register_system(
		w,
		{name = "animate", stage = .Fixed, procedure = animate, terms = terms, data = s},
	)
}

// destroy frees the events' strings and lists.
destroy :: proc(s: ^State) {
	clear_events(s, &s.tick_events)
	clear_events(s, &s.frame_events)
	clear_events(s, &s.raised)
	delete(s.tick_events)
	delete(s.frame_events)
	delete(s.raised)
	s.raised = nil
}

// prepare loads each Animator's graph and clips into the frame's table, so the animate system's jobs read no assets,
// and starts the instance of an Animator whose graph is new or changed, keeping the parameters that it still has. It
// starts each Root_Motion's frame from nothing. Call it in the frame code before the ticks.
prepare :: proc(s: ^State, w: ^ecs.World) {
	table := make([dynamic]Resolved, w.platform.frame_allocator)
	driven_clips := make([dynamic]Driven_Clip, w.platform.frame_allocator)
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
			if d, driven := a.driven.?; driven {
				for sample in d.samples {
					load_driven_clip(s, &driven_clips, sample.clip)
				}
			}
			if motions != nil {
				motions[i].frame_translation, motions[i].frame_yaw = {}, 0
			}
		}
	}
	s.graphs = table[:]
	s.driven_clips = driven_clips[:]
}

// load_driven_clip adds a driven clip's blob to a table, if it loads and the table does not have it.
@(private)
load_driven_clip :: proc(s: ^State, table: ^[dynamic]Driven_Clip, guid: format.Guid) {
	if guid == {} {
		return
	}
	for c in table {
		if c.guid == guid {
			return
		}
	}
	if data, blob, ok := clip_data(s, guid); ok {
		append(table, Driven_Clip{guid, {data, blob}})
	}
}

// end_frame lets the frame's graphs go, which prepare made, before asset.poll can free their blobs. Until the next
// prepare, an Animator has no graph: Animation calls from scripts that run between frames, such as a main script that a
// reload starts or an editor's scene load, find none. Call it at the end of the frame code, before asset.poll.
end_frame :: proc(s: ^State) {
	s.graphs, s.driven_clips = nil, nil
}

// begin_frame clears the frame's events. Call it in the frame code before the ticks, with physics.begin_frame.
begin_frame :: proc(s: ^State) {
	clear_events(s, &s.frame_events)
}

// animate moves each playing Animator whose graph is ready by a tick, and records its events and root motion.
animate :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	events: ^[dynamic]Job_Event
	// The flush runs only for a stage whose jobs asked for a buffer, and it is what moves the drivers' markers to the
	// tick's events.
	if len(s.raised) > 0 {
		events = (^[dynamic]Job_Event)(ecs.job_buffer(ctx, s.job_events))
	}
	it := ecs.query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		motions := ecs.column(view, 1, Root_Motion)
		for &a, i in ecs.column(view, 0, Animator) {
			d, driven := &a.driven.?
			r, ready := ready_graph(s, &a)
			if !ready {
				if driven {
					d.ticked = d.samples
				}
				continue
			}
			out: anim_graph.Tick_Output
			if a.playing && !(driven && d.hold) {
				anim_graph.advance(&r.graph, &a.instance, ctx.dt * max(a.speed, 0), &out)
			}
			a.state, a.time = a.instance.state, current_time(&a.instance)
			translation, yaw := out.translation, out.yaw
			if driven {
				translation, yaw = driven_root_motion(s, r, d, translation, yaw)
			}
			if motions != nil {
				m := &motions[i]
				m.translation, m.yaw = translation, yaw
				m.frame_translation += rotate_y(translation, m.frame_yaw)
				m.frame_yaw += yaw
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
				log.warnf(
					"anim: an entity's graph raised %d events past MAX_TICK_EVENTS in a tick",
					out.dropped,
				)
			}
		}
	}
}

// driven_root_motion is a tick's root motion while a driver holds an Animator: the graph's, by what the driven weights
// leave of it, and each reported sample's move since the last tick, by its weight. A sample whose clip changed, or
// whose time did not move forward, moves nothing. It keeps the samples for the next tick.
@(private)
driven_root_motion :: proc(
	s: ^State,
	r: ^Resolved,
	d: ^Driven,
	translation: [3]f32,
	yaw: f32,
) -> (
	[3]f32,
	f32,
) {
	weights, total := driven_weights(d.samples)
	t, y := translation * (1 - total), yaw * (1 - total)
	for sample, i in d.samples {
		before := d.ticked[i]
		if weights[i] <= 0 ||
		   sample.root_motion != .Reported ||
		   sample.clip != before.clip ||
		   sample.time <= before.time {
			continue
		}
		c := find_driven_clip(s, sample.clip) or_continue
		if !fits_skin(
			c.blob,
			r.graph.clips[0].blob.skin,
			len(format.skin_joints(r.skin_data, r.skin)),
		) {
			continue
		}
		duration := c.blob.duration
		delta, turn := anim_graph.clip_root_motion(
			&r.graph,
			c,
			clamp(before.time, 0, duration),
			clamp(sample.time, 0, duration),
		)
		t += delta * weights[i]
		y += turn * weights[i]
	}
	d.ticked = d.samples
	return t, y
}

// driven_weights is each driven sample's weight, from 0 to 1, scaled so that they add up to 1 at most, and their sum.
@(private)
driven_weights :: proc(
	samples: [MAX_DRIVEN]Driven_Sample,
) -> (
	weights: [MAX_DRIVEN]f32,
	total: f32,
) {
	for sample, i in samples {
		weights[i] = clamp(sample.weight, 0, 1) if sample.clip != {} else 0
		total += weights[i]
	}
	if total > 1 {
		for &w in weights {
			w /= total
		}
		total = 1
	}
	return
}

@(private)
find_driven_clip :: proc(s: ^State, guid: format.Guid) -> (anim_graph.Clip, bool) {
	for c in s.driven_clips {
		if c.guid == guid {
			return c.clip, true
		}
	}
	return {}, false
}

// fits_skin reports whether a clip is of a skin, with the skin's joints.
@(private)
fits_skin :: proc(clip: ^format.Animation_Blob, skin: format.Guid, joint_count: int) -> bool {
	return clip != nil && clip.skin == skin && int(clip.joint_count) == joint_count
}

// begin_drive starts a driver's hold on an Animator, whose driven samples it then writes with drive, and gives its
// token. With hold, the graph's time stops while it is driven. A driver that held the Animator before loses it: its
// token goes stale, and its drive calls return false (see docs/animation/design.md#driving-an-animator).
begin_drive :: proc(
	s: ^State,
	w: ^ecs.World,
	e: ecs.Entity,
	hold := false,
) -> (
	token: Drive_Token,
	ok: bool,
) {
	a := ecs.get(w, e, Animator)
	if a == nil {
		return
	}
	s.next_drive += 1
	if s.next_drive == 0 {
		s.next_drive = 1
	}
	a.driven = Driven {
		generation = s.next_drive,
		hold       = hold,
	}
	return {e, s.next_drive}, true
}

// drive sets the driven samples of the Animator that a token holds, up to MAX_DRIVEN; the rest weigh nothing. The next
// presented frame poses them, in every mode, and the next tick reports their root motion. It returns false, and
// writes nothing, for a stale token, whose driver has lost the Animator.
drive :: proc(w: ^ecs.World, token: Drive_Token, samples: []Driven_Sample) -> bool {
	d := driven_of(w, token) or_return
	d.samples = {}
	copy(d.samples[:], samples)
	return true
}

// end_drive ends a driver's hold, and the graph's pose shows again. Through a stale token, it does nothing.
end_drive :: proc(w: ^ecs.World, token: Drive_Token) {
	if _, ok := driven_of(w, token); ok {
		ecs.get(w, token.entity, Animator).driven = nil
	}
}

// is_driving reports whether a token still holds its Animator.
is_driving :: proc(w: ^ecs.World, token: Drive_Token) -> bool {
	_, ok := driven_of(w, token)
	return ok
}

// clip_length is a loaded clip's duration in seconds, and false when the clip is not loaded. It loads nothing.
clip_length :: proc(s: ^State, clip: format.Guid) -> (seconds: f32, ok: bool) {
	_, blob := loaded_clip(s, clip) or_return
	return blob.duration, true
}

// Clip_Motion is a clip and the root joint of an entity's graph, which clip_motion measures the clip's root motion by.
Clip_Motion :: struct {
	graph: anim_graph.Graph,
	clip:  anim_graph.Clip,
}

// clip_motion_of is what a driver measures a clip's root motion on an entity with (see
// docs/animation/design.md#driving-an-animator). False when the entity has no Animator, its graph is not ready or has
// no root joint, or the clip is not loaded or is of another skin. In a frame it takes the graph from prepare's table.
// Outside one, it loads the graph into allocator, as present does.
clip_motion_of :: proc(
	s: ^State,
	w: ^ecs.World,
	entity: ecs.Entity,
	clip: format.Guid,
	allocator: mem.Allocator,
) -> (
	motion: Clip_Motion,
	ok: bool,
) {
	a := ecs.get(w, entity, Animator)
	if a == nil {
		return
	}
	r: Resolved
	if ready, in_frame := ready_graph(s, a); in_frame {
		r = ready^
	} else {
		r = load_graph(s, a, allocator)
		if !r.ready {
			return
		}
	}
	if r.graph.root < 0 {
		return
	}
	data, blob := loaded_clip(s, clip) or_return
	if !fits_skin(blob, r.graph.clips[0].blob.skin, len(format.skin_joints(r.skin_data, r.skin))) {
		return
	}
	return {r.graph, {data, blob}}, true
}

// clip_motion is the root joint's move from one time of a clip to a later one, in seconds held to the clip's length:
// along x and z, in the model's space turned to the root's heading at the first time, and its turn about y in radians.
clip_motion :: proc(m: ^Clip_Motion, from, to: f32) -> (delta: [3]f32, turn: f32) {
	d := m.clip.blob.duration
	return anim_graph.clip_root_motion(&m.graph, m.clip, clamp(from, 0, d), clamp(to, 0, d))
}

// clip_markers is the markers that an entity's graph puts on a clip, in the order of their times: those of the first of
// the graph's clips that plays it. They are empty outside a frame, when the entity's graph is not ready, and when the
// graph does not play the clip.
clip_markers :: proc(
	s: ^State,
	w: ^ecs.World,
	entity: ecs.Entity,
	clip: format.Guid,
) -> []format.Animation_Graph_Marker {
	a := ecs.get(w, entity, Animator)
	if a == nil {
		return nil
	}
	r, ready := ready_graph(s, a)
	if !ready || r.graph.blob == nil {
		return nil
	}
	g := &r.graph
	for c in format.animation_graph_clips(g.data, g.blob) {
		if c.clip == clip {
			return format.animation_graph_markers(g.data, g.blob)[c.first_marker:][:c.marker_count]
		}
	}
	return nil
}

// MAX_RAISED is the most markers that drivers can raise before a flush. Frames without a tick, such as those of a
// cutscene on the real clock while the game is paused, raise markers that wait for the next tick.
MAX_RAISED :: 256

// raise_marker raises a marker of clip_markers for an entity, as its graph raises one in a tick, from its current
// state. It makes the event at once, from the graph of this frame, and the next tick's flush puts it before the graph's
// own events, in the order of the calls, so it reaches the entity's behaviours as on_animation_event. A driver raises
// the markers that its clips pass, since driven clips raise none of their own. False outside a frame, when the
// entity's graph is not ready, and past MAX_RAISED markers waiting for a flush.
raise_marker :: proc(
	s: ^State,
	w: ^ecs.World,
	entity: ecs.Entity,
	marker: format.Animation_Graph_Marker,
) -> bool {
	a := ecs.get(w, entity, Animator)
	if a == nil {
		return false
	}
	r, ready := ready_graph(s, a)
	if !ready || r.graph.blob == nil {
		return false
	}
	if len(s.raised) >= MAX_RAISED {
		log.warnf("anim: drivers raised more than %d markers before a tick", MAX_RAISED)
		return false
	}
	if s.raised == nil {
		s.raised = make([dynamic]Event, w.platform.heap_allocator)
	}
	fired := Job_Event {
		entity,
		a.slot,
		{kind = .Marker, state = a.instance.state, event = marker.event},
	}
	append(&s.raised, make_event(s, r, fired))
	return true
}

// loaded_clip is a clip's blob, if the clip is loaded. It adds no user.
@(private)
loaded_clip :: proc(
	s: ^State,
	guid: format.Guid,
) -> (
	data: []byte,
	blob: ^format.Animation_Blob,
	ok: bool,
) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.find(s.assets, guid) or_return
	data = asset.data(s.assets, h) or_return
	blob = format.animation_view(data) or_return
	return data, blob, true
}

// driven_of is the driven state that a token holds, if the token is not stale.
@(private)
driven_of :: proc(w: ^ecs.World, token: Drive_Token) -> (^Driven, bool) {
	a := ecs.get(w, token.entity, Animator)
	if a == nil || token.generation == 0 {
		return nil, false
	}
	d, driven := &a.driven.?
	if !driven || d.generation != token.generation {
		return nil, false
	}
	return d, true
}

// ready_graph is an Animator's graph in the frame's table, if prepare made it ready and started the Animator's
// instance for it. An Animator that the ticks spawned waits for the next frame.
@(private)
ready_graph :: proc(s: ^State, a: ^Animator) -> (^Resolved, bool) {
	if int(a.slot) >= len(s.graphs) {
		return nil, false
	}
	r := &s.graphs[a.slot]
	if !r.ready ||
	   a.instance.key != r.key ||
	   r.graph_guid != a.graph ||
	   (a.graph == {} && (r.clip_guid != a.clip || r.loop != a.loop)) {
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
	// The raised events move to the tick's list, which owns their strings from now on.
	for e in s.raised {
		append(&s.tick_events, e)
		append(&s.frame_events, copy_event(s, e))
	}
	clear(&s.raised)
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
			ready := r.ready && a.instance.key == r.key
			d, driven := a.driven.?
			// The skin that the pose is of: the graph's, or without a ready graph, the first driven clip's that loads.
			skin_guid: format.Guid
			skin_bytes: []byte
			skin: ^format.Skin_Blob
			if ready {
				skin_guid, skin_bytes, skin = r.graph.clips[0].blob.skin, r.skin_data, r.skin
			} else if driven {
				skin_guid, skin_bytes, skin = driven_skin(s, d)
			}
			if skin == nil {
				continue
			}
			joints := format.skin_joints(skin_bytes, skin)
			rest := make([]anim_graph.Joint_Pose, len(joints), allocator)
			scratch := make([]anim_graph.Joint_Pose, len(joints), allocator)
			locals := make([]anim_graph.Joint_Pose, len(joints), allocator)
			models := make([]matrix[4, 4]f32, len(joints), allocator)
			palette := make([][3][4]f32, len(joints), allocator)
			anim_graph.rest_pose(joints, rest)
			if ready {
				anim_graph.present(&r.graph, &a.instance, w.clock.alpha, rest, scratch, locals)
				if motions != nil {
					anim_graph.remove_root_motion(&r.graph, locals)
				}
			} else {
				copy(locals, rest)
			}
			if driven {
				blend_driven(
					s,
					&r.graph,
					d,
					skin_guid,
					motions != nil,
					rest,
					scratch,
					locals,
					allocator,
				)
			}
			sphere := anim_graph.compose(joints, locals, models, palette)
			append(
				&poses,
				render.Skin_Pose{entity = entities[i], palette = palette, sphere = sphere},
			)
		}
	}
	return poses[:]
}

// driven_skin is the skin of the first driven clip that weighs anything and loads, which an Animator without a ready
// graph is posed in.
@(private)
driven_skin :: proc(
	s: ^State,
	d: Driven,
) -> (
	guid: format.Guid,
	data: []byte,
	blob: ^format.Skin_Blob,
) {
	weights, _ := driven_weights(d.samples)
	for sample, i in d.samples {
		if weights[i] <= 0 {
			continue
		}
		_, clip := clip_data(s, sample.clip) or_continue
		bytes, skin := skin_data(s, clip.skin) or_continue
		return clip.skin, bytes, skin
	}
	return
}

// blend_driven blends an Animator's driven clips over its pose, each at its own time, which is given rather than
// stepped, so it takes no alpha. The pose keeps what the weights leave of it. A clip's root motion stays in the pose,
// or leaves it, as its Driven_Root_Motion says. A clip that has not loaded, or is of another skin, is left out.
@(private)
blend_driven :: proc(
	s: ^State,
	g: ^anim_graph.Graph,
	d: Driven,
	skin: format.Guid,
	has_root_motion: bool,
	rest, scratch, locals: []anim_graph.Joint_Pose,
	allocator: mem.Allocator,
) {
	weights, total := driven_weights(d.samples)
	if total <= 0 {
		return
	}
	sum := make([]anim_graph.Joint_Pose, len(locals), allocator)
	anim_graph.accumulate(sum, locals, 1 - total)
	used := 1 - total
	blended := false
	for sample, i in d.samples {
		if weights[i] <= 0 {
			continue
		}
		data, clip := clip_data(s, sample.clip) or_continue
		if !fits_skin(clip, skin, len(locals)) {
			continue
		}
		copy(scratch, rest)
		anim_graph.sample(data, clip, clamp(sample.time, 0, clip.duration), scratch)
		switch sample.root_motion {
		case .In_Place:
			anim_graph.remove_root_motion(g, scratch)
		case .Reported:
			if has_root_motion {
				anim_graph.remove_root_motion(g, scratch)
			}
		case .In_Pose:
		}
		anim_graph.accumulate(sum, scratch, weights[i])
		used += weights[i]
		blended = true
	}
	if !blended {
		return
	}
	anim_graph.resolve(sum, used, rest)
	copy(locals, sum)
}

// preview_pose moves a graph that plays apart from any entity, as the editor's preview plays one, by dt seconds, and
// gives its pose. The instance is the caller's; it starts again with a new blob, keeping the parameters that the graph
// still has. data is the graph's blob, which may be one that the editor has not saved, and the clips and the skin load by
// their GUIDs. The pose leaves out root motion, so the mesh stays in view. It is not ready until they have all loaded.
preview_pose :: proc(
	assets: ^asset.Assets,
	data: []byte,
	inst: ^anim_graph.Instance,
	dt: f32,
	allocator: mem.Allocator,
) -> (
	palette: [][3][4]f32,
	sphere: [4]f32,
	ok: bool,
) {
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
resolve :: proc(
	s: ^State,
	table: ^[dynamic]Resolved,
	a: ^Animator,
	allocator: mem.Allocator,
) -> int {
	for &r, i in table {
		if r.graph_guid == a.graph &&
		   (a.graph != {} || (r.clip_guid == a.clip && r.loop == a.loop)) {
			return i
		}
	}
	append(table, load_graph(s, a, allocator))
	return len(table) - 1
}

// load_graph loads an Animator's graph and its clips, or its clip without a graph, and their skin, and finds the
// root motion joint by its name. With graph_bytes, those are the graph's blob, and the Animator names none.
@(private)
load_graph :: proc(
	s: ^State,
	a: ^Animator,
	allocator: mem.Allocator,
	graph_bytes: []byte = nil,
) -> (
	r: Resolved,
) {
	r = {
		graph_guid = a.graph,
		clip_guid  = a.clip,
		loop       = a.loop,
	}
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
			parent =
				parent * linalg.matrix4_from_trs_f32(pose.translation, pose.rotation, pose.scale)
			rotation = rotation * pose.rotation
		}
		r.graph.root, r.graph.root_parent, r.graph.root_parent_rotation, r.graph.root_rest =
			i, parent, rotation, joint_rest(j)
		return
	}
}

@(private)
joint_rest :: proc(j: format.Skin_Joint) -> anim_graph.Joint_Pose {
	return {
		j.translation,
		quaternion(
			real = j.rotation.w,
			imag = j.rotation.x,
			jmag = j.rotation.y,
			kmag = j.rotation.z,
		),
		j.scale,
	}
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
				log.warnf(
					"anim: %s: clip %s has an event at %.3f s, past its end at %.3f s",
					path,
					format.blob_string(g.data, c.name),
					m.time,
					g.clips[i].blob.duration,
				)
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
parameter :: proc(
	s: ^State,
	a: ^Animator,
	name: string,
) -> (
	index: int,
	kind: format.Animation_Graph_Parameter_Kind,
	ok: bool,
) {
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
	return format.blob_string(
		r.graph.data,
		format.animation_graph_states(r.graph.data, r.graph.blob)[a.instance.state].name,
	)
}

// root_motion_world is an entity's last tick of root motion in the world: its move, turned and scaled by the entity's
// Transform, and its turn about the world's y. It reads only the entity's own components; what to do with them is the
// caller's.
root_motion_world :: proc(
	w: ^ecs.World,
	e: ecs.Entity,
) -> (
	delta: [3]f32,
	turn: quaternion128,
	ok: bool,
) {
	m := ecs.get(w, e, Root_Motion)
	t := ecs.get(w, e, ecs.Transform)
	if m == nil || t == nil {
		return {}, 1, false
	}
	return linalg.quaternion_mul_vector3(t.rotation, m.translation * t.scale),
		linalg.quaternion_angle_axis_f32(m.yaw, {0, 1, 0}),
		true
}

// graph_data is an animation graph's blob, which it loads if it is not loaded.
graph_data :: proc(
	s: ^State,
	guid: format.Guid,
) -> (
	data: []byte,
	blob: ^format.Animation_Graph_Blob,
	ok: bool,
) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.load(s.assets, guid) or_return
	data = asset.data(s.assets, h) or_return
	blob = format.animation_graph_view(data) or_return
	return data, blob, true
}

// clip_data is an animation clip's blob, which it loads if it is not loaded.
clip_data :: proc(
	s: ^State,
	guid: format.Guid,
) -> (
	data: []byte,
	blob: ^format.Animation_Blob,
	ok: bool,
) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.load(s.assets, guid) or_return
	data = asset.data(s.assets, h) or_return
	blob = format.animation_view(data) or_return
	return data, blob, true
}

// skin_data is a skin's blob, which it loads if it is not loaded.
skin_data :: proc(
	s: ^State,
	guid: format.Guid,
) -> (
	data: []byte,
	blob: ^format.Skin_Blob,
	ok: bool,
) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.load(s.assets, guid) or_return
	data = asset.data(s.assets, h) or_return
	blob = format.skin_view(data) or_return
	return data, blob, true
}
