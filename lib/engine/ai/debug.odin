package ai

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// What the editor shows of a running agent (see docs/ai/agents.md#the-editor): its blackboard's values and, for a
// technique whose module has nodes, what each node does.

// Node_Result is how a decision node last ended, for the editor. None is a node that has not ended since the agent
// started. Aborted is a node that its parent or its guard stopped while it ran.
Node_Result :: enum u8 {
	None,
	Succeeded,
	Failed,
	Aborted,
}

// Node_View is a decision node's part in the agent's last think, by its ID in the text: whether it runs, and how it
// last ended.
Node_View :: struct {
	id:      u32,
	running: bool,
	last:    Node_Result,
}

// Key_View is a blackboard key and its value, by name. enum_name is an Enum's name for its value, or "".
Key_View :: struct {
	name:      string,
	type:      format.Blackboard_Type,
	value:     Value,
	enum_name: string,
}

// Agent_Debug is what an agent does, for the editor: its decision, its blackboard's values in slot order, and the
// nodes of its module that run or ended. The strings are the blobs', valid until the next asset poll.
Agent_Debug :: struct {
	decision: format.Guid,
	keys:     []Key_View,
	nodes:    []Node_View,
}

// agent_debug is an entity's agent, from the blobs that the assets have loaded and the agent started with, so the
// editor can read it between frames, when the frame's views are gone. It is false for an agent that is not ready, or
// whose blobs were recooked and have not restarted it. The slices are in the allocator.
agent_debug :: proc(s: ^State, e: ecs.Entity, allocator := context.temp_allocator) -> (debug: Agent_Debug, ok: bool) {
	if s.world == nil || s.assets == nil {
		return {}, false
	}
	slot, ready := ready_of(s, s.world, e)
	if ready == nil {
		return {}, false
	}
	board_data := loaded_data(s, slot.blackboard) or_return
	board := format.blackboard_view(board_data) or_return
	decision_data := loaded_data(s, slot.decision) or_return
	decision := format.decision_view(decision_data) or_return
	if board.header.key != ready.board_key || decision.header.key != ready.decision_key {
		return {}, false
	}
	debug.decision = slot.decision
	keys := format.blackboard_keys(board_data, board)
	debug.keys = make([]Key_View, len(keys), allocator)
	for k, i in keys {
		view := Key_View {
			name  = format.blob_string(board_data, k.name),
			type  = k.type,
			value = decode(k.type, value_bytes(ready.values, k)),
		}
		if index, is_enum := view.value.(Enum_Index); is_enum {
			view.enum_name = format.blackboard_enum_name(board_data, board, k, u32(index))
		}
		debug.keys[i] = view
	}
	module := s.modules[decision.technique]
	if module.nodes != nil {
		debug.nodes = module.nodes(Decision{data = decision_data, blob = decision}, ready.state, allocator)
	}
	return debug, true
}

// native_actions is the registered native actions, with their parameters, for the editor.
native_actions :: proc(s: ^State) -> []Native_Action {
	return s.natives[:s.native_count]
}

@(private)
loaded_data :: proc(s: ^State, guid: format.Guid) -> (data: []byte, ok: bool) {
	handle := asset.find(s.assets, guid) or_return
	return asset.data(s.assets, handle)
}
