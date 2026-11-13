package ai

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The Blackboard, Agent and Perception libraries (see docs/ai/agents.md#scripts and docs/ai/perception.md#scripts).
// Scripts act, write the blackboard and make noises; they do not decide. Their writes apply at once, since the script steps are serial, and a write to an agent that is not ready
// yet, as an awake's is, applies when it is.

@(private = "file")
STATE_KEY :: "cinnabar.ai"

// register_scripts defines the libraries and sets the scripts' fixed hook, which runs the script actions. Call it in
// the game's script registration, so a reload defines them again. It does not write s, which the runtime that writes
// the definitions file has none of.
register_scripts :: proc(r: ^script.Runtime, s: ^State) {
	luau.pushlightuserdata(r.L, s)
	luau.setfield(r.L, luau.REGISTRYINDEX, STATE_KEY)
	script.set_fixed_hook(r, {run_script_actions, s})
	script.define(r, "Blackboard.get", proc(L: ^luau.State) -> c.int {
		s := state_of(L)
		e, name := agent_args(L, s)
		slot, ready := ready_of(s, s.world, e)
		if ready == nil {
			luau.pushnil(L)
			return 1
		}
		board, _ := board_of(s, slot.blackboard)
		key := key_of(L, board, name)
		bytes := value_bytes(ready.values, key)
		switch key.type {
		case .Float:
			luau.pushnumber(L, f64((^f32)(raw_data(bytes))^))
		case .Int:
			luau.pushnumber(L, f64((^i32)(raw_data(bytes))^))
		case .Bool:
			luau.pushboolean(L, b32(bytes[0] != 0))
		case .Enum:
			luau.pushodinstring(L, format.blackboard_enum_name(board.data, board.blob, key, (^u32)(raw_data(bytes))^))
		case .Entity:
			script.push_entity(L, (^ecs.Entity)(raw_data(bytes))^)
		case .Position:
			script.push_position(L, (^ecs.World_Position)(raw_data(bytes))^)
		case .Vector:
			script.push_vector(L, (^[3]f32)(raw_data(bytes))^)
		case .String:
			luau.pushnil(L)
		}
		return 1
	}, "(entity: Entity, key: string) -> any")
	script.define(r, "Blackboard.set", proc(L: ^luau.State) -> c.int {
		s := state_of(L)
		e, name := agent_args(L, s)
		slot, ready := ready_of(s, s.world, e)
		board: Board
		board_ok := false
		if slot != nil {
			board, board_ok = board_of(s, slot.blackboard)
		}
		c := Command {
			entity = e,
			kind   = .Write_Named,
			key    = format.animation_graph_hash(name),
		}
		if ready == nil || !board_ok {
			// The agent is not ready, so the write waits for it, and its key's type is found then: a number is a float,
			// and a string an enum's name, by its hash.
			if luau.type(L, 3) == .STRING {
				c.type = .String
				(^u32)(&c.value)^ = format.animation_graph_hash(string(luau.L_checkstring(L, 3)))
			} else if value, ok := value_arg(L, 3); ok {
				c.type, c.value, _ = encode(value)
			} else {
				script.raise(L, "Blackboard.set takes a number, a boolean, an enum's name, an Entity, a WorldPosition or a vector")
			}
			append(&s.early, c)
			return 0
		}
		key := key_of(L, board, name)
		bytes: [format.BLACKBOARD_VALUE_SIZE]byte
		put :: proc(bytes: ^[format.BLACKBOARD_VALUE_SIZE]byte, v: $T) {
			(^T)(bytes)^ = v
		}
		switch key.type {
		case .Float:
			put(&bytes, f32(luau.L_checknumber(L, 3)))
		case .Int:
			put(&bytes, i32(luau.L_checknumber(L, 3)))
		case .Bool:
			put(&bytes, u8(luau.L_checkboolean(L, 3)))
		case .Enum:
			value := string(luau.L_checkstring(L, 3))
			found := false
			names := format.blackboard_enum_names(board.data, board.blob)[key.first_enum:][:key.enum_count]
			for n, i in names {
				if format.blob_string(board.data, n) == value {
					put(&bytes, u32(i))
					found = true
				}
			}
			if !found {
				script.raise(L, fmt.tprintf("%s is not one of the enum %s's values", value, name))
			}
		case .Entity:
			put(&bytes, luau.isnil(L, 3) ? ecs.Entity(0) : script.check_entity(L, 3))
		case .Position:
			put(&bytes, script.check_position(L, 3))
		case .Vector:
			put(&bytes, script.check_vector(L, 3))
		case .String:
		}
		c.type, c.value = key.type, bytes
		apply_write(s, slot, ready, board, c)
		return 0
	}, "(entity: Entity, key: string, value: any) -> ()")
	script.define(r, "Agent.current_action", proc(L: ^luau.State) -> c.int {
		s := state_of(L)
		e := script.check_entity(L, 1)
		if !ecs.is_alive(s.world, e) || !ecs.has(s.world, e, Agent) {
			script.raise(L, "the entity has no Agent")
		}
		name := current_action(s, e)
		if name == "" {
			luau.pushnil(L)
		} else {
			luau.pushodinstring(L, name)
		}
		return 1
	}, "(entity: Entity) -> string?")
	script.define(r, "Agent.scores", proc(L: ^luau.State) -> c.int {
		s := state_of(L)
		e := script.check_entity(L, 1)
		if !ecs.is_alive(s.world, e) || !ecs.has(s.world, e, Agent) {
			script.raise(L, "the entity has no Agent")
		}
		options, ok := scores(s, e, context.temp_allocator)
		if !ok {
			luau.pushnil(L)
			return 1
		}
		luau.createtable(L, c.int(len(options)), 0)
		for o, i in options {
			luau.createtable(L, 0, 5)
			luau.pushnumber(L, f64(o.id))
			luau.setfield(L, -2, "option")
			luau.pushodinstring(L, o.action)
			luau.setfield(L, -2, "action")
			luau.pushnumber(L, f64(o.score))
			luau.setfield(L, -2, "score")
			if o.target != 0 {
				script.push_entity(L, o.target)
				luau.setfield(L, -2, "target")
			}
			luau.createtable(L, c.int(len(o.considerations)), 0)
			for cs, k in o.considerations {
				luau.createtable(L, 0, 3)
				luau.pushnumber(L, f64(cs.id))
				luau.setfield(L, -2, "consideration")
				luau.pushnumber(L, f64(cs.input))
				luau.setfield(L, -2, "input")
				luau.pushnumber(L, f64(cs.score))
				luau.setfield(L, -2, "score")
				luau.rawseti(L, -2, c.int(k + 1))
			}
			luau.setfield(L, -2, "considerations")
			luau.rawseti(L, -2, c.int(i + 1))
		}
		return 1
	}, "(entity: Entity) -> { { option: number, action: string, score: number, target: Entity?, considerations: { { consideration: number, input: number, score: number } } } }?")
	script.define(r, "Agent.plan", proc(L: ^luau.State) -> c.int {
		s := state_of(L)
		e := script.check_entity(L, 1)
		if !ecs.is_alive(s.world, e) || !ecs.has(s.world, e, Agent) {
			script.raise(L, "the entity has no Agent")
		}
		view, ok := plan(s, e, context.temp_allocator)
		if !ok {
			luau.pushnil(L)
			return 1
		}
		luau.createtable(L, 0, 6)
		if view.goal != 0 {
			luau.pushnumber(L, f64(view.goal))
			luau.setfield(L, -2, "goal")
		}
		luau.createtable(L, c.int(len(view.goals)), 0)
		for g, i in view.goals {
			luau.createtable(L, 0, 2)
			luau.pushnumber(L, f64(g.id))
			luau.setfield(L, -2, "goal")
			luau.pushnumber(L, f64(g.priority))
			luau.setfield(L, -2, "priority")
			luau.rawseti(L, -2, c.int(i + 1))
		}
		luau.setfield(L, -2, "goals")
		luau.createtable(L, c.int(len(view.steps)), 0)
		for step, i in view.steps {
			luau.createtable(L, 0, 2)
			luau.pushnumber(L, f64(step.id))
			luau.setfield(L, -2, "node")
			luau.pushodinstring(L, step.action)
			luau.setfield(L, -2, "action")
			luau.rawseti(L, -2, c.int(i + 1))
		}
		luau.setfield(L, -2, "steps")
		// From 1, as Luau counts.
		luau.pushnumber(L, f64(view.step + 1))
		luau.setfield(L, -2, "step")
		luau.pushnumber(L, f64(view.nodes))
		luau.setfield(L, -2, "nodes")
		luau.pushboolean(L, b32(view.searching))
		luau.setfield(L, -2, "searching")
		return 1
	}, "(entity: Entity) -> { goal: number?, goals: { { goal: number, priority: number } }, steps: { { node: number, action: string } }, step: number, nodes: number, searching: boolean }?")
	script.define(r, "Perception.noise", proc(L: ^luau.State) -> c.int {
		s := state_of(L)
		position := script.check_position(L, 1)
		loudness := f32(luau.L_checknumber(L, 2))
		tag := string(luau.L_checkstring(L, 3))
		source: ecs.Entity
		if !luau.isnoneornil(L, 4) {
			source = script.check_entity(L, 4)
		}
		if _, found := tag_index(s.tags, tag); !found {
			script.raise(L, fmt.tprintf("there is no tag %q: perception.tags names the project's", tag))
		}
		noise(s, position, loudness, tag, source)
		return 0
	}, "(position: WorldPosition, loudness: number, tag: string, source: Entity?) -> ()")
}

// current_action is the name of the action that an agent runs or starts, or "".
current_action :: proc(s: ^State, e: ecs.Entity) -> string {
	slot, ready := ready_of(s, s.world, e)
	if ready == nil {
		return ""
	}
	view := action_view(ready.action)
	decision, ok := decision_of(s, slot.decision)
	actions := format.decision_actions(decision.data, decision.blob) if ok else nil
	if view.status != .Running || int(view.ref) >= len(actions) {
		return ""
	}
	return format.blob_string(decision.data, actions[view.ref].name)
}

@(private = "file")
state_of :: proc(L: ^luau.State) -> ^State {
	luau.getfield(L, luau.REGISTRYINDEX, STATE_KEY)
	s := (^State)(luau.tolightuserdata(L, -1))
	luau.pop(L, 1)
	return s
}

// agent_args reads an entity with an Agent and a key's name.
@(private = "file")
agent_args :: proc(L: ^luau.State, s: ^State) -> (ecs.Entity, string) {
	e := script.check_entity(L, 1)
	if !ecs.is_alive(s.world, e) || !ecs.has(s.world, e, Agent) {
		script.raise(L, "the entity has no Agent")
	}
	return e, string(luau.L_checkstring(L, 2))
}

// key_of is the key of a name, which raises an error for a name that the blackboard does not have.
@(private = "file")
key_of :: proc(L: ^luau.State, board: Board, name: string) -> format.Blackboard_Key {
	slot, found := format.blackboard_find(board.data, board.blob, format.animation_graph_hash(name))
	if !found {
		script.raise(L, fmt.tprintf("the agent's blackboard has no key %s", name))
	}
	return format.blackboard_keys(board.data, board.blob)[slot]
}

// value_arg reads a value whose key's type is not known yet, other than a string: a number is a float, and nil an
// entity that is none.
@(private = "file")
value_arg :: proc(L: ^luau.State, idx: c.int) -> (Value, bool) {
	#partial switch luau.type(L, idx) {
	case .NUMBER:
		return f32(luau.tonumber(L, idx)), true
	case .BOOLEAN:
		return bool(luau.toboolean(L, idx)), true
	case .VECTOR:
		return script.check_vector(L, idx), true
	case .NIL:
		return ecs.Entity(0), true
	case .LIGHTUSERDATA:
		return script.check_entity(L, idx), true
	case .USERDATA:
		if p, ok := script.to_position(L, idx); ok {
			return p, true
		}
	}
	return nil, false
}
