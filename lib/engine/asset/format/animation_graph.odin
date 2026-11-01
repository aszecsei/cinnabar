package asset_format

import "core:hash"
import "core:mem"

import "cinnabar:core/layout"

// An animation graph is an .animation_graph text file: parameters that gameplay sets, the clips that the graph plays,
// with the events at their times, and a state machine whose states each play a clip or a blend of clips by a
// parameter, and whose transitions cross-fade between them (see docs/content/kinds/animation-graphs.md).
ANIMATION_GRAPH_EXTENSION :: ".animation_graph"

// A graph has at most this many parameters, so that its triggers fit in a u32.
MAX_ANIMATION_GRAPH_PARAMETERS :: 16
// A blend has at most this many clips.
MAX_ANIMATION_GRAPH_POINTS :: 8
// An event has at most this many arguments.
MAX_ANIMATION_GRAPH_ARGS :: 2
// An index into a graph's records that is not there: a state's missing event, or a transition from any state.
ANIMATION_GRAPH_NONE :: max(u32)

// Animation_Graph_Parameter_Kind is what a parameter holds: a number, true or false (1 or 0), or a trigger, which is
// set for the graph's next tick only.
Animation_Graph_Parameter_Kind :: enum u32 {
	Float,
	Bool,
	Trigger,
}

Animation_Graph_Parameter :: struct {
	name:    Slice,
	// animation_graph_hash of the name, which gameplay finds the parameter by.
	hash:    u32,
	kind:    Animation_Graph_Parameter_Kind,
	// The value that the graph starts with: a Float's number, or a Bool's 1 or 0.
	default: f32,
	padding: u32,
}
#assert(size_of(Animation_Graph_Parameter) == 24)

// Animation_Graph_Clip is a clip that the graph plays, by the name that its states and blends give it.
Animation_Graph_Clip :: struct {
	clip:         Guid,
	name:         Slice,
	// The clip's Animation_Graph_Marker records, in the order of their times.
	first_marker: u32,
	marker_count: u32,
}
#assert(size_of(Animation_Graph_Clip) == 32)

// Animation_Graph_Marker is an event at a time of a clip, in seconds from its start.
Animation_Graph_Marker :: struct {
	time:  f32,
	event: u32,
}
#assert(size_of(Animation_Graph_Marker) == 8)

Animation_Graph_Value_Kind :: enum u32 {
	None,
	Number,
	Text,
}

// Animation_Graph_Value is an argument of an event: a number or a string.
Animation_Graph_Value :: struct {
	kind:   Animation_Graph_Value_Kind,
	number: f32,
	text:   Slice,
}
#assert(size_of(Animation_Graph_Value) == 16)

// Animation_Graph_Event is what the graph raises at a clip's marker or a state's entry or exit: a name, and arguments
// of None kind after the last.
Animation_Graph_Event :: struct {
	name:    Slice,
	hash:    u32,
	padding: u32,
	args:    [MAX_ANIMATION_GRAPH_ARGS]Animation_Graph_Value,
}
#assert(size_of(Animation_Graph_Event) == 48)

// Animation_Graph_Motion is what a state plays: one clip, or a blend of clips by a Float parameter, between the two
// clips whose thresholds the parameter is between.
Animation_Graph_Motion :: enum u32 {
	Clip,
	Blend_1D,
}

// Animation_Graph_Point is a clip of a state's motion, and for a blend, the parameter's value where it plays alone.
Animation_Graph_Point :: struct {
	clip:      u32,
	threshold: f32,
}
#assert(size_of(Animation_Graph_Point) == 8)

Animation_Graph_State :: struct {
	name:             Slice,
	hash:             u32,
	motion:           Animation_Graph_Motion,
	// A Blend_1D's Float parameter, or ANIMATION_GRAPH_NONE.
	parameter:        u32,
	// The motion's Animation_Graph_Point records: one for a clip, and for a blend, in the order of their thresholds.
	first_point:      u32,
	point_count:      u32,
	// How fast the motion plays, from 0, and whether it loops or holds at its end.
	speed:            f32,
	loop:             b32,
	// The Animation_Graph_Event records that the graph raises when it enters and leaves the state, or
	// ANIMATION_GRAPH_NONE.
	enter_event:      u32,
	exit_event:       u32,
	// The state's own Animation_Graph_Transition records, in the order that the graph tries them.
	first_transition: u32,
	transition_count: u32,
	// The state's node in the text, which an editor or a debugger names it by.
	node:             u32,
}
#assert(size_of(Animation_Graph_State) == 56)

// Animation_Graph_Condition_Op is how a condition tests its parameter: a Float against value, a Bool as true or
// false, or a Trigger as set.
Animation_Graph_Condition_Op :: enum u32 {
	Greater,
	Less,
	Equal,
	Not_Equal,
	True,
	False,
	Trigger,
}

Animation_Graph_Condition :: struct {
	parameter: u32,
	op:        Animation_Graph_Condition_Op,
	value:     f32,
	padding:   u32,
}
#assert(size_of(Animation_Graph_Condition) == 16)

// Animation_Graph_Transition leaves its from state, or any other state, for its to state when all its conditions hold
// and, with an exit time, the from state has played that many times through. It cross-fades over duration seconds.
Animation_Graph_Transition :: struct {
	// A state, or ANIMATION_GRAPH_NONE for any state.
	from:            u32,
	to:              u32,
	first_condition: u32,
	condition_count: u32,
	// In plays of the from state's motion, or below 0 for none.
	exit_time:       f32,
	duration:        f32,
	node:            u32,
	padding:         u32,
}
#assert(size_of(Animation_Graph_Transition) == 32)

// Animation_Graph_Blob is the start of an animation graph blob (see docs/content/blobs-and-loading.md#blob-format).
Animation_Graph_Blob :: struct {
	header:      Blob_Header,
	// The state that the graph starts in.
	entry:       u32,
	// The first transition from any state: transitions are grouped by their from state, in the states' order, and the
	// ones from any state are last.
	first_any:   u32,
	// The joint whose motion the graph reports as root motion, by name, or empty for none.
	root_motion: Slice,
	parameters:  Slice,
	clips:       Slice,
	markers:     Slice,
	events:      Slice,
	points:      Slice,
	states:      Slice,
	transitions: Slice,
	conditions:  Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/animations/fox.animation_graph".
	source_path: Slice,
}

// animation_graph_hash is the hash of a parameter's, state's or event's name, which the runtime finds it by.
animation_graph_hash :: proc "contextless" (name: string) -> u32 {
	return hash.fnv32a(transmute([]byte)name)
}

animation_graph_layout :: proc() -> u64 {
	h := layout.hash(Animation_Graph_Blob)
	h ~= layout.hash(Animation_Graph_Parameter) * 31
	h ~= layout.hash(Animation_Graph_Clip) * 961
	h ~= layout.hash(Animation_Graph_Event) * 29791
	h ~= layout.hash(Animation_Graph_State) * 923521
	h ~= layout.hash(Animation_Graph_Transition) * 28629151
	h ~= layout.hash(Animation_Graph_Condition) * 887503681
	return h
}

// animation_graph_view checks an animation graph blob: its header, its layout, that its slices and records are inside
// it, and that every index between its records is in range.
animation_graph_view :: proc(data: []byte) -> (blob: ^Animation_Graph_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Animation_Graph || header.layout != animation_graph_layout() || len(data) < size_of(Animation_Graph_Blob) {
		return
	}
	blob = (^Animation_Graph_Blob)(raw_data(data))
	inside :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(data)) && int(s.size) % size == 0 && int(s.offset) % align == 0
	}
	if !inside(data, blob.root_motion, 1, 1) || !inside(data, blob.source_path, 1, 1) ||
	   !inside(data, blob.parameters, size_of(Animation_Graph_Parameter), align_of(Animation_Graph_Parameter)) ||
	   !inside(data, blob.clips, size_of(Animation_Graph_Clip), align_of(Animation_Graph_Clip)) ||
	   !inside(data, blob.markers, size_of(Animation_Graph_Marker), align_of(Animation_Graph_Marker)) ||
	   !inside(data, blob.events, size_of(Animation_Graph_Event), align_of(Animation_Graph_Event)) ||
	   !inside(data, blob.points, size_of(Animation_Graph_Point), align_of(Animation_Graph_Point)) ||
	   !inside(data, blob.states, size_of(Animation_Graph_State), align_of(Animation_Graph_State)) ||
	   !inside(data, blob.transitions, size_of(Animation_Graph_Transition), align_of(Animation_Graph_Transition)) ||
	   !inside(data, blob.conditions, size_of(Animation_Graph_Condition), align_of(Animation_Graph_Condition)) {
		return nil, false
	}
	parameters := animation_graph_parameters(data, blob)
	clips := animation_graph_clips(data, blob)
	markers := animation_graph_markers(data, blob)
	events := animation_graph_events(data, blob)
	points := animation_graph_points(data, blob)
	states := animation_graph_states(data, blob)
	transitions := animation_graph_transitions(data, blob)
	conditions := animation_graph_conditions(data, blob)
	range :: proc(first, count: u32, length: int) -> bool {
		return u64(first) + u64(count) <= u64(length)
	}
	optional :: proc(index: u32, length: int) -> bool {
		return index == ANIMATION_GRAPH_NONE || int(index) < length
	}
	if len(parameters) > MAX_ANIMATION_GRAPH_PARAMETERS || len(states) == 0 || int(blob.entry) >= len(states) ||
	   int(blob.first_any) > len(transitions) {
		return nil, false
	}
	for p in parameters {
		if !inside(data, p.name, 1, 1) || p.kind > max(Animation_Graph_Parameter_Kind) {
			return nil, false
		}
	}
	for c in clips {
		if !inside(data, c.name, 1, 1) || !range(c.first_marker, c.marker_count, len(markers)) {
			return nil, false
		}
	}
	for m in markers {
		if int(m.event) >= len(events) {
			return nil, false
		}
	}
	for e in events {
		if !inside(data, e.name, 1, 1) {
			return nil, false
		}
		for a in e.args {
			if a.kind > max(Animation_Graph_Value_Kind) || !inside(data, a.text, 1, 1) {
				return nil, false
			}
		}
	}
	for p in points {
		if int(p.clip) >= len(clips) {
			return nil, false
		}
	}
	for s in states {
		if !inside(data, s.name, 1, 1) || s.motion > max(Animation_Graph_Motion) || s.point_count == 0 ||
		   !range(s.first_point, s.point_count, len(points)) || !range(s.first_transition, s.transition_count, int(blob.first_any)) ||
		   !optional(s.enter_event, len(events)) || !optional(s.exit_event, len(events)) {
			return nil, false
		}
		if s.motion == .Blend_1D {
			if int(s.parameter) >= len(parameters) || parameters[s.parameter].kind != .Float || s.point_count > MAX_ANIMATION_GRAPH_POINTS {
				return nil, false
			}
		} else if s.point_count != 1 {
			return nil, false
		}
	}
	for t, i in transitions {
		any_state := i >= int(blob.first_any)
		if any_state != (t.from == ANIMATION_GRAPH_NONE) || !optional(t.from, len(states)) || int(t.to) >= len(states) ||
		   !range(t.first_condition, t.condition_count, len(conditions)) {
			return nil, false
		}
	}
	for c in conditions {
		if int(c.parameter) >= len(parameters) || c.op > max(Animation_Graph_Condition_Op) {
			return nil, false
		}
	}
	return blob, true
}

animation_graph_parameters :: proc "contextless" (data: []byte, blob: ^Animation_Graph_Blob) -> []Animation_Graph_Parameter {
	bytes := blob_bytes(data, blob.parameters)
	return ([^]Animation_Graph_Parameter)(raw_data(bytes))[:len(bytes) / size_of(Animation_Graph_Parameter)]
}

animation_graph_clips :: proc "contextless" (data: []byte, blob: ^Animation_Graph_Blob) -> []Animation_Graph_Clip {
	bytes := blob_bytes(data, blob.clips)
	return ([^]Animation_Graph_Clip)(raw_data(bytes))[:len(bytes) / size_of(Animation_Graph_Clip)]
}

animation_graph_markers :: proc "contextless" (data: []byte, blob: ^Animation_Graph_Blob) -> []Animation_Graph_Marker {
	bytes := blob_bytes(data, blob.markers)
	return ([^]Animation_Graph_Marker)(raw_data(bytes))[:len(bytes) / size_of(Animation_Graph_Marker)]
}

animation_graph_events :: proc "contextless" (data: []byte, blob: ^Animation_Graph_Blob) -> []Animation_Graph_Event {
	bytes := blob_bytes(data, blob.events)
	return ([^]Animation_Graph_Event)(raw_data(bytes))[:len(bytes) / size_of(Animation_Graph_Event)]
}

animation_graph_points :: proc "contextless" (data: []byte, blob: ^Animation_Graph_Blob) -> []Animation_Graph_Point {
	bytes := blob_bytes(data, blob.points)
	return ([^]Animation_Graph_Point)(raw_data(bytes))[:len(bytes) / size_of(Animation_Graph_Point)]
}

animation_graph_states :: proc "contextless" (data: []byte, blob: ^Animation_Graph_Blob) -> []Animation_Graph_State {
	bytes := blob_bytes(data, blob.states)
	return ([^]Animation_Graph_State)(raw_data(bytes))[:len(bytes) / size_of(Animation_Graph_State)]
}

animation_graph_transitions :: proc "contextless" (data: []byte, blob: ^Animation_Graph_Blob) -> []Animation_Graph_Transition {
	bytes := blob_bytes(data, blob.transitions)
	return ([^]Animation_Graph_Transition)(raw_data(bytes))[:len(bytes) / size_of(Animation_Graph_Transition)]
}

animation_graph_conditions :: proc "contextless" (data: []byte, blob: ^Animation_Graph_Blob) -> []Animation_Graph_Condition {
	bytes := blob_bytes(data, blob.conditions)
	return ([^]Animation_Graph_Condition)(raw_data(bytes))[:len(bytes) / size_of(Animation_Graph_Condition)]
}

Animation_Graph_Parameter_Contents :: struct {
	name:    string,
	kind:    Animation_Graph_Parameter_Kind,
	default: f32,
}

// Animation_Graph_Clip_Contents is a clip as animation_graph_write takes it, with its markers, whose events index the
// graph's events.
Animation_Graph_Clip_Contents :: struct {
	name:    string,
	clip:    Guid,
	markers: []Animation_Graph_Marker,
}

Animation_Graph_Value_Contents :: struct {
	kind:   Animation_Graph_Value_Kind,
	number: f32,
	text:   string,
}

Animation_Graph_Event_Contents :: struct {
	name: string,
	args: [MAX_ANIMATION_GRAPH_ARGS]Animation_Graph_Value_Contents,
}

// Animation_Graph_State_Contents is a state as animation_graph_write takes it, with its points. Its transitions are
// the graph's whose from is the state.
Animation_Graph_State_Contents :: struct {
	name:        string,
	motion:      Animation_Graph_Motion,
	parameter:   u32,
	points:      []Animation_Graph_Point,
	speed:       f32,
	loop:        bool,
	enter_event: u32,
	exit_event:  u32,
	node:        u32,
}

Animation_Graph_Transition_Contents :: struct {
	from:       u32,
	to:         u32,
	conditions: []Animation_Graph_Condition,
	exit_time:  f32,
	duration:   f32,
	node:       u32,
}

Animation_Graph_Contents :: struct {
	guid:        Guid,
	key:         u64,
	entry:       u32,
	root_motion: string,
	parameters:  []Animation_Graph_Parameter_Contents,
	clips:       []Animation_Graph_Clip_Contents,
	events:      []Animation_Graph_Event_Contents,
	states:      []Animation_Graph_State_Contents,
	// In the order that the graph tries them, among those from the same state.
	transitions: []Animation_Graph_Transition_Contents,
	source_path: string,
}

// animation_graph_write builds an animation graph blob. It groups the transitions by their from state, in the states'
// order, and puts those from any state last, keeping their order within each group.
animation_graph_write :: proc(contents: Animation_Graph_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Animation_Graph_Blob), allocator)
	records :: proc(buffer: ^[dynamic]byte, $T: typeid, count: int) -> Slice {
		return reserve_bytes(buffer, count * size_of(T), align_of(T))
	}
	put :: proc(buffer: ^[dynamic]byte, s: Slice, index: int, record: ^$T) {
		mem.copy(&buffer[int(s.offset) + index * size_of(T)], record, size_of(T))
	}
	marker_count, point_count, condition_count := 0, 0, 0
	for c in contents.clips {
		marker_count += len(c.markers)
	}
	for s in contents.states {
		point_count += len(s.points)
	}
	for t in contents.transitions {
		condition_count += len(t.conditions)
	}
	parameters := records(&buffer, Animation_Graph_Parameter, len(contents.parameters))
	clips := records(&buffer, Animation_Graph_Clip, len(contents.clips))
	markers := records(&buffer, Animation_Graph_Marker, marker_count)
	events := records(&buffer, Animation_Graph_Event, len(contents.events))
	points := records(&buffer, Animation_Graph_Point, point_count)
	states := records(&buffer, Animation_Graph_State, len(contents.states))
	transitions := records(&buffer, Animation_Graph_Transition, len(contents.transitions))
	conditions := records(&buffer, Animation_Graph_Condition, condition_count)
	text :: proc(buffer: ^[dynamic]byte, s: string) -> Slice {
		return append_bytes(buffer, transmute([]byte)s)
	}

	for p, i in contents.parameters {
		record := Animation_Graph_Parameter{name = text(&buffer, p.name), hash = animation_graph_hash(p.name), kind = p.kind, default = p.default}
		put(&buffer, parameters, i, &record)
	}
	next_marker := 0
	for c, i in contents.clips {
		record := Animation_Graph_Clip{clip = c.clip, name = text(&buffer, c.name), first_marker = u32(next_marker), marker_count = u32(len(c.markers))}
		put(&buffer, clips, i, &record)
		for m in c.markers {
			m := m
			put(&buffer, markers, next_marker, &m)
			next_marker += 1
		}
	}
	for e, i in contents.events {
		record := Animation_Graph_Event{name = text(&buffer, e.name), hash = animation_graph_hash(e.name)}
		for a, j in e.args {
			record.args[j] = {kind = a.kind, number = a.number, text = text(&buffer, a.text)}
		}
		put(&buffer, events, i, &record)
	}

	// The transitions in their groups, and the first of each state's group.
	order := make([dynamic]int, 0, len(contents.transitions), context.temp_allocator)
	first := make([]u32, len(contents.states), context.temp_allocator)
	count := make([]u32, len(contents.states), context.temp_allocator)
	for _, s in contents.states {
		first[s] = u32(len(order))
		for t, i in contents.transitions {
			if t.from == u32(s) {
				append(&order, i)
				count[s] += 1
			}
		}
	}
	first_any := u32(len(order))
	for t, i in contents.transitions {
		if t.from == ANIMATION_GRAPH_NONE {
			append(&order, i)
		}
	}
	next_condition := 0
	for index, i in order {
		t := contents.transitions[index]
		record := Animation_Graph_Transition {
			from            = t.from,
			to              = t.to,
			first_condition = u32(next_condition),
			condition_count = u32(len(t.conditions)),
			exit_time       = t.exit_time,
			duration        = t.duration,
			node            = t.node,
		}
		put(&buffer, transitions, i, &record)
		for c in t.conditions {
			c := c
			put(&buffer, conditions, next_condition, &c)
			next_condition += 1
		}
	}

	next_point := 0
	for s, i in contents.states {
		record := Animation_Graph_State {
			name             = text(&buffer, s.name),
			hash             = animation_graph_hash(s.name),
			motion           = s.motion,
			parameter        = s.parameter,
			first_point      = u32(next_point),
			point_count      = u32(len(s.points)),
			speed            = s.speed,
			loop             = b32(s.loop),
			enter_event      = s.enter_event,
			exit_event       = s.exit_event,
			first_transition = first[i],
			transition_count = count[i],
			node             = s.node,
		}
		put(&buffer, states, i, &record)
		for p in s.points {
			p := p
			put(&buffer, points, next_point, &p)
			next_point += 1
		}
	}

	root_motion := text(&buffer, contents.root_motion)
	source_path := text(&buffer, contents.source_path)
	blob := Animation_Graph_Blob {
		header = {magic = BLOB_MAGIC, kind = .Animation_Graph, layout = animation_graph_layout(), key = contents.key, guid = contents.guid},
		entry = contents.entry,
		first_any = first_any,
		root_motion = root_motion,
		parameters = parameters,
		clips = clips,
		markers = markers,
		events = events,
		points = points,
		states = states,
		transitions = transitions,
		conditions = conditions,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
