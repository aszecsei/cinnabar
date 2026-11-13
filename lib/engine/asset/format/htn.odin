package asset_format

import "core:mem"

import "cinnabar:core/layout"

// HTN is the technique data of a decision whose technique is Htn (see docs/content/kinds/decisions.md#htn): an
// Htn_Header, then the planning keys' slots, the primitive tasks as Plan_Actions, the compound tasks, their methods, the
// methods' subtasks, the tests and the effects. The agent's module state, which htn_state lays out from the header's
// counts, holds the agent's phase, the plan runner's state, the running plan's steps, expected world state and method
// traversal record, and the decomposition: its world state and the one it began in, the methods and actions that it may
// use, its plan, its record, and its stack of the methods that it decomposes.

// A decision has at most this many compound tasks, methods and primitive tasks.
MAX_HTN_TASKS :: 256
MAX_HTN_METHODS :: 1024
MAX_HTN_ACTIONS :: 256
// A decomposition holds at most this many nested methods, and its record at most this many choices.
MAX_HTN_DEPTH :: 32
MAX_HTN_RECORD :: 64

// Htn_Phase is where an agent's HTN is: without a plan, decomposing for one, running one, or running one while it
// decomposes again for a better one.
Htn_Phase :: enum u32 {
	Idle,
	Planning,
	Running,
	Checking,
}

// Htn_Agent is at the start of the agent's module state: its phase, the steps of its last decomposition that ended, and
// the length of the running plan's record.
Htn_Agent :: struct {
	phase:         Htn_Phase,
	steps:         u32,
	record_length: u32,
	padding:       u32,
}
#assert(size_of(Htn_Agent) == 16)

// Htn_Choice is a choice of a method traversal record: the compound task, and the index of its method that was chosen,
// among the task's methods.
Htn_Choice :: struct {
	task:   u16,
	method: u16,
}
#assert(size_of(Htn_Choice) == 4)

// Htn_Frame is a method that a decomposition decomposes, by its index among the methods, and its next subtask.
Htn_Frame :: struct {
	method: u16,
	next:   u16,
}
#assert(size_of(Htn_Frame) == 4)

// Htn_Search is the start of a decomposition's state: its counts of choices, frames and the plan's steps, and the steps
// that it took. After a backtrack, it takes the first replay_to choices of its record again, and then tries the task
// at replay_to from the method retry_from, while retrying is set. A bounded decomposition takes no method after the
// running plan's record while it is equal to that record.
Htn_Search :: struct {
	choice_count: u32,
	frame_count:  u32,
	plan_length:  u32,
	steps:        u32,
	replay_to:    u32,
	retry_from:   u32,
	retrying:     u8,
	bounded:      u8,
	equal:        u8,
	padding:      [5]u8,
}
#assert(size_of(Htn_Search) == 32)

// Htn_Task is a compound task: its decision node and its methods, a range of the methods in order of preference.
Htn_Task :: struct {
	node:         u32,
	first_method: u32,
	method_count: u32,
}
#assert(size_of(Htn_Task) == 12)

// Htn_Method is a method: its decision node, whose guard is the method's, its preconditions, a range of the tests, and
// its subtasks, a range of the subtasks.
Htn_Method :: struct {
	node:          u32,
	first_test:    u32,
	test_count:    u32,
	first_subtask: u32,
	subtask_count: u32,
}
#assert(size_of(Htn_Method) == 20)

// Htn_Subtask_Kind is whether a subtask is a primitive task, an action, or a compound task.
Htn_Subtask_Kind :: enum u32 {
	Action,
	Task,
}

// Htn_Subtask is a subtask of a method: an action or a compound task, by its index among them.
Htn_Subtask :: struct {
	kind:  Htn_Subtask_Kind,
	index: u32,
}
#assert(size_of(Htn_Subtask) == 8)

// Htn_Header starts the data. layout is htn_layout's, so data of another build is refused.
Htn_Header :: struct {
	layout:        u64,
	key_count:     u32,
	action_count:  u32,
	task_count:    u32,
	method_count:  u32,
	subtask_count: u32,
	test_count:    u32,
	effect_count:  u32,
	// The root task, by its index among the compound tasks.
	root:          u32,
	// The most actions that a plan holds.
	max_plan:      u32,
	padding:       u32,
}
#assert(size_of(Htn_Header) == 48)

htn_layout :: proc() -> u64 {
	h := layout.hash(Htn_Header)
	h ~= layout.hash(Htn_Task) * 31
	h ~= layout.hash(Htn_Method) * 961
	h ~= layout.hash(Htn_Subtask) * 29791
	h ~= layout.hash(Plan_Action) * 923521
	h ~= layout.hash(Plan_Test) * 28629151
	h ~= layout.hash(Plan_Effect) * 887503681
	h ~= layout.hash(Plan_Run) * 27512614111
	h ~= layout.hash(Htn_Agent) * 852891037441
	h ~= layout.hash(Htn_Search) * 26439622160671
	h ~= layout.hash(Htn_Choice) * 819628286980801
	h ~= layout.hash(Htn_Frame) * 25408476896404831
	return h
}

// Htn_State is where each part of an agent's module state is, as offsets, and its size.
Htn_State :: struct {
	// [max_plan]u16, the running plan's actions, by index.
	steps:          u64,
	// [key_count]i32, the world state that the running plan expects now.
	expected:       u64,
	// [MAX_HTN_RECORD]Htn_Choice, the running plan's record.
	record:         u64,
	// Htn_Search, then [key_count]i32, the decomposition's world state, and [key_count]i32, the one it began in; the
	// methods and the actions that it may use, a bit each; [max_plan]u16, its plan; [MAX_HTN_RECORD]Htn_Choice, its
	// record; and [MAX_HTN_DEPTH]Htn_Frame, its methods.
	search:         u64,
	world:          u64,
	begin:          u64,
	usable_methods: u64,
	usable_actions: u64,
	plan:           u64,
	choices:        u64,
	frames:         u64,
	size:           u64,
}

// The offset of the Plan_Run, after the Htn_Agent.
HTN_RUN :: size_of(Htn_Agent)

// htn_state lays out the module state of a decision of these counts. The cook sizes the state with it, and the module
// finds its parts with it.
htn_state :: proc "contextless" (key_count, action_count, method_count, max_plan: u32) -> (s: Htn_State) {
	k := u64(key_count)
	steps := (u64(max_plan) * 2 + 3) &~ 3
	at := u64(HTN_RUN + size_of(Plan_Run))
	s.steps = at
	at += steps
	s.expected = at
	at += k * 4
	s.record = at
	at += MAX_HTN_RECORD * size_of(Htn_Choice)
	s.search = at
	at += size_of(Htn_Search)
	s.world = at
	at += k * 4
	s.begin = at
	at += k * 4
	s.usable_methods = at
	at += (u64(method_count) + 31) / 32 * 4
	s.usable_actions = at
	at += (u64(action_count) + 31) / 32 * 4
	s.plan = at
	at += steps
	s.choices = at
	at += MAX_HTN_RECORD * size_of(Htn_Choice)
	s.frames = at
	at += MAX_HTN_DEPTH * size_of(Htn_Frame)
	s.size = (at + 7) &~ 7
	return
}

// Htn_Data is a view of the data, without checks: htn_view checks it once, when the decision loads.
Htn_Data :: struct {
	header:   ^Htn_Header,
	// The planning keys' slots.
	keys:     []u32,
	actions:  []Plan_Action,
	tasks:    []Htn_Task,
	methods:  []Htn_Method,
	subtasks: []Htn_Subtask,
	tests:    []Plan_Test,
	effects:  []Plan_Effect,
}

@(private = "file")
htn_size :: proc "contextless" (h: ^Htn_Header) -> u64 {
	return size_of(Htn_Header) + u64(h.key_count) * 4 + u64(h.action_count) * size_of(Plan_Action) + u64(h.task_count) * size_of(Htn_Task) +
		u64(h.method_count) * size_of(Htn_Method) + u64(h.subtask_count) * size_of(Htn_Subtask) + u64(h.test_count) * size_of(Plan_Test) +
		u64(h.effect_count) * size_of(Plan_Effect)
}

// htn_data is a view of the data, which it does not check, besides its size.
htn_data :: proc "contextless" (data: []byte) -> (h: Htn_Data) {
	if len(data) < size_of(Htn_Header) {
		return
	}
	header := (^Htn_Header)(raw_data(data))
	if u64(len(data)) < htn_size(header) {
		return
	}
	at := size_of(Htn_Header)
	take :: proc "contextless" (data: []byte, at: ^int, $T: typeid, count: u32) -> []T {
		s := ([^]T)(raw_data(data[at^:]))[:count]
		at^ += int(count) * size_of(T)
		return s
	}
	h.header = header
	h.keys = take(data, &at, u32, header.key_count)
	h.actions = take(data, &at, Plan_Action, header.action_count)
	h.tasks = take(data, &at, Htn_Task, header.task_count)
	h.methods = take(data, &at, Htn_Method, header.method_count)
	h.subtasks = take(data, &at, Htn_Subtask, header.subtask_count)
	h.tests = take(data, &at, Plan_Test, header.test_count)
	h.effects = take(data, &at, Plan_Effect, header.effect_count)
	return
}

// htn_state_of is the layout of the data's module state.
htn_state_of :: proc "contextless" (h: Htn_Data) -> Htn_State {
	return htn_state(h.header.key_count, h.header.action_count, h.header.method_count, h.header.max_plan)
}

// htn_view checks the data against its decision: its layout and size, its counts and limits, that the module state
// holds its layout, that the root is a compound task, that each action's node has an action, that each task has methods
// and each method subtasks, at most a u16's count, and that every range and index is in range. It does not check keys: htn_check does, with
// the blackboard.
htn_view :: proc(data: []byte, decision_data: []byte, decision: ^Decision_Blob) -> (h: Htn_Data, ok: bool) {
	if len(data) < size_of(Htn_Header) || uintptr(raw_data(data)) % align_of(Htn_Header) != 0 {
		return
	}
	header := (^Htn_Header)(raw_data(data))
	if header.layout != htn_layout() || u64(len(data)) != htn_size(header) {
		return
	}
	if header.key_count > MAX_PLAN_KEYS || header.action_count == 0 || header.action_count > MAX_HTN_ACTIONS || header.task_count == 0 ||
	   header.task_count > MAX_HTN_TASKS || header.method_count == 0 || header.method_count > MAX_HTN_METHODS || header.root >= header.task_count ||
	   header.max_plan == 0 || header.max_plan > MAX_PLAN_LENGTH {
		return
	}
	h = htn_data(data)
	if htn_state_of(h).size > u64(decision.state_size) {
		return {}, false
	}
	nodes := decision_nodes(decision_data, decision)
	range :: proc "contextless" (first, count: u32, length: int) -> bool {
		return u64(first) + u64(count) <= u64(length)
	}
	if !plan_tests_ok(h.tests, header.key_count) || !plan_effects_ok(h.effects, header.key_count) {
		return {}, false
	}
	for a in h.actions {
		if int(a.node) >= len(nodes) || nodes[a.node].action == DECISION_NONE {
			return {}, false
		}
		if !range(a.first_test, a.test_count, len(h.tests)) || !range(a.first_effect, a.effect_count, len(h.effects)) {
			return {}, false
		}
	}
	for task in h.tasks {
		if int(task.node) >= len(nodes) || task.method_count == 0 || !range(task.first_method, task.method_count, len(h.methods)) {
			return {}, false
		}
	}
	for m in h.methods {
		// A frame counts a method's subtasks in a u16.
		if int(m.node) >= len(nodes) || m.subtask_count == 0 || m.subtask_count > u32(max(u16)) || !range(m.first_test, m.test_count, len(h.tests)) ||
		   !range(m.first_subtask, m.subtask_count, len(h.subtasks)) {
			return {}, false
		}
	}
	for s in h.subtasks {
		switch s.kind {
		case .Action:
			if int(s.index) >= len(h.actions) {
				return {}, false
			}
		case .Task:
			if int(s.index) >= len(h.tasks) {
				return {}, false
			}
		case:
			return {}, false
		}
	}
	return h, true
}

// htn_check checks the data against its decision and the decision's blackboard: htn_view's checks, and that the
// planning keys are distinct bool, int and enum keys and each effect fits its key.
htn_check :: proc(data: []byte, decision_data: []byte, decision: ^Decision_Blob, board_data: []byte, board: ^Blackboard_Blob) -> bool {
	h, ok := htn_view(data, decision_data, decision)
	if !ok {
		return false
	}
	return plan_keys_ok(h.keys, h.effects, blackboard_keys(board_data, board))
}

// Htn_Contents is the data as htn_write takes it.
Htn_Contents :: struct {
	root:     u32,
	max_plan: u32,
	keys:     []u32,
	actions:  []Plan_Action,
	tasks:    []Htn_Task,
	methods:  []Htn_Method,
	subtasks: []Htn_Subtask,
	tests:    []Plan_Test,
	effects:  []Plan_Effect,
}

// htn_write builds the data.
htn_write :: proc(c: Htn_Contents, allocator := context.allocator) -> []byte {
	header := Htn_Header {
		layout        = htn_layout(),
		key_count     = u32(len(c.keys)),
		action_count  = u32(len(c.actions)),
		task_count    = u32(len(c.tasks)),
		method_count  = u32(len(c.methods)),
		subtask_count = u32(len(c.subtasks)),
		test_count    = u32(len(c.tests)),
		effect_count  = u32(len(c.effects)),
		root          = c.root,
		max_plan      = c.max_plan,
	}
	data := make([]byte, int(htn_size(&header)), allocator)
	at := 0
	put :: proc(data: []byte, at: ^int, from: rawptr, size: int) {
		if size > 0 {
			mem.copy(&data[at^], from, size)
		}
		at^ += size
	}
	put(data, &at, &header, size_of(header))
	put(data, &at, raw_data(c.keys), len(c.keys) * 4)
	put(data, &at, raw_data(c.actions), len(c.actions) * size_of(Plan_Action))
	put(data, &at, raw_data(c.tasks), len(c.tasks) * size_of(Htn_Task))
	put(data, &at, raw_data(c.methods), len(c.methods) * size_of(Htn_Method))
	put(data, &at, raw_data(c.subtasks), len(c.subtasks) * size_of(Htn_Subtask))
	put(data, &at, raw_data(c.tests), len(c.tests) * size_of(Plan_Test))
	put(data, &at, raw_data(c.effects), len(c.effects) * size_of(Plan_Effect))
	return data
}
