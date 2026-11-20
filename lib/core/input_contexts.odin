package core

// The contexts that the game can define besides gameplay.
MAX_INPUT_CONTEXTS :: 16
// The pushes that the stacks hold at once, across every player.
MAX_INPUT_CONTEXT_PUSHES :: 32
INPUT_CONTEXT_PUSHER_CAPACITY :: 32

// GAMEPLAY_CONTEXT is the context under every stack. It allows every action, and the game cannot define it again.
GAMEPLAY_CONTEXT :: "gameplay"

// Input_Action_Set is a set of actions by their index in Input_Actions.
Input_Action_Set :: bit_set[0 ..< MAX_INPUT_ACTIONS;u32]

// Input_Players is a set of players. A player is a gamepad slot, and the keyboard is the first player's.
Input_Players :: bit_set[0 ..< MAX_GAMEPADS;u8]

EVERY_PLAYER :: Input_Players{0, 1, 2, 3}

// Input_Context_Mode says what a context does with the actions that it does not name.
Input_Context_Mode :: enum u8 {
	// It blocks them.
	Only,
	// The context below it in the stack decides for them.
	Pass,
	// It allows every action, named or not.
	All,
}

// Input_Context is a named set of actions that a push allows. It holds no strings or pointers, so it survives a code
// reload.
Input_Context :: struct {
	name:        [INPUT_ACTION_NAME_CAPACITY]u8,
	name_length: u8,
	mode:        Input_Context_Mode,
	allows:      Input_Action_Set,
}

// Input_Context_Token is what a push gives, and what pops it. 0 is no push. A token is never given twice, so a pop
// through a stale one does nothing.
Input_Context_Token :: distinct u32

// Input_Context_Owner is what pushed, which pops its pushes when it ends: the script runtime's behaviours, main
// scripts and script actions, each by its kind, index and generation. The zero value is a push that its pusher pops
// itself.
Input_Context_Owner :: struct {
	kind:       u8,
	index:      u32,
	generation: u64,
}

// Input_Context_Push is one push: on the stack of each of its players, at the same place in push order.
Input_Context_Push :: struct {
	token:         Input_Context_Token,
	// 0 is gameplay, and n is defined[n - 1].
	ctx:           u8,
	players:       Input_Players,
	owner:         Input_Context_Owner,
	// Who pushed, for the editor: a behaviour's class, or what native code names itself.
	pusher:        [INPUT_CONTEXT_PUSHER_CAPACITY]u8,
	pusher_length: u8,
}

// Input_Contexts is the defined contexts and each player's stack. The stacks share one array in push order, so each
// player's stack is the pushes that name it. The zero value has no pushes, so every action reads as it would without
// contexts.
Input_Contexts :: struct {
	defined:       [MAX_INPUT_CONTEXTS]Input_Context,
	defined_count: int,
	pushes:        [MAX_INPUT_CONTEXT_PUSHES]Input_Context_Push,
	push_count:    int,
	last_token:    Input_Context_Token,
	// For each player, the actions that a change of the stack allowed again, which read as neither pressed nor
	// released until a frame where their bindings are quiet (see input_contexts_settle). Only change_stack adds to it.
	held:          [MAX_GAMEPADS]Input_Action_Set,
}

// input_contexts_find is the index of the context with a name, 0 for gameplay, or -1.
input_contexts_find :: proc "contextless" (contexts: ^Input_Contexts, name: string) -> int {
	if name == GAMEPLAY_CONTEXT {
		return 0
	}
	for &d, i in contexts.defined[:contexts.defined_count] {
		if string(d.name[:d.name_length]) == name {
			return i + 1
		}
	}
	return -1
}

// input_context_name is the name of the context at an index that input_contexts_find gave.
input_context_name :: proc "contextless" (contexts: ^Input_Contexts, index: int) -> string {
	if index == 0 {
		return GAMEPLAY_CONTEXT
	}
	d := &contexts.defined[index - 1]
	return string(d.name[:d.name_length])
}

Input_Context_Error :: enum u8 {
	None,
	Name,
	Gameplay,
	Full,
}

// input_contexts_define makes a context, or gives one that exists its new mode and actions. A context that is on a
// stack changes there at once, and an action that the change allows again is held as a pop's would be. It fails for
// an empty or too long name, for gameplay, and for a full table.
input_contexts_define :: proc "contextless" (
	contexts: ^Input_Contexts,
	name: string,
	mode: Input_Context_Mode,
	allows: Input_Action_Set,
) -> (
	index: int,
	err: Input_Context_Error,
) {
	if len(name) == 0 || len(name) > INPUT_ACTION_NAME_CAPACITY {
		return -1, .Name
	}
	if name == GAMEPLAY_CONTEXT {
		return -1, .Gameplay
	}
	index = input_contexts_find(contexts, name)
	if index < 0 {
		if contexts.defined_count >= MAX_INPUT_CONTEXTS {
			return -1, .Full
		}
		contexts.defined_count += 1
		index = contexts.defined_count
		d := &contexts.defined[index - 1]
		d^ = {}
		copy(d.name[:], name)
		d.name_length = u8(len(name))
	}
	change_stack(contexts, Context_Define{index, mode, allows})
	return index, .None
}

// input_contexts_push puts a context on top of each player's stack. pusher names who pushed, for the editor, and is
// cut to INPUT_CONTEXT_PUSHER_CAPACITY bytes. It fails, with the zero token, for an unknown context, no players, or
// MAX_INPUT_CONTEXT_PUSHES pushes on the stacks.
input_contexts_push :: proc "contextless" (
	contexts: ^Input_Contexts,
	index: int,
	players: Input_Players = EVERY_PLAYER,
	pusher: string = "",
	owner: Input_Context_Owner = {},
) -> Input_Context_Token {
	if index < 0 || index > contexts.defined_count || players == {} {
		return 0
	}
	if contexts.push_count >= MAX_INPUT_CONTEXT_PUSHES {
		return 0
	}
	contexts.last_token += 1
	if contexts.last_token == 0 {
		contexts.last_token = 1
	}
	push := Input_Context_Push {
		token   = contexts.last_token,
		ctx     = u8(index),
		players = players,
		owner   = owner,
	}
	push.pusher_length = u8(copy(push.pusher[:], pusher))
	change_stack(contexts, push)
	return push.token
}

// input_contexts_pop takes a push off the stacks, wherever it is in them, and is whether it was there. A stale or zero
// token does nothing.
input_contexts_pop :: proc "contextless" (
	contexts: ^Input_Contexts,
	token: Input_Context_Token,
) -> bool {
	if token == 0 || input_contexts_pushed(contexts, token) == nil {
		return false
	}
	change_stack(contexts, Context_Pop{token = token})
	return true
}

// input_contexts_pop_owned takes off every push of an owner.
input_contexts_pop_owned :: proc "contextless" (
	contexts: ^Input_Contexts,
	owner: Input_Context_Owner,
) {
	if owner != {} {
		change_stack(contexts, Context_Pop{owner = owner})
	}
}

// input_contexts_clear takes off every push, for a new script VM.
input_contexts_clear :: proc "contextless" (contexts: ^Input_Contexts) {
	change_stack(contexts, Context_Pop{every = true})
}

// input_contexts_pushed is the push of a token, or nil when it is not on the stacks.
input_contexts_pushed :: proc "contextless" (
	contexts: ^Input_Contexts,
	token: Input_Context_Token,
) -> ^Input_Context_Push {
	if token == 0 {
		return nil
	}
	for &p in contexts.pushes[:contexts.push_count] {
		if p.token == token {
			return &p
		}
	}
	return nil
}

// input_context_pusher is who made a push.
input_context_pusher :: proc "contextless" (push: ^Input_Context_Push) -> string {
	return string(push.pusher[:push.pusher_length])
}

// input_contexts_allows is whether a player's stack lets an action through: the top push that names the player and
// does not pass the action down decides, and gameplay, under every stack, allows it.
input_contexts_allows :: proc "contextless" (
	contexts: ^Input_Contexts,
	player: int,
	action: int,
) -> bool {
	#reverse for &p in contexts.pushes[:contexts.push_count] {
		if player not_in p.players {
			continue
		}
		if p.ctx == 0 {
			return true
		}
		d := &contexts.defined[p.ctx - 1]
		switch d.mode {
		case .All:
			return true
		case .Only:
			return action in d.allows
		case .Pass:
			if action in d.allows {
				return true
			}
		}
	}
	return true
}

// allowed is the actions that a player's stack lets through.
@(private = "file")
allowed :: proc "contextless" (contexts: ^Input_Contexts, player: int) -> (set: Input_Action_Set) {
	for action in 0 ..< MAX_INPUT_ACTIONS {
		if input_contexts_allows(contexts, player, action) {
			set += {action}
		}
	}
	return
}

@(private = "file")
Context_Define :: struct {
	index:  int,
	mode:   Input_Context_Mode,
	allows: Input_Action_Set,
}

// Context_Pop takes off the push of a token, every push of an owner, or every push.
@(private = "file")
Context_Pop :: struct {
	token: Input_Context_Token,
	owner: Input_Context_Owner,
	every: bool,
}

@(private = "file")
Context_Change :: union {
	Input_Context_Push,
	Context_Pop,
	Context_Define,
}

// change_stack is the one writer of the pushes and of what the defined contexts allow. An action that a player's
// stack blocked before the change and allows after it is held, so a key that is down as a cutscene ends does not fire.
@(private = "file")
change_stack :: proc "contextless" (contexts: ^Input_Contexts, change: Context_Change) {
	before: [MAX_GAMEPADS]Input_Action_Set
	for player in 0 ..< MAX_GAMEPADS {
		before[player] = allowed(contexts, player)
	}
	switch c in change {
	case Input_Context_Push:
		contexts.pushes[contexts.push_count] = c
		contexts.push_count += 1
	case Context_Pop:
		kept := 0
		for p in contexts.pushes[:contexts.push_count] {
			if !(c.every ||
				   (c.token != 0 && p.token == c.token) ||
				   (c.owner != {} && p.owner == c.owner)) {
				contexts.pushes[kept] = p
				kept += 1
			}
		}
		contexts.push_count = kept
	case Context_Define:
		d := &contexts.defined[c.index - 1]
		d.mode = c.mode
		d.allows = c.allows
	}
	for player in 0 ..< MAX_GAMEPADS {
		contexts.held[player] += allowed(contexts, player) - before[player]
	}
}

// input_contexts_settle lets go of the held actions whose bindings are quiet for their player: none down, pressed or
// released. Call it each time the input that actions read changes, before they are read.
input_contexts_settle :: proc "contextless" (actions: ^Input_Actions, input: ^Input) {
	contexts := &actions.contexts
	for player in 0 ..< MAX_GAMEPADS {
		for action in contexts.held[player] {
			if action >= actions.count || !player_active(actions, input, action, player) {
				contexts.held[player] -= {action}
			}
		}
	}
}

// player_active is whether any binding of an action is down, pressed or released on a player's inputs.
@(private = "file")
player_active :: proc "contextless" (
	actions: ^Input_Actions,
	input: ^Input,
	action: int,
	player: int,
) -> bool {
	a := &actions.items[action]
	for b in a.current[:a.current_count] {
		for state in Binding_State {
			if player_binding_state(input, b, state, player, player == 0) {
				return true
			}
		}
	}
	return false
}
