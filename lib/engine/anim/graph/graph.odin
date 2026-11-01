package anim_graph

import "core:math"

import format "cinnabar:engine/asset/format"

// An instance keeps at most this many weighted samples of clips: the current state's, a state that it fades from,
// and those that an interrupted fade froze. Past it, the lightest are dropped.
MAX_SAMPLES :: 8
// A tick raises at most this many events; past it, Tick_Output counts the rest as dropped.
MAX_TICK_EVENTS :: 16
// A state or a clip that is not there.
NONE :: max(u16)

Sample_Flag :: enum u8 {
	// The clip wraps at its end, rather than holding there.
	Loop,
	// An interrupted fade stopped the clip, which fades out where it stopped.
	Frozen,
}

Sample_Flags :: bit_set[Sample_Flag;u8]

// Sample is one clip that an instance plays, with its weight after the last tick and the one before, which
// presentation interpolates between (see docs/animation/design.md#ticks-and-presentation).
Sample :: struct {
	clip:            u16,
	// The state that plays it, and its point in the state's motion, which together name the sample from tick to tick.
	state:           u16,
	point:           u8,
	flags:           Sample_Flags,
	// Seconds into the clip after the last tick, and how far the last tick moved it, before any wrap.
	time:            f32,
	step:            f32,
	weight:          f32,
	previous_weight: f32,
	// A frozen sample's weight when it froze, which fades to 0 over the fade.
	base:            f32,
}

// Instance is what one entity's graph keeps from tick to tick: its parameters, its state, the fade between states,
// and its samples. It is plain data, so it lives in a component.
Instance :: struct {
	// The graph blob's key that the instance was made for, so a new blob makes it again.
	key:             u64,
	parameters:      [format.MAX_ANIMATION_GRAPH_PARAMETERS]f32,
	// Each parameter's name's hash, so a new graph finds the values of the ones that it still has.
	hashes:          [format.MAX_ANIMATION_GRAPH_PARAMETERS]u32,
	// A bit for each trigger parameter that is set, which the next tick sees and then clears.
	triggers:        u32,
	state:           u16,
	// The state that the current one fades from, or NONE.
	source:          u16,
	// Whether the graph has ticked since it started in its entry state, whose entry the first tick raises.
	started:         bool,
	sample_count:    u8,
	// Plays of the current state's motion, and of the source's, from their entry: the integer part counts loops.
	progress:        f32,
	source_progress: f32,
	// Seconds into the fade to the current state, and its length; the fade is over at its length.
	fade:            f32,
	fade_duration:   f32,
	samples:         [MAX_SAMPLES]Sample,
}
#assert(size_of(Instance) <= 512)

// Fired_Kind is why the graph raised an event: it left a state, entered one, or passed a clip's marker.
Fired_Kind :: enum u8 {
	Exit,
	Enter,
	Marker,
}

// Fired is an event that a tick raised: an index into the graph blob's events, and the state that raised it.
Fired :: struct {
	kind:  Fired_Kind,
	state: u16,
	event: u32,
}

// Tick_Output is what a tick gives back besides the instance: its events in the order that they happened, and the
// root motion that it moved (see docs/animation/design.md#root-motion).
Tick_Output :: struct {
	events:      [MAX_TICK_EVENTS]Fired,
	event_count: int,
	dropped:     int,
	// The root joint's move over the tick, in the model's space turned to its heading at the tick's start, along x
	// and z, and its turn about y, in radians.
	translation: [3]f32,
	yaw:         f32,
}

// Clip is a clip's blob, which the caller loaded.
Clip :: struct {
	data: []byte,
	blob: ^format.Animation_Blob,
}

// Graph is what a tick reads: the graph blob and its clips' blobs, in the blob's order. Without a blob, the graph
// plays its one clip, looping or held: an Animator's clip without a graph.
Graph :: struct {
	data:                 []byte,
	blob:                 ^format.Animation_Graph_Blob,
	clips:                []Clip,
	// Without a blob: whether the clip loops.
	loop:                 bool,
	// The root motion joint, or -1; its parent's rest matrix in the model's space, and the matrix's rotation; and
	// its own rest pose.
	root:                 int,
	root_parent:          matrix[4, 4]f32,
	root_parent_rotation: quaternion128,
	root_rest:            Joint_Pose,
}

// Motion is a state's motion, copied out of the blob, or a graph without a blob's one clip.
@(private)
Motion :: struct {
	points:      [format.MAX_ANIMATION_GRAPH_POINTS]format.Animation_Graph_Point,
	count:       int,
	kind:        format.Animation_Graph_Motion,
	parameter:   u32,
	speed:       f32,
	loop:        bool,
	enter_event: u32,
	exit_event:  u32,
}

@(private)
motion_of :: proc(g: ^Graph, state: u16) -> (m: Motion) {
	if g.blob == nil {
		m.count, m.speed, m.loop = 1, 1, g.loop
		m.parameter, m.enter_event, m.exit_event = format.ANIMATION_GRAPH_NONE, format.ANIMATION_GRAPH_NONE, format.ANIMATION_GRAPH_NONE
		return
	}
	s := format.animation_graph_states(g.data, g.blob)[state]
	points := format.animation_graph_points(g.data, g.blob)[s.first_point:][:s.point_count]
	copy(m.points[:], points)
	m.count = len(points)
	m.kind, m.parameter, m.speed, m.loop = s.motion, s.parameter, s.speed, bool(s.loop)
	m.enter_event, m.exit_event = s.enter_event, s.exit_event
	return
}

@(private)
clip_duration :: proc(g: ^Graph, clip: u32) -> f32 {
	if int(clip) >= len(g.clips) || g.clips[clip].blob == nil {
		return 0
	}
	return g.clips[clip].blob.duration
}

// blend_weights is each of a motion's clips' weight: a clip alone, or for a blend, the two clips whose thresholds the
// parameter is between, by how near it is to each, and the first or the last alone beyond them.
@(private)
blend_weights :: proc(m: ^Motion, inst: ^Instance) -> (weights: [format.MAX_ANIMATION_GRAPH_POINTS]f32) {
	if m.kind != .Blend_1D || m.count < 2 {
		weights[0] = 1
		return
	}
	value := inst.parameters[m.parameter]
	points := m.points[:m.count]
	if value <= points[0].threshold {
		weights[0] = 1
		return
	}
	for i in 1 ..< len(points) {
		if value < points[i].threshold {
			u := (value - points[i - 1].threshold) / (points[i].threshold - points[i - 1].threshold)
			weights[i - 1], weights[i] = 1 - u, u
			return
		}
	}
	weights[len(points) - 1] = 1
	return
}

// motion_duration is how long one play of a motion lasts: its clips' durations, by their weights, so a blend's clips
// stay in step, each at the same share of its own length. A motion without a length counts plays by seconds.
@(private)
motion_duration :: proc(g: ^Graph, m: ^Motion, weights: [format.MAX_ANIMATION_GRAPH_POINTS]f32) -> f32 {
	d: f32
	for i in 0 ..< m.count {
		d += weights[i] * clip_duration(g, m.points[i].clip)
	}
	return d if d > 0 else 1
}

// phase is how far into one play a motion is, from its progress: the fraction when it loops, and up to 1 when it holds.
@(private)
phase :: proc "contextless" (progress: f32, loop: bool) -> f32 {
	return progress - math.floor(progress) if loop else min(progress, 1)
}

// wrap_time keeps a clip's time inside it: wrapped when it loops, and held at either end when it does not.
wrap_time :: proc "contextless" (t, duration: f32, loop: bool) -> f32 {
	if duration <= 0 {
		return 0
	}
	if !loop {
		return clamp(t, 0, duration)
	}
	wrapped := math.mod(t, duration)
	return wrapped + duration if wrapped < 0 else wrapped
}

// init starts an instance in the graph's entry state, with the parameters at their defaults and no trigger set, and
// its samples posed there, so it presents before its first tick.
init :: proc(g: ^Graph, inst: ^Instance, key: u64) {
	inst^ = {
		key    = key,
		source = NONE,
	}
	if g.blob != nil {
		inst.state = u16(g.blob.entry)
		for p, i in format.animation_graph_parameters(g.data, g.blob) {
			inst.parameters[i] = p.default if p.kind != .Trigger else 0
			inst.hashes[i] = p.hash
		}
	}
	build_samples(g, inst, 0, 0)
	for &s in inst.samples[:inst.sample_count] {
		s.previous_weight = s.weight
	}
}

// keep_parameters gives a new instance the values of an old one's parameters whose names its graph still has, and
// their triggers, so a graph that changes while the game runs keeps what gameplay set.
keep_parameters :: proc(g: ^Graph, inst: ^Instance, old: ^Instance) {
	if g.blob == nil {
		return
	}
	for p, i in format.animation_graph_parameters(g.data, g.blob) {
		for h, j in old.hashes {
			if h == p.hash && h != 0 {
				inst.parameters[i] = old.parameters[j]
				if p.kind == .Trigger && old.triggers & (1 << u32(j)) != 0 {
					inst.triggers |= 1 << u32(i)
				}
				break
			}
		}
	}
}

// advance moves an instance by a tick of dt seconds, already scaled by the Animator's speed. It takes at most one
// transition, from the parameters and triggers that gameplay set and the progress after the last tick, and clears the
// triggers. It then moves the states and the fade, makes the samples, and gives the tick's events and root motion.
advance :: proc(g: ^Graph, inst: ^Instance, dt: f32, out: ^Tick_Output) {
	out^ = {}
	entered := !inst.started
	if entered {
		inst.started = true
		m := motion_of(g, inst.state)
		raise(out, .Enter, inst.state, m.enter_event)
	}
	if g.blob != nil {
		if t, ok := pick_transition(g, inst); ok {
			take_transition(g, inst, t, out)
			entered = true
		}
	}
	inst.triggers = 0

	current := motion_of(g, inst.state)
	weights := blend_weights(&current, inst)
	previous_progress, source_previous := inst.progress, inst.source_progress
	inst.progress += dt * current.speed / motion_duration(g, &current, weights)
	if inst.source != NONE {
		source := motion_of(g, inst.source)
		inst.source_progress += dt * source.speed / motion_duration(g, &source, blend_weights(&source, inst))
	}
	inst.fade += dt
	if inst.fade >= inst.fade_duration {
		inst.source = NONE
	}
	build_samples(g, inst, previous_progress, source_previous)
	markers(g, inst, &current, weights, previous_progress, entered, out)
	root_motion(g, inst, out)
}

@(private)
raise :: proc(out: ^Tick_Output, kind: Fired_Kind, state: u16, event: u32) {
	if event == format.ANIMATION_GRAPH_NONE {
		return
	}
	if out.event_count == MAX_TICK_EVENTS {
		out.dropped += 1
		return
	}
	out.events[out.event_count] = {kind, state, event}
	out.event_count += 1
}

// pick_transition is the first transition whose conditions hold: the current state's own, in their order, then those
// from any state that go elsewhere.
@(private)
pick_transition :: proc(g: ^Graph, inst: ^Instance) -> (format.Animation_Graph_Transition, bool) {
	states := format.animation_graph_states(g.data, g.blob)
	transitions := format.animation_graph_transitions(g.data, g.blob)
	conditions := format.animation_graph_conditions(g.data, g.blob)
	s := states[inst.state]
	own := transitions[s.first_transition:][:s.transition_count]
	from_any := transitions[g.blob.first_any:]
	for group in ([2][]format.Animation_Graph_Transition{own, from_any}) {
		for t in group {
			if t.to == u32(inst.state) {
				continue
			}
			if t.exit_time >= 0 && inst.progress < t.exit_time {
				continue
			}
			holds := true
			for c in conditions[t.first_condition:][:t.condition_count] {
				if !condition_holds(c, inst) {
					holds = false
					break
				}
			}
			if holds {
				return t, true
			}
		}
	}
	return {}, false
}

@(private)
condition_holds :: proc(c: format.Animation_Graph_Condition, inst: ^Instance) -> bool {
	v := inst.parameters[c.parameter]
	switch c.op {
	case .Greater:
		return v > c.value
	case .Less:
		return v < c.value
	case .Equal:
		return v == c.value
	case .Not_Equal:
		return v != c.value
	case .True:
		return v != 0
	case .False:
		return v == 0
	case .Trigger:
		return inst.triggers & (1 << c.parameter) != 0
	}
	return false
}

// take_transition leaves the current state for the transition's. Without a fade, the old state stops. Otherwise, it
// fades out as the new one fades in; and if a fade was already under way, everything that played freezes where it is
// and fades out instead.
@(private)
take_transition :: proc(g: ^Graph, inst: ^Instance, t: format.Animation_Graph_Transition, out: ^Tick_Output) {
	old := motion_of(g, inst.state)
	raise(out, .Exit, inst.state, old.exit_event)
	fading := inst.fade < inst.fade_duration
	switch {
	case t.duration <= 0:
		inst.source = NONE
	case fading:
		for &s in inst.samples[:inst.sample_count] {
			if s.weight > 0 {
				s.flags += {.Frozen}
				s.base, s.step = s.weight, 0
			}
		}
		inst.source = NONE
	case:
		inst.source, inst.source_progress = inst.state, inst.progress
	}
	inst.state = u16(t.to)
	inst.progress = 0
	inst.fade, inst.fade_duration = 0, t.duration
	m := motion_of(g, inst.state)
	raise(out, .Enter, inst.state, m.enter_event)
}

// build_samples makes the instance's samples for its progress: the current state's clips, by the fade; the source's,
// or the frozen samples, by what is left of it; and, for one more tick at weight 0, the samples that are gone, so
// presentation fades them out rather than cutting.
@(private)
build_samples :: proc(g: ^Graph, inst: ^Instance, previous_progress, source_previous: f32) {
	f: f32 = 1
	if inst.fade < inst.fade_duration {
		f = inst.fade / inst.fade_duration
	}
	next: [3 * MAX_SAMPLES]Sample
	count := 0
	if f < 1 {
		for s in inst.samples[:inst.sample_count] {
			if .Frozen in s.flags {
				frozen := s
				frozen.weight = s.base * (1 - f)
				frozen.step = 0
				next[count] = frozen
				count += 1
			}
		}
		if inst.source != NONE {
			source := motion_of(g, inst.source)
			add_state(g, &source, inst.source, inst.source_progress, source_previous, blend_weights(&source, inst), 1 - f, next[:], &count)
		}
	}
	current := motion_of(g, inst.state)
	add_state(g, &current, inst.state, inst.progress, previous_progress, blend_weights(&current, inst), f, next[:], &count)

	// Each sample's weight before the tick is its old one; a sample that is new starts from 0.
	for &n in next[:count] {
		n.previous_weight = 0
		for old in inst.samples[:inst.sample_count] {
			if same_sample(n, old) {
				n.previous_weight = old.weight
				break
			}
		}
	}
	for old in inst.samples[:inst.sample_count] {
		if old.weight <= 0 || count == len(next) {
			continue
		}
		kept := false
		for n in next[:count] {
			if same_sample(n, old) {
				kept = true
				break
			}
		}
		if !kept {
			gone := old
			gone.previous_weight, gone.weight, gone.step = old.weight, 0, 0
			next[count] = gone
			count += 1
		}
	}
	// Past MAX_SAMPLES, the samples that weigh least, before and after the tick, go; a later one before an earlier.
	for count > MAX_SAMPLES {
		lightest := 0
		for i in 1 ..< count {
			if max(next[i].weight, next[i].previous_weight) <= max(next[lightest].weight, next[lightest].previous_weight) {
				lightest = i
			}
		}
		copy(next[lightest:count - 1], next[lightest + 1:count])
		count -= 1
	}
	copy(inst.samples[:], next[:count])
	inst.sample_count = u8(count)
}

@(private)
same_sample :: proc "contextless" (a, b: Sample) -> bool {
	return a.state == b.state && a.point == b.point && (.Frozen in a.flags) == (.Frozen in b.flags)
}

// add_state adds a state's clips that weigh anything, each at the state's phase of its own duration, with the step
// from its progress before the tick.
@(private)
add_state :: proc(g: ^Graph, m: ^Motion, state: u16, progress, previous: f32, weights: [format.MAX_ANIMATION_GRAPH_POINTS]f32, scale: f32, next: []Sample, count: ^int) {
	advanced := phase_step(progress, previous, m.loop)
	for i in 0 ..< m.count {
		w := weights[i] * scale
		if w <= 0 || count^ == len(next) {
			continue
		}
		d := clip_duration(g, m.points[i].clip)
		flags: Sample_Flags
		if m.loop {
			flags += {.Loop}
		}
		next[count^] = {
			clip   = u16(m.points[i].clip),
			state  = state,
			point  = u8(i),
			flags  = flags,
			time   = phase(progress, m.loop) * d,
			step   = advanced * d,
			weight = w,
		}
		count^ += 1
	}
}

// phase_step is how far a motion's phase moved from one progress to another: the whole distance when it loops, so
// presentation moves forward across a wrap, and up to its end when it holds.
@(private)
phase_step :: proc "contextless" (progress, previous: f32, loop: bool) -> f32 {
	return progress - previous if loop else min(progress, 1) - min(previous, 1)
}

// present writes the instance's pose between its last two ticks, by alpha from 0 to 1, into locals: each sample at
// its time less its step times 1 - alpha, and its weight between the two, blended over rest. scratch is a pose of
// the same length that it samples each clip into.
present :: proc(g: ^Graph, inst: ^Instance, alpha: f32, rest: []Joint_Pose, scratch: []Joint_Pose, locals: []Joint_Pose) {
	for &l in locals {
		l = {}
	}
	total: f32
	for s in inst.samples[:inst.sample_count] {
		w := s.previous_weight + (s.weight - s.previous_weight) * alpha
		if w <= 0 || int(s.clip) >= len(g.clips) || g.clips[s.clip].blob == nil {
			continue
		}
		c := g.clips[s.clip]
		t := wrap_time(s.time - s.step * (1 - alpha), c.blob.duration, .Loop in s.flags)
		copy(scratch, rest)
		sample(c.data, c.blob, t, scratch)
		accumulate(locals, scratch, w)
		total += w
	}
	resolve(locals, total, rest)
}
