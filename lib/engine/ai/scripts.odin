package ai

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The Blackboard and Agent libraries (see docs/ai/agents.md#scripts). Scripts act and write the blackboard; they do
// not decide. Their writes apply at once, since the script steps are serial, and a write to an agent that is not ready
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
