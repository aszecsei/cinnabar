package editor

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:strings"

import "cinnabar:engine/ai"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"

#assert(len(format.Blackboard_Type) == len(link.Agent_Kind))
#assert(int(format.Blackboard_Type.String) == int(link.Agent_Kind.String))
#assert(int(ai.Node_Result.Aborted) == int(link.Agent_Result.Aborted))

// agent_view is what an entity's Agent does: empty but for the entity without one, or before it is ready.
@(private = "file")
agent_view :: proc(e: ^Editor, entity: ecs.Entity, allocator: runtime.Allocator) -> (view: link.Agent_View) {
	view.entity = u64(entity)
	if e.ai == nil {
		return
	}
	debug, ok := ai.agent_debug(e.ai, entity, allocator)
	if !ok {
		return
	}
	view.decision = ([16]u8)(debug.decision)
	view.nodes = make([]link.Agent_Node, len(debug.nodes), allocator)
	for n, i in debug.nodes {
		view.nodes[i] = {id = n.id, running = n.running, last = link.Agent_Result(n.last)}
	}
	view.values = make([]link.Agent_Value, len(debug.keys), allocator)
	for k, i in debug.keys {
		view.values[i] = {name = k.name, kind = link.Agent_Kind(k.type), text = value_text(k, allocator)}
	}
	return
}

// value_text is a key's value as the editor shows it.
@(private = "file")
value_text :: proc(k: ai.Key_View, allocator: runtime.Allocator) -> string {
	switch v in k.value {
	case f32:
		return number_text(f64(v), allocator)
	case i32:
		return fmt.aprintf("%d", v, allocator = allocator)
	case bool:
		return "true" if v else "false"
	case ai.Enum_Index:
		return k.enum_name
	case ecs.Entity:
		if v == 0 {
			return "none"
		}
		return fmt.aprintf("#%d:%d", ecs.entity_index(v), ecs.entity_generation(v), allocator = allocator)
	case ecs.World_Position:
		return triple_text(ecs.position_to_meters(v), allocator)
	case [3]f32:
		return triple_text({f64(v.x), f64(v.y), f64(v.z)}, allocator)
	}
	return ""
}

// number_text is a number with up to three decimals.
@(private = "file")
number_text :: proc(v: f64, allocator: runtime.Allocator) -> string {
	text := fmt.aprintf("%.3f", v, allocator = allocator)
	if strings.contains_rune(text, '.') {
		text = strings.trim_right(strings.trim_right(text, "0"), ".")
	}
	return "0" if text == "-0" else text
}

@(private = "file")
triple_text :: proc(v: [3]f64, allocator: runtime.Allocator) -> string {
	return fmt.aprintf("[%s, %s, %s]", number_text(v.x, allocator), number_text(v.y, allocator), number_text(v.z, allocator), allocator = allocator)
}

// send_agents sends the view of each watched entity's Agent that changed since the editor last got it: the first after a
// watch, whatever it is, so the editor drops a view that it kept from an earlier watch, then one empty view for an Agent
// that has gone, so the editor keeps no old state.
@(private)
send_agents :: proc(e: ^Editor, out: ^[dynamic]byte, allocator: runtime.Allocator) {
	for &watched in e.session.watched {
		view := agent_view(e, watched.entity, allocator)
		encoded := make([dynamic]byte, allocator)
		link.write_message(&encoded, view)
		// 0 is the empty view's, so a real 0 counts as 1.
		h := view.decision == {} ? 0 : max(hash.fnv64a(encoded[link.HEADER_SIZE:]), 1)
		if sent, ok := watched.agent_sent.?; !ok || sent != h {
			watched.agent_sent = h
			append(out, ..encoded[:])
		}
	}
}

// agent_actions is the game's native actions, with their parameters.
@(private)
agent_actions :: proc(e: ^Editor, allocator: runtime.Allocator) -> link.Agent_Actions {
	if e.ai == nil {
		return {}
	}
	natives := ai.native_actions(e.ai)
	actions := make([]link.Agent_Action_Info, len(natives), allocator)
	for n, i in natives {
		params := make([]link.Agent_Action_Param, len(n.params), allocator)
		for p, j in n.params {
			params[j] = {name = p.name, kind = link.Agent_Kind(p.type)}
		}
		actions[i] = {name = n.name, params = params}
	}
	return {actions = actions}
}
