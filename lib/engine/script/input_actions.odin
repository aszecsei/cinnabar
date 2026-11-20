package script

import "core:c"
import "core:fmt"

import "cinnabar:core"
import "cinnabar:core/luau"

// register_input_actions defines the Input functions of the named actions. The actions are in r.input_actions, which
// holds no strings or pointers, so the scripts that define them run again after a reload and keep what the player set.
@(private)
register_input_actions :: proc(r: ^Runtime) {
	define(r, "Input.define_action", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		name := check_action_name(L, 1)
		luau.L_checktype(L, 2, .TABLE)
		bindings: [core.MAX_ACTION_BINDINGS]core.Binding
		count := read_bindings(L, 2, &bindings)
		if _, ok := core.input_actions_define(&r.input_actions, name, bindings[:count]); !ok {
			if len(name) == 0 || len(name) > core.INPUT_ACTION_NAME_CAPACITY {
				luau.L_errorL(
					L,
					"an action name of 1 to %d bytes expected",
					c.int(core.INPUT_ACTION_NAME_CAPACITY),
				)
			}
			luau.L_errorL(L, "no room for more than %d actions", c.int(core.MAX_INPUT_ACTIONS))
		}
		return 0
	})
	define(r, "Input.action_down", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		index, pad := check_action_and_pad(L)
		luau.pushboolean(L, b32(core.action_down(&r.input_actions, &r.input, index, pad)))
		return 1
	})
	define(r, "Input.action_pressed", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		index, pad := check_action_and_pad(L)
		luau.pushboolean(L, b32(core.action_pressed(&r.input_actions, &r.input, index, pad)))
		return 1
	})
	define(r, "Input.action_released", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		index, pad := check_action_and_pad(L)
		luau.pushboolean(L, b32(core.action_released(&r.input_actions, &r.input, index, pad)))
		return 1
	})
	define(r, "Input.action_value", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		index, pad := check_action_and_pad(L)
		luau.pushnumber(L, f64(core.action_value(&r.input_actions, &r.input, index, pad)))
		return 1
	})
	define(r, "Input.bindings", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		action := &r.input_actions.items[check_action(L, 1)]
		luau.createtable(L, c.int(action.current_count), 0)
		for b, i in action.current[:action.current_count] {
			buffer: [core.BINDING_FORMAT_CAPACITY]u8
			luau.pushodinstring(L, core.binding_format(b, buffer[:]))
			luau.rawseti(L, -2, c.int(i + 1))
		}
		return 1
	})
	define(r, "Input.set_bindings", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		index := check_action(L, 1)
		luau.L_checktype(L, 2, .TABLE)
		bindings: [core.MAX_ACTION_BINDINGS]core.Binding
		count := read_bindings(L, 2, &bindings)
		core.input_actions_set(&r.input_actions, index, bindings[:count])
		return 0
	})
	define(r, "Input.reset_bindings", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		if luau.isnoneornil(L, 1) {
			for i in 0 ..< r.input_actions.count {
				core.input_actions_reset(&r.input_actions, i)
			}
		} else {
			core.input_actions_reset(&r.input_actions, check_action(L, 1))
		}
		return 0
	})
	define(r, "Input.any_pressed", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		devices: core.Input_Devices = {.Keyboard, .Gamepad}
		if !luau.isnoneornil(L, 1) {
			switch string(luau.L_checkstring(L, 1)) {
			case "keyboard":
				devices = {.Keyboard}
			case "gamepad":
				devices = {.Gamepad}
			case:
				luau.L_argerrorL(L, 1, "\"keyboard\" or \"gamepad\" expected")
			}
		}
		binding, ok := core.any_pressed(&r.input, devices)
		if !ok {
			luau.pushnil(L)
			return 1
		}
		buffer: [core.BINDING_FORMAT_CAPACITY]u8
		luau.pushodinstring(L, core.binding_format(binding, buffer[:]))
		return 1
	})
	define(r, "Input.define_context", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		name := check_action_name(L, 1)
		contexts := &r.input_actions.contexts
		mode := core.Input_Context_Mode.Only
		allows: core.Input_Action_Set
		if luau.type(L, 2) == .STRING && luau.toodinstring(L, 2) == "all" {
			mode = .All
		} else {
			if luau.type(L, 2) != .TABLE {
				luau.L_argerrorL(L, 2, "a table of action names or \"all\" expected")
			}
			for i in 1 ..= int(luau.objlen(L, 2)) {
				luau.rawgeti(L, 2, c.int(i))
				if luau.type(L, -1) != .STRING {
					luau.L_errorL(L, "action %d is not a string", c.int(i))
				}
				allows += {check_action(L, -1)}
				luau.pop(L, 1)
			}
			if luau.toboolean(L, 3) {
				mode = .Pass
			}
		}
		switch _, err := core.input_contexts_define(contexts, name, mode, allows); err {
		case .None:
		case .Name:
			luau.L_errorL(
				L,
				"a context name of 1 to %d bytes expected",
				c.int(core.INPUT_ACTION_NAME_CAPACITY),
			)
		case .Gameplay:
			luau.L_errorL(L, "the gameplay context allows every action and cannot be defined")
		case .Full:
			luau.L_errorL(L, "no room for more than %d contexts", c.int(core.MAX_INPUT_CONTEXTS))
		}
		return 0
	})
	define(r, "Input.push_context", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		contexts := &r.input_actions.contexts
		name := check_action_name(L, 1)
		index := core.input_contexts_find(contexts, name)
		if index < 0 {
			luau.L_errorL(L, "unknown input context '%.*s'", c.int(len(name)), raw_data(name))
		}
		players := core.EVERY_PLAYER
		if !luau.isnoneornil(L, 2) {
			players = {check_pad(L, 2)}
		}
		owner, pusher := running_owner(r, L)
		token := core.input_contexts_push(contexts, index, players, pusher, owner)
		if token == 0 {
			luau.L_errorL(
				L,
				"no room for more than %d input context pushes",
				c.int(core.MAX_INPUT_CONTEXT_PUSHES),
			)
		}
		luau.pushlightuserdatatagged(L, rawptr(uintptr(token)), c.int(Light_Tag.Input_Context))
		return 1
	})
	light_method(r, .Input_Context, "pop", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		core.input_contexts_pop(&r.input_actions.contexts, to_input_context(L, 1))
		return 0
	})
	light_method(r, .Input_Context, "is_pushed", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		pushed := core.input_contexts_pushed(&r.input_actions.contexts, to_input_context(L, 1))
		luau.pushboolean(L, b32(pushed != nil))
		return 1
	})
}

// settle_contexts lets go of the held actions whose bindings are quiet: in the input that the scripts read, and in the
// edges that wait for the next fixed tick, so a tap that a tick has not had yet stays held. The script runtime settles
// when it sets its input, and again when a phase or a tick ends, so a pop on quiet input holds nothing into the next
// frame.
@(private)
settle_contexts :: proc(r: ^Runtime) {
	input := r.input
	input.pressed += r.pending_pressed
	input.released += r.pending_released
	for &pad, i in input.gamepads {
		pad.pressed += r.pending_gamepad_pressed[i]
		pad.released += r.pending_gamepad_released[i]
		pad.direction_pressed += r.pending_direction_pressed[i]
		pad.direction_released += r.pending_direction_released[i]
	}
	core.input_contexts_settle(&r.input_actions, &input)
}

// to_input_context is the token of the context push at idx.
@(private)
to_input_context :: proc(L: ^luau.State, idx: c.int) -> core.Input_Context_Token {
	return core.Input_Context_Token(
		uintptr(luau.tolightuserdatatagged(L, idx, c.int(Light_Tag.Input_Context))),
	)
}

// input_context_text is a push's text for tostring: its context's name, or that it was popped.
@(private)
input_context_text :: proc(r: ^Runtime, token: core.Input_Context_Token) -> string {
	contexts := &r.input_actions.contexts
	push := core.input_contexts_pushed(contexts, token)
	if push == nil {
		return "InputContext(popped)"
	}
	return fmt.aprintf(
		"InputContext(%s)",
		core.input_context_name(contexts, int(push.ctx)),
		allocator = frame(r),
	)
}

// The kinds of Input_Context_Owner that the script runtime gives.
@(private = "file")
Owner_Kind :: enum u8 {
	None,
	Behaviour,
	// One run of a main script: its waiter's index and sequence number, so a restart is a new owner.
	Main_Script,
	Action,
}

// context_owner is a behaviour as the owner of the contexts that it pushes.
@(private)
context_owner :: proc(h: Instance_Handle) -> core.Input_Context_Owner {
	return {u8(Owner_Kind.Behaviour), h.index, u64(h.generation)}
}

// main_context_owner is a run of a main script, by the waiter that runs it, as an owner.
@(private)
main_context_owner :: proc(id: Waiter_Id) -> core.Input_Context_Owner {
	return {u8(Owner_Kind.Main_Script), u32(id.index), id.seq}
}

// action_context_owner is a script action as an owner.
@(private)
action_context_owner :: proc(h: Action_Handle) -> core.Input_Context_Owner {
	return {u8(Owner_Kind.Action), h.index, u64(h.generation)}
}

// running_owner is the owner of the code that runs, and its name for the editor: the behaviour whose callback or
// coroutine runs, the script action whose callback runs, the coroutine of an action, or the run of a main script. Code
// that none of them runs, such as a predicate, owns nothing, and pops its own pushes.
@(private = "file")
running_owner :: proc(r: ^Runtime, L: ^luau.State) -> (core.Input_Context_Owner, string) {
	if i := instance_at(r, r.writer); r.writer != {} && i != nil {
		return context_owner(r.writer), instance_class(r, L, i, "__behaviour")
	}
	if a := action_at(r, r.running_action); a != nil {
		return action_context_owner(r.running_action), table_class(r, L, a.table, "__action")
	}
	if r.current_waiter >= 0 {
		w := &r.waiters[r.current_waiter]
		switch owner in w.owner {
		case Main_Script:
			return main_context_owner({r.current_waiter, w.seq}), "script"
		case Action_Handle:
			if a := action_at(r, owner); a != nil {
				return action_context_owner(owner), table_class(r, L, a.table, "__action")
			}
		case Instance_Handle:
		}
	}
	return {}, "script"
}

// owner_live is whether an owner has not ended.
@(private = "file")
owner_live :: proc(r: ^Runtime, owner: core.Input_Context_Owner) -> bool {
	switch Owner_Kind(owner.kind) {
	case .None:
		return true
	case .Behaviour:
		return instance_at(r, {owner.index, u32(owner.generation)}) != nil
	case .Main_Script:
		if int(owner.index) >= r.waiter_used {
			return false
		}
		w := &r.waiters[owner.index]
		return w.status != .Free && w.seq == owner.generation
	case .Action:
		return action_at(r, {owner.index, u32(owner.generation)}) != nil
	}
	return false
}

// pop_orphaned_contexts takes off the pushes of the behaviours, main scripts and script actions that are gone, however
// they went, so a lost handle cannot lock the input.
@(private)
pop_orphaned_contexts :: proc(r: ^Runtime) {
	contexts := &r.input_actions.contexts
	for i := 0; i < contexts.push_count; {
		owner := contexts.pushes[i].owner
		if !owner_live(r, owner) {
			// Every push of the owner goes, and none of them is before i, so i is the next one now.
			core.input_contexts_pop_owned(contexts, owner)
			continue
		}
		i += 1
	}
}

// instance_class is the class name of a behaviour, in frame memory.
@(private = "file")
instance_class :: proc(r: ^Runtime, L: ^luau.State, i: ^Instance, field: cstring) -> string {
	return table_class(r, L, i.table, field)
}

// table_class is the name in a field of the class of an instance table, in frame memory, or "script".
@(private = "file")
table_class :: proc(r: ^Runtime, L: ^luau.State, table: c.int, field: cstring) -> string {
	luau.getref(L, table)
	defer luau.pop(L, 1)
	if !luau.getmetatable(L, -1) {
		return "script"
	}
	defer luau.pop(L, 1)
	luau.rawgetfield(L, -1, field)
	defer luau.pop(L, 1)
	if luau.type(L, -1) != .STRING {
		return "script"
	}
	return fmt.aprintf("%s", luau.toodinstring(L, -1), allocator = frame(r))
}

// check_action_name is the string argument at idx, for an action name.
@(private = "file")
check_action_name :: proc(L: ^luau.State, idx: c.int) -> string {
	n: c.size_t
	s := luau.L_checklstring(L, idx, &n)
	return string(s[:n])
}

// check_action is the index of the action that argument idx names. An unknown name raises an error that has it.
@(private = "file")
check_action :: proc(L: ^luau.State, idx: c.int) -> int {
	name := check_action_name(L, idx)
	index := core.input_actions_find(&runtime_of(L).input_actions, name)
	if index < 0 {
		luau.L_errorL(L, "unknown input action '%.*s'", c.int(len(name)), raw_data(name))
	}
	return index
}

// check_action_and_pad reads the arguments of a query: the action's name, and an optional pad from 1 to 4.
@(private = "file")
check_action_and_pad :: proc(L: ^luau.State) -> (index: int, pad: Maybe(int)) {
	index = check_action(L, 1)
	if !luau.isnoneornil(L, 2) {
		pad = check_pad(L, 2)
	}
	return
}

// check_pad is the slot, from 0, of the pad from 1 to 4 at idx.
@(private = "file")
check_pad :: proc(L: ^luau.State, idx: c.int) -> int {
	n := luau.L_checkinteger(L, idx)
	if n < 1 || n > core.MAX_GAMEPADS {
		luau.L_argerrorL(L, idx, "a gamepad slot from 1 to 4 expected")
	}
	return int(n - 1)
}

// read_bindings parses the strings of the array table at idx. A string that is not a binding, a value that is not a
// string, or more than MAX_ACTION_BINDINGS of them raises an error.
@(private = "file")
read_bindings :: proc(
	L: ^luau.State,
	idx: c.int,
	bindings: ^[core.MAX_ACTION_BINDINGS]core.Binding,
) -> int {
	n := int(luau.objlen(L, idx))
	if n > core.MAX_ACTION_BINDINGS {
		luau.L_errorL(L, "at most %d bindings expected", c.int(core.MAX_ACTION_BINDINGS))
	}
	for i in 0 ..< n {
		luau.rawgeti(L, idx, c.int(i + 1))
		if luau.type(L, -1) != .STRING {
			luau.L_errorL(L, "binding %d is not a string", c.int(i + 1))
		}
		text := luau.toodinstring(L, -1)
		b, ok := core.binding_parse(text)
		if !ok {
			luau.L_errorL(L, "'%.*s' is not a binding", c.int(len(text)), raw_data(text))
		}
		bindings[i] = b
		luau.pop(L, 1)
	}
	return n
}
