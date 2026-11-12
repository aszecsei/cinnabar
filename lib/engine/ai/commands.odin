package ai

import "base:runtime"
import "core:log"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// Commands to agents (see docs/ai/agents.md#blackboards): blackboard writes and the actions to start or stop. Decision
// modules, native actions and other systems' jobs record them in their job's list, which the world flushes after the
// tick's Fixed systems, in system order and then job order, and they apply then, in that order. A blackboard therefore
// never depends on the jobs' timing. Scripts write at once, since the script steps are serial.

Command_Kind :: enum u8 {
	// A write to the key at a slot, which a decision's write names.
	Write,
	// A write to the key whose name has the hash in key.
	Write_Named,
	Start,
	Stop,
	// A noise for perception: its source in entity, its position in value, its tag's hash in key, and its loudness in
	// amount.
	Noise,
}

// Command is a command to an agent. agent is its slot when a decision or an action gave it, so a command for a slot
// that went does nothing; zero finds the agent by its entity.
Command :: struct {
	entity: ecs.Entity,
	agent:  Agent_Handle,
	kind:   Command_Kind,
	type:   format.Blackboard_Type,
	// A Write's slot, or a Write_Named's hash.
	key:    u32,
	// A Start's action reference.
	ref:    u32,
	// A Noise's loudness.
	amount: f32,
	value:  [format.BLACKBOARD_VALUE_SIZE]byte,
}

// Enum_Index is an enum key's value, the index of its name.
Enum_Index :: distinct u32

// Value is a blackboard value: a float, an int, a bool, an enum's index, an entity, a position or a vector.
Value :: union {
	f32,
	i32,
	bool,
	Enum_Index,
	ecs.Entity,
	ecs.World_Position,
	[3]f32,
}

// encode is a value's type and bytes, as an agent's values hold them.
encode :: proc(v: Value) -> (type: format.Blackboard_Type, bytes: [format.BLACKBOARD_VALUE_SIZE]byte, ok: bool) {
	put :: proc(bytes: ^[format.BLACKBOARD_VALUE_SIZE]byte, v: $T) {
		(^T)(bytes)^ = v
	}
	switch x in v {
	case f32:
		type = .Float
		put(&bytes, x)
	case i32:
		type = .Int
		put(&bytes, x)
	case bool:
		type = .Bool
		put(&bytes, u8(x))
	case Enum_Index:
		type = .Enum
		put(&bytes, u32(x))
	case ecs.Entity:
		type = .Entity
		put(&bytes, x)
	case ecs.World_Position:
		type = .Position
		put(&bytes, x)
	case [3]f32:
		type = .Vector
		put(&bytes, x)
	case:
		return
	}
	return type, bytes, true
}

// decode is the value of a type in bytes.
decode :: proc(type: format.Blackboard_Type, bytes: []byte) -> Value {
	switch type {
	case .Float:
		return (^f32)(raw_data(bytes))^
	case .Int:
		return (^i32)(raw_data(bytes))^
	case .Bool:
		return bytes[0] != 0
	case .Enum:
		return Enum_Index((^u32)(raw_data(bytes))^)
	case .Entity:
		return (^ecs.Entity)(raw_data(bytes))^
	case .Position:
		return (^ecs.World_Position)(raw_data(bytes))^
	case .Vector:
		return (^[3]f32)(raw_data(bytes))^
	case .String:
	}
	return nil
}

// Writer is where commands are recorded: a system's job's list, which job_writer gives.
Writer :: struct {
	list: ^[dynamic]Command,
}

// job_writer is a system's job's own list, which the world flushes after the tick's Fixed systems in system order and
// then job order.
job_writer :: proc(s: ^State, ctx: ^ecs.System_Context) -> Writer {
	return {job_commands(s, ctx)}
}

// write_key asks to write an agent's key, by its name, from a system's job. A key that the agent's blackboard does not
// have, or of another type, is warned about when the write applies.
write_key :: proc(to: Writer, e: ecs.Entity, key: string, value: Value) {
	type, bytes, ok := encode(value)
	if !ok {
		return
	}
	append(to.list, Command{entity = e, kind = .Write_Named, type = type, key = format.animation_graph_hash(key), value = bytes})
}

// set_key writes an agent's key, by its name, at once, from frame code or a script step. A write to an agent that is
// not ready yet applies when it is.
set_key :: proc(s: ^State, e: ecs.Entity, key: string, value: Value) {
	type, bytes, ok := encode(value)
	if ok {
		apply(s, Command{entity = e, kind = .Write_Named, type = type, key = format.animation_graph_hash(key), value = bytes})
	}
}

// get_key is an agent's key, by its name, or false for an agent that is not ready or a key that its blackboard does not
// have.
get_key :: proc(s: ^State, e: ecs.Entity, key: string) -> (Value, bool) {
	slot, ready := ready_of(s, s.world, e)
	if ready == nil {
		return nil, false
	}
	board, ok := board_of(s, slot.blackboard)
	if !ok {
		return nil, false
	}
	index, found := format.blackboard_find(board.data, board.blob, format.animation_graph_hash(key))
	if !found {
		return nil, false
	}
	k := format.blackboard_keys(board.data, board.blob)[index]
	return decode(k.type, value_bytes(ready.values, k)), true
}

@(private)
job_commands :: proc(s: ^State, ctx: ^ecs.System_Context) -> ^[dynamic]Command {
	return (^[dynamic]Command)(ecs.job_buffer(ctx, s.job_commands))
}

@(private)
make_job_commands :: proc(user: rawptr, allocator: runtime.Allocator) -> rawptr {
	list := new([dynamic]Command, allocator)
	list^ = make([dynamic]Command, allocator)
	return list
}

// flush_job_commands applies the jobs' commands, in system order and then job order.
@(private)
flush_job_commands :: proc(user: rawptr, buffers: []rawptr) {
	s := (^State)(user)
	for b in buffers {
		for c in (^[dynamic]Command)(b) {
			apply(s, c)
		}
	}
}

// apply applies a command to its agent. A write by name to an agent that is not ready yet waits for it to be.
@(private)
apply :: proc(s: ^State, c: Command) {
	w := s.world
	if c.kind == .Noise {
		apply_noise(s, c)
		return
	}
	slot: ^Agent_Slot
	if c.agent != {} {
		slot = slot_of(s, c.agent)
		if slot != nil && slot.entity != c.entity {
			slot = nil
		}
	} else {
		slot, _ = agent_slot(s, w, c.entity)
	}
	if slot == nil {
		if c.kind == .Write_Named && c.agent == {} && ecs.is_alive(w, c.entity) && ecs.has(w, c.entity, Agent) {
			append(&s.early, c)
		}
		return
	}
	ready, is_ready := &slot.phase.(Agent_Ready)
	if !is_ready {
		if c.kind == .Write_Named {
			append(&s.early, c)
		}
		return
	}
	switch c.kind {
	case .Write, .Write_Named:
		board, ok := board_of(s, slot.blackboard)
		if ok {
			apply_write(s, slot, ready, board, c)
		}
	case .Start:
		start_ref(s, slot, ready, c.ref)
	case .Stop:
		set_action(s, slot.entity, ready, nil)
	case .Noise:
	}
}

// apply_write writes a key of an agent's values, checking its type. A write by name finds its key by its hash.
@(private)
apply_write :: proc(s: ^State, slot: ^Agent_Slot, ready: ^Agent_Ready, board: Board, c: Command) {
	keys := format.blackboard_keys(board.data, board.blob)
	index := int(c.key)
	if c.kind == .Write_Named {
		found: bool
		if index, found = format.blackboard_find(board.data, board.blob, c.key); !found {
			log.warnf("ai: entity %v's blackboard has no key of the name written", slot.entity)
			return
		}
	}
	if index >= len(keys) {
		return
	}
	key := keys[index]
	value := c.value
	switch {
	case key.type == c.type:
	case c.type == .String && key.type == .Enum:
		// An enum's name by its hash, from a script's write before the agent was ready.
		hash := (^u32)(&value)^
		found := false
		for n, i in format.blackboard_enum_names(board.data, board.blob)[key.first_enum:][:key.enum_count] {
			if format.animation_graph_hash(format.blob_string(board.data, n)) == hash {
				(^u32)(&value)^ = u32(i)
				found = true
			}
		}
		if !found {
			log.warnf("ai: entity %v's key %s has no value of the name written", slot.entity, format.blob_string(board.data, key.name))
			return
		}
	case convertible(c.type, key.type, false):
		value = convert(c.type, key.type, value)
	case:
		log.warnf("ai: entity %v's key %s is a %v, and the value written is a %v", slot.entity, format.blob_string(board.data, key.name), key.type, c.type)
		return
	}
	copy(value_bytes(ready.values, key), value[:])
}

// start_ref starts a decision's action reference: a native action if one has its name, else a script action if a
// module defined one, else it fails, as prepare warned. The action that runs or starts is left as it is.
@(private)
start_ref :: proc(s: ^State, slot: ^Agent_Slot, ready: ^Agent_Ready, ref: u32) {
	if view := action_view(ready.action); view.ref == ref && view.status == .Running {
		return
	}
	decision, ok := decision_of(s, slot.decision)
	actions := format.decision_actions(decision.data, decision.blob) if ok else nil
	if int(ref) >= len(actions) {
		set_action(s, slot.entity, ready, Action_Done{ref, .Failed})
		return
	}
	a := actions[ref]
	switch {
	case find_native(s, a.hash) != nil:
		set_action(s, slot.entity, ready, Native_Starting{ref})
	case s.scripts != nil && script.action_defined(s.scripts, format.blob_string(decision.data, a.name)):
		set_action(s, slot.entity, ready, Script_Starting{ref})
	case:
		set_action(s, slot.entity, ready, Action_Done{ref, .Failed})
	}
}
