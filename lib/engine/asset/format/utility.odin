package asset_format

import "core:mem"

import "cinnabar:core/layout"

// Utility is the technique data of a decision whose technique is Utility (see docs/content/kinds/decisions.md#utility):
// a Utility_Header, then its options, its considerations, the links from each option to its considerations, and the
// points of its table curves. Each option scores the product of its considerations, each an input normalized over a
// range and mapped through a curve. The agent's module state holds the running option, then each option's state, then
// the input and the score of each link, which the last think wrote, for debuggers.

// A place of a distance input that is the agent itself, not a key.
UTILITY_SELF :: max(u32) - 1
// A table curve has at most this many points.
MAX_UTILITY_POINTS :: 32

Utility_Pick :: enum u8 {
	// The highest score.
	Best,
	// A random pick among the scores within a fraction of the highest, by score.
	Weighted,
}

UTILITY_PICK_NAMES :: [Utility_Pick]string {
	.Best     = "best",
	.Weighted = "weighted",
}

Utility_Curve :: enum u8 {
	Linear,
	Polynomial,
	Logistic,
	Logit,
	Step,
	Table,
}

UTILITY_CURVE_NAMES :: [Utility_Curve]string {
	.Linear     = "linear",
	.Polynomial = "polynomial",
	.Logistic   = "logistic",
	.Logit      = "logit",
	.Step       = "step",
	.Table      = "table",
}

// Utility_Input is what a consideration reads: Number a float, int or bool key at slot a; Distance the meters between
// the places a and b, each an entity or position key or UTILITY_SELF; Since the seconds since the key at slot a last
// changed.
Utility_Input :: enum u8 {
	Number,
	Distance,
	Since,
}

// Utility_Consideration is an input normalized over [min, max] to 0 to 1, and mapped through its curve. A table's
// points are a range of the points, in the order of their x.
Utility_Consideration :: struct {
	// The decision's node, for its ID.
	node:        u32,
	input:       Utility_Input,
	curve:       Utility_Curve,
	padding:     [2]u8,
	a:           u32,
	b:           u32,
	min:         f32,
	max:         f32,
	slope:       f32,
	exponent:    f32,
	x_shift:     f32,
	y_shift:     f32,
	first_point: u32,
	point_count: u32,
}
#assert(size_of(Utility_Consideration) == 48)

Utility_Point :: struct {
	x, y: f32,
}
#assert(size_of(Utility_Point) == 8)

Utility_Flag :: enum u8 {
	// The option has a cooldown, in cooldown.
	Cooldown,
	// The option scores only perceived entities whose tag's name has the hash target_tag.
	Tag,
}

Utility_Flags :: bit_set[Utility_Flag;u8]

// Utility_Option is an option: its decision node, whose guard, action and writes are the option's, its weight, and its
// considerations, a range of the links. target is the slot of an entity key, or DECISION_NONE: an option with one is
// scored for each entity that the agent perceives, and writes the best into the key when it wins.
Utility_Option :: struct {
	node:        u32,
	weight:      f32,
	first_link:  u32,
	link_count:  u32,
	target:      u32,
	target_tag:  u32,
	flags:       Utility_Flags,
	padding:     [3]u8,
	cooldown:    Tree_Time,
	// The offsets of its Utility_Option_State, and of its links' Utility_Link_State, in the agent's module state.
	state:       u32,
	links_state: u32,
}
#assert(size_of(Utility_Option) == 48)

// Utility_Option_State is an option's state in the agent's module state: the tick that it may run again in after a
// cooldown, the best target of the last think, and its score in the last think, before momentum.
Utility_Option_State :: struct {
	ready_at: u64,
	target:   u64,
	score:    f32,
	padding:  u32,
}
#assert(size_of(Utility_Option_State) == 24)

// Utility_Link_State is a link's normalized input and score in the last think, for the best target.
Utility_Link_State :: struct {
	input: f32,
	score: f32,
}
#assert(size_of(Utility_Link_State) == 8)

// Utility_Running is at the start of the agent's module state: the option that runs, plus 1, so a zero state runs none.
Utility_Running :: struct {
	option:  u32,
	padding: u32,
}
#assert(size_of(Utility_Running) == 8)

// Utility_Header starts the data. layout is utility_layout's, so data of another build is refused.
Utility_Header :: struct {
	layout:              u64,
	option_count:        u32,
	consideration_count: u32,
	link_count:          u32,
	point_count:         u32,
	pick:                Utility_Pick,
	padding:             [3]u8,
	// The fraction of the highest score that a weighted pick takes options within.
	within:              f32,
	// The fraction that the running option's score gains.
	momentum:            f32,
	padding2:            u32,
}
#assert(size_of(Utility_Header) == 40)

utility_layout :: proc() -> u64 {
	h := layout.hash(Utility_Header)
	h ~= layout.hash(Utility_Option) * 31
	h ~= layout.hash(Utility_Consideration) * 961
	h ~= layout.hash(Utility_Point) * 29791
	h ~= layout.hash(Utility_Option_State) * 923521
	h ~= layout.hash(Utility_Link_State) * 28629151
	h ~= layout.hash(Tree_Time) * 887503681
	return h
}

// Utility_Data is a view of the data, without checks: utility_view checks it once, when the decision loads.
Utility_Data :: struct {
	header:         ^Utility_Header,
	options:        []Utility_Option,
	considerations: []Utility_Consideration,
	// The considerations of each option's range, by index.
	links:          []u32,
	points:         []Utility_Point,
}

// utility_size is the bytes of data of the counts.
@(private = "file")
utility_size :: proc "contextless" (options, considerations, links, points: u64) -> u64 {
	return size_of(Utility_Header) + options * size_of(Utility_Option) + considerations * size_of(Utility_Consideration) + links * 4 + points * size_of(Utility_Point)
}

// utility_data is a view of the data, which it does not check, besides its size.
utility_data :: proc "contextless" (data: []byte) -> (u: Utility_Data) {
	if len(data) < size_of(Utility_Header) {
		return
	}
	h := (^Utility_Header)(raw_data(data))
	if u64(len(data)) < utility_size(u64(h.option_count), u64(h.consideration_count), u64(h.link_count), u64(h.point_count)) {
		return
	}
	at := size_of(Utility_Header)
	u.header = h
	u.options = ([^]Utility_Option)(raw_data(data[at:]))[:h.option_count]
	at += int(h.option_count) * size_of(Utility_Option)
	u.considerations = ([^]Utility_Consideration)(raw_data(data[at:]))[:h.consideration_count]
	at += int(h.consideration_count) * size_of(Utility_Consideration)
	u.links = ([^]u32)(raw_data(data[at:]))[:h.link_count]
	at += int(h.link_count) * 4
	u.points = ([^]Utility_Point)(raw_data(data[at:]))[:h.point_count]
	return
}

// utility_view checks the data against its decision: its layout and size, that each option's decision node has an
// action, that its links and each table's points are in range, that a table's points go up in x, and that each state is
// inside the module state. It does not check keys: utility_check does, with the blackboard.
utility_view :: proc(data: []byte, decision_data: []byte, decision: ^Decision_Blob) -> (u: Utility_Data, ok: bool) {
	if len(data) < size_of(Utility_Header) || uintptr(raw_data(data)) % align_of(Utility_Header) != 0 {
		return
	}
	h := (^Utility_Header)(raw_data(data))
	if h.layout != utility_layout() || h.option_count == 0 || h.pick > max(Utility_Pick) ||
	   u64(len(data)) != utility_size(u64(h.option_count), u64(h.consideration_count), u64(h.link_count), u64(h.point_count)) {
		return
	}
	if !(h.within >= 0 && h.within <= 1) || !(h.momentum >= 0) {
		return
	}
	u = utility_data(data)
	nodes := decision_nodes(decision_data, decision)
	state_size := u64(decision.state_size)
	if state_size < size_of(Utility_Running) {
		return {}, false
	}
	for o in u.options {
		if int(o.node) >= len(nodes) || nodes[o.node].action == DECISION_NONE || o.cooldown.source > max(Tree_Time_Source) {
			return {}, false
		}
		if u64(o.first_link) + u64(o.link_count) > u64(len(u.links)) || !(o.weight >= 0) {
			return {}, false
		}
		if o.state % 8 != 0 || u64(o.state) + size_of(Utility_Option_State) > state_size {
			return {}, false
		}
		if o.links_state % 4 != 0 || u64(o.links_state) + u64(o.link_count) * size_of(Utility_Link_State) > state_size {
			return {}, false
		}
	}
	for l in u.links {
		if int(l) >= len(u.considerations) {
			return {}, false
		}
	}
	for c in u.considerations {
		if int(c.node) >= len(nodes) || c.input > max(Utility_Input) || c.curve > max(Utility_Curve) {
			return {}, false
		}
		if !(c.max != c.min) || !is_finite(c.min) || !is_finite(c.max) || !is_finite(c.slope) || !is_finite(c.exponent) ||
		   !is_finite(c.x_shift) || !is_finite(c.y_shift) {
			return {}, false
		}
		if c.curve == .Table {
			if c.point_count < 2 || c.point_count > MAX_UTILITY_POINTS || u64(c.first_point) + u64(c.point_count) > u64(len(u.points)) {
				return {}, false
			}
			points := u.points[c.first_point:][:c.point_count]
			for i in 1 ..< len(points) {
				if !(points[i].x >= points[i - 1].x) {
					return {}, false
				}
			}
		}
	}
	return u, true
}

@(private = "file")
is_finite :: proc "contextless" (x: f32) -> bool {
	return x - x == 0
}

// utility_check checks the data against its decision and the decision's blackboard: utility_view's checks, and that
// each key that it reads is of a type that it reads.
utility_check :: proc(data: []byte, decision_data: []byte, decision: ^Decision_Blob, board_data: []byte, board: ^Blackboard_Blob) -> bool {
	u, ok := utility_view(data, decision_data, decision)
	if !ok {
		return false
	}
	keys := blackboard_keys(board_data, board)
	is :: proc(keys: []Blackboard_Key, slot: u32, types: bit_set[Blackboard_Type]) -> bool {
		return int(slot) < len(keys) && keys[slot].type in types
	}
	place :: proc(keys: []Blackboard_Key, slot: u32) -> bool {
		return slot == UTILITY_SELF || is(keys, slot, {.Entity, .Position})
	}
	for o in u.options {
		if o.target != DECISION_NONE && !is(keys, o.target, {.Entity}) {
			return false
		}
		if o.cooldown.source == .Key && !is(keys, o.cooldown.key, {.Float, .Int}) {
			return false
		}
	}
	for c in u.considerations {
		switch c.input {
		case .Number:
			if !is(keys, c.a, {.Float, .Int, .Bool}) {
				return false
			}
		case .Distance:
			if !place(keys, c.a) || !place(keys, c.b) {
				return false
			}
		case .Since:
			if int(c.a) >= len(keys) {
				return false
			}
		}
	}
	return true
}

// Utility_Contents is the data as utility_write takes it.
Utility_Contents :: struct {
	pick:           Utility_Pick,
	within:         f32,
	momentum:       f32,
	options:        []Utility_Option,
	considerations: []Utility_Consideration,
	links:          []u32,
	points:         []Utility_Point,
}

// utility_write builds the data.
utility_write :: proc(c: Utility_Contents, allocator := context.allocator) -> []byte {
	size := utility_size(u64(len(c.options)), u64(len(c.considerations)), u64(len(c.links)), u64(len(c.points)))
	data := make([]byte, int(size), allocator)
	header := Utility_Header {
		layout              = utility_layout(),
		option_count        = u32(len(c.options)),
		consideration_count = u32(len(c.considerations)),
		link_count          = u32(len(c.links)),
		point_count         = u32(len(c.points)),
		pick                = c.pick,
		within              = c.within,
		momentum            = c.momentum,
	}
	at := 0
	put :: proc(data: []byte, at: ^int, from: rawptr, size: int) {
		if size > 0 {
			mem.copy(&data[at^], from, size)
		}
		at^ += size
	}
	put(data, &at, &header, size_of(header))
	put(data, &at, raw_data(c.options), len(c.options) * size_of(Utility_Option))
	put(data, &at, raw_data(c.considerations), len(c.considerations) * size_of(Utility_Consideration))
	put(data, &at, raw_data(c.links), len(c.links) * 4)
	put(data, &at, raw_data(c.points), len(c.points) * size_of(Utility_Point))
	return data
}
