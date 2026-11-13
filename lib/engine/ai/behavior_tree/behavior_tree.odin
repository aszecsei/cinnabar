// Package behavior_tree is the decision module of the behavior tree technique (see docs/ai/behavior-trees.md): a tree
// of sequences, selectors, parallels, actions, waits, sets and conditions over the agent's blackboard, with guards that
// abort and other decorators, which the cooker writes in depth-first order (see
// docs/content/kinds/decisions.md#behavior-trees). Each think checks the guards that abort and resumes the tree from
// its running nodes. Every node's state is in the agent's module state, so a code reload keeps it, and the module
// holds no state of its own.
package behavior_tree

import "cinnabar:engine/ai"
import format "cinnabar:engine/asset/format"

// Status is where a node is. Again is a node that repeats, which starts again at the next think, since it started in
// this one. Succeeded and Failed are the result that a node ended with, which a parallel reads of its children.
Status :: enum u8 {
	Idle,
	Running,
	Again,
	Succeeded,
	Failed,
}

// Node_State is a node's state in the agent's module state. child is a sequence's or a selector's running child, by
// its index in the tree; repeats is how many times a repeating node succeeded; entered is the think that the node last
// started in, as Think_Context.thinks counts them.
Node_State :: struct {
	status:  Status,
	padding: [3]u8,
	child:   u32,
	repeats: u32,
	entered: u32,
}
#assert(size_of(Node_State) == format.TREE_STATE_SIZE)

// Result is what a node gives its parent in a think.
Result :: enum u8 {
	Running,
	Succeeded,
	Failed,
}

// register registers the module with the agents' AI. Call it in register_world, after ai.register, which clears the
// modules, so a code reload registers it again.
register :: proc(s: ^ai.State) {
	ai.register_module(s, .Behavior_Tree, {think = think, check = check})
}

// check checks a decision's tree against the decision and its blackboard, once, before an agent starts with it.
check :: proc(decision: ai.Decision, board: ai.Board) -> bool {
	data := format.decision_technique_data(decision.data, decision.blob)
	return format.tree_check(data, decision.data, decision.blob, board.data, board.blob)
}

// Tree is a think's view of the agent's tree.
@(private)
Tree :: struct {
	t:      ^ai.Think_Context,
	nodes:  []format.Tree_Node,
	// The decision's nodes, which hold the tree's guards, actions and writes.
	shared: []format.Decision_Node,
	now:    u64,
}

// think runs the agent's tree: it resumes the root if it runs, and starts it otherwise, so a tree that ended starts
// again at the next think.
think :: proc(t: ^ai.Think_Context) {
	b := Tree {
		t      = t,
		nodes  = format.tree_nodes(ai.technique_data(t)),
		shared = format.decision_nodes(t.decision.data, t.decision.blob),
		now    = t.world.clock.tick,
	}
	switch state(&b, 0).status {
	case .Running, .Again:
		resume(&b, 0)
	case .Idle, .Succeeded, .Failed:
		enter(&b, 0)
	}
}

@(private)
state :: proc(b: ^Tree, i: u32) -> ^Node_State {
	return (^Node_State)(&b.t.state[b.nodes[i].state])
}

@(private)
timer :: proc(b: ^Tree, i: u32, which: format.Tree_Timer) -> ^u64 {
	return (^u64)(&b.t.state[format.tree_timer(b.nodes[i], which)])
}

// ticks is a time in ticks, from its constant or its key as the blackboard is now, rounded to the nearest tick.
@(private)
ticks :: proc(b: ^Tree, time: format.Tree_Time) -> u64 {
	seconds := f64(time.seconds)
	if time.source == .Key {
		keys := format.blackboard_keys(b.t.board.data, b.t.board.blob)
		key := keys[time.key]
		bytes := b.t.values[key.offset:]
		#partial switch key.type {
		case .Float:
			seconds = f64((^f32)(raw_data(bytes))^)
		case .Int:
			seconds = f64((^i32)(raw_data(bytes))^)
		}
	}
	if !(seconds > 0) {
		return 0
	}
	return u64(seconds * f64(b.t.world.clock.tick_rate) + 0.5)
}

@(private)
guard :: proc(b: ^Tree, i: u32) -> bool {
	return ai.condition_holds(b.t, b.shared[b.nodes[i].node].condition)
}

@(private)
cooling :: proc(b: ^Tree, i: u32) -> bool {
	return .Cooldown in b.nodes[i].flags && b.now < timer(b, i, .Ready_At)^
}

// enter starts a node. One that is cooling down or whose guard fails does not run, and fails.
@(private)
enter :: proc(b: ^Tree, i: u32) -> Result {
	n := b.nodes[i]
	if cooling(b, i) || !guard(b, i) {
		result := decorate(n, .Failed)
		state(b, i)^ = {
			status = status_of(result),
		}
		return result
	}
	state(b, i)^ = {
		status  = .Running,
		entered = b.t.thinks,
	}
	if .Time_Limit in n.flags {
		timer(b, i, .Started)^ = b.now
	}
	return settle(b, i, start(b, i))
}

// start starts a node's kind, as it does when the node starts and when it repeats, and gives its result.
@(private)
start :: proc(b: ^Tree, i: u32) -> Result {
	n := b.nodes[i]
	switch n.kind {
	case .Sequence, .Selector:
		state(b, i).child = i + 1
		return run_children(b, i, true)
	case .Parallel:
		for c := i + 1; c < n.end; c = b.nodes[c].end {
			state(b, c).status = .Idle
		}
		return run_parallel(b, i)
	case .Action:
		ai.start_action(b.t, b.shared[n.node].action)
		return .Running
	case .Wait:
		until := b.now + ticks(b, n.seconds)
		timer(b, i, .Wait_Until)^ = until
		return .Succeeded if b.now >= until else .Running
	case .Set:
		ai.node_writes(b.t, b.shared[n.node])
		return .Succeeded
	case .Condition:
		return .Succeeded if ai.condition_holds(b.t, n.test) else .Failed
	}
	return .Failed
}

// resume runs a node that runs: it fails when its time limit passed or its guard aborts itself, a selector first lets
// an earlier child whose guard aborts lower priorities cut in, and then the node's kind goes on.
@(private)
resume :: proc(b: ^Tree, i: u32) -> Result {
	n := b.nodes[i]
	st := state(b, i)
	if .Time_Limit in n.flags && b.now >= timer(b, i, .Started)^ + ticks(b, n.time_limit) {
		abort(b, i)
		return finish(b, i, .Failed)
	}
	if (n.abort == .Self || n.abort == .Both) && !guard(b, i) {
		abort(b, i)
		return finish(b, i, .Failed)
	}
	if st.status == .Again {
		st.status = .Running
		st.entered = b.t.thinks
		return settle(b, i, start(b, i))
	}
	result: Result
	switch n.kind {
	case .Selector:
		for c := i + 1; c < st.child; c = b.nodes[c].end {
			if (b.nodes[c].abort == .Lower || b.nodes[c].abort == .Both) && !cooling(b, c) && guard(b, c) {
				abort(b, st.child)
				st.child = c
				return settle(b, i, run_children(b, i, true))
			}
		}
		result = run_children(b, i, false)
	case .Sequence:
		result = run_children(b, i, false)
	case .Parallel:
		result = run_parallel(b, i)
	case .Action:
		view := b.t.action
		switch {
		case view.ref != b.shared[n.node].action:
			// Another action replaced it.
			result = .Failed
		case view.status == .Running:
			result = .Running
		case view.status == .Succeeded:
			result = .Succeeded
		case:
			result = .Failed
		}
	case .Wait:
		result = .Succeeded if b.now >= timer(b, i, .Wait_Until)^ else .Running
	case .Set, .Condition:
		// They end when they start, so they never run.
		result = .Failed
	}
	return settle(b, i, result)
}

// run_children runs a sequence's or a selector's children from its running child, which it enters, or resumes, until
// one runs or ends the node: a sequence ends when a child fails or the last succeeds, a selector when a child succeeds
// or the last fails.
@(private)
run_children :: proc(b: ^Tree, i: u32, entering: bool) -> Result {
	n := b.nodes[i]
	st := state(b, i)
	c := st.child
	result := enter(b, c) if entering else resume(b, c)
	for {
		switch {
		case result == .Running:
			return .Running
		case n.kind == .Sequence && result == .Failed, n.kind == .Selector && result == .Succeeded:
			return result
		}
		c = b.nodes[c].end
		if c >= n.end {
			return .Succeeded if n.kind == .Sequence else .Failed
		}
		st.child = c
		result = enter(b, c)
	}
}

// run_parallel runs a parallel's children that run, entering those that have not started, until its policy ends it,
// and then aborts those that still run.
@(private)
run_parallel :: proc(b: ^Tree, i: u32) -> Result {
	n := b.nodes[i]
	succeeded, failed, running := 0, 0, 0
	ended := false
	result: Result
	for c := i + 1; c < n.end; c = b.nodes[c].end {
		r: Result
		switch state(b, c).status {
		case .Idle:
			r = enter(b, c)
		case .Running, .Again:
			r = resume(b, c)
		case .Succeeded:
			r = .Succeeded
		case .Failed:
			r = .Failed
		}
		switch r {
		case .Running:
			running += 1
		case .Succeeded:
			succeeded += 1
		case .Failed:
			failed += 1
		}
		if n.policy == .One && succeeded > 0 {
			ended, result = true, .Succeeded
		} else if n.policy == .All && failed > 0 {
			ended, result = true, .Failed
		}
		if ended {
			break
		}
	}
	if !ended {
		if running > 0 {
			return .Running
		}
		result = .Failed if n.policy == .One else .Succeeded
	}
	for c := i + 1; c < n.end; c = b.nodes[c].end {
		abort(b, c)
	}
	return result
}

// settle takes the result of a node's kind: a node that repeats starts its kind again when it succeeds, at once or, if
// it started in this think, at the next, and a node that ends finishes.
@(private)
settle :: proc(b: ^Tree, i: u32, result: Result) -> Result {
	n := b.nodes[i]
	if result == .Running {
		return .Running
	}
	st := state(b, i)
	if result == .Succeeded && n.repeat != 0 {
		st.repeats += 1
		if n.repeat == format.TREE_FOREVER || st.repeats < n.repeat {
			if st.entered == b.t.thinks {
				st.status = .Again
				return .Running
			}
			st.entered = b.t.thinks
			return settle(b, i, start(b, i))
		}
	}
	return finish(b, i, result)
}

// finish ends a node that ran with its result, after invert and force, and starts its cooldown.
@(private)
finish :: proc(b: ^Tree, i: u32, result: Result) -> Result {
	n := b.nodes[i]
	final := decorate(n, result)
	state(b, i).status = status_of(final)
	if .Cooldown in n.flags {
		timer(b, i, .Ready_At)^ = b.now + ticks(b, n.cooldown)
	}
	return final
}

// decorate is a result after a node's invert and force.
@(private)
decorate :: proc(n: format.Tree_Node, result: Result) -> Result {
	r := result
	if .Invert in n.flags {
		r = .Failed if r == .Succeeded else .Succeeded
	}
	switch n.force {
	case .None:
	case .Succeed:
		r = .Succeeded
	case .Fail:
		r = .Failed
	}
	return r
}

@(private)
status_of :: proc(r: Result) -> Status {
	switch r {
	case .Running:
		return .Running
	case .Succeeded:
		return .Succeeded
	case .Failed:
	}
	return .Failed
}

// abort stops a node's subtree: each node in it that runs stops, and is idle, with its cooldown started, and an action
// that runs is stopped.
@(private)
abort :: proc(b: ^Tree, i: u32) {
	for j in i ..< b.nodes[i].end {
		st := state(b, j)
		if st.status != .Running && st.status != .Again {
			continue
		}
		n := b.nodes[j]
		if n.kind == .Action && st.status == .Running {
			ai.stop_action(b.t)
		}
		st.status = .Idle
		if .Cooldown in n.flags {
			timer(b, j, .Ready_At)^ = b.now + ticks(b, n.cooldown)
		}
	}
}
