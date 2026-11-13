package htn

import "cinnabar:engine/ai"
import format "cinnabar:engine/asset/format"

// The decomposition (see docs/ai/htn.md#decomposition): a total-order forward decomposition of the root task, as SHOP's.
// The to-do list is a stack of the methods that it decomposes, each with its next subtask. A compound task takes the
// first of its methods, in their order, that the decomposition may use and whose preconditions hold in its copy of the
// world state. A primitive task's preconditions must hold there, and its effects then apply to the copy. When a task
// fails, the decomposition backtracks to its last choice and tries the next method of that choice's task. It keeps no
// snapshots: it begins again from the world state that it began in, takes its recorded choices again up to the one
// that it retries, and goes on from there. Each task that it takes is a step, replays among them, so it goes on over
// thinks within a budget of steps. Its state is in the agent's module state, and it reads only the technique's data.

Decomposition :: struct {
	header:         ^format.Htn_Search,
	// The decomposition's copy of the world state, and the world state that it began in.
	world:          []i32,
	begin:          []i32,
	// The methods and the actions that the decomposition may use, a bit each by index.
	usable_methods: []u32,
	usable_actions: []u32,
	// The plan's actions, by index, at most max_plan of them.
	plan:           []u16,
	// The method traversal record: the method that each compound task chose, in the order that they were decomposed.
	choices:        []format.Htn_Choice,
	// The methods that the decomposition decomposes, the last on top.
	frames:         []format.Htn_Frame,
}

Decompose_Result :: enum u8 {
	Decomposing,
	Found,
	Failed,
	// A bounded decomposition found the running plan's record again, or no plan before it.
	Not_Better,
}

// decomposition_of is the decomposition in an agent's module state.
decomposition_of :: proc(h: format.Htn_Data, layout: format.Htn_State, state: []byte) -> Decomposition {
	k, m, a := int(h.header.key_count), int(h.header.method_count), int(h.header.action_count)
	return {
		header = (^format.Htn_Search)(&state[layout.search]),
		world = ([^]i32)(&state[layout.world])[:k],
		begin = ([^]i32)(&state[layout.begin])[:k],
		usable_methods = ([^]u32)(&state[layout.usable_methods])[:(m + 31) / 32],
		usable_actions = ([^]u32)(&state[layout.usable_actions])[:(a + 31) / 32],
		plan = ([^]u16)(&state[layout.plan])[:h.header.max_plan],
		choices = ([^]format.Htn_Choice)(&state[layout.choices])[:format.MAX_HTN_RECORD],
		frames = ([^]format.Htn_Frame)(&state[layout.frames])[:format.MAX_HTN_DEPTH],
	}
}

// decompose_begin begins a decomposition of the root from the world state that it begins in and the methods and
// actions that it may use, which it holds already. A bounded decomposition looks for a better record than the running
// plan's: while its choices are equal to that record, it takes no method after the record's at that place.
decompose_begin :: proc(d: ^Decomposition, bounded: bool) {
	d.header^ = {
		bounded = u8(bounded),
		equal   = u8(bounded),
	}
	copy(d.world, d.begin)
}

// decompose_step takes at most budget tasks of a decomposition. It is found when no task is left. A bounded one whose
// record is equal to the running plan's, record, is not better, since the same record gives the same plan, and neither
// is one that fails.
decompose_step :: proc(d: ^Decomposition, h: format.Htn_Data, record: []format.Htn_Choice, budget: int) -> Decompose_Result {
	s := d.header
	budget := budget
	for {
		for s.frame_count > 0 {
			top := d.frames[s.frame_count - 1]
			if u32(top.next) < h.methods[top.method].subtask_count {
				break
			}
			s.frame_count -= 1
		}
		if s.frame_count == 0 && s.choice_count > 0 {
			return .Not_Better if s.equal != 0 else .Found
		}
		if budget <= 0 {
			return .Decomposing
		}
		budget -= 1
		s.steps += 1
		ok: bool
		if s.frame_count == 0 {
			ok = take_task(d, h, record, h.header.root)
		} else {
			top := &d.frames[s.frame_count - 1]
			m := h.methods[top.method]
			sub := h.subtasks[m.first_subtask + u32(top.next)]
			top.next += 1
			switch sub.kind {
			case .Action:
				ok = take_action(d, h, sub.index)
			case .Task:
				ok = take_task(d, h, record, sub.index)
			}
		}
		if !ok && !backtrack(d) {
			return .Not_Better if s.bounded != 0 else .Failed
		}
	}
}

// is_usable is whether a bit of a set is on.
@(private)
is_usable :: proc(bits: []u32, index: u32) -> bool {
	return bits[index / 32] & (1 << (index % 32)) != 0
}

// take_task decomposes a compound task by its first method that may be used and whose preconditions hold. While the
// decomposition replays, it takes its recorded method again, and at the choice that it retries, it begins after the
// method that failed. While a bounded decomposition is equal to the running plan's record, it takes no method after
// the record's. It is false when no method is left, or when the record or the stack of methods is full.
@(private)
take_task :: proc(d: ^Decomposition, h: format.Htn_Data, record: []format.Htn_Choice, task: u32) -> bool {
	s := d.header
	at := s.choice_count
	if at >= format.MAX_HTN_RECORD || s.frame_count >= format.MAX_HTN_DEPTH {
		return false
	}
	t := h.tasks[task]
	first, last := u32(0), t.method_count
	switch {
	case at < s.replay_to:
		first = u32(d.choices[at].method)
		last = first + 1
	case at == s.replay_to && s.retrying != 0:
		first = s.retry_from
		s.retrying = 0
	}
	if s.equal != 0 {
		if int(at) >= len(record) {
			return false
		}
		last = min(last, u32(record[at].method) + 1)
	}
	for k in first ..< last {
		index := t.first_method + k
		m := h.methods[index]
		if !is_usable(d.usable_methods, index) || !ai.plan_tests_hold(h.tests[m.first_test:][:m.test_count], d.world) {
			continue
		}
		d.choices[at] = {
			task   = u16(task),
			method = u16(k),
		}
		s.choice_count += 1
		d.frames[s.frame_count] = {
			method = u16(index),
		}
		s.frame_count += 1
		if s.equal != 0 && k < u32(record[at].method) {
			s.equal = 0
		}
		return true
	}
	return false
}

// take_action adds a primitive task to the plan, if the decomposition may use it, the plan has room, and its
// preconditions hold, and applies its effects to the decomposition's world state.
@(private)
take_action :: proc(d: ^Decomposition, h: format.Htn_Data, action: u32) -> bool {
	s := d.header
	a := h.actions[action]
	if !is_usable(d.usable_actions, action) || int(s.plan_length) >= len(d.plan) || !ai.plan_tests_hold(h.tests[a.first_test:][:a.test_count], d.world) {
		return false
	}
	ai.plan_apply(h.effects[a.first_effect:][:a.effect_count], d.world)
	d.plan[s.plan_length] = u16(action)
	s.plan_length += 1
	return true
}

// backtrack goes back to the last choice, to try the next method of its task: the decomposition begins again from the
// world state that it began in, and replays the choices before it. It is false when no choice is left.
@(private)
backtrack :: proc(d: ^Decomposition) -> bool {
	s := d.header
	if s.choice_count == 0 {
		return false
	}
	last := s.choice_count - 1
	s.replay_to = last
	s.retry_from = u32(d.choices[last].method) + 1
	s.retrying = 1
	s.choice_count = 0
	s.frame_count = 0
	s.plan_length = 0
	s.equal = s.bounded
	copy(d.world, d.begin)
	return true
}
