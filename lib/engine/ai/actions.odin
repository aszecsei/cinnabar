package ai

import "core:log"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// Actions (see docs/ai/agents.md#actions). An action is started with its arguments, ticked, and stopped: each tick it
// is running, or it succeeded or failed, and then it is stopped. It is stopped too when its agent's decision starts
// another, stops it, or goes. Native actions are registered by name in register_world, and run in the ai actions
// system, after the decisions, on jobs by chunks. Script actions are Luau classes, which run in the scripts' fixed step,
// in the order of the agents' slots.

// Param is a native action's parameter: its name, and the type of value that it takes.
Param :: struct {
	name: string,
	type: format.Blackboard_Type,
}

// Native_Action is an action in Odin. start and stop are optional; an action without a tick succeeds when it starts.
// Each runs on a job for its agent: it reads the world, writes the blackboard and other components through a Writer
// or the system's buffers, and keeps what it needs between ticks in its state, state_size bytes up to
// MAX_ACTION_STATE, zero when it starts. data is what its procedures get as Action_Context.data, such as the state of
// the package that registers it, which they cannot otherwise find.
Native_Action :: struct {
	name:       string,
	params:     []Param,
	state_size: int,
	start:      proc(a: ^Action_Context),
	tick:       proc(a: ^Action_Context) -> Action_Status,
	stop:       proc(a: ^Action_Context),
	data:       rawptr,
	hash:       u32,
}

// Arg is an argument that an action starts with, of its parameter's type. text is a String's, which is valid only in
// start.
Arg :: struct {
	hash:  u32,
	type:  format.Blackboard_Type,
	value: [format.BLACKBOARD_VALUE_SIZE]byte,
	text:  string,
}

// Action_Context is what a native action's start, tick and stop get. args are the action's arguments in start only,
// and nil in tick and stop. In stop, the agent may be gone.
Action_Context :: struct {
	system: ^ecs.System_Context,
	world:  ^ecs.World,
	entity: ecs.Entity,
	args:   []Arg,
	state:  []byte,
	// The agent's values and blackboard, which get reads. nil in stop.
	values: []byte,
	board:  Board,
	// The tick's length in seconds.
	dt:     f32,
	out:    Writer,
	// The native action's data.
	data:   rawptr,
}

// register_action registers a native action by its name, which decisions name it by. Call it in register_world, after
// register, so a code reload makes the list again.
register_action :: proc(s: ^State, action: Native_Action) {
	a := action
	a.hash = format.animation_graph_hash(a.name)
	switch {
	case s.native_count == MAX_NATIVE_ACTIONS:
		log.errorf("ai: more than %d native actions", MAX_NATIVE_ACTIONS)
	case a.state_size > MAX_ACTION_STATE:
		log.errorf("ai: the native action %s keeps %d bytes, more than %d", a.name, a.state_size, MAX_ACTION_STATE)
	case len(a.params) > MAX_ACTION_PARAMS:
		log.errorf("ai: the native action %s has more than %d parameters", a.name, MAX_ACTION_PARAMS)
	case find_native(s, a.hash) != nil:
		log.errorf("ai: another native action has the name %s, or its hash", a.name)
	case:
		// The parameters are copied, so a caller may give a slice of its own stack.
		params := s.native_params[s.native_count][:len(a.params)]
		copy(params, a.params)
		a.params = params
		s.natives[s.native_count] = a
		s.native_count += 1
	}
}

@(private)
find_native :: proc(s: ^State, hash: u32) -> ^Native_Action {
	for &a in s.natives[:s.native_count] {
		if a.hash == hash {
			return &a
		}
	}
	return nil
}

// arg is an argument of a native action's start by its parameter's name, as a Value. A String is arg_text's.
arg :: proc(a: ^Action_Context, name: string) -> (Value, bool) {
	hash := format.animation_graph_hash(name)
	for x in a.args {
		if x.hash == hash && x.type != .String {
			value := x.value
			return decode(x.type, value[:]), true
		}
	}
	return nil, false
}

// arg_text is a String argument of a native action's start by its parameter's name.
arg_text :: proc(a: ^Action_Context, name: string) -> (string, bool) {
	hash := format.animation_graph_hash(name)
	for x in a.args {
		if x.hash == hash && x.type == .String {
			return x.text, true
		}
	}
	return "", false
}

// get is a key of the agent's blackboard by its name, as it is in this tick.
get :: proc(a: ^Action_Context, name: string) -> (Value, bool) {
	return get_hashed(a, format.animation_graph_hash(name))
}

// get_hashed is a key of the agent's blackboard by its name's hash, as format.animation_graph_hash gives it, for an
// action that keeps a key's name past its start, where String arguments end.
get_hashed :: proc(a: ^Action_Context, hash: u32) -> (Value, bool) {
	if a.values == nil {
		return nil, false
	}
	slot, found := format.blackboard_find(a.board.data, a.board.blob, hash)
	if !found {
		return nil, false
	}
	key := format.blackboard_keys(a.board.data, a.board.blob)[slot]
	return decode(key.type, value_bytes(a.values, key)), true
}

// convertible is whether an argument of a type fits a parameter of a type: the same type, a number for a number, or a
// vector constant for a position, in meters.
@(private)
convertible :: proc(from, to: format.Blackboard_Type, constant: bool) -> bool {
	return from == to || (from == .Float && to == .Int) || (from == .Int && to == .Float) || (constant && from == .Vector && to == .Position)
}

// convert gives an argument's bytes as a parameter's type.
@(private)
convert :: proc(from, to: format.Blackboard_Type, value: [format.BLACKBOARD_VALUE_SIZE]byte) -> (result: [format.BLACKBOARD_VALUE_SIZE]byte) {
	value := value
	switch {
	case from == .Float && to == .Int:
		(^i32)(&result)^ = i32((^f32)(&value)^)
	case from == .Int && to == .Float:
		(^f32)(&result)^ = f32((^i32)(&value)^)
	case from == .Vector && to == .Position:
		(^ecs.World_Position)(&result)^ = ecs.position_offset({}, (^[3]f32)(&value)^)
	case:
		result = value
	}
	return
}

// arg_value is an action reference's argument's value now: a constant, a key's value, or the agent.
@(private)
arg_value :: proc(decision: Decision, board: Board, values: []byte, e: ecs.Entity, a: format.Decision_Arg) -> (bytes: [format.BLACKBOARD_VALUE_SIZE]byte, text: string) {
	switch a.source {
	case .Constant:
		c := format.decision_constants(decision.data, decision.blob)[a.index]
		return c.value, format.blob_string(decision.data, c.text)
	case .Key:
		key := format.blackboard_keys(board.data, board.blob)[a.index]
		copy(bytes[:], value_bytes(values, key))
		if key.type == .Enum {
			text = format.blackboard_enum_name(board.data, board.blob, key, (^u32)(&bytes)^)
		}
	case .Self:
		(^ecs.Entity)(&bytes)^ = e
	}
	return
}

// check_actions warns, once for each version of a decision, about its action references that no native or script
// action has, and about arguments that a native action has no parameter for or that are of another type.
@(private)
check_actions :: proc(s: ^State, decision: Decision) {
	args := format.decision_args(decision.data, decision.blob)
	path := format.blob_string(decision.data, decision.blob.source_path)
	for a in format.decision_actions(decision.data, decision.blob) {
		name := format.blob_string(decision.data, a.name)
		native := find_native(s, a.hash)
		if native == nil {
			if s.scripts == nil || !script.action_defined(s.scripts, name) {
				log.warnf("ai: %s starts the action %s, which no native action or script defines, so it fails", path, name)
			}
			continue
		}
		for arg in args[a.first_arg:][:a.arg_count] {
			arg_name := format.blob_string(decision.data, arg.name)
			param: Maybe(Param)
			for p in native.params {
				if format.animation_graph_hash(p.name) == arg.hash {
					param = p
				}
			}
			if p, has := param.?; !has {
				log.warnf("ai: %s gives the action %s the argument %s, which it has no parameter for", path, name, arg_name)
			} else if !convertible(arg.type, p.type, arg.source == .Constant) {
				log.warnf("ai: %s gives the action %s's parameter %s a %v, and it takes a %v", path, name, arg_name, arg.type, p.type)
			}
		}
	}
}

// native_args are a native action's arguments for its start, for each of its parameters that the reference gives,
// as the parameter's type.
@(private)
native_args :: proc(native: ^Native_Action, decision: Decision, board: Board, values: []byte, e: ecs.Entity, a: format.Decision_Action, allocator := context.allocator) -> []Arg {
	result := make([dynamic]Arg, 0, len(native.params), allocator)
	args := format.decision_args(decision.data, decision.blob)[a.first_arg:][:a.arg_count]
	for p in native.params {
		hash := format.animation_graph_hash(p.name)
		for x in args {
			if x.hash == hash && convertible(x.type, p.type, x.source == .Constant) {
				bytes, text := arg_value(decision, board, values, e, x)
				append(&result, Arg{hash = hash, type = p.type, value = convert(x.type, p.type, bytes), text = text})
			}
		}
	}
	return result[:]
}

// actions_system is the ai actions system: on jobs by chunks of agents, it starts the native actions that the last
// tick's decisions chose, and ticks those that run. A job writes only its own agents' actions.
@(private)
actions_system :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	w := ctx.world
	it := ecs.query_iter(w, ctx.query, ctx.first_chunk, ctx.chunk_count)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		for state, row in ecs.column(view, 0, Agent_State) {
			slot := slot_of(s, state.agent)
			if slot == nil || slot.entity != entities[row] {
				continue
			}
			if ready, ok := &slot.phase.(Agent_Ready); ok {
				run_native(s, ctx, slot, ready)
			}
		}
	}
}

@(private)
run_native :: proc(s: ^State, ctx: ^ecs.System_Context, slot: ^Agent_Slot, ready: ^Agent_Ready) {
	board, board_ok := board_of(s, slot.blackboard)
	decision, decision_ok := decision_of(s, slot.decision)
	if !board_ok || !decision_ok {
		return
	}
	a := Action_Context {
		system = ctx,
		world  = ctx.world,
		entity = slot.entity,
		values = ready.values,
		board  = board,
		dt     = ctx.dt,
		out    = job_writer(s, ctx),
	}
	native: ^Native_Action
	#partial switch p in ready.action {
	case Native_Starting:
		ref := format.decision_actions(decision.data, decision.blob)[p.ref]
		native = find_native(s, ref.hash)
		if native == nil {
			ready.action = Action_Done{p.ref, .Failed}
			return
		}
		ready.action = Native_Running{ref = p.ref, hash = ref.hash}
		running := &ready.action.(Native_Running)
		a.state = running.memory[:native.state_size]
		a.data = native.data
		a.args = native_args(native, decision, board, ready.values, slot.entity, ref, ctx.world.platform.frame_allocator)
		if native.start != nil {
			native.start(&a)
		}
		a.args = nil
	case Native_Running:
		native = find_native(s, p.hash)
		if native == nil {
			// The action went with a code reload, so it cannot be stopped.
			ready.action = Action_Done{p.ref, .Failed}
			return
		}
	case:
		return
	}
	running := &ready.action.(Native_Running)
	a.state = running.memory[:native.state_size]
	a.data = native.data
	status := native.tick(&a) if native.tick != nil else .Succeeded
	if status == .Running {
		return
	}
	if native.stop != nil {
		native.stop(&a)
	}
	ready.action = Action_Done{running.ref, status}
}

// stop_native_endings stops the native actions that were replaced or whose agents went, in the order that they ended.
@(private)
stop_native_endings :: proc(s: ^State, ctx: ^ecs.System_Context) {
	for &e in s.ending_native {
		run := &e.run.(Native_Running)
		native := find_native(s, run.hash)
		if native == nil || native.stop == nil {
			continue
		}
		a := Action_Context {
			system = ctx,
			world  = ctx.world,
			entity = e.entity,
			state  = run.memory[:native.state_size],
			dt     = ctx.dt,
			out    = job_writer(s, ctx),
			data   = native.data,
		}
		native.stop(&a)
	}
	clear(&s.ending_native)
}

// run_script_actions is the scripts' fixed hook: it stops the script actions that ended, then, in the order of the
// agents' slots, starts those that the decisions chose and ticks those that run.
@(private)
run_script_actions :: proc(r: ^script.Runtime, data: rawptr) {
	s := (^State)(data)
	for e in s.ending_script {
		script.stop_action(r, e.run.(Script_Running).handle)
	}
	clear(&s.ending_script)
	dt := 1 / f64(s.world.clock.tick_rate)
	for &slot in s.agents.slots {
		// An agent that a script despawned in this step keeps its slot until the next think, but does not act.
		ready, ok := &slot.phase.(Agent_Ready)
		if !ok || !ecs.is_alive(s.world, slot.entity) || ecs.has(s.world, slot.entity, ecs.Inactive) {
			continue
		}
		#partial switch p in ready.action {
		case Script_Starting:
			board, board_ok := board_of(s, slot.blackboard)
			decision, decision_ok := decision_of(s, slot.decision)
			if !board_ok || !decision_ok {
				continue
			}
			ref := format.decision_actions(decision.data, decision.blob)[p.ref]
			args := script_args(decision, board, ready.values, slot.entity, ref, s.platform.frame_allocator)
			handle, status := script.start_action(r, format.blob_string(decision.data, ref.name), slot.entity, args)
			if status != .Running {
				ready.action = Action_Done{p.ref, .Failed}
				continue
			}
			ready.action = Script_Running{p.ref, handle}
		case Script_Running:
		case:
			continue
		}
		running := ready.action.(Script_Running)
		status := script.tick_action(r, running.handle, dt)
		if status != .Running {
			script.stop_action(r, running.handle)
			ready.action = Action_Done{running.ref, status}
		}
	}
}

// script_args are a script action's arguments, as Luau takes them: a number for a float or an int, an enum's name, and
// the rest as they are.
@(private)
script_args :: proc(decision: Decision, board: Board, values: []byte, e: ecs.Entity, a: format.Decision_Action, allocator := context.allocator) -> []script.Action_Arg {
	args := format.decision_args(decision.data, decision.blob)[a.first_arg:][:a.arg_count]
	result := make([]script.Action_Arg, len(args), allocator)
	for x, i in args {
		bytes, text := arg_value(decision, board, values, e, x)
		value: script.Action_Value
		switch x.type {
		case .Float:
			value = f64((^f32)(&bytes)^)
		case .Int:
			value = f64((^i32)(&bytes)^)
		case .Bool:
			value = bytes[0] != 0
		case .Enum, .String:
			value = text
		case .Entity:
			value = (^ecs.Entity)(&bytes)^
		case .Position:
			value = (^ecs.World_Position)(&bytes)^
		case .Vector:
			value = (^[3]f32)(&bytes)^
		}
		result[i] = {format.blob_string(decision.data, x.name), value}
	}
	return result
}
