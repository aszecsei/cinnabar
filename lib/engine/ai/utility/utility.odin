// Package utility is the decision module of the utility technique (see docs/ai/utility.md): each think scores every
// option of the agent's decision, the weight times the product of its considerations, each an input from the
// blackboard or the world normalized over a range and mapped through a response curve (see
// docs/content/kinds/decisions.md#utility). The best option runs, or a weighted random pick among the options near the
// best, by the agent's own generator. The running option keeps a bonus while it runs, and an option may cool down after
// it ends. The running option, the cooldowns and the last scores are in the agent's module state, so a code reload
// keeps them, and the module holds no state of its own.
package utility

import "base:runtime"
import "core:math"

import "cinnabar:engine/ai"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/random"

// The most options that a decision's module state can hold.
@(private)
MAX_OPTIONS :: format.MAX_DECISION_STATE / size_of(format.Utility_Option_State)
// The most considerations that an option's links can hold in the module state.
@(private)
MAX_LINKS :: format.MAX_DECISION_STATE / size_of(format.Utility_Link_State)

// LOGIT_EDGE keeps a logit's input inside (0, 1), where its logarithm is finite.
@(private)
LOGIT_EDGE :: 1e-6

// register registers the module with the agents' AI. Call it in register_world, after ai.register, which clears the
// modules, so a code reload registers it again.
register :: proc(s: ^ai.State) {
	ai.register_module(s, .Utility, {think = think, check = check, scores = scores})
}

// check checks a decision's options and considerations against the decision and its blackboard, once, before an agent
// starts with it.
check :: proc(decision: ai.Decision, board: ai.Board) -> bool {
	data := format.decision_technique_data(decision.data, decision.blob)
	return format.utility_check(data, decision.data, decision.blob, board.data, board.blob)
}

// curve maps an input, normalized to 0 to 1, through a consideration's curve: slope times the curve's shape at the
// input less x_shift, plus y_shift, clamped to 0 to 1. A result that is not a number is 0.
curve :: proc(c: format.Utility_Consideration, points: []format.Utility_Point, x: f64) -> f64 {
	u := x - f64(c.x_shift)
	k := f64(c.exponent)
	f: f64
	switch c.curve {
	case .Linear:
		f = u
	case .Polynomial:
		f = math.pow(u, k)
	case .Logistic:
		f = 1 / (1 + math.exp(-10 * k * (u - 0.5)))
	case .Logit:
		z := clamp(u, LOGIT_EDGE, 1 - LOGIT_EDGE)
		f = 0.5 + math.ln(z / (1 - z)) / (10 * k)
	case .Step:
		f = 1 if u >= 0.5 else 0
	case .Table:
		f = math.pow(table(points, u), k)
	}
	y := f64(c.slope) * f + f64(c.y_shift)
	if math.is_nan(y) {
		return 0
	}
	return clamp(y, 0, 1)
}

// table is the line through a table's points at x, and the first or the last point's y beyond them. Where two points
// have one x, a step, it is the later point's y.
@(private)
table :: proc(points: []format.Utility_Point, x: f64) -> f64 {
	if len(points) == 0 {
		return 0
	}
	if x < f64(points[0].x) {
		return f64(points[0].y)
	}
	for i in 1 ..< len(points) {
		a, b := points[i - 1], points[i]
		if x < f64(b.x) {
			t := (x - f64(a.x)) / f64(b.x - a.x)
			return f64(a.y) + t * f64(b.y - a.y)
		}
	}
	return f64(points[len(points) - 1].y)
}

// normalize is a value over a consideration's range, from min at 0 to max at 1, clamped. A range may go down.
normalize :: proc(c: format.Utility_Consideration, value: f64) -> f64 {
	x := (value - f64(c.min)) / f64(c.max - c.min)
	if math.is_nan(x) {
		return 0
	}
	return clamp(x, 0, 1)
}

// compensate is a consideration's score made up for the count of an option's considerations, so that an option is not
// scored lower only for having more (Dave Mark's compensation factor): each score gains its distance from 1, times
// 1 - 1 / count, times itself.
compensate :: proc(score: f64, count: int) -> f64 {
	if count <= 1 {
		return score
	}
	modification := 1 - 1 / f64(count)
	return score + (1 - score) * modification * score
}

// Think is a think's view of the agent's decision.
@(private)
Think :: struct {
	t:      ^ai.Think_Context,
	u:      format.Utility_Data,
	shared: []format.Decision_Node,
	now:    u64,
}

@(private)
running_of :: proc(b: ^Think) -> ^format.Utility_Running {
	return (^format.Utility_Running)(&b.t.state[0])
}

@(private)
option_state :: proc(state: []byte, o: format.Utility_Option) -> ^format.Utility_Option_State {
	return (^format.Utility_Option_State)(&state[o.state])
}

@(private)
link_states :: proc(state: []byte, o: format.Utility_Option) -> []format.Utility_Link_State {
	// An option without considerations may have its links' states at the end of the state.
	return ([^]format.Utility_Link_State)(rawptr(uintptr(raw_data(state)) + uintptr(o.links_state)))[:o.link_count]
}

// think scores the options and runs the best: the running option, while it runs and no other beats its score with its
// momentum, or else a new pick, which replaces the running action.
think :: proc(t: ^ai.Think_Context) {
	b := Think {
		t      = t,
		u      = format.utility_data(ai.technique_data(t)),
		shared = format.decision_nodes(t.decision.data, t.decision.blob),
		now    = t.world.clock.tick,
	}
	running := running_of(&b)
	if running.option != 0 {
		o := b.u.options[running.option - 1]
		if t.action.ref != b.shared[o.node].action || t.action.status != .Running {
			// Its action ended, or another replaced it.
			end_option(&b, running.option - 1)
			running.option = 0
		}
	}
	effective: [MAX_OPTIONS]f64
	top := 0.0
	for o, i in b.u.options {
		score := score_option(&b, o)
		if running.option == u32(i + 1) {
			score *= 1 + f64(b.u.header.momentum)
		}
		effective[i] = score
		top = max(top, score)
	}
	if !(top > 0) {
		if running.option != 0 {
			ai.stop_action(t)
			end_option(&b, running.option - 1)
			running.option = 0
		}
		return
	}
	choice: int
	if running.option != 0 && effective[running.option - 1] >= top {
		choice = int(running.option - 1)
	} else {
		choice = pick(&b, effective[:len(b.u.options)], top)
	}
	o := b.u.options[choice]
	if o.target != format.DECISION_NONE {
		target := ecs.Entity(option_state(t.state, o).target)
		if target != key_entity(t, o.target) {
			ai.write_entity(t, o.target, target)
		}
	}
	if running.option == u32(choice + 1) {
		return
	}
	if running.option != 0 {
		end_option(&b, running.option - 1)
	}
	ai.node_writes(t, b.shared[o.node])
	ai.start_action(t, b.shared[o.node].action)
	running.option = u32(choice + 1)
}

// pick is the highest score, the first of equals, or with pick = weighted a random pick by score among those within the
// fraction of the highest, by the agent's generator, which it draws from only when there is more than one.
@(private)
pick :: proc(b: ^Think, effective: []f64, top: f64) -> int {
	if b.u.header.pick == .Best {
		for e, i in effective {
			if e >= top {
				return i
			}
		}
	}
	floor := top * (1 - f64(b.u.header.within))
	total := 0.0
	count := 0
	last := -1
	for e, i in effective {
		if e > 0 && e >= floor {
			total += e
			count += 1
			last = i
		}
	}
	if count == 1 {
		return last
	}
	r := random.float64(b.t.random) * total
	for e, i in effective {
		if e > 0 && e >= floor {
			if r < e {
				return i
			}
			r -= e
		}
	}
	return last
}

// end_option starts an option's cooldown, as it ends.
@(private)
end_option :: proc(b: ^Think, index: u32) {
	o := b.u.options[index]
	if .Cooldown in o.flags {
		option_state(b.t.state, o).ready_at = b.now + ticks(b, o.cooldown)
	}
}

// score_option scores an option, and keeps its score, its target and its considerations' inputs and scores in the
// state. An option that cools down, or whose guard does not hold, scores 0. One with a target is scored for each entity
// that the agent perceives now, of its tag if it names one, with the target key holding that entity, and keeps the
// best, the first of equals: none perceived scores 0. Without a target, or an agent's memory, it scores once, and its
// target is the key's own value.
@(private)
score_option :: proc(b: ^Think, o: format.Utility_Option) -> f64 {
	t := b.t
	st := option_state(t.state, o)
	records := link_states(t.state, o)
	for &r in records {
		r = {}
	}
	st.score, st.target = 0, 0
	if .Cooldown in o.flags && b.now < st.ready_at {
		return 0
	}
	if o.target == format.DECISION_NONE || t.perception == nil {
		score := score_values(b, o, records)
		st.score = f32(score)
		if o.target != format.DECISION_NONE {
			st.target = u64(key_entity(t, o.target))
		}
		return score
	}
	values := t.values
	defer t.values = values
	buffer: [format.MAX_BLACKBOARD_SIZE]byte
	copy(buffer[:], values)
	t.values = buffer[:len(values)]
	key := format.blackboard_keys(t.board.data, t.board.blob)[o.target]
	slot := (^ecs.Entity)(&buffer[key.offset])
	best := -1.0
	scratch: [MAX_LINKS]format.Utility_Link_State
	m := t.perception
	for entry in m.entries[:m.count] {
		if !ai.perceived_now(entry) || (.Tag in o.flags && !ai.tag_matches(t, entry, o.target_tag)) {
			continue
		}
		slot^ = entry.entity
		score := score_values(b, o, scratch[:o.link_count])
		if score > best {
			best = score
			st.target = u64(entry.entity)
			copy(records, scratch[:o.link_count])
		}
	}
	best = max(best, 0)
	st.score = f32(best)
	return best
}

// score_values scores an option on the context's values: its weight times each of its considerations, made up for
// their count, and 0 when its guard does not hold. It keeps each consideration's input and score in records.
@(private)
score_values :: proc(b: ^Think, o: format.Utility_Option, records: []format.Utility_Link_State) -> f64 {
	if !ai.condition_holds(b.t, b.shared[o.node].condition) {
		return 0
	}
	score := f64(o.weight)
	count := int(o.link_count)
	for k in 0 ..< count {
		c := b.u.considerations[b.u.links[o.first_link + u32(k)]]
		x, y := consider(b.t, c, b.u.points)
		records[k] = {f32(x), f32(y)}
		score *= compensate(y, count)
	}
	return score
}

// consider is a consideration's input on the context's values, normalized over its range, and its score through its
// curve, a table's points being a range of points. GOAP scores its goals' considerations with it too.
consider :: proc(t: ^ai.Think_Context, c: format.Utility_Consideration, points: []format.Utility_Point) -> (x, y: f64) {
	x = normalize(c, input(t, c))
	y = curve(c, points[c.first_point:][:c.point_count] if c.curve == .Table else nil, x)
	return
}

// input is a consideration's input before its range: a key's number, a distance in meters, or the seconds since a key
// changed.
@(private)
input :: proc(t: ^ai.Think_Context, c: format.Utility_Consideration) -> f64 {
	switch c.input {
	case .Number:
		return ai.key_number(t, c.a)
	case .Distance:
		return ai.distance(t, c.a, c.b)
	case .Since:
		return ai.seconds_since_changed(t, c.a)
	}
	return 0
}

@(private)
key_entity :: proc(t: ^ai.Think_Context, slot: u32) -> ecs.Entity {
	key := format.blackboard_keys(t.board.data, t.board.blob)[slot]
	return (^ecs.Entity)(&t.values[key.offset])^
}

// ticks is a time in ticks, from its constant or its key as the blackboard is now, rounded to the nearest tick.
@(private)
ticks :: proc(b: ^Think, time: format.Tree_Time) -> u64 {
	seconds := f64(time.seconds)
	if time.source == .Key {
		seconds = ai.key_number(b.t, time.key)
	}
	if !(seconds > 0) {
		return 0
	}
	return u64(seconds * f64(b.t.world.clock.tick_rate) + 0.5)
}

// scores gives what the agent's last think scored, for debuggers and scripts (see ai.scores).
scores :: proc(decision: ai.Decision, board: ai.Board, state: []byte, allocator: runtime.Allocator) -> []ai.Option_Score {
	u := format.utility_data(format.decision_technique_data(decision.data, decision.blob))
	shared := format.decision_nodes(decision.data, decision.blob)
	actions := format.decision_actions(decision.data, decision.blob)
	result := make([]ai.Option_Score, len(u.options), allocator)
	for o, i in u.options {
		st := option_state(state, o)
		records := link_states(state, o)
		considerations := make([]ai.Consideration_Score, o.link_count, allocator)
		for r, k in records {
			c := u.considerations[u.links[o.first_link + u32(k)]]
			considerations[k] = {
				id    = shared[c.node].id,
				input = r.input,
				score = r.score,
			}
		}
		result[i] = {
			id             = shared[o.node].id,
			action         = format.blob_string(decision.data, actions[shared[o.node].action].name),
			score          = st.score,
			target         = ecs.Entity(st.target),
			considerations = considerations,
		}
	}
	return result
}
