package asset_format

import "core:mem"

import "cinnabar:core/layout"

// A decision is a .decision text file: how an agent picks its actions, by one technique (a behavior tree, utility,
// GOAP or HTN) over a blackboard. Its conditions, action references and blackboard writes are shared by every
// technique, and the technique's own part is opaque here (see docs/content/kinds/decisions.md).
DECISION_EXTENSION :: ".decision"

// An index into a decision's records that is not there: a node without a condition or an action.
DECISION_NONE :: max(u32)
// A decision's module state is at most this many bytes, in each agent.
MAX_DECISION_STATE :: 4096
// A condition's stack is at most this deep.
MAX_DECISION_STACK :: 16

Decision_Technique :: enum u32 {
	Behavior_Tree,
	Utility,
	Goap,
	Htn,
}

// DECISION_TECHNIQUE_NAMES are the techniques as a decision's text names them.
DECISION_TECHNIQUE_NAMES :: [Decision_Technique]string {
	.Behavior_Tree = "behavior_tree",
	.Utility       = "utility",
	.Goap          = "goap",
	.Htn           = "htn",
}

// Decision_Node is a node of the decision's text, with the shared parts that it has. Its technique's data refers to
// it by its index.
Decision_Node :: struct {
	// The node's ID in the text, for the editor and debuggers.
	id:          u32,
	// The node's kind in the text, such as "selector", which the technique reads.
	kind:        Slice,
	// Its `when`, or DECISION_NONE.
	condition:   u32,
	// Its `action`, or DECISION_NONE.
	action:      u32,
	// Its `set` lines, a range of the writes.
	first_write: u32,
	write_count: u32,
}
#assert(size_of(Decision_Node) == 28)

// Decision_Condition is a condition: a range of the ops, which leave one bool.
Decision_Condition :: struct {
	first_op: u32,
	op_count: u32,
}
#assert(size_of(Decision_Condition) == 8)

// Decision_Op_Code is a step of a condition, which is in postfix order on a stack. Key pushes the value at a slot, and
// Constant a constant; Self pushes the agent. Distance pops two places, each an entity or a position, and pushes the
// meters between them, or infinity when an entity is none, dead or has no Transform. A comparison pops two values of
// its op's type and pushes a bool. And and Or pop two bools, and Not one.
Decision_Op_Code :: enum u8 {
	Key,
	Constant,
	Self,
	Distance,
	Less,
	Less_Equal,
	Greater,
	Greater_Equal,
	Equal,
	Not_Equal,
	And,
	Or,
	Not,
}

// Decision_Op is a step of a condition. type is the type of the values that a comparison compares, where Float
// compares numbers, so a Float and an Int: Float, Bool, Enum or Entity. operand is a Key's slot or a Constant's index.
Decision_Op :: struct {
	code:    Decision_Op_Code,
	type:    u8,
	padding: u16,
	operand: u32,
}
#assert(size_of(Decision_Op) == 8)

// Decision_Constant is a value in the text: value holds its bytes as the agent's values hold its type's, and a
// String's text is text. An Entity constant is none.
Decision_Constant :: struct {
	type:  Blackboard_Type,
	text:  Slice,
	value: [BLACKBOARD_VALUE_SIZE]byte,
}
#assert(size_of(Decision_Constant) == 36)

// Decision_Action is an action reference: an action by its name, and its arguments, a range of the args.
Decision_Action :: struct {
	name:      Slice,
	// animation_graph_hash of the name, which the runtime finds the action by.
	hash:      u32,
	first_arg: u32,
	arg_count: u32,
}
#assert(size_of(Decision_Action) == 20)

// Decision_Source is where an argument's or a write's value comes from: a constant, by its index, the value at a slot,
// or the agent itself.
Decision_Source :: enum u32 {
	Constant,
	Key,
	Self,
}

// Decision_Arg is an argument of an action reference: its name, which the action's parameters name, and its value.
// type is the value's type, a String only for a constant.
Decision_Arg :: struct {
	name:   Slice,
	hash:   u32,
	source: Decision_Source,
	index:  u32,
	type:   Blackboard_Type,
}
#assert(size_of(Decision_Arg) == 24)

// Decision_Write is a `set <key> = <value>`: the slot that it writes and its value, of the key's type.
Decision_Write :: struct {
	key:    u32,
	source: Decision_Source,
	index:  u32,
}
#assert(size_of(Decision_Write) == 12)

// Decision_Blob is the start of a decision blob (see docs/content/blobs-and-loading.md#blob-format).
Decision_Blob :: struct {
	header:         Blob_Header,
	technique:      Decision_Technique,
	// The bytes of module state that each agent has, which the technique's reader sized.
	state_size:     u32,
	blackboard:     Guid,
	// The cache key of the blackboard that the decision was cooked against. A decision is used only with a blackboard
	// blob of the same key, since its slots are that blackboard's.
	blackboard_key: u64,
	nodes:          Slice,
	conditions:     Slice,
	ops:            Slice,
	constants:      Slice,
	actions:        Slice,
	args:           Slice,
	writes:         Slice,
	// The technique's own part, which only it reads, aligned to 16.
	technique_data: Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/ai/guard.decision".
	source_path:    Slice,
}

decision_layout :: proc() -> u64 {
	h := layout.hash(Decision_Blob)
	h ~= layout.hash(Decision_Node) * 31
	h ~= layout.hash(Decision_Condition) * 961
	h ~= layout.hash(Decision_Op) * 29791
	h ~= layout.hash(Decision_Constant) * 923521
	h ~= layout.hash(Decision_Action) * 28629151
	h ~= layout.hash(Decision_Arg) * 887503681
	h ~= layout.hash(Decision_Write) * 27512614111
	return h
}

// decision_view checks a decision blob: its header, its layout, that its slices and records are inside it, and that
// every index between its records is in range. It does not check slots against a blackboard: decision_check does,
// with the blackboard's blob.
decision_view :: proc(data: []byte) -> (blob: ^Decision_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Decision || header.layout != decision_layout() || len(data) < size_of(Decision_Blob) {
		return
	}
	blob = (^Decision_Blob)(raw_data(data))
	inside :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(data)) && int(s.size) % size == 0 && int(s.offset) % align == 0
	}
	if blob.technique > max(Decision_Technique) || blob.state_size > MAX_DECISION_STATE ||
	   !inside(data, blob.nodes, size_of(Decision_Node), align_of(Decision_Node)) ||
	   !inside(data, blob.conditions, size_of(Decision_Condition), align_of(Decision_Condition)) ||
	   !inside(data, blob.ops, size_of(Decision_Op), align_of(Decision_Op)) ||
	   !inside(data, blob.constants, size_of(Decision_Constant), align_of(Decision_Constant)) ||
	   !inside(data, blob.actions, size_of(Decision_Action), align_of(Decision_Action)) ||
	   !inside(data, blob.args, size_of(Decision_Arg), align_of(Decision_Arg)) ||
	   !inside(data, blob.writes, size_of(Decision_Write), align_of(Decision_Write)) ||
	   !inside(data, blob.technique_data, 1, 16) || !inside(data, blob.source_path, 1, 1) {
		return nil, false
	}
	range :: proc(first, count: u32, length: int) -> bool {
		return u64(first) + u64(count) <= u64(length)
	}
	optional :: proc(index: u32, length: int) -> bool {
		return index == DECISION_NONE || int(index) < length
	}
	conditions := decision_conditions(data, blob)
	ops := decision_ops(data, blob)
	constants := decision_constants(data, blob)
	actions := decision_actions(data, blob)
	args := decision_args(data, blob)
	writes := decision_writes(data, blob)
	for n in decision_nodes(data, blob) {
		if !inside(data, n.kind, 1, 1) || !optional(n.condition, len(conditions)) || !optional(n.action, len(actions)) ||
		   !range(n.first_write, n.write_count, len(writes)) {
			return nil, false
		}
	}
	for c in conditions {
		if c.op_count == 0 || !range(c.first_op, c.op_count, len(ops)) {
			return nil, false
		}
	}
	for o in ops {
		if o.code > max(Decision_Op_Code) || (o.code == .Constant && int(o.operand) >= len(constants)) {
			return nil, false
		}
	}
	for c in constants {
		if c.type > max(Blackboard_Type) || !inside(data, c.text, 1, 1) {
			return nil, false
		}
	}
	for a in actions {
		if !inside(data, a.name, 1, 1) || !range(a.first_arg, a.arg_count, len(args)) {
			return nil, false
		}
	}
	for a in args {
		if !inside(data, a.name, 1, 1) || a.source > max(Decision_Source) || a.type > max(Blackboard_Type) ||
		   (a.source == .Constant && int(a.index) >= len(constants)) {
			return nil, false
		}
	}
	for w in writes {
		if w.source > max(Decision_Source) || (w.source == .Constant && int(w.index) >= len(constants)) {
			return nil, false
		}
	}
	return blob, true
}

// decision_check checks that a decision fits a blackboard: that it was cooked against it, and that every slot that it
// names is one of its keys, of the type that the decision expects.
decision_check :: proc(data: []byte, blob: ^Decision_Blob, board_data: []byte, board: ^Blackboard_Blob) -> bool {
	if blob.blackboard != board.header.guid || blob.blackboard_key != board.header.key {
		return false
	}
	keys := blackboard_keys(board_data, board)
	for o in decision_ops(data, blob) {
		if o.code == .Key && int(o.operand) >= len(keys) {
			return false
		}
	}
	for a in decision_args(data, blob) {
		if a.source == .Key && (int(a.index) >= len(keys) || keys[a.index].type != a.type) {
			return false
		}
	}
	for w in decision_writes(data, blob) {
		if int(w.key) >= len(keys) || (w.source == .Key && (int(w.index) >= len(keys) || keys[w.index].type != keys[w.key].type)) {
			return false
		}
	}
	return true
}

decision_nodes :: proc "contextless" (data: []byte, blob: ^Decision_Blob) -> []Decision_Node {
	bytes := blob_bytes(data, blob.nodes)
	return ([^]Decision_Node)(raw_data(bytes))[:len(bytes) / size_of(Decision_Node)]
}

decision_conditions :: proc "contextless" (data: []byte, blob: ^Decision_Blob) -> []Decision_Condition {
	bytes := blob_bytes(data, blob.conditions)
	return ([^]Decision_Condition)(raw_data(bytes))[:len(bytes) / size_of(Decision_Condition)]
}

decision_ops :: proc "contextless" (data: []byte, blob: ^Decision_Blob) -> []Decision_Op {
	bytes := blob_bytes(data, blob.ops)
	return ([^]Decision_Op)(raw_data(bytes))[:len(bytes) / size_of(Decision_Op)]
}

decision_constants :: proc "contextless" (data: []byte, blob: ^Decision_Blob) -> []Decision_Constant {
	bytes := blob_bytes(data, blob.constants)
	return ([^]Decision_Constant)(raw_data(bytes))[:len(bytes) / size_of(Decision_Constant)]
}

decision_actions :: proc "contextless" (data: []byte, blob: ^Decision_Blob) -> []Decision_Action {
	bytes := blob_bytes(data, blob.actions)
	return ([^]Decision_Action)(raw_data(bytes))[:len(bytes) / size_of(Decision_Action)]
}

decision_args :: proc "contextless" (data: []byte, blob: ^Decision_Blob) -> []Decision_Arg {
	bytes := blob_bytes(data, blob.args)
	return ([^]Decision_Arg)(raw_data(bytes))[:len(bytes) / size_of(Decision_Arg)]
}

decision_writes :: proc "contextless" (data: []byte, blob: ^Decision_Blob) -> []Decision_Write {
	bytes := blob_bytes(data, blob.writes)
	return ([^]Decision_Write)(raw_data(bytes))[:len(bytes) / size_of(Decision_Write)]
}

decision_technique_data :: proc "contextless" (data: []byte, blob: ^Decision_Blob) -> []byte {
	return blob_bytes(data, blob.technique_data)
}

Decision_Node_Contents :: struct {
	id:          u32,
	kind:        string,
	condition:   u32,
	action:      u32,
	first_write: u32,
	write_count: u32,
}

Decision_Constant_Contents :: struct {
	type:  Blackboard_Type,
	text:  string,
	value: [BLACKBOARD_VALUE_SIZE]byte,
}

Decision_Action_Contents :: struct {
	name:      string,
	first_arg: u32,
	arg_count: u32,
}

Decision_Arg_Contents :: struct {
	name:   string,
	source: Decision_Source,
	index:  u32,
	type:   Blackboard_Type,
}

// Decision_Contents is a decision as decision_write takes it: its records, with strings for their names.
Decision_Contents :: struct {
	guid:           Guid,
	key:            u64,
	technique:      Decision_Technique,
	state_size:     u32,
	blackboard:     Guid,
	blackboard_key: u64,
	nodes:          []Decision_Node_Contents,
	conditions:     []Decision_Condition,
	ops:            []Decision_Op,
	constants:      []Decision_Constant_Contents,
	actions:        []Decision_Action_Contents,
	args:           []Decision_Arg_Contents,
	writes:         []Decision_Write,
	technique_data: []byte,
	source_path:    string,
}

// decision_write builds a decision blob.
decision_write :: proc(contents: Decision_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Decision_Blob), allocator)
	records :: proc(buffer: ^[dynamic]byte, $T: typeid, count: int) -> Slice {
		return reserve_bytes(buffer, count * size_of(T), align_of(T))
	}
	put :: proc(buffer: ^[dynamic]byte, s: Slice, index: int, record: ^$T) {
		mem.copy(&buffer[int(s.offset) + index * size_of(T)], record, size_of(T))
	}
	text :: proc(buffer: ^[dynamic]byte, s: string) -> Slice {
		return append_bytes(buffer, transmute([]byte)s)
	}
	nodes := records(&buffer, Decision_Node, len(contents.nodes))
	conditions := records(&buffer, Decision_Condition, len(contents.conditions))
	ops := records(&buffer, Decision_Op, len(contents.ops))
	constants := records(&buffer, Decision_Constant, len(contents.constants))
	actions := records(&buffer, Decision_Action, len(contents.actions))
	args := records(&buffer, Decision_Arg, len(contents.args))
	writes := records(&buffer, Decision_Write, len(contents.writes))
	technique_data := reserve_bytes(&buffer, len(contents.technique_data), 16)
	copy(buffer[technique_data.offset:], contents.technique_data)
	for n, i in contents.nodes {
		record := Decision_Node {
			id          = n.id,
			kind        = text(&buffer, n.kind),
			condition   = n.condition,
			action      = n.action,
			first_write = n.first_write,
			write_count = n.write_count,
		}
		put(&buffer, nodes, i, &record)
	}
	for c, i in contents.conditions {
		c := c
		put(&buffer, conditions, i, &c)
	}
	for o, i in contents.ops {
		o := o
		put(&buffer, ops, i, &o)
	}
	for c, i in contents.constants {
		record := Decision_Constant {
			type  = c.type,
			text  = text(&buffer, c.text),
			value = c.value,
		}
		put(&buffer, constants, i, &record)
	}
	for a, i in contents.actions {
		record := Decision_Action {
			name      = text(&buffer, a.name),
			hash      = animation_graph_hash(a.name),
			first_arg = a.first_arg,
			arg_count = a.arg_count,
		}
		put(&buffer, actions, i, &record)
	}
	for a, i in contents.args {
		record := Decision_Arg {
			name   = text(&buffer, a.name),
			hash   = animation_graph_hash(a.name),
			source = a.source,
			index  = a.index,
			type   = a.type,
		}
		put(&buffer, args, i, &record)
	}
	for w, i in contents.writes {
		w := w
		put(&buffer, writes, i, &w)
	}
	source_path := text(&buffer, contents.source_path)
	blob := Decision_Blob {
		header = {magic = BLOB_MAGIC, kind = .Decision, layout = decision_layout(), key = contents.key, guid = contents.guid},
		technique = contents.technique,
		state_size = contents.state_size,
		blackboard = contents.blackboard,
		blackboard_key = contents.blackboard_key,
		nodes = nodes,
		conditions = conditions,
		ops = ops,
		constants = constants,
		actions = actions,
		args = args,
		writes = writes,
		technique_data = technique_data,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
