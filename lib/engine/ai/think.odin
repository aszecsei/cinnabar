package ai

import "base:runtime"
import "core:math"
import "core:slice"

import "cinnabar:core/jobs"
import "cinnabar:core/profile"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/random"

// Thinking (see docs/ai/agents.md#thinking). In each tick, the ai think system takes the agents whose think is due,
// the first budget of them by priority and then by the time since each last thought, and runs their decision modules
// on jobs, THINK_BATCH agents to a job. A module reads the agent's blackboard and its own state and writes only its
// state; what it decides, actions to start or stop and blackboard writes, goes into the job's commands, which apply
// after the tick's Fixed systems in system order and then job order. A think therefore gives the same result on one job
// or many.

// Module is a technique's decision module. think runs on a job, and may read the world, but writes only the agent's
// module state and the context's outputs. It never calls a script. check, if it is there, checks the technique's data
// against the decision and its blackboard before an agent starts with them: an agent whose decision it refuses waits,
// so think gets only data that checked. scores, if it is there, gives what the agent's last think scored, from its
// module state, for debuggers and scripts (see scores). A planning module has searching, which is whether the agent's
// module state holds a search that its next think goes on with: the think system shares the technique's plan budget
// among those agents, and they think again in the next tick (see docs/ai/agents.md#planning). It has plan too, which
// gives the agent's goal and plan from its module state (see plan).
Module :: struct {
	think:     proc(t: ^Think_Context),
	check:     proc(decision: Decision, board: Board) -> bool,
	scores:    proc(decision: Decision, board: Board, state: []byte, allocator: runtime.Allocator) -> []Option_Score,
	searching: proc(state: []byte) -> bool,
	plan:      proc(decision: Decision, board: Board, state: []byte, allocator: runtime.Allocator) -> Plan_View,
}

// Option_Score is an option that a module scored in the agent's last think: its decision node's ID, its action's name,
// its score, the target that it scored best for, or none, and the score of each of its considerations.
Option_Score :: struct {
	id:             u32,
	action:         string,
	score:          f32,
	target:         ecs.Entity,
	considerations: []Consideration_Score,
}

// Consideration_Score is a consideration of an option: its decision node's ID, its input normalized to 0 to 1, and its
// score.
Consideration_Score :: struct {
	id:    u32,
	input: f32,
	score: f32,
}

// Action_View is the agent's action as its decision sees it: the action reference that it started, DECISION_NONE for
// none, and whether it runs or ended.
Action_View :: struct {
	ref:    u32,
	status: Action_Status,
}

// Think_Context is what a module gets for one agent's think.
Think_Context :: struct {
	world:      ^ecs.World,
	entity:     ecs.Entity,
	decision:   Decision,
	board:      Board,
	// The agent's values, which the module reads and writes only through writes.
	values:     []byte,
	// The agent's module state, decision.blob.state_size bytes, zero when the agent starts.
	state:      []byte,
	action:     Action_View,
	// Seconds since the agent last thought, 0 at its first think.
	dt:         f32,
	// How many times the agent thought before.
	thinks:     u32,
	agent:      Agent_Handle,
	// The job's commands.
	out:        ^[dynamic]Command,
	// The agent's own generator, which only its thinks draw from, so a run replays the same (see set_seed).
	random:     ^random.State,
	// The tick that each key last changed in, by slot.
	changed:    []u64,
	// What the agent perceives, or nil for an agent that has perceived nothing, and the project's tags.
	perception: ^Perception_Memory,
	tags:       ^Tag_Names,
	// The search nodes that the agent may expand in this think: its share of its technique's plan budget, if its module
	// state held a search when the think began, and 0 otherwise.
	plan_budget: int,
}

// technique_data is the technique's part of the agent's decision.
technique_data :: proc(t: ^Think_Context) -> []byte {
	return format.decision_technique_data(t.decision.data, t.decision.blob)
}

// start_action asks to start a decision's action reference, by its index, which stops the action that runs. Asking for
// the action that runs or starts does nothing.
start_action :: proc(t: ^Think_Context, ref: u32) {
	append(t.out, Command{entity = t.entity, agent = t.agent, kind = .Start, ref = ref})
}

// stop_action asks to stop the action that runs.
stop_action :: proc(t: ^Think_Context) {
	append(t.out, Command{entity = t.entity, agent = t.agent, kind = .Stop})
}

// write asks for a decision's blackboard write, by its index, with its value as the blackboard is now.
write :: proc(t: ^Think_Context, index: u32) {
	writes := format.decision_writes(t.decision.data, t.decision.blob)
	w := writes[index]
	keys := format.blackboard_keys(t.board.data, t.board.blob)
	key := keys[w.key]
	c := Command {
		entity = t.entity,
		agent  = t.agent,
		kind   = .Write,
		key    = w.key,
		type   = key.type,
	}
	switch w.source {
	case .Constant:
		constant := format.decision_constants(t.decision.data, t.decision.blob)[w.index]
		c.value = constant.value
	case .Key:
		copy(c.value[:], value_bytes(t.values, keys[w.index]))
	case .Self:
		(^ecs.Entity)(&c.value)^ = t.entity
	}
	append(t.out, c)
}

// node_writes asks for each of a node's `set` writes, in their order.
node_writes :: proc(t: ^Think_Context, node: format.Decision_Node) {
	for i in node.first_write ..< node.first_write + node.write_count {
		write(t, i)
	}
}

// key_number is a float, int or bool key's value as a number, a bool being 0 or 1, and 0 for a key of another type.
key_number :: proc(t: ^Think_Context, slot: u32) -> f64 {
	keys := format.blackboard_keys(t.board.data, t.board.blob)
	key := keys[slot]
	bytes := value_bytes(t.values, key)
	#partial switch key.type {
	case .Float:
		return f64((^f32)(raw_data(bytes))^)
	case .Int:
		return f64((^i32)(raw_data(bytes))^)
	case .Bool:
		return 1 if bytes[0] != 0 else 0
	}
	return 0
}

// entity_place is where an entity is: its Transform's position, if it is alive and has one.
entity_place :: proc(w: ^ecs.World, e: ecs.Entity) -> (ecs.World_Position, bool) {
	if e == 0 || !ecs.is_alive(w, e) {
		return {}, false
	}
	transform := ecs.get(w, e, ecs.Transform)
	if transform == nil {
		return {}, false
	}
	return transform.position, true
}

// place_of is where a place is: the agent for format.UTILITY_SELF, an entity key's entity, or a position key's
// position. An entity that is none, dead or without a Transform is no place.
place_of :: proc(t: ^Think_Context, slot: u32) -> (ecs.World_Position, bool) {
	if slot == format.UTILITY_SELF {
		return entity_place(t.world, t.entity)
	}
	keys := format.blackboard_keys(t.board.data, t.board.blob)
	key := keys[slot]
	bytes := value_bytes(t.values, key)
	#partial switch key.type {
	case .Entity:
		return entity_place(t.world, (^ecs.Entity)(raw_data(bytes))^)
	case .Position:
		return (^ecs.World_Position)(raw_data(bytes))^, true
	}
	return {}, false
}

// distance is the meters between two places, as place_of finds them, or infinity when either is no place.
distance :: proc(t: ^Think_Context, a, b: u32) -> f64 {
	pa, a_ok := place_of(t, a)
	pb, b_ok := place_of(t, b)
	if !a_ok || !b_ok {
		return math.INF_F64
	}
	return place_distance(pa, pb)
}

@(private)
place_distance :: proc(a, b: ecs.World_Position) -> f64 {
	d := ecs.position_sub_f64(a, b)
	return math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
}

// seconds_since_changed is the seconds since the key at a slot last changed, or since the agent started if it never
// did.
seconds_since_changed :: proc(t: ^Think_Context, slot: u32) -> f64 {
	now := t.world.clock.tick
	at := t.changed[slot]
	if now <= at {
		return 0
	}
	return f64(now - at) / f64(t.world.clock.tick_rate)
}

// write_entity asks to write an entity into the entity key at a slot.
write_entity :: proc(t: ^Think_Context, slot: u32, e: ecs.Entity) {
	c := Command {
		entity = t.entity,
		agent  = t.agent,
		kind   = .Write,
		key    = slot,
		type   = .Entity,
	}
	(^ecs.Entity)(&c.value)^ = e
	append(t.out, c)
}

// tag_matches is whether a perceived entity's tag is the project's tag whose name has a hash.
tag_matches :: proc(t: ^Think_Context, entry: Memory_Entry, hash: u32) -> bool {
	if t.tags == nil {
		return false
	}
	tag, found := tag_of_hash(t.tags, hash)
	return found && int(entry.tag) == tag
}

// Stack_Value is a value on a condition's stack: a number, bits for a bool, an enum or an entity, or a place.
@(private)
Stack_Value :: struct {
	number:   f64,
	bits:     u64,
	position: ecs.World_Position,
	// A position, or an entity whose position is in position. A place that is none or has no Transform is not one.
	place:    bool,
}

// condition_holds evaluates a decision's condition, by its index, against the agent's values and the world's
// Transforms. DECISION_NONE holds.
condition_holds :: proc(t: ^Think_Context, index: u32) -> bool {
	if index == format.DECISION_NONE {
		return true
	}
	condition := format.decision_conditions(t.decision.data, t.decision.blob)[index]
	ops := format.decision_ops(t.decision.data, t.decision.blob)[condition.first_op:][:condition.op_count]
	constants := format.decision_constants(t.decision.data, t.decision.blob)
	keys := format.blackboard_keys(t.board.data, t.board.blob)
	stack: [format.MAX_DECISION_STACK]Stack_Value
	top := 0
	push_bytes :: proc(t: ^Think_Context, type: format.Blackboard_Type, bytes: []byte) -> (v: Stack_Value) {
		switch type {
		case .Float:
			v.number = f64((^f32)(raw_data(bytes))^)
		case .Int:
			v.number = f64((^i32)(raw_data(bytes))^)
		case .Bool:
			v.bits = u64(bytes[0])
		case .Enum:
			v.bits = u64((^u32)(raw_data(bytes))^)
		case .Entity:
			e := (^ecs.Entity)(raw_data(bytes))^
			v.bits = u64(e)
			v.position, v.place = entity_place(t.world, e)
		case .Position:
			v.position, v.place = (^ecs.World_Position)(raw_data(bytes))^, true
		case .Vector, .String:
		}
		return
	}
	for o in ops {
		switch o.code {
		case .Key:
			key := keys[o.operand]
			stack[top] = push_bytes(t, key.type, value_bytes(t.values, key))
			top += 1
		case .Constant:
			c := constants[o.operand]
			value := c.value
			stack[top] = push_bytes(t, c.type, value[:])
			top += 1
		case .Self:
			self := t.entity
			stack[top] = push_bytes(t, .Entity, mem_bytes(&self))
			top += 1
		case .Distance:
			a, b := stack[top - 2], stack[top - 1]
			top -= 1
			meters := math.INF_F64
			if a.place && b.place {
				meters = place_distance(a.position, b.position)
			}
			stack[top - 1] = {number = meters}
		case .Less, .Less_Equal, .Greater, .Greater_Equal, .Equal, .Not_Equal:
			a, b := stack[top - 2], stack[top - 1]
			top -= 1
			result: bool
			if format.Blackboard_Type(o.type) == .Float {
				switch o.code {
				case .Less:
					result = a.number < b.number
				case .Less_Equal:
					result = a.number <= b.number
				case .Greater:
					result = a.number > b.number
				case .Greater_Equal:
					result = a.number >= b.number
				case .Equal:
					result = a.number == b.number
				case .Not_Equal:
					result = a.number != b.number
				case .Key, .Constant, .Self, .Distance, .And, .Or, .Not:
				}
			} else {
				result = (a.bits == b.bits) == (o.code == .Equal)
			}
			stack[top - 1] = {bits = u64(result)}
		case .And:
			top -= 1
			stack[top - 1] = {bits = u64(stack[top - 1].bits != 0 && stack[top].bits != 0)}
		case .Or:
			top -= 1
			stack[top - 1] = {bits = u64(stack[top - 1].bits != 0 || stack[top].bits != 0)}
		case .Not:
			stack[top - 1] = {bits = u64(stack[top - 1].bits == 0)}
		}
	}
	return top == 1 && stack[0].bits != 0
}

@(private)
mem_bytes :: proc(e: ^ecs.Entity) -> []byte {
	return ([^]byte)(e)[:size_of(ecs.Entity)]
}

// Think_Job is a batch of agents that one job thinks for.
@(private)
Think_Job :: struct {
	s:       ^State,
	world:   ^ecs.World,
	agents:  []u32,
	// Each agent's share of its technique's plan budget.
	shares:  []int,
	out:     [dynamic]Command,
	ctx:     runtime.Context,
}

@(private)
think_job :: proc(data: rawptr) {
	j := (^Think_Job)(data)
	context = j.ctx
	s := j.s
	w := j.world
	now := w.clock.tick
	for index, k in j.agents {
		slot := &s.agents.slots[index]
		ready := &slot.phase.(Agent_Ready)
		board, _ := board_of(s, slot.blackboard)
		decision, _ := decision_of(s, slot.decision)
		t := Think_Context {
			world      = w,
			entity     = slot.entity,
			decision   = decision,
			board      = board,
			values     = ready.values,
			state      = ready.state,
			action     = action_view(ready.action),
			dt         = 0 if ready.thinks == 0 else f32(now - ready.last_think) / f32(w.clock.tick_rate),
			thinks     = ready.thinks,
			agent      = {index, s.agents.generations[index]},
			out        = &j.out,
			random     = &ready.random,
			changed    = ready.changed,
			perception = ready.perception,
			tags       = &s.tags,
			plan_budget = j.shares[k],
		}
		s.modules[decision.blob.technique].think(&t)
	}
}

// action_view is an action as a decision sees it.
@(private)
action_view :: proc(a: Action_Phase) -> Action_View {
	switch p in a {
	case Native_Starting:
		return {p.ref, .Running}
	case Script_Starting:
		return {p.ref, .Running}
	case Native_Running:
		return {p.ref, .Running}
	case Script_Running:
		return {p.ref, .Running}
	case Action_Done:
		return {p.ref, p.status}
	}
	return {format.DECISION_NONE, .Succeeded}
}

// think_system is the ai think system: it stops the native actions that ended, keeps the pool in step with the
// world's agents, makes ready those whose blobs loaded, and runs the decisions of the agents that think in this tick.
@(private)
think_system :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	w := ctx.world
	stop_native_endings(s, ctx)
	check_agents(s, w, ctx.commands)
	ready_agents(s, w)
	think(s, w, ctx)
}

// Due is an agent whose think is due, with what orders it for the budget.
@(private)
Due :: struct {
	index:      u32,
	priority:   i32,
	last_think: u64,
}

// due_agents is the agents that think in this tick: those whose think is due and whose entities are active, the first
// budget of them by priority, highest first, then by the tick each last thought in, oldest first, then by slot. The
// order never depends on an entity's handle.
@(private)
due_agents :: proc(s: ^State, w: ^ecs.World) -> []u32 {
	now := w.clock.tick
	due := make([dynamic]Due, w.platform.frame_allocator)
	for &slot, index in s.agents.slots {
		ready, ok := &slot.phase.(Agent_Ready)
		if !ok || ready.next_think > now || ecs.has(w, slot.entity, ecs.Inactive) {
			continue
		}
		agent := ecs.get(w, slot.entity, Agent)
		append(&due, Due{u32(index), agent.priority, ready.last_think})
	}
	slice.sort_by(due[:], proc(a, b: Due) -> bool {
		if a.priority != b.priority {
			return a.priority > b.priority
		}
		if a.last_think != b.last_think {
			return a.last_think < b.last_think
		}
		return a.index < b.index
	})
	count := min(len(due), s.budget)
	result := make([]u32, count, w.platform.frame_allocator)
	for d, i in due[:count] {
		result[i] = d.index
	}
	return result
}

@(private)
think :: proc(s: ^State, w: ^ecs.World, ctx: ^ecs.System_Context) {
	agents := due_agents(s, w)
	if len(agents) == 0 {
		return
	}
	p := &w.platform.profile
	profile.begin(p, profile.name(p, "AI think", .Frame))
	defer profile.end(p)
	shares := plan_shares(s, agents, w.platform.frame_allocator)
	batches := (len(agents) + THINK_BATCH - 1) / THINK_BATCH
	work := make([]Think_Job, batches, w.platform.frame_allocator)
	list := make([]jobs.Job, batches, w.platform.frame_allocator)
	for b in 0 ..< batches {
		first, end := b * THINK_BATCH, min((b + 1) * THINK_BATCH, len(agents))
		work[b] = {
			s       = s,
			world   = w,
			agents  = agents[first:end],
			shares  = shares[first:end],
			out     = make([dynamic]Command, w.platform.frame_allocator),
			ctx     = context,
		}
		list[b] = {think_job, &work[b]}
	}
	counter: jobs.Counter
	w.platform.jobs_run(list, &counter)
	w.platform.jobs_wait(&counter)
	// The batches' commands, in batch order, which is the agents' order.
	out := job_commands(s, ctx)
	for &j in work {
		append(out, ..j.out[:])
	}
	now := w.clock.tick
	for index in agents {
		slot := &s.agents.slots[index]
		ready := &slot.phase.(Agent_Ready)
		ready.last_think = now
		ready.thinks += 1
		ready.next_think = now + (1 if searching(s, slot, ready) else interval_ticks(w, slot.entity))
	}
}

// searching is whether an agent's module state holds a search that its next think goes on with.
@(private)
searching :: proc(s: ^State, slot: ^Agent_Slot, ready: ^Agent_Ready) -> bool {
	decision, ok := decision_of(s, slot.decision)
	if !ok {
		return false
	}
	module := s.modules[decision.blob.technique]
	return module.searching != nil && module.searching(ready.state)
}

// plan_shares is each agent's share of its technique's plan budget, by the agents' order. Each technique's budget is
// shared evenly among its agents that are searching, and the first of them by the agents' order get one node more
// while the budget's remainder lasts. Other agents get 0. The shares depend only on the order and the agents' states,
// so a think gives the same result on one job or many.
@(private)
plan_shares :: proc(s: ^State, agents: []u32, allocator: runtime.Allocator) -> []int {
	shares := make([]int, len(agents), allocator)
	techniques := make([]format.Decision_Technique, len(agents), allocator)
	searchers := make([]bool, len(agents), allocator)
	counts: [format.Decision_Technique]int
	for index, i in agents {
		slot := &s.agents.slots[index]
		if !searching(s, slot, &slot.phase.(Agent_Ready)) {
			continue
		}
		decision, _ := decision_of(s, slot.decision)
		techniques[i] = decision.blob.technique
		searchers[i] = true
		counts[techniques[i]] += 1
	}
	given: [format.Decision_Technique]int
	for searcher, i in searchers {
		if !searcher {
			continue
		}
		t := techniques[i]
		budget := s.plan_budgets[t]
		shares[i] = budget / counts[t] + (1 if given[t] < budget % counts[t] else 0)
		given[t] += 1
	}
	return shares
}
